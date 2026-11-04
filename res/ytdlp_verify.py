"""Prüft eine OpenPGP-Signatur (v4, RSA, binär, abgetrennt) ohne gpg – nur Standardbibliothek.

Sofa lädt yt-dlp ohne TLS-Zertifikatsprüfung (User-Entscheidung 2026-11-04). Die Echtheit sichert
stattdessen die Signatur der yt-dlp-Maintainer über SHA2-256SUMS (Release-Asset SHA2-256SUMS.sig);
ihr öffentlicher Schlüssel (public.key aus dem yt-dlp-Repo) liegt in der App.

  python3 -I ytdlp_verify.py <public.key> <SHA2-256SUMS> <SHA2-256SUMS.sig> <datei> <name>
Exit 0 = Signatur gültig und SHA-256 von <datei> steht in den Summen unter <name>.
"""
import base64
import hashlib
import sys

HASHES = {  # OpenPGP-Hash-ID -> (hashlib-Name, DigestInfo-Präfix nach RFC 8017)
    8: ("sha256", bytes.fromhex("3031300d060960864801650304020105000420")),
    9: ("sha384", bytes.fromhex("3041300d060960864801650304020205000430")),
    10: ("sha512", bytes.fromhex("3051300d060960864801650304020305000440")),
}


def dearmor(data):
    if not data.lstrip().startswith(b"-----BEGIN PGP"):
        return data
    body, started = [], False
    for line in data.decode("ascii").splitlines():
        if line.startswith("-----BEGIN"):
            started = True
            continue
        if line.startswith("-----END"):
            break
        if not started or ":" in line and not body:
            continue  # Kopfzeilen (Version: …)
        if line.startswith("="):
            break  # CRC24
        body.append(line.strip())
    return base64.b64decode("".join(body))


def packets(data):
    i = 0
    while i < len(data):
        h = data[i]
        if not h & 0x80:
            raise ValueError("kein OpenPGP-Paket")
        if h & 0x40:  # neues Format
            tag, i = h & 0x3F, i + 1
            l0 = data[i]
            if l0 < 192:
                n, i = l0, i + 1
            elif l0 < 224:
                n, i = ((l0 - 192) << 8) + data[i + 1] + 192, i + 2
            elif l0 == 255:
                n, i = int.from_bytes(data[i + 1:i + 5], "big"), i + 5
            else:
                raise ValueError("Teil-Längen nicht unterstützt")
        else:  # altes Format
            tag, lt, i = (h >> 2) & 0x0F, h & 3, i + 1
            size = (1, 2, 4)[lt] if lt < 3 else None
            if size is None:
                raise ValueError("unbestimmte Länge nicht unterstützt")
            n, i = int.from_bytes(data[i:i + size], "big"), i + size
        yield tag, data[i:i + n]
        i += n


def mpi(b, o):
    bits = int.from_bytes(b[o:o + 2], "big")
    n = (bits + 7) // 8
    return int.from_bytes(b[o + 2:o + 2 + n], "big"), o + 2 + n


def rsa_keys(keydata):
    """Fingerprint (v4) -> (n, e) für alle RSA-Schlüssel und -Unterschlüssel."""
    keys = {}
    for tag, body in packets(dearmor(keydata)):
        if tag not in (6, 14) or body[0] != 4 or body[5] not in (1, 3):
            continue
        n, o = mpi(body, 6)
        e, o = mpi(body, o)
        fp = hashlib.sha1(b"\x99" + len(body[:o]).to_bytes(2, "big") + body[:o]).digest()
        keys[fp] = (n, e)
    return keys


def subpackets(b):
    i, out = 0, []
    while i < len(b):
        l0 = b[i]
        if l0 < 192:
            n, i = l0, i + 1
        elif l0 < 255:
            n, i = ((l0 - 192) << 8) + b[i + 1] + 192, i + 2
        else:
            n, i = int.from_bytes(b[i + 1:i + 5], "big"), i + 5
        out.append((b[i] & 0x7F, b[i + 1:i + n]))
        i += n
    return out


def verify(keydata, data, sigdata):
    keys = rsa_keys(keydata)
    for tag, s in packets(dearmor(sigdata)):
        if tag != 2 or s[0] != 4 or s[1] != 0 or s[2] != 1 or s[3] not in HASHES:
            continue  # nur v4, Binärdokument, RSA
        hl = int.from_bytes(s[4:6], "big")
        hashed = s[6:6 + hl]
        o = 6 + hl
        ul = int.from_bytes(s[o:o + 2], "big")
        unhashed = s[o + 2:o + 2 + ul]
        o += 2 + ul
        left16 = s[o:o + 2]
        sig, _ = mpi(s, o + 2)
        issuer_fp = [v[1:] for t, v in subpackets(hashed) + subpackets(unhashed) if t == 33 and v[:1] == b"\x04"]
        issuer_id = [v for t, v in subpackets(hashed) + subpackets(unhashed) if t == 16]
        cands = [k for fp, k in keys.items() if fp in issuer_fp or fp[-8:] in issuer_id] or list(keys.values())
        name, prefix = HASHES[s[3]]
        h = hashlib.new(name)
        h.update(data)
        h.update(s[:6 + hl])
        h.update(b"\x04\xff" + (6 + hl).to_bytes(4, "big"))
        digest = h.digest()
        if digest[:2] != left16:
            return False
        for n, e in cands:
            k = (n.bit_length() + 7) // 8
            em = pow(sig, e, n).to_bytes(k, "big")
            t = prefix + digest
            if em == b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t:
                return True
    return False


def main(argv):
    key, sums, sig, path, name = argv[1:6]
    rb = lambda p: open(p, "rb").read()
    if not verify(rb(key), rb(sums), rb(sig)):
        print("Signatur ungültig", file=sys.stderr)
        return 1
    want = None
    for line in rb(sums).decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == name:
            want = parts[0].lower()
    have = hashlib.sha256(rb(path)).hexdigest()
    if want != have:
        print("Prüfsumme passt nicht: %s" % name, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
