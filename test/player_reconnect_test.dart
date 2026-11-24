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

// 0.2.27: the pause + background repro (user, 2026-11-25 02:30):
// watch → PAUSE → switch to the chat app (AniBee backgrounded)
// → return → "Couldn't load episode" over the frame that had
// been playing fine. While the app is suspended iOS kills mpv's
// connections and the signed segment URLs age out, so the dead
// stream must be re-resolved on return — never greeted with a
// fatal error. On resume with the trailer in the error state,
// the player re-resolves FRESH signed URLs and reloads at the
// saved position behind a "Reconnecting…" state, restoring the
// prior play state (stays paused if he paused).
//
// ONE real-mpv load per file (VM limit, proven by probe: only
// the first load in a flutter_tester process ever reports a
// duration — a second load never arrives). The screen is pumped
// with NO initial stream, so the reconnect's load is the only
// one; the error is produced by the simulated mpv error, not by
// a failed load.
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
    id: 'reconnect-test',
    title: 'Reconnect Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for the 0.2.27 reconnect fix.',
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

  testWidgets('pause + background + return reconnects, not errors',
      (WidgetTester tester) async {
    final SettingsStore store = await SettingsStore.load();
    late TrailerPlayer trailer;
    await tester.runAsync(() async {
      trailer = TrailerPlayer();
    });
    final List<Episode> episodes = mockEpisodes(anime);
    int resolveCalls = 0;
    ResolvedStream freshStream() {
      final String path =
          File('test/fixtures/skip_test_5s.mp4').absolute.path;
      return ResolvedStream(
        url: 'file://$path',
        label: 'Test 1080p',
        source: 'Test',
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: FullPlayerScreen(
          trailer: trailer,
          store: store,
          anime: anime,
          episodes: episodes,
          initialEpisode: episodes.first,
          onResolveEpisode: (Episode episode) async {
            resolveCalls++;
            return freshStream();
          },
        ),
      ),
    );
    await tester.pump();
    // The background kill, simulated: the trailer is in the
    // error state (grace elapsed, nothing playing).
    trailer.simulatePlayerErrorForTest('cplayer: Failed to load media');
    await tester.pump(const Duration(seconds: 4));
    expect(trailer.loadError, isNotNull);
    expect(find.text("Couldn't load episode"), findsOneWidget);
    // Background, then return.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // Reconnecting… shows and the episode is re-resolved.
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(resolveCalls, 1);
    // The fresh load clears the error (loadStream clears
    // loadError on entry) and the overlay goes away when the
    // load finishes.
    expect(
      await waitFor(
        tester,
        const Duration(seconds: 90),
        () =>
            trailer.loadError == null &&
            find.text('Reconnecting…').evaluate().isEmpty,
      ),
      isTrue,
    );
    expect(find.text("Couldn't load episode"), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    trailer.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
