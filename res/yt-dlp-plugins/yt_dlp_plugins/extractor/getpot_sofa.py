# Sofa's PO token provider for yt-dlp: asks the sofa-yt sidecar (res/sofa-yt, GET /pot), which mints
# with its BotGuard instance - so the yt-dlp fallback and the sidecar present ONE web identity to
# YouTube, and no separate token server is needed (it replaced bgutil-ytdlp-pot-provider + its node
# server, 2026-11-05). The sidecar's address comes per request from Sofa (env SOFA_POT_URL, set by
# ytresolver.py). Without the sidecar the request is rejected and yt-dlp goes on without a token.
from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request

from yt_dlp.extractor.youtube.pot.provider import (
    ExternalRequestFeature,
    PoTokenContext,
    PoTokenProvider,
    PoTokenProviderError,
    PoTokenProviderRejectedRequest,
    PoTokenRequest,
    PoTokenResponse,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot.utils import WEBPO_CLIENTS, get_webpo_content_binding


@register_provider
class SofaPTP(PoTokenProvider):
    PROVIDER_VERSION = '1.0.0'
    BUG_REPORT_LOCATION = 'https://github.com/robertkleinschuster/sofa/issues'
    _SUPPORTED_CLIENTS = WEBPO_CLIENTS
    _SUPPORTED_CONTEXTS = (PoTokenContext.GVS, PoTokenContext.PLAYER, PoTokenContext.SUBS)
    # the plugin itself only talks to 127.0.0.1; Sofa runs yt-dlp without TLS verification
    _SUPPORTED_EXTERNAL_REQUEST_FEATURES = (ExternalRequestFeature.DISABLE_TLS_VERIFICATION,)
    _TIMEOUT = 20.0

    @staticmethod
    def _base():
        return os.environ.get('SOFA_POT_URL', '')

    def is_available(self) -> bool:
        return bool(self._base())

    def _real_request_pot(self, request: PoTokenRequest) -> PoTokenResponse:
        base = self._base()
        if not base:
            raise PoTokenProviderRejectedRequest('sofa-yt sidecar not running')
        binding = get_webpo_content_binding(request)[0]
        if not binding:
            raise PoTokenProviderRejectedRequest('no content binding')
        url = base + '/pot?' + urllib.parse.urlencode({'binding': binding})
        try:
            with urllib.request.urlopen(url, timeout=self._TIMEOUT) as r:
                j = json.load(r)
        except urllib.error.HTTPError as e:
            try:
                msg = json.load(e).get('error')
            except Exception:
                msg = None
            raise PoTokenProviderError(f'sofa-yt /pot: {msg or e}') from e
        except Exception as e:
            raise PoTokenProviderError(f'sofa-yt /pot unreachable: {e!r}') from e
        if not j.get('poToken'):
            raise PoTokenProviderError('sofa-yt /pot answered without a token')
        self.logger.trace(f'PO token for {request.context.value} via sofa-yt')
        return PoTokenResponse(po_token=j['poToken'])


@register_preference(SofaPTP)
def sofa_getpot_preference(provider, request):
    return 200
