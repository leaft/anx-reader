import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/tts/models/tts_audio.dart';
import 'package:web_socket_channel/io.dart';

const _sampleRate = 24000;

Future<TtsAudio> synthesizeOpenAiRealtimeSpeech({
  required Uri endpoint,
  required String apiKey,
  required String model,
  required String voice,
  required String text,
  required String instructions,
  required Duration timeout,
}) async {
  final uri = endpoint.replace(
    queryParameters: {...endpoint.queryParameters, 'model': model},
  );
  final client = HttpClient();
  final channel = IOWebSocketChannel.connect(
    uri,
    headers: {'Authorization': 'Bearer $apiKey'},
    connectTimeout: timeout,
    customClient: client,
  );

  try {
    return await _readSpeech(channel, {
      'type': 'response.create',
      'response': {
        'conversation': 'none',
        'output_modalities': ['audio'],
        'instructions': instructions,
        'audio': {
          'output': {
            'format': {'type': 'audio/pcm', 'rate': _sampleRate},
            'voice': voice,
          },
        },
        'input': [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': text},
            ],
          },
        ],
      },
    }).timeout(timeout);
  } finally {
    client.close(force: true);
    unawaited(channel.sink.close().then<void>((_) {}, onError: (Object _) {}));
  }
}

Future<TtsAudio> _readSpeech(
  IOWebSocketChannel channel,
  Map<String, Object?> request,
) async {
  await channel.ready;
  channel.sink.add(jsonEncode(request));

  final pcm = BytesBuilder(copy: false);
  await for (final message in channel.stream) {
    final event = jsonDecode(message as String) as Map<String, dynamic>;
    switch (event['type']) {
      case 'response.output_audio.delta':
        pcm.add(base64Decode(event['delta'] as String));
      case 'response.done':
        final response = event['response'] as Map<String, dynamic>;
        final status = response['status'];
        if (status != 'completed') {
          final details = response['status_details'];
          throw StateError(
            'OpenAI Realtime speech ended with $status: $details',
          );
        }
        if (pcm.isEmpty || pcm.length.isOdd) {
          throw const FormatException(
            'OpenAI Realtime returned invalid PCM audio',
          );
        }
        return _encodeWav(pcm.takeBytes());
      case 'error':
        final error = event['error'] as Map<String, dynamic>;
        throw StateError('OpenAI Realtime speech failed: ${error['message']}');
    }
  }
  throw StateError('OpenAI Realtime disconnected before finishing speech');
}

TtsAudio _encodeWav(Uint8List pcm) {
  const headerSize = 44;
  const channels = 1;
  const bitsPerSample = 16;
  const blockAlign = channels * (bitsPerSample ~/ 8);
  const byteRate = _sampleRate * blockAlign;

  final wav = Uint8List(headerSize + pcm.length);
  final header = ByteData.sublistView(wav, 0, headerSize);
  wav.setAll(0, ascii.encode('RIFF'));
  header.setUint32(4, wav.length - 8, Endian.little);
  wav.setAll(8, ascii.encode('WAVEfmt '));
  header.setUint32(16, 16, Endian.little); // PCM format chunk size
  header.setUint16(20, 1, Endian.little); // PCM format code
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, _sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  wav.setAll(36, ascii.encode('data'));
  header.setUint32(40, pcm.length, Endian.little);
  wav.setAll(headerSize, pcm);
  final duration = Duration(
    microseconds: pcm.length * Duration.microsecondsPerSecond ~/ byteRate,
  );
  return TtsAudio.wav(wav, duration: duration);
}
