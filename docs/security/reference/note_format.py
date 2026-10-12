#!/usr/bin/env python3
"""Reference implementation of the Circuit encrypted note format (CNT1).

The board (C++) and the Android app (Dart) must agree with this byte for byte.
Run this file to regenerate docs/security/test-vectors.json.
"""

import json
import struct
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"CNT1"
VERSION = 1
HEADER_LEN = 28
TAG_LEN = 16
CHUNK = 4096


def header(key_id, note_id, chunk=CHUNK, rate=16000, channels=1, bits=16) -> bytes:
    out = MAGIC + struct.pack("<BBH", VERSION, 0, HEADER_LEN) + struct.pack("<II", key_id, note_id)
    out += struct.pack("<IHHI", rate, channels, bits, chunk)
    assert len(out) == HEADER_LEN
    return out


def _nonce_aad(hdr, note_id, index):
    return struct.pack("<IQ", note_id, index), hdr + struct.pack("<Q", index)


def encrypt(master, key_id, note_id, pcm, chunk=CHUNK, rate=16000, channels=1, bits=16) -> bytes:
    hdr = header(key_id, note_id, chunk, rate, channels, bits)
    aes = AESGCM(master)
    out = hdr
    for index, pos in enumerate(range(0, len(pcm), chunk)):
        nonce, aad = _nonce_aad(hdr, note_id, index)
        out += aes.encrypt(nonce, pcm[pos : pos + chunk], aad)  # ciphertext || tag
    return out


def decrypt(master, blob: bytes):
    """Returns (pcm, fields). Raises ValueError on any tampering or a wrong key."""
    if len(blob) < HEADER_LEN or blob[:4] != MAGIC:
        raise ValueError("not a CNT1 file")
    version, _res, hlen = struct.unpack_from("<BBH", blob, 4)
    key_id, note_id, rate, channels, bits, chunk = struct.unpack_from("<IIIHHI", blob, 8)
    if version != VERSION or hlen != HEADER_LEN or chunk == 0:
        raise ValueError("unsupported file")
    hdr = blob[:HEADER_LEN]
    aes = AESGCM(master)
    pcm, pos, index = b"", HEADER_LEN, 0
    while pos < len(blob):
        take = min(chunk + TAG_LEN, len(blob) - pos)
        if take < TAG_LEN:
            raise ValueError("short chunk")
        nonce, aad = _nonce_aad(hdr, note_id, index)
        try:
            pcm += aes.decrypt(nonce, blob[pos : pos + take], aad)
        except Exception:
            raise ValueError("authentication failed")
        pos += take
        index += 1
    return pcm, dict(key_id=key_id, note_id=note_id, rate=rate, channels=channels, bits=bits, chunk=chunk)


MOMENTS_FLAG = 0x80000000  # the Moments file's header note id is the part's note id OR this
MOMENTS_MAX = 120


def encrypt_moments(master, key_id, note_id, offsets_ms) -> bytes:
    """The sealed Moments file of one part: offsets in ms from the start of that part."""
    if not 0 < len(offsets_ms) <= MOMENTS_MAX:
        raise ValueError("1 to %d moments" % MOMENTS_MAX)
    payload = struct.pack("<I", len(offsets_ms)) + b"".join(struct.pack("<I", ms) for ms in offsets_ms)
    return encrypt(master, key_id, note_id | MOMENTS_FLAG, payload, rate=0, channels=0, bits=0)


def decrypt_moments(master, note_id, blob: bytes):
    """Returns the offsets. Raises ValueError if the file is not this note's, or was changed."""
    if len(blob) < HEADER_LEN:
        raise ValueError("not a CNT1 file")
    if struct.unpack_from("<I", blob, 12)[0] != (note_id | MOMENTS_FLAG):
        raise ValueError("moments file of another note")
    payload, fields = decrypt(master, blob)
    if (fields["rate"], fields["channels"], fields["bits"]) != (0, 0, 0) or len(payload) < 4:
        raise ValueError("not a moments file")
    (count,) = struct.unpack_from("<I", payload)
    if not 0 < count <= MOMENTS_MAX or len(payload) != 4 + 4 * count:
        raise ValueError("bad moments payload")
    return list(struct.unpack_from("<%dI" % count, payload, 4))


def wav_from_pcm(pcm: bytes, rate=16000, channels=1, bits=16) -> bytes:
    block = channels * bits // 8
    return (
        b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * block, block, bits)
        + b"data" + struct.pack("<I", len(pcm)) + pcm
    )


def vectors():
    master = bytes(range(32))
    cases = []
    for name, pcm in (
        ("three chunks, short last", bytes(i % 251 for i in range(150))),
        ("exact multiple of the chunk size", bytes(i % 251 for i in range(128))),
    ):
        blob = encrypt(master, 0x01020304, 7, pcm, chunk=64)
        cases.append({"name": name, "plaintextHex": pcm.hex(), "fileHex": blob.hex()})
    offsets = [512, 9216, 23296, 59999]
    moments = {
        "noteId": 7,
        "offsetsMs": offsets,
        "fileHex": encrypt_moments(master, 0x01020304, 7, offsets).hex(),
    }
    return {"format": "CNT1", "masterKeyHex": master.hex(), "keyId": 0x01020304, "noteId": 7, "chunkSize": 64, "cases": cases,
            "moments": moments}


if __name__ == "__main__":
    target = Path(__file__).resolve().parents[1] / "test-vectors.json"
    target.write_text(json.dumps(vectors(), indent=2) + "\n")
    print("wrote", target)
