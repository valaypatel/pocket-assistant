import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:short_circuit/main.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<MusicClient> _client(
  Future<http.Response> Function(http.Request) handler, {
  String url = 'https://abc.lambda-url.eu-west-1.on.aws/',
  String key = 'secret-key',
}) async {
  FlutterSecureStorage.setMockInitialValues({
    'music_function_url': url,
    'music_service_key': key,
  });
  return MusicClient(client: MockClient(handler));
}

final _wav = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0]);

const _matched = {
  'matched': true,
  'title': 'Tum Hi Ho',
  'artist': 'Arijit Singh',
  'album': 'Aashiqui 2',
  'artworkUrl': 'https://img/hq.jpg',
  'providerUrl': 'https://www.shazam.com/track/1',
};

void main() {
  group('SongResult and notes', () {
    test('a matched result survives saving and loading', () {
      final note = CircuitNote(
        id: '1',
        createdAt: DateTime(2026, 10, 5, 9, 30),
        status: 'Song identified',
        kind: 'song',
        song: SongResult(
          state: 'matched',
          title: 'Tum Hi Ho',
          artist: 'Arijit Singh',
          album: 'Aashiqui 2',
          artworkUrl: 'https://img/hq.jpg',
          providerUrl: 'https://www.shazam.com/track/1',
          recognizedAt: DateTime(2026, 10, 5, 9, 31),
        ),
      );
      final copy = CircuitNote.fromJson(
        jsonDecode(jsonEncode(note.toJson())) as Map<String, dynamic>,
      );
      expect(copy.isSong, isTrue);
      expect(copy.song!.state, 'matched');
      expect(copy.song!.title, 'Tum Hi Ho');
      expect(copy.song!.recognizedAt, DateTime(2026, 10, 5, 9, 31));
    });

    test('every state round-trips and keeps its error text', () {
      for (final state in [
        'queued',
        'identifying',
        'matched',
        'no_match',
        'failed',
      ]) {
        final result = SongResult.fromJson(
          SongResult(state: state, error: 'Try again.').toJson(),
        );
        expect(result.state, state);
        expect(result.error, 'Try again.');
      }
    });

    test('a voice note stays a voice note and copyWith keeps song fields', () {
      final voice = CircuitNote(
        id: '2',
        createdAt: DateTime(2026),
        status: 'x',
      );
      expect(voice.isSong, isFalse);
      expect(voice.toJson().containsKey('kind'), isFalse);
      final song = CircuitNote(
        id: '3',
        createdAt: DateTime(2026),
        status: 'x',
        kind: 'song',
        song: const SongResult(state: 'no_match'),
      ).copyWith(status: 'No match found', audioPath: '/a.wav');
      expect(song.isSong, isTrue);
      expect(song.song!.state, 'no_match');
    });

    test('busy covers queued and identifying only', () {
      expect(const SongResult(state: 'queued').busy, isTrue);
      expect(const SongResult(state: 'identifying').busy, isTrue);
      expect(const SongResult(state: 'failed').busy, isFalse);
      expect(const SongResult(state: 'matched').busy, isFalse);
    });
  });

  group('MusicClient', () {
    test('sends the clip as authenticated audio and reads a match', () async {
      http.Request? seen;
      final client = await _client((request) async {
        seen = request;
        return _json(200, _matched);
      });
      final result = await client.identify(_wav);
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://abc.lambda-url.eu-west-1.on.aws/music/identify',
      );
      expect(seen!.headers['authorization'], 'Bearer secret-key');
      expect(seen!.headers['content-type'], startsWith('audio/wav'));
      expect(seen!.bodyBytes, _wav);
      expect(result.matched, isTrue);
      expect(result.artist, 'Arijit Singh');
      expect(result.providerUrl, 'https://www.shazam.com/track/1');
    });

    test('no match is a result, not an error', () async {
      final client = await _client((_) async => _json(200, {'matched': false}));
      final result = await client.identify(_wav);
      expect(result.state, 'no_match');
      expect(result.title, isNull);
    });

    test('failures become short messages the user can act on', () async {
      Future<String> failure(
        Future<http.Response> Function(http.Request) h,
      ) async {
        final client = await _client(h);
        try {
          await client.identify(_wav);
        } catch (error) {
          return error.toString();
        }
        return 'no error';
      }

      expect(
        await failure((_) async => _json(401, {})),
        contains('service key'),
      );
      expect(
        await failure((_) async => _json(400, {})),
        contains('read as audio'),
      );
      expect(await failure((_) async => _json(413, {})), contains('too large'));
      expect(await failure((_) async => _json(502, {})), contains('Try again'));
      expect(
        await failure((_) async => throw http.ClientException('offline')),
        contains('Could not reach'),
      );
      expect(
        await failure((_) async => http.Response('<html>', 200)),
        contains('could not read'),
      );
    });

    test('raw server output never reaches the message', () async {
      final client = await _client(
        (_) async => http.Response('Traceback: secret detail', 500),
      );
      await expectLater(
        client.identify(_wav),
        throwsA(predicate((e) => !e.toString().contains('secret detail'))),
      );
    });

    test(
      'asks for a key and an https address before sending anything',
      () async {
        var calls = 0;
        FlutterSecureStorage.setMockInitialValues({});
        final empty = MusicClient(
          client: MockClient((_) async {
            calls++;
            return _json(200, _matched);
          }),
        );
        await expectLater(empty.identify(_wav), throwsException);
        expect(await empty.isConfigured(), isFalse);

        final insecure = await _client((_) async {
          calls++;
          return _json(200, _matched);
        }, url: 'http://example.com');
        await expectLater(
          insecure.identify(_wav),
          throwsA(predicate((e) => e.toString().contains('https://'))),
        );
        expect(calls, 0);
      },
    );

    test('test connection checks the key against the health route', () async {
      Uri? asked;
      final good = await _client((request) async {
        asked = request.url;
        return _json(200, {'ok': true});
      });
      await good.testConnection();
      expect(asked!.path, '/music/health');
      final bad = await _client((_) async => _json(401, {}));
      await expectLater(
        bad.testConnection(),
        throwsA(predicate((e) => e.toString().contains('service key'))),
      );
    });

    test(
      'the service Spotify links come first, then the app\'s own search',
      () {
        const song = SongResult(
          state: 'matched',
          title: 'Tum Hi Ho',
          artist: 'Arijit Singh',
          spotifyUri: 'spotify:search:Tum%20Hi%20Ho',
          spotifyUrl: 'https://open.spotify.com/search/Tum%20Hi%20Ho',
        );
        final tried = spotifyCandidates(song).map((u) => u.toString()).toList();
        expect(tried.take(2), [
          'spotify:search:Tum%20Hi%20Ho',
          'https://open.spotify.com/search/Tum%20Hi%20Ho',
        ]);
        // Own search is kept as a last resort, without repeating a duplicate.
        expect(tried.length, 4);
        expect(
          spotifyCandidates(const SongResult(state: 'matched', title: 'T'))
              .length,
          2,
        );
      },
    );

    test('the exact track comes before any search link', () {
      const song = SongResult(
        state: 'matched',
        title: 'Tum Hi Ho',
        artist: 'Arijit Singh',
        spotifyTrackUri: 'spotify:track:3GYlZ8cmRBzJ',
        spotifyTrackUrl: 'https://open.spotify.com/track/3GYlZ8cmRBzJ',
        spotifyUri: 'spotify:search:Tum%20Hi%20Ho',
        spotifyUrl: 'https://open.spotify.com/search/Tum%20Hi%20Ho',
      );
      final tried = spotifyCandidates(song).map((u) => u.toString()).toList();
      expect(tried.first, 'spotify:track:3GYlZ8cmRBzJ');
      expect(tried[1], 'https://open.spotify.com/track/3GYlZ8cmRBzJ');
      expect(tried.indexOf('spotify:search:Tum%20Hi%20Ho'), greaterThan(1));
      // Round-trips through storage, so an old note keeps working too.
      final restored = SongResult.fromJson(song.toJson());
      expect(restored.spotifyTrackUri, 'spotify:track:3GYlZ8cmRBzJ');
      expect(SongResult.fromJson({'state': 'matched'}).spotifyTrackUri, isNull);
    });

    test('the exact track links are read from the service answer', () async {
      final client = await _client(
        (_) async => _json(200, {
          ..._matched,
          'spotifyTrackUri': 'spotify:track:abc',
          'spotifyTrackUrl': 'https://open.spotify.com/track/abc',
        }),
      );
      final result = await client.identify(_wav);
      expect(result.spotifyTrackUri, 'spotify:track:abc');
      expect(result.spotifyTrackUrl, 'https://open.spotify.com/track/abc');
    });

    test('only spotify and https links are ever opened', () {
      const song = SongResult(
        state: 'matched',
        title: 'T',
        artist: 'A',
        spotifyUri: 'intent://evil#Intent;end',
        spotifyUrl: 'http://not-secure.example/x',
      );
      for (final uri in spotifyCandidates(song)) {
        expect(uri.scheme == 'spotify' || uri.scheme == 'https', isTrue);
        expect(uri.toString(), isNot(contains('evil')));
      }
    });

    test(
      'Spotify links in the service answer are kept on the result',
      () async {
        final client = await _client(
          (_) async => _json(200, {
            ..._matched,
            'spotifyUri': 'spotify:search:x',
            'spotifyUrl': 'https://open.spotify.com/search/x',
          }),
        );
        final result = await client.identify(_wav);
        expect(result.spotifyUri, 'spotify:search:x');
        expect(result.spotifyUrl, 'https://open.spotify.com/search/x');
        final restored = SongResult.fromJson(result.toJson());
        expect(restored.spotifyUrl, 'https://open.spotify.com/search/x');
      },
    );

    test('Spotify links search by title and artist, escaped', () {
      final links = spotifyLinks('Kal Ho Naa Ho', 'Sonu Nigam & Co');
      expect(
        links.app.toString(),
        'spotify:search:Kal%20Ho%20Naa%20Ho%20Sonu%20Nigam%20%26%20Co',
      );
      expect(links.web.host, 'open.spotify.com');
      expect(links.web.path, startsWith('/search/'));
      expect(
        spotifyLinks('Only title', null).app.toString(),
        'spotify:search:Only%20title',
      );
    });

    test('save and clear use secure storage', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final client = MusicClient();
      await client.save(url: ' https://x.example ', key: ' k ');
      expect(await client.functionUrl(), 'https://x.example');
      expect(await client.serviceKey(), 'k');
      expect(await client.isConfigured(), isTrue);
      await client.clear();
      expect(await client.isConfigured(), isFalse);
    });
  });

  group('SongPage', () {
    Widget page(
      CircuitNote? note, {
      void Function(String)? onIdentify,
      VoidCallback? onSettings,
      void Function(String)? onUseAsNote,
      Future<bool> Function(Uri)? openLink,
    }) => MaterialApp(
      theme: buildScTheme(),
      home: SongPage(
        noteId: 'n1',
        noteById: (_) => note,
        onIdentify: (id) async => onIdentify?.call(id),
        onPlay: (_) async {},
        onDelete: (_) async {},
        onOpenSettings: onSettings ?? () {},
        onUseAsNote: (id) async => onUseAsNote?.call(id),
        openLink: openLink,
      ),
    );

    CircuitNote note(SongResult song, {String? audio = '/clip.wav'}) =>
        CircuitNote(
          id: 'n1',
          createdAt: DateTime(2026, 10, 5, 9, 30),
          status: 'x',
          audioPath: audio,
          kind: 'song',
          song: song,
        );

    Future<void> show(WidgetTester tester, Widget widget) async {
      await tester.pumpWidget(widget);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); // stop the refresh timer
    }

    testWidgets('a match shows the track and opens the provider link', (
      tester,
    ) async {
      Uri? opened;
      await tester.pumpWidget(
        page(
          note(
            const SongResult(
              state: 'matched',
              title: 'Tum Hi Ho',
              artist: 'Arijit Singh',
              album: 'Aashiqui 2',
              providerUrl: 'https://www.shazam.com/track/1',
            ),
          ),
          openLink: (uri) async {
            opened = uri;
            return true;
          },
        ),
      );
      await tester.pump();
      expect(find.text('Tum Hi Ho'), findsOneWidget);
      expect(find.text('Arijit Singh'), findsOneWidget);
      expect(find.text('Aashiqui 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Open the track page in your browser'));
      await tester.pump();
      expect(opened.toString(), 'https://www.shazam.com/track/1');
      expect(find.byTooltip('Play the clip'), findsOneWidget);
      expect(find.byTooltip('Delete this clip'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Open in Spotify tries the app, then falls back to the web', (
      tester,
    ) async {
      final tried = <String>[];
      await tester.pumpWidget(
        page(
          note(
            const SongResult(
              state: 'matched',
              title: 'Tum Hi Ho',
              artist: 'Arijit Singh',
            ),
          ),
          openLink: (uri) async {
            tried.add(uri.toString());
            return uri.scheme != 'spotify'; // as if the app is not installed
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Open in Spotify'));
      await tester.pump();
      // No links from the service (older Lambda), so the app builds its own.
      expect(tried, [
        'spotify:search:Tum%20Hi%20Ho%20Arijit%20Singh',
        'https://open.spotify.com/search/Tum%20Hi%20Ho%20Arijit%20Singh',
      ]);
      expect(find.text('Could not open the link.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Spotify opens once when the app is installed', (tester) async {
      final tried = <String>[];
      await tester.pumpWidget(
        page(
          note(const SongResult(state: 'matched', title: 'T', artist: 'A')),
          openLink: (uri) async {
            tried.add(uri.scheme);
            return true;
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Open in Spotify'));
      await tester.pump();
      expect(tried, ['spotify']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed link says so instead of doing nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        page(
          note(const SongResult(state: 'matched', title: 'T', artist: 'A')),
          openLink: (_) async => false,
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Open in Spotify'));
      await tester.pump();
      expect(find.text('Could not open the link.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Open in Spotify opens the exact track first', (tester) async {
      final tried = <String>[];
      await tester.pumpWidget(
        page(
          note(
            const SongResult(
              state: 'matched',
              title: 'T',
              artist: 'A',
              spotifyTrackUri: 'spotify:track:abc',
              spotifyUri: 'spotify:search:T',
            ),
          ),
          openLink: (uri) async {
            tried.add(uri.toString());
            return true;
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Open in Spotify'));
      await tester.pump();
      expect(tried, ['spotify:track:abc']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a clip taken for a song can be turned into a voice note', (
      tester,
    ) async {
      String? converted;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildScTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SongPage(
                      noteId: 'n1',
                      noteById: (_) =>
                          note(const SongResult(state: 'no_match')),
                      onIdentify: (_) async {},
                      onPlay: (_) async {},
                      onDelete: (_) async {},
                      onOpenSettings: () {},
                      onUseAsNote: (id) async => converted = id,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('This is a voice note, not a song. Transcribe it'),
      );
      await tester.pumpAndSettle();
      expect(converted, 'n1');
      expect(find.text('open'), findsOneWidget); // page closed
      expect(find.text('Transcribing as a voice note…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a matched song offers no voice-note conversion', (
      tester,
    ) async {
      await tester.pumpWidget(
        page(note(const SongResult(state: 'matched', title: 'T', artist: 'A'))),
      );
      await tester.pump();
      expect(
        find.byTooltip('This is a voice note, not a song. Transcribe it'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no match is explained and can be retried', (tester) async {
      String? retried;
      await tester.pumpWidget(
        page(
          note(const SongResult(state: 'no_match')),
          onIdentify: (id) => retried = id,
        ),
      );
      await tester.pump();
      expect(find.text('No match found'), findsOneWidget);
      await tester.tap(find.byTooltip('Identify again'));
      await tester.pump();
      expect(retried, 'n1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure shows its message, retry and settings', (
      tester,
    ) async {
      var settings = 0;
      await tester.pumpWidget(
        page(
          note(
            const SongResult(
              state: 'failed',
              error: 'The service key was not accepted. Check it in Settings.',
            ),
          ),
          onSettings: () => settings++,
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('service key was not accepted'),
        findsOneWidget,
      );
      expect(find.byTooltip('Identify again'), findsOneWidget);
      await tester.tap(find.byTooltip('Music recognition settings'));
      expect(settings, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('while identifying, retry is disabled and busy', (
      tester,
    ) async {
      await tester.pumpWidget(
        page(note(const SongResult(state: 'identifying'))),
      );
      await tester.pump();
      expect(find.text('Identifying…'), findsOneWidget);
      expect(find.byTooltip('Identifying'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('before the clip syncs, it says so and disables playback', (
      tester,
    ) async {
      await tester.pumpWidget(page(note(const SongResult(), audio: null)));
      await tester.pump();
      expect(find.text('Waiting for the clip to sync'), findsOneWidget);
      expect(
        find.byTooltip('Play (the clip has not synced yet)'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a deleted note shows a way back', (tester) async {
      await tester.pumpWidget(page(null));
      await tester.pump();
      expect(find.text('This clip is gone'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lays out on a small phone with a long title', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await show(
        tester,
        page(
          note(
            const SongResult(
              state: 'matched',
              title: 'A very long song title that has to wrap across lines',
              artist: 'An artist with a long name, featuring someone else',
              album: 'An album called something very long indeed',
              providerUrl: 'https://example.com/t',
            ),
          ),
        ),
      );
    });
  });

  testWidgets('Music recognition settings page lays out and shows its fields', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(theme: buildScTheme(), home: const MusicSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('SERVICE ADDRESS'), findsOneWidget);
    expect(find.text('SERVICE KEY'), findsOneWidget);
    expect(find.byTooltip('Save and test music recognition'), findsOneWidget);
    // No provider branding in normal UI.
    expect(
      find.textContaining(RegExp('shazam', caseSensitive: false)),
      findsNothing,
    );
  });
}
