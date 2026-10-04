part of 'main.dart';

const _musicUrlKey = 'music_function_url';
const _musicKeyKey = 'music_service_key';

/// Outcome of identifying a song clip. Stored on the note.
class SongResult {
  const SongResult({
    this.state = 'queued',
    this.title,
    this.artist,
    this.album,
    this.artworkUrl,
    this.providerUrl,
    this.spotifyUri,
    this.spotifyUrl,
    this.spotifyTrackUri,
    this.spotifyTrackUrl,
    this.recognizedAt,
    this.error,
  });

  /// queued, identifying, matched, no_match or failed.
  final String state;
  final String? title;
  final String? artist;
  final String? album;
  final String? artworkUrl;
  final String? providerUrl;

  /// Spotify links from the service: the app's address and a web page. Usually
  /// a search for the song rather than one exact track. Null from older
  /// versions of the service, in which case the app builds its own search.
  final String? spotifyUri;
  final String? spotifyUrl;

  /// The exact Spotify track, when the service has Spotify credentials and found
  /// it. Opens the song itself, not a search.
  final String? spotifyTrackUri;
  final String? spotifyTrackUrl;
  final DateTime? recognizedAt;

  /// A short, safe message for the user; never raw server output.
  final String? error;

  bool get matched => state == 'matched';
  bool get busy => state == 'queued' || state == 'identifying';

  SongResult withState(String state, {String? error}) => SongResult(
    state: state,
    title: title,
    artist: artist,
    album: album,
    artworkUrl: artworkUrl,
    providerUrl: providerUrl,
    spotifyUri: spotifyUri,
    spotifyUrl: spotifyUrl,
    spotifyTrackUri: spotifyTrackUri,
    spotifyTrackUrl: spotifyTrackUrl,
    recognizedAt: recognizedAt,
    error: error,
  );

  factory SongResult.fromJson(Map<String, dynamic> json) => SongResult(
    state: json['state']?.toString() ?? 'queued',
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    artworkUrl: json['artworkUrl'] as String?,
    providerUrl: json['providerUrl'] as String?,
    spotifyUri: json['spotifyUri'] as String?,
    spotifyUrl: json['spotifyUrl'] as String?,
    spotifyTrackUri: json['spotifyTrackUri'] as String?,
    spotifyTrackUrl: json['spotifyTrackUrl'] as String?,
    recognizedAt: DateTime.tryParse(json['recognizedAt']?.toString() ?? ''),
    error: json['error'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'state': state,
    'title': ?title,
    'artist': ?artist,
    'album': ?album,
    'artworkUrl': ?artworkUrl,
    'providerUrl': ?providerUrl,
    'spotifyUri': ?spotifyUri,
    'spotifyUrl': ?spotifyUrl,
    'spotifyTrackUri': ?spotifyTrackUri,
    'spotifyTrackUrl': ?spotifyTrackUrl,
    'recognizedAt': ?recognizedAt?.toIso8601String(),
    'error': ?error,
  };
}

/// Talks to the private song-recognition service. Audio goes over HTTPS with a
/// bearer key and is not kept by the service.
class MusicClient {
  MusicClient({this.client});

  /// Tests pass a fake; the app uses a fresh client per request.
  final http.Client? client;

  Future<String?> serviceKey() => _secureStorage.read(key: _musicKeyKey);
  Future<String?> functionUrl() => _secureStorage.read(key: _musicUrlKey);

  Future<bool> isConfigured() async {
    final url = (await functionUrl())?.trim() ?? '';
    final key = (await serviceKey())?.trim() ?? '';
    return url.isNotEmpty && key.isNotEmpty;
  }

  Future<void> save({required String url, required String key}) async {
    await _secureStorage.write(key: _musicUrlKey, value: url.trim());
    await _secureStorage.write(key: _musicKeyKey, value: key.trim());
  }

  Future<void> clear() async {
    await _secureStorage.delete(key: _musicUrlKey);
    await _secureStorage.delete(key: _musicKeyKey);
  }

  /// The service address plus [path], or an exception explaining what to fix.
  static Uri endpoint(String? base, String path) {
    final text = (base ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    if (text.isEmpty) {
      throw Exception('Add the music service address in Settings.');
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw Exception('The music service address must start with https://');
    }
    return uri.replace(path: '${uri.path}$path');
  }

  Future<({Uri uri, String key})> _target(String path) async {
    final key = (await serviceKey())?.trim() ?? '';
    if (key.isEmpty) throw Exception('Add the music service key in Settings.');
    return (uri: endpoint(await functionUrl(), path), key: key);
  }

  Future<void> testConnection() async {
    final target = await _target('/music/health');
    final response = await _send(
      (client) => client
          .get(target.uri, headers: {'authorization': 'Bearer ${target.key}'})
          .timeout(const Duration(seconds: 20)),
    );
    if (response.statusCode != 200) throw _failure(response.statusCode);
  }

  Future<SongResult> identify(Uint8List wav) async {
    final target = await _target('/music/identify');
    final response = await _send(
      (client) => client
          .post(
            target.uri,
            headers: {
              'authorization': 'Bearer ${target.key}',
              'content-type': 'audio/wav',
            },
            body: wav,
          )
          .timeout(const Duration(seconds: 40)),
    );
    if (response.statusCode != 200) throw _failure(response.statusCode);
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        'The music service sent an answer the app could not read.',
      );
    }
    if (json['matched'] != true) {
      return SongResult(state: 'no_match', recognizedAt: DateTime.now());
    }
    String? text(String name) {
      final value = json[name]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    return SongResult(
      state: 'matched',
      title: text('title') ?? 'Unknown title',
      artist: text('artist'),
      album: text('album'),
      artworkUrl: text('artworkUrl'),
      providerUrl: text('providerUrl'),
      spotifyUri: text('spotifyUri'),
      spotifyUrl: text('spotifyUrl'),
      spotifyTrackUri: text('spotifyTrackUri'),
      spotifyTrackUrl: text('spotifyTrackUrl'),
      recognizedAt: DateTime.now(),
    );
  }

  Future<http.Response> _send(
    Future<http.Response> Function(http.Client client) request,
  ) async {
    final active = client ?? http.Client();
    try {
      return await request(active);
    } on TimeoutException {
      throw Exception('The music service took too long. Try again.');
    } catch (_) {
      throw Exception(
        'Could not reach the music service. Check the phone\'s connection and try again.',
      );
    } finally {
      if (client == null) active.close();
    }
  }

  Exception _failure(int status) => Exception(switch (status) {
    401 => 'The service key was not accepted. Check it in Settings.',
    400 => 'The clip could not be read as audio.',
    413 => 'The clip is too large to identify.',
    404 => 'The service address looks wrong. Check it in Settings.',
    _ => 'The music service could not identify this clip right now. Try again.',
  });
}

/// A short slice of a WAV recording, taken from the middle, for recognition.
///
/// Voice notes from Circuit's button can run for minutes; identifying a song
/// needs about 12 seconds, and a smaller upload is faster and under the
/// service's size limit. Clips already short enough, and anything that is not a
/// plain PCM WAV, are returned unchanged.
Uint8List wavSample(Uint8List wav, {int seconds = 12}) {
  int u16(int at) => wav[at] | (wav[at + 1] << 8);
  int u32(int at) => u16(at) | (u16(at + 2) << 16);
  bool tag(int at, String text) =>
      at + 4 <= wav.length && String.fromCharCodes(wav, at, at + 4) == text;

  if (wav.length < 44 || !tag(0, 'RIFF') || !tag(8, 'WAVE')) return wav;
  int? channels, rate, bits, dataAt, dataSize;
  var at = 12;
  while (at + 8 <= wav.length) {
    final size = u32(at + 4);
    if (tag(at, 'fmt ') && at + 24 <= wav.length) {
      channels = u16(at + 10);
      rate = u32(at + 12);
      bits = u16(at + 22);
    } else if (tag(at, 'data')) {
      dataAt = at + 8;
      dataSize = size > wav.length - dataAt ? wav.length - dataAt : size;
      break;
    }
    at += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (channels == null || rate == null || bits == null || dataAt == null) {
    return wav;
  }
  final frame = channels * bits ~/ 8;
  if (frame <= 0 || rate <= 0) return wav;
  final wanted = seconds * rate * frame;
  // Leave a little slack so a 13 second clip is not needlessly rewritten.
  if (dataSize! <= wanted + 3 * rate * frame) return wav;

  var start = (dataSize - wanted) ~/ 2;
  start -= start % frame;
  final out = Uint8List(44 + wanted);
  final view = ByteData.sublistView(out);
  void put(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      out[offset + i] = text.codeUnitAt(i);
    }
  }

  put(0, 'RIFF');
  view.setUint32(4, 36 + wanted, Endian.little);
  put(8, 'WAVE');
  put(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, rate, Endian.little);
  view.setUint32(28, rate * frame, Endian.little);
  view.setUint16(32, frame, Endian.little);
  view.setUint16(34, bits, Endian.little);
  put(36, 'data');
  view.setUint32(40, wanted, Endian.little);
  out.setRange(44, 44 + wanted, wav, dataAt + start);
  return out;
}

/// Links that open a track in Spotify: the app's own address first, then the
/// web page (which Spotify's app also claims when it is installed).
///
/// The recognition service only knows its own track page, so this searches by
/// title and artist rather than pointing at an exact Spotify track.
({Uri app, Uri web}) spotifyLinks(String? title, String? artist) {
  final query = [title, artist]
      .whereType<String>()
      .map((part) => part.trim())
      .where((p) => p.isNotEmpty)
      .join(' ');
  final encoded = Uri.encodeComponent(query);
  return (
    app: Uri.parse('spotify:search:$encoded'),
    web: Uri.parse('https://open.spotify.com/search/$encoded'),
  );
}

/// Every address worth trying to open a matched song in Spotify, best first:
/// the exact track if the service found it, then the search links it sent, then
/// a search the app builds itself. Only `spotify:` and `https://` addresses are
/// accepted.
List<Uri> spotifyCandidates(SongResult song) {
  final built = spotifyLinks(song.title, song.artist);
  final seen = <String>{};
  final out = <Uri>[];
  for (final text in [
    song.spotifyTrackUri,
    song.spotifyTrackUrl,
    song.spotifyUri,
    song.spotifyUrl,
  ]) {
    final uri = text == null ? null : Uri.tryParse(text);
    if (uri == null) continue;
    final ok =
        uri.scheme == 'spotify' ||
        (uri.scheme == 'https' && uri.host.isNotEmpty);
    if (ok && seen.add(uri.toString())) out.add(uri);
  }
  for (final uri in [built.app, built.web]) {
    if (seen.add(uri.toString())) out.add(uri);
  }
  return out;
}
