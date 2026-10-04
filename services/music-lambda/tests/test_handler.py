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
    monkeypatch.delenv("SPOTIFY_CLIENT_ID", raising=False)
    monkeypatch.delenv("SPOTIFY_CLIENT_SECRET", raising=False)
    handler._spotify_token.update(value=None, expires_at=0.0)


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
        "spotifyTrackUri": None,
        "spotifyTrackUrl": None,
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


# ---- exact Spotify track lookup -------------------------------------------------

import urllib.error  # noqa: E402
import urllib.parse  # noqa: E402


def with_isrc(isrc="USRC17607839", title="Tum Hi Ho", artist="Arijit Singh"):
    return {"track": {"title": title, "subtitle": artist, "isrc": isrc}}


class FakeSpotify:
    """Stands in for accounts.spotify.com and api.spotify.com."""

    def __init__(self, monkeypatch, searches):
        self.calls = []
        self.searches = list(searches)  # one answer per search call
        monkeypatch.setenv("SPOTIFY_CLIENT_ID", "id123")
        monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "secret456")
        monkeypatch.setattr(handler, "_http_json", self)

    def __call__(self, request):
        self.calls.append(request)
        if request.full_url == handler.SPOTIFY_TOKEN_URL:
            return {"access_token": "tok", "expires_in": 3600}
        answer = self.searches.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    def queries(self):
        out = []
        for request in self.calls:
            if request.full_url.startswith(handler.SPOTIFY_SEARCH_URL):
                out.append(urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query)["q"][0])
        return out


def found(track_id, name="Tum Hi Ho"):
    return {"tracks": {"items": [{"id": track_id, "name": name}]}}


NOTHING = {"tracks": {"items": []}}


def test_exact_track_is_found_by_isrc(monkeypatch):
    stub_shazam(monkeypatch, with_isrc())
    spotify = FakeSpotify(monkeypatch, [found("3GYlZ8cmRBzJ")])
    result = body(handler.lambda_handler(event(), Ctx()))
    assert result["spotifyTrackUri"] == "spotify:track:3GYlZ8cmRBzJ"
    assert result["spotifyTrackUrl"] == "https://open.spotify.com/track/3GYlZ8cmRBzJ"
    assert spotify.queries() == ["isrc:USRC17607839"]
    token_request = spotify.calls[0]
    assert token_request.get_header("Authorization").startswith("Basic ")
    assert spotify.calls[1].get_header("Authorization") == "Bearer tok"


def test_falls_back_to_title_and_artist_when_the_isrc_finds_nothing(monkeypatch):
    stub_shazam(monkeypatch, with_isrc())
    spotify = FakeSpotify(monkeypatch, [NOTHING, found("abc")])
    result = body(handler.lambda_handler(event(), Ctx()))
    assert result["spotifyTrackUri"] == "spotify:track:abc"
    assert spotify.queries() == ['isrc:USRC17607839', 'track:"Tum Hi Ho" artist:"Arijit Singh"']


def test_without_an_isrc_it_searches_by_text(monkeypatch):
    stub_shazam(monkeypatch, with_isrc(isrc=None))
    spotify = FakeSpotify(monkeypatch, [found("abc")])
    assert body(handler.lambda_handler(event(), Ctx()))["spotifyTrackUri"] == "spotify:track:abc"
    assert spotify.queries() == ['track:"Tum Hi Ho" artist:"Arijit Singh"']


def test_a_different_song_is_never_accepted_from_a_text_search(monkeypatch):
    stub_shazam(monkeypatch, with_isrc(isrc=None))
    FakeSpotify(monkeypatch, [found("zzz", name="Completely Other Song")])
    result = body(handler.lambda_handler(event(), Ctx()))
    assert result["matched"] is True
    assert result["spotifyTrackUri"] is None


def test_quotes_in_a_title_cannot_break_the_search(monkeypatch):
    stub_shazam(monkeypatch, with_isrc(isrc=None, title='Say "Hello"'))
    spotify = FakeSpotify(monkeypatch, [NOTHING])
    handler.lambda_handler(event(), Ctx())
    assert '"Hello"' not in spotify.queries()[0].split("track:", 1)[1].strip('"')


def test_no_spotify_credentials_means_no_spotify_calls(monkeypatch):
    stub_shazam(monkeypatch, with_isrc())
    calls = []
    monkeypatch.setattr(handler, "_http_json", lambda request: calls.append(request))
    result = body(handler.lambda_handler(event(), Ctx()))
    assert calls == []
    assert result["matched"] is True and result["spotifyTrackUri"] is None


def test_a_spotify_outage_never_loses_the_match(monkeypatch, caplog):
    stub_shazam(monkeypatch, with_isrc())
    FakeSpotify(monkeypatch, [urllib.error.URLError("down")])
    with caplog.at_level("INFO"):
        response = handler.lambda_handler(event(), Ctx())
    assert response["statusCode"] == 200
    result = body(response)
    assert result["matched"] is True and result["title"] == "Tum Hi Ho"
    assert result["spotifyTrackUri"] is None
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert "spotify_lookup_failed" in logged and "URLError" in logged
    assert "Tum Hi Ho" not in logged and "USRC17607839" not in logged


def test_the_token_is_reused_between_requests(monkeypatch):
    stub_shazam(monkeypatch, with_isrc())
    spotify = FakeSpotify(monkeypatch, [found("a"), found("b")])
    handler.lambda_handler(event(), Ctx())
    handler.lambda_handler(event(), Ctx())
    token_calls = [c for c in spotify.calls if c.full_url == handler.SPOTIFY_TOKEN_URL]
    assert len(token_calls) == 1


def test_no_match_makes_no_spotify_calls(monkeypatch):
    stub_shazam(monkeypatch, {"matches": []})
    spotify = FakeSpotify(monkeypatch, [])
    assert body(handler.lambda_handler(event(), Ctx()))["matched"] is False
    assert spotify.calls == []


def test_the_isrc_is_not_returned_to_the_app(monkeypatch):
    stub_shazam(monkeypatch, with_isrc())
    FakeSpotify(monkeypatch, [found("a")])
    assert "_isrc" not in body(handler.lambda_handler(event(), Ctx()))
