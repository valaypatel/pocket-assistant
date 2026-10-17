import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// What Circuit plays: 16 kHz, mono, 16-bit, in a plain 44-byte-header WAV (the board checks this).
const broadcastSampleRate = 16000;

/// Circuit refuses longer clips, so the phone refuses first and can say why.
const broadcastMaxSeconds = 30;

/// The longest text that fits in [broadcastMaxSeconds] of speech, with room to spare.
const broadcastMaxCharacters = 400;

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Turns 16-bit mono speech (Gemini returns 24 kHz) into the clip Circuit plays.
///
/// Circuit's speaker is already at full volume, so the clip itself has to be loud: the speech is scaled
/// so its loudest moment reaches full scale, then soft-limited, which lifts the quiet words by roughly
/// 8 dB without the harshness of hard clipping.
Uint8List broadcastWav(Uint8List pcm, {int sourceRate = 24000}) {
  final count = pcm.length ~/ 2;
  if (count == 0) throw StateError('The voice came back empty.');
  final source = ByteData.sublistView(pcm);
  final samples = List<double>.generate(
    count,
    (i) => source.getInt16(i * 2, Endian.little) / 32768.0,
  );
  final length = (count * broadcastSampleRate / sourceRate).floor();
  if (length > broadcastSampleRate * broadcastMaxSeconds) {
    throw StateError(
      'That message is longer than $broadcastMaxSeconds seconds.',
    );
  }
  final resampled = List<double>.generate(length, (i) {
    final at = i * sourceRate / broadcastSampleRate;
    final i0 = at.floor();
    final i1 = math.min(i0 + 1, count - 1);
    final fraction = at - i0;
    return samples[i0] * (1 - fraction) + samples[i1] * fraction;
  });
  final peak = resampled.fold<double>(0, (p, v) => math.max(p, v.abs()));
  if (peak < 1e-4) throw StateError('The voice came back silent.');

  const drive = 3.0;
  final limit = _tanh(drive);
  final out = ByteData(44 + length * 2);
  void tag(int at, String text) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, broadcastSampleRate, Endian.little);
  out.setUint32(28, broadcastSampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, length * 2, Endian.little);
  for (var i = 0; i < length; i++) {
    final shaped = 0.95 * _tanh(drive * resampled[i] / peak) / limit;
    out.setInt16(44 + i * 2, (shaped * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// The audio inside a Gemini text-to-speech reply, as a clip for Circuit.
Uint8List broadcastWavFromGeminiReply(String body) {
  final data = jsonDecode(body);
  Object? inline;
  if (data is Map &&
      data['candidates'] is List &&
      (data['candidates'] as List).isNotEmpty) {
    final content = ((data['candidates'] as List).first as Map)['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is List && parts.isNotEmpty) {
      inline = (parts.first as Map)['inlineData'];
    }
  }
  final encoded = inline is Map ? inline['data'] : null;
  if (encoded is! String || encoded.isEmpty) {
    throw StateError('Gemini sent no voice. Try again.');
  }
  final mime = (inline as Map)['mimeType'] as String? ?? '';
  final rate =
      int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '') ??
      24000;
  return broadcastWav(base64Decode(encoded), sourceRate: rate);
}
