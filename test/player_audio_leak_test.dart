import 'dart:async';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/player/trailer_player.dart';
import 'package:anibee/screens/full_player_screen.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 0.2.27: the audio leak (phone-proven 2026-11-25 — JJK EP3 via
// Anime-Sama: "Couldn't load episode" while the episode's AUDIO
// kept playing, and it kept playing after going back to Detail).
// Leaving the player (back button / screen popped) MUST stop
// playback: dispose -> backToInline -> stop.
//
// ONE real-mpv load per file (VM limit, proven by probe: only
// the first load in a flutter_tester process ever reports a
// duration — a second load never arrives). Polls are wall-clock
// deadlines, in real time (same pattern as
// player_center_pause_test.dart — fake time must not be advanced
// while mpv reads its temp playlist).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'VideoOutputManager.Create') {
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          final int handle = int.parse(args['handle'] as String);
          await messenger.handlePlatformMessage(
            'com.alexmercerind/media_kit_video',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('VideoOutput.Resize', <String, Object>{
                'handle': handle,
                'rect': <String, Object>{
                  'left': 0.0,
                  'top': 0.0,
                  'width': 800.0,
                  'height': 600.0,
                },
                'id': 1,
              }),
            ),
            null,
          );
        }
        return null;
      },
    );
  });

  const Anime anime = Anime(
    id: 'audio-leak-test',
    title: 'Audio Leak Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for the 0.2.27 audio-leak fix.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  /// Poll [cond] in real time until it holds or [timeout]
  /// elapses (wall clock — the VM's mpv init takes seconds and
  /// varies run to run).
  Future<bool> waitFor(
    WidgetTester tester,
    Duration timeout,
    bool Function() cond,
  ) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      if (cond()) return true;
    }
    return cond();
  }

  testWidgets('leaving the player stops playback — no audio leak',
      (WidgetTester tester) async {
    final SettingsStore store = await SettingsStore.load();
    late TrailerPlayer trailer;
    await tester.runAsync(() async {
      trailer = TrailerPlayer();
    });
    final List<Episode> episodes = mockEpisodes(anime);
    final String path =
        File('test/fixtures/skip_test_5s.mp4').absolute.path;
    await tester.pumpWidget(
      MaterialApp(
        home: FullPlayerScreen(
          trailer: trailer,
          store: store,
          anime: anime,
          episodes: episodes,
          initialEpisode: episodes.first,
          stream: ResolvedStream(
            url: 'file://$path',
            label: 'Test 1080p',
            source: 'Test',
          ),
        ),
      ),
    );
    await tester.pump();
    // The screen's load plays the clip: wait for it to arrive
    // and be playing. (The VM never advances mpv's position
    // headless, so `playing` + `duration` are the observables.)
    expect(
      await waitFor(
        tester,
        const Duration(seconds: 90),
        () => trailer.player.state.duration > Duration.zero,
      ),
      isTrue,
    );
    unawaited(trailer.player.seek(Duration.zero));
    unawaited(trailer.player.play());
    expect(
      await waitFor(
        tester,
        const Duration(seconds: 60),
        () => trailer.player.state.playing,
      ),
      isTrue,
    );
    // Back, the way the user does it: the screen leaves the tree
    // (dispose -> backToInline -> stop) and Detail stops again.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(
      await waitFor(
        tester,
        const Duration(seconds: 30),
        () =>
            !trailer.loaded && !trailer.player.state.playing,
      ),
      isTrue,
    );
    // Let media_kit's internal open timer fire before teardown.
    await tester.pump(const Duration(seconds: 6));
    trailer.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
