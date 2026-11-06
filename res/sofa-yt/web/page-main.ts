// The engine in the youtube.com page, loaded by Sofa's Firefox extension as a content script in the
// page's world at document_start (extension/manifest.json). No global: the page's scripts cannot see
// the engine; it is reached only through the MessagePort handed to the extension's bridge here.
import { sofaEngine } from './engine.ts';
import { HELLO, dispatch, isCommand } from './protocol.ts';

if (window === window.top && location.origin === 'https://www.youtube.com') {
  const channel = new MessageChannel();
  const port = channel.port1;
  port.onmessage = (e: MessageEvent) => {
    if (isCommand(e.data)) void dispatch(sofaEngine, e.data).then((answer) => port.postMessage(answer));
  };
  sofaEngine.connect((json) => port.postMessage({ event: json }));
  // the bridge (isolated world, also document_start) takes the port; delivery is a later task, when
  // both scripts have run and before the page's own scripts can listen
  window.postMessage({ [HELLO]: true }, location.origin, [channel.port2]);
}
