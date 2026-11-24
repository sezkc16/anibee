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

// 0.2.27: the stale-load audio leak (phone-proven 2026-11-25 —
// audio restarted on the Detail screen after going back during
// a slow open). A loadStream in flight used to call play() AFTER
// the player had been stopped — a load-generation counter now
// invalidates stale loads, so the late play() never runs.
//
// ONE real-mpv load per file (VM limit, proven by probe: only
// the first load in a flutter_tester process ever reports a
// duration — a second load never arrives). The load is the local
// clip: it still takes ~10 s in this VM, so a stop at 300 ms
// lands inside open(). (A delayed HTTP server was tried first;
// mpv's connection to it wedged the runner's teardown, so the
// local file stands in for the slow HLS open — the race under
// test, stop landing mid-open, is identical.) Player commands
// are never awaited here — an awaited stop() behind an in-flight
// open hung a probe run for the full test timeout; the test
// polls the observable state instead.
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
    id: 'stale-load-test',
    title: 'Stale Load Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for the 0.2.27 stale-load fix.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  testWidgets('stale load cannot restart audio after stop',
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
            label: 'Delayed',
            source: 'Test',
          ),
        ),
      ),
    );
    await tester.pump();
    // Stop while the load is still in flight. Unawaited: the
    // stop queues behind the in-flight open and executes when it
    // completes; the stale load's post-open play() must be
    // blocked by the generation guard either way.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    unawaited(trailer.stop());
    // Watch for 30 s: the open alone takes ~10–17 s in this VM,
    // and the stale play() (pre-fix) lands as a TRANSIENT
    // playing=true window (~4 s) before mpv corrects it — a
    // single end-state check would miss it. Fail if playback
    // EVER restarts or the load EVER reports loaded.
    bool everPlayed = false;
    bool everLoaded = false;
    final DateTime deadline =
        DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      if (trailer.player.state.playing) everPlayed = true;
      if (trailer.loaded) everLoaded = true;
    }
    expect(everPlayed, isFalse);
    expect(everLoaded, isFalse);
    expect(trailer.loadError, isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    trailer.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
