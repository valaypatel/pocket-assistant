"""Song recognition for the Circuit app.

POST /music/identify  raw WAV bytes -> {matched, title, artist, album, artworkUrl,
                      providerUrl, spotifyUri, spotifyUrl,
                      spotifyTrackUri, spotifyTrackUrl}
GET  /music/health    checks the service key, returns {"ok": true}

Audio is held in memory for the duration of one request. Nothing is written to
disk or S3, and the logs carry only the request id, route and outcome.
"""

import asyncio
import base64
import binascii
import hmac
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_AUDIO_BYTES = int(os.environ.get("MAX_AUDIO_BYTES", 3 * 1024 * 1024))

log = logging.getLogger()
log.setLevel(logging.INFO)

SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_SEARCH_URL = "https://api.spotify.com/v1/search"
SPOTIFY_TIMEOUT_SECONDS = 5

_spotify_token = {"value": None, "expires_at": 0.0}


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "cache-control": "no-store",
        },
        "body": json.dumps(body),
    }


def _log(request_id, route, outcome, **extra):
    # Never log audio or track details; outcome and sizes only.
    log.info(json.dumps({"requestId": request_id, "route": route, "outcome": outcome, **extra}))


def _authorised(headers):
    expected = os.environ.get("SERVICE_KEY", "")
    if not expected:
        return False  # An unconfigured service must never accept requests.
    supplied = headers.get("authorization", "")
    if not supplied.startswith("Bearer "):
        return False
    return hmac.compare_digest(supplied[7:].encode(), expected.encode())


def _is_wav(data):
    return len(data) >= 44 and data[0:4] == b"RIFF" and data[8:12] == b"WAVE"


def _spotify_links(track):
    """Spotify links Shazam attaches to a track: (app uri, web url), or None.

    They are usually searches for the title and artist rather than one exact
    Spotify track, so callers should treat them as "find this song".
    """
    uri = url = None
    hub = track.get("hub")
    providers = hub.get("providers") if isinstance(hub, dict) else None
    for provider in providers if isinstance(providers, list) else []:
        if not isinstance(provider, dict):
            continue
        if str(provider.get("type", "")).upper() != "SPOTIFY":
            continue
        actions = provider.get("actions")
        for action in actions if isinstance(actions, list) else []:
            if not isinstance(action, dict):
                continue
            target = action.get("uri")
            if not isinstance(target, str):
                continue
            if target.startswith("spotify:") and uri is None:
                uri = target
            elif target.startswith("https://") and url is None:
                url = target
    return uri, url


def normalize(result):
    """Reduces a ShazamIO response to the fields the app uses."""
    track = result.get("track") if isinstance(result, dict) else None
    if not track:
        return {
            "matched": False,
            "title": None,
            "artist": None,
            "album": None,
            "artworkUrl": None,
            "providerUrl": None,
            "spotifyUri": None,
            "spotifyUrl": None,
            "spotifyTrackUri": None,
            "spotifyTrackUrl": None,
        }
    album = None
    for section in track.get("sections") or []:
        for item in section.get("metadata") or []:
            if str(item.get("title", "")).lower() == "album":
                album = item.get("text")
    images = track.get("images") or {}
    spotify_uri, spotify_url = _spotify_links(track)
    return {
        "matched": True,
        "title": track.get("title"),
        "artist": track.get("subtitle"),
        "album": album,
        "artworkUrl": images.get("coverarthq") or images.get("coverart"),
        "providerUrl": track.get("url"),
        "spotifyUri": spotify_uri,
        "spotifyUrl": spotify_url,
        # Filled in by the optional Spotify lookup; null until then.
        "spotifyTrackUri": None,
        "spotifyTrackUrl": None,
        "_isrc": track.get("isrc") if isinstance(track.get("isrc"), str) else None,
    }


async def _recognize(audio):
    from shazamio import Shazam  # imported late so tests can stub it

    return await Shazam().recognize(audio)


def _http_json(request):
    """Sends a request and returns the decoded JSON body. Patched in tests."""
    with urllib.request.urlopen(request, timeout=SPOTIFY_TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def _spotify_access_token():
    """An app token from Spotify's client-credentials flow, cached until it expires."""
    client_id = os.environ.get("SPOTIFY_CLIENT_ID", "")
    client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        return None
    now = time.time()
    if _spotify_token["value"] and now < _spotify_token["expires_at"] - 30:
        return _spotify_token["value"]
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    request = urllib.request.Request(
        SPOTIFY_TOKEN_URL,
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    answer = _http_json(request)
    token = answer.get("access_token")
    if not isinstance(token, str):
        return None
    _spotify_token["value"] = token
    _spotify_token["expires_at"] = now + float(answer.get("expires_in", 3600))
    return token


def _same_song(wanted, found):
    """Loose title check so a near-miss search result is never opened as the song."""
    a, b = (wanted or "").strip().lower(), (found or "").strip().lower()
    return bool(a) and bool(b) and (a in b or b in a)


def _spotify_search(token, query):
    url = SPOTIFY_SEARCH_URL + "?" + urllib.parse.urlencode({"q": query, "type": "track", "limit": 1})
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    items = ((_http_json(request) or {}).get("tracks") or {}).get("items") or []
    return items[0] if items and isinstance(items[0], dict) else None


def spotify_track(title, artist, isrc):
    """The exact Spotify track as (uri, url), or None.

    Needs SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET. Looks up by ISRC (the
    recording's own code) first, then by title and artist, and only accepts a
    result whose title matches. Sends no audio, only text.
    """
    token = _spotify_access_token()
    if token is None:
        return None
    candidates = []
    if isrc:
        candidates.append(("isrc", f"isrc:{isrc}"))
    if title:
        clean = lambda text: text.replace('"', " ").strip()  # noqa: E731
        query = f'track:"{clean(title)}"' + (f' artist:"{clean(artist)}"' if artist else "")
        candidates.append(("text", query))
    for kind, query in candidates:
        found = _spotify_search(token, query)
        if not found or not found.get("id"):
            continue
        # An ISRC identifies the recording, so it needs no title check.
        if kind == "text" and not _same_song(title, found.get("name")):
            continue
        return f"spotify:track:{found['id']}", f"https://open.spotify.com/track/{found['id']}"
    return None


def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", "local")
    http = (event.get("requestContext") or {}).get("http") or {}
    method = http.get("method", "")
    path = event.get("rawPath", "")
    route = f"{method} {path}"
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if route not in ("POST /music/identify", "GET /music/health"):
        _log(request_id, route, "not_found")
        return _response(404, {"error": "not_found"})

    if not os.environ.get("SERVICE_KEY"):
        _log(request_id, route, "not_configured")
        return _response(500, {"error": "not_configured"})
    if not _authorised(headers):
        _log(request_id, route, "unauthorised")
        return _response(401, {"error": "unauthorised"})

    if route == "GET /music/health":
        _log(request_id, route, "ok")
        return _response(200, {"ok": True})

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        if len(body) > (MAX_AUDIO_BYTES * 4) // 3 + 8:
            _log(request_id, route, "too_large")
            return _response(413, {"error": "too_large"})
        try:
            audio = base64.b64decode(body, validate=True)
        except (binascii.Error, ValueError):
            _log(request_id, route, "invalid_audio")
            return _response(400, {"error": "invalid_audio"})
    else:
        audio = body.encode("latin-1", errors="ignore")

    if len(audio) > MAX_AUDIO_BYTES:
        _log(request_id, route, "too_large", bytes=len(audio))
        return _response(413, {"error": "too_large"})
    if not _is_wav(audio):
        _log(request_id, route, "invalid_audio", bytes=len(audio))
        return _response(400, {"error": "invalid_audio"})

    try:
        result = normalize(asyncio.run(_recognize(audio)))
    except Exception as error:  # Upstream is unofficial; report a retryable failure.
        _log(request_id, route, "recognition_failed", error=type(error).__name__)
        return _response(502, {"error": "recognition_failed"})
    finally:
        del audio

    isrc = result.pop("_isrc", None)
    spotify = "off"
    configured = bool(os.environ.get("SPOTIFY_CLIENT_ID") and os.environ.get("SPOTIFY_CLIENT_SECRET"))
    if result["matched"] and configured:
        try:
            exact = spotify_track(result["title"], result["artist"], isrc)
            spotify = "exact" if exact else "none"
            if exact:
                result["spotifyTrackUri"], result["spotifyTrackUrl"] = exact
        except Exception as error:  # A missing Spotify link must never lose the match.
            spotify = "failed"
            log.warning(json.dumps({"requestId": request_id, "route": route, "outcome": "spotify_lookup_failed", "error": type(error).__name__}))
    _log(request_id, route, "matched" if result["matched"] else "no_match", spotify=spotify)
    return _response(200, result)
