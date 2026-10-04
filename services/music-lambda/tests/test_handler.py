import base64
import json
import os
import sys
import tempfile
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import handler  # noqa: E402

KEY = "test-key-0123456789abcdef0123"


def wav(seconds=1):
    data = b"\x00\x00" * 16000 * seconds
    header = (
        b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVEfmt "
        + (16).to_bytes(4, "little") + (1).to_bytes(2, "little") + (1).to_bytes(2, "little")
        + (16000).to_bytes(4, "little") + (32000).to_bytes(4, "little")
        + (2).to_bytes(2, "little") + (16).to_bytes(2, "little") + b"data"
        + len(data).to_bytes(4, "little")
    )
    return header + data


def event(method="POST", path="/music/identify", body=None, key=KEY, b64=True):
    headers = {"Authorization": f"Bearer {key}"} if key is not None else {}
    if body is None:
        body = wav()
    return {
        "rawPath": path,
        "requestContext": {"http": {"method": method}},
        "headers": headers,
        "body": base64.b64encode(body).decode() if b64 else body.decode("latin-1"),
        "isBase64Encoded": b64,
    }


class Ctx:
    aws_request_id = "req-1"


@pytest.fixture(autouse=True)
def configured(monkeypatch):
    monkeypatch.setenv("SERVICE_KEY", KEY)


def stub_shazam(monkeypatch, result=None, error=None):
    """Replaces the shazamio module so no network or audio decoding happens."""
    seen = {}

    class Shazam:
        async def recognize(self, audio):
            seen["audio"] = bytes(audio)
            if error:
                raise error
            return result

    module = types.ModuleType("shazamio")
    module.Shazam = Shazam
    monkeypatch.setitem(sys.modules, "shazamio", module)
    return seen


TRACK = {
    "track": {
        "title": "Tum Hi Ho",
        "subtitle": "Arijit Singh",
        "url": "https://www.shazam.com/track/1",
        "images": {"coverart": "https://img/small.jpg", "coverarthq": "https://img/hq.jpg"},
        "hub": {
            "providers": [
                {
                    "type": "SPOTIFY",
                    "actions": [
                        {"type": "uri", "uri": "https://open.spotify.com/search/Tum%20Hi%20Ho"},
                        {"type": "uri", "uri": "spotify:search:Tum%20Hi%20Ho"},
                    ],
                },
                {"type": "DEEZER", "actions": [{"type": "uri", "uri": "https://deezer.example/x"}]},
            ]
        },
        "sections": [
            {"metadata": [{"title": "Album", "text": "Aashiqui 2"}, {"title": "Label", "text": "T"}]}
        ],
    }
}


def body(response):
    return json.loads(response["body"])


def test_matched_track_is_normalised(monkeypatch):
    seen = stub_shazam(monkeypatch, TRACK)
    response = handler.lambda_handler(event(), Ctx())
    assert response["statusCode"] == 200
    assert body(response) == {
        "matched": True,
        "title": "Tum Hi Ho",
        "artist": "Arijit Singh",
        "album": "Aashiqui 2",
        "artworkUrl": "https://img/hq.jpg",
        "providerUrl": "https://www.shazam.com/track/1",
        "spotifyUri": "spotify:search:Tum%20Hi%20Ho",
        "spotifyUrl": "https://open.spotify.com/search/Tum%20Hi%20Ho",
    }
    assert seen["audio"][:4] == b"RIFF"


def test_a_track_without_spotify_links_still_matches(monkeypatch):
    track = {"track": {"title": "T", "subtitle": "A", "hub": {"providers": [{"type": "DEEZER", "actions": [{"uri": "https://d/x"}]}]}}}
    stub_shazam(monkeypatch, track)
    result = body(handler.lambda_handler(event(), Ctx()))
    assert result["matched"] is True
    assert result["spotifyUri"] is None and result["spotifyUrl"] is None


def test_odd_provider_data_does_not_break_a_match(monkeypatch):
    track = {"track": {"title": "T", "hub": {"providers": [{"type": "SPOTIFY", "actions": [{"uri": 5}, {}, "junk", {"uri": "ftp://x"}]}, "junk", 7]}}}
    stub_shazam(monkeypatch, track)
    response = handler.lambda_handler(event(), Ctx())
    assert response["statusCode"] == 200
    assert body(response)["matched"] is True
    assert body(response)["spotifyUri"] is None


def test_no_match_is_not_an_error(monkeypatch):
    stub_shazam(monkeypatch, {"matches": []})
    response = handler.lambda_handler(event(), Ctx())
    assert response["statusCode"] == 200
    assert body(response)["matched"] is False
    assert body(response)["title"] is None


def test_upstream_failure_is_a_retryable_502(monkeypatch):
    stub_shazam(monkeypatch, error=RuntimeError("boom with secret detail"))
    response = handler.lambda_handler(event(), Ctx())
    assert response["statusCode"] == 502
    assert body(response) == {"error": "recognition_failed"}
    assert "secret" not in response["body"]


@pytest.mark.parametrize("key", [None, "wrong-key", ""])
def test_missing_or_wrong_key_is_rejected(monkeypatch, key):
    stub_shazam(monkeypatch, TRACK)
    assert handler.lambda_handler(event(key=key), Ctx())["statusCode"] == 401


def test_unconfigured_service_never_accepts(monkeypatch):
    monkeypatch.delenv("SERVICE_KEY")
    stub_shazam(monkeypatch, TRACK)
    assert handler.lambda_handler(event(key=""), Ctx())["statusCode"] == 500


def test_non_wav_is_rejected(monkeypatch):
    stub_shazam(monkeypatch, TRACK)
    response = handler.lambda_handler(event(body=b"ID3" + b"\x00" * 100), Ctx())
    assert response["statusCode"] == 400
    assert body(response) == {"error": "invalid_audio"}


def test_bad_base64_is_rejected(monkeypatch):
    stub_shazam(monkeypatch, TRACK)
    bad = event()
    bad["body"] = "***not base64***"
    assert handler.lambda_handler(bad, Ctx())["statusCode"] == 400


def test_oversize_clip_is_rejected(monkeypatch):
    stub_shazam(monkeypatch, TRACK)
    monkeypatch.setattr(handler, "MAX_AUDIO_BYTES", 1000)
    assert handler.lambda_handler(event(body=wav(1)), Ctx())["statusCode"] == 413


def test_health_checks_the_key(monkeypatch):
    ok = handler.lambda_handler(event("GET", "/music/health", body=b""), Ctx())
    assert ok["statusCode"] == 200 and body(ok) == {"ok": True}
    denied = handler.lambda_handler(event("GET", "/music/health", body=b"", key="x"), Ctx())
    assert denied["statusCode"] == 401


def test_unknown_route(monkeypatch):
    assert handler.lambda_handler(event("GET", "/other", body=b""), Ctx())["statusCode"] == 404


def test_logs_hold_no_audio_or_track_details(monkeypatch, caplog):
    stub_shazam(monkeypatch, TRACK)
    with caplog.at_level("INFO"):
        handler.lambda_handler(event(), Ctx())
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert "req-1" in logged and "matched" in logged
    for private in ("Tum Hi Ho", "Arijit", "Aashiqui", base64.b64encode(wav())[:40].decode()):
        assert private not in logged


def test_request_writes_nothing_to_disk(monkeypatch):
    stub_shazam(monkeypatch, TRACK)
    tmp = Path(tempfile.gettempdir())
    before = {p.name for p in tmp.iterdir()}
    handler.lambda_handler(event(), Ctx())
    assert {p.name for p in tmp.iterdir()} == before
