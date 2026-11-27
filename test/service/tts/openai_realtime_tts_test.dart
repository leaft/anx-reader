import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/page/settings_page/narrate.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:anx_reader/service/tts/online_tts.dart';
import 'package:anx_reader/service/tts/openai_realtime_speech.dart';
import 'package:anx_reader/service/tts/openai_tts_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('settings offer and save the Realtime prefetch durations',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({
      'ttsService': 'openai',
      'onlineTtsConfig_openai': '{"prefetchMinutes":42}',
    });
    await Prefs().initPrefs();
    final provider = OpenAiTtsProvider();
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: NarrateSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(provider.prefetchDuration, const Duration(minutes: 1));

    final durationField = find.ancestor(
      of: find.text('Audio prefetch duration'),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    await tester.ensureVisible(durationField);
    await tester.tap(durationField);
    await tester.pumpAndSettle();
    expect(find.text('1 minute').hitTestable(), findsOneWidget);
    expect(find.text('5 minutes').hitTestable(), findsOneWidget);
    expect(find.text('10 minutes').hitTestable(), findsOneWidget);
    await tester.tap(find.text('5 minutes').hitTestable());
    await tester.pumpAndSettle();
    expect(provider.prefetchDuration, const Duration(minutes: 5));

    await tester.tap(durationField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 minutes').hitTestable());
    await tester.pumpAndSettle();
    expect(provider.prefetchDuration, const Duration(minutes: 10));
    await Prefs().prefs.reload();
    expect(provider.prefetchDuration, const Duration(minutes: 10));
  });

  testWidgets('prefetches a minute of WAV and refills without reordering',
      (tester) async {
    const pcmBytes = 24000 * 2 * 5;
    SharedPreferences.setMockInitialValues({
      'ttsService': 'openai',
      'openBookAnimation': false,
    });
    await Prefs().initPrefs();

    final reader = _TestReader();
    await tester.pumpWidget(ProviderScope(child: reader));

    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('xyz.luan/audioplayers');
    const globalChannel = MethodChannel('xyz.luan/audioplayers.global');
    const globalEvents = MethodChannel('xyz.luan/audioplayers.global/events');
    late MethodChannel events;
    final played = <int>[];
    late Completer<void> firstPlaybackStarted;
    late int prepared;

    Future<void> emit(String event, [Object? value]) async {
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': event,
          'value': value,
        }),
        (_) {},
      );
    }

    messenger.setMockMethodCallHandler(globalChannel, (_) async => null);
    messenger.setMockMethodCallHandler(globalEvents, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          events = MethodChannel(
            '${channel.name}/events/${call.arguments['playerId']}',
          );
          messenger.setMockMethodCallHandler(events, (_) async => null);
        case 'setSourceBytes':
          expect(call.arguments['mimeType'], 'audio/wav');
          final bytes = call.arguments['bytes'] as Uint8List;
          expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
          expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
          final wave = ByteData.sublistView(bytes);
          expect(wave.getUint32(24, Endian.little), 24000);
          expect(wave.getUint32(40, Endian.little), pcmBytes);
          prepared = wave.getUint16(44, Endian.little);
          expect(wave.getUint16(46, Endian.little), prepared + 1);
          await emit('audio.onPrepared', true);
        case 'resume':
          played.add(prepared);
          if (!firstPlaybackStarted.isCompleted) {
            firstPlaybackStarted.complete();
          }
      }
      return null;
    });

    await tester.runAsync(() async {
      await HttpOverrides.runWithHttpOverrides(() async {
        firstPlaybackStarted = Completer<void>();
        final requests = <int>[];
        final generated = <int>[];
        final anotherSentenceGenerated = Completer<void>();
        final server = await _serveSpeech((socket, request) async {
          final input = request['input'].single['content'].single;
          final number = int.parse((input['text'] as String).split(' ').last);
          requests.add(number);
          if (number == 1) await anotherSentenceGenerated.future;
          if (number > 5) await firstPlaybackStarted.future;
          _sendAudio(socket, [number, 0]);
          final pcm = Uint8List(pcmBytes - 2)..[0] = number + 1;
          _sendAudio(socket, pcm);
          _finish(socket, 'completed');
          generated.add(number);
          if (!anotherSentenceGenerated.isCompleted) {
            anotherSentenceGenerated.complete();
          }
        });

        await Prefs().saveOnlineTtsConfig('openai', {
          'key': 'test-key',
          'url': 'ws://127.0.0.1:${server.port}/v1/realtime',
        });
        final tts = OnlineTts();
        final readerState = epubPlayerKey.currentState! as _TestReaderState;
        await tts.init(() {}, () => readerState.position++, () {});

        final speaking = tts.speak();
        try {
          await _waitFor(() => played.length == 1 && generated.length == 13);
          // One playing segment and 12 queued segments of five seconds each.
          expect(requests, unorderedEquals(List.generate(13, (i) => i + 1)));
          expect(generated.first, isNot(1));
          expect(played, [1]);

          await emit('audio.onComplete');
          await _waitFor(() => played.length == 2 && generated.length == 14);
          expect(played, [1, 2]);

          await Prefs().saveOnlineTtsConfig('openai', {
            ...Prefs().getOnlineTtsConfig('openai'),
            'prefetchMinutes': '5',
          });
          await _waitFor(() => generated.length == 15);
          expect(played, [1, 2]);

          for (var number = 3; number <= 15; number++) {
            await emit('audio.onComplete');
            await _waitFor(() => played.length == number);
            expect(played.last, number);
          }
          expect(requests, unorderedEquals(List.generate(15, (i) => i + 1)));

          await tts.stop();
          await speaking;
          await tts.speak(content: '第 1');
          expect(played, [...List.generate(15, (i) => i + 1), 1]);
        } finally {
          await tts.dispose();
          await speaking;
          await server.close(force: true);
        }
      }, _RealHttp());
    });
  });

  test('rejects partial audio when the Realtime response is incomplete',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await _serveSpeech((socket, _) async {
        _sendAudio(socket, [1, 0]);
        _finish(socket, 'incomplete');
      });
      try {
        await expectLater(
          synthesizeOpenAiRealtimeSpeech(
            endpoint: Uri.parse('ws://127.0.0.1:${server.port}/v1/realtime'),
            apiKey: 'test-key',
            model: 'gpt-realtime-2.1-mini',
            voice: 'alloy',
            text: '读取这段文字。',
            instructions: 'Read verbatim.',
            timeout: const Duration(seconds: 3),
          ),
          throwsA(isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('incomplete'),
          )),
        );
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
  });
}

Future<HttpServer> _serveSpeech(
  Future<void> Function(WebSocket, Map<String, dynamic>) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    expect(request.uri.path, '/v1/realtime');
    expect(request.uri.queryParameters['model'], 'gpt-realtime-2.1-mini');
    expect(request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer test-key');
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((message) async {
      final event = jsonDecode(message as String) as Map<String, dynamic>;
      expect(event['type'], 'response.create');
      final response = event['response'] as Map<String, dynamic>;
      expect(response['conversation'], 'none');
      expect(response['output_modalities'], ['audio']);
      expect(response['audio']['output']['format'],
          {'type': 'audio/pcm', 'rate': 24000});
      await respond(socket, response);
    });
  });
  return server;
}

void _sendAudio(WebSocket socket, List<int> pcm) {
  socket.add(jsonEncode({
    'type': 'response.output_audio.delta',
    'delta': base64Encode(pcm),
  }));
}

void _finish(WebSocket socket, String status) {
  socket.add(jsonEncode({
    'type': 'response.done',
    'response': {'status': status},
  }));
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for audio playback');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _RealHttp extends HttpOverrides {}

class _TestReader extends EpubPlayer {
  _TestReader()
      : super(
          key: epubPlayerKey,
          book: Book.mock(),
          initialThemes: const [],
          showOrHideAppBarAndBottomBar: () {},
          onLoadEnd: () {},
          updateParent: () {},
        );

  @override
  ConsumerState<EpubPlayer> createState() => _TestReaderState();
}

class _TestReaderState extends EpubPlayerState {
  int position = 0;
  final sentences = List.generate(
    15,
    (i) => TtsSentence(text: '第 ${i + 1}', cfi: 'test-cfi-${i + 1}'),
  );

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  Future<List<TtsSentence>> ttsCollectDetails({
    required int count,
    bool includeCurrent = false,
    int offset = 1,
  }) async =>
      sentences
          .skip(position + (includeCurrent ? 0 : offset))
          .take(count)
          .toList();

  @override
  Future<void> ttsHighlightByCfi(String cfi) async {}
}
