import 'dart:typed_data';

class TtsAudio {
  const TtsAudio.mp3(this.bytes)
      : mimeType = 'audio/mp3',
        duration = null;
  const TtsAudio.wav(this.bytes, {required Duration this.duration})
      : mimeType = 'audio/wav';

  final Uint8List bytes;
  final String mimeType;
  final Duration? duration;
}
