import 'package:anx_reader/service/tts/models/tts_audio.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';

class TtsSegment {
  TtsSegment({required this.sentence});

  final TtsSentence sentence;
  TtsAudio? audio;
  bool isSilent = false;
  int fetchVersion =
      0; // Version to track if audio was fetched with current settings

  bool get isReady => isSilent || (audio != null && audio!.bytes.isNotEmpty);
}
