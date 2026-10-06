part of 'main.dart';

const _aiModeKey = 'ai_mode';

/// Where transcription comes from: the person's own Gemini key (free), or a
/// paid subscription served by Circuit's backend.
enum AiMode {
  ownKey,
  subscription;

  /// Anything unknown or missing is the own-key mode, which is how the app has
  /// always worked.
  static AiMode parse(String? value) => AiMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => AiMode.ownKey,
  );
}

class AiModeStore {
  const AiModeStore._();

  static Future<AiMode> read() async {
    final preferences = await SharedPreferences.getInstance();
    return AiMode.parse(preferences.getString(_aiModeKey));
  }

  static Future<void> save(AiMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_aiModeKey, mode.name);
  }
}

/// Turns a recording into a transcript. Both modes answer the same way, so the
/// rest of the app does not care which one it is talking to.
abstract class Transcriber {
  Future<GeminiTranscription> transcribeWav(
    Uint8List wavBytes, {
    bool detectMusic = true,
  });
}

/// Whether this person has an active subscription. Nothing sells one yet; the
/// real check (Play Billing, verified on a server) replaces [NoEntitlement].
abstract class Entitlement {
  Future<bool> isActive();
}

class NoEntitlement implements Entitlement {
  const NoEntitlement();

  @override
  Future<bool> isActive() async => false;
}

class SubscriptionUnavailable implements Exception {
  const SubscriptionUnavailable([
    this.message = 'Subscriptions are not available yet. Use your own key.',
  ]);
  final String message;

  @override
  String toString() => message;
}

/// The paid mode. The backend that would do the work is not built, so this
/// refuses rather than quietly using another path for the person's audio.
class SubscriptionTranscriber implements Transcriber {
  const SubscriptionTranscriber({this.entitlement = const NoEntitlement()});

  final Entitlement entitlement;

  @override
  Future<GeminiTranscription> transcribeWav(
    Uint8List wavBytes, {
    bool detectMusic = true,
  }) async {
    if (!await entitlement.isActive()) {
      throw const SubscriptionUnavailable();
    }
    throw const SubscriptionUnavailable(
      'The subscription service is not set up yet.',
    );
  }
}

Transcriber transcriberFor(AiMode mode) => switch (mode) {
  AiMode.ownKey => const GeminiClient(),
  AiMode.subscription => const SubscriptionTranscriber(),
};
