import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/broadcast_audio.dart';

Uint8List pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int> sine(int count, int amplitude, {int rate = 24000}) => List.generate(
  count,
  (i) => (amplitude * math.sin(2 * math.pi * 300 * i / rate)).round(),
);

double rms(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  final count = (wav.length - 44) ~/ 2;
  var sum = 0.0;
  for (var i = 0; i < count; i++) {
    final v = data.getInt16(44 + i * 2, Endian.little);
    sum += v * v;
  }
  return math.sqrt(sum / count);
}

void main() {
  test('writes the plain 16 kHz mono 16-bit header Circuit checks', () {
    final wav = broadcastWav(pcm(sine(24000, 8000)));
    final h = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(h.getUint16(20, Endian.little), 1);
    expect(h.getUint16(22, Endian.little), 1);
    expect(h.getUint32(24, Endian.little), 16000);
    expect(h.getUint16(34, Endian.little), 16);
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(h.getUint32(40, Endian.little), wav.length - 44);
  });

  test('resamples 24 kHz to 16 kHz', () {
    final wav = broadcastWav(pcm(sine(24000, 8000))); // one second
    expect((wav.length - 44) ~/ 2, 16000);
  });

  test('takes microphone speech at 16 kHz as it is', () {
    final wav = broadcastWav(
      pcm(sine(16000, 3000, rate: 16000)),
      sourceRate: 16000,
    );
    expect((wav.length - 44) ~/ 2, 16000);
  });

  test('makes quiet speech much louder but never clips', () {
    final quiet = pcm(sine(24000, 2000));
    final wav = broadcastWav(quiet);
    final data = ByteData.sublistView(wav);
    var peak = 0;
    for (var i = 0; i < (wav.length - 44) ~/ 2; i++) {
      peak = math.max(peak, data.getInt16(44 + i * 2, Endian.little).abs());
    }
    expect(peak, lessThanOrEqualTo(32767 * 0.95 + 1));
    expect(peak, greaterThan(32767 * 0.9));
    expect(rms(wav), greaterThan(rms(quiet) * 4));
  });

  test('refuses empty, silent and over-long audio', () {
    expect(() => broadcastWav(Uint8List(0)), throwsStateError);
    expect(() => broadcastWav(pcm(List.filled(2400, 0))), throwsStateError);
    expect(
      () => broadcastWav(pcm(List.filled(24000 * 31, 1000))),
      throwsStateError,
    );
  });

  test('reads the audio out of a Gemini reply, using its sample rate', () {
    final reply = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/L16;codec=pcm;rate=16000',
                  'data': base64Encode(pcm(sine(16000, 6000, rate: 16000))),
                },
              },
            ],
          },
        },
      ],
    });
    final wav = broadcastWavFromGeminiReply(reply);
    expect((wav.length - 44) ~/ 2, 16000);
    expect(
      () => broadcastWavFromGeminiReply('{"candidates":[]}'),
      throwsStateError,
    );
  });
}
