import 'package:anibee/models.dart';
import 'package:anibee/player/trailer_player.dart';
import 'package:anibee/screens/full_player_screen.dart';
import 'package:anibee/services/cast_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cast_service_test.dart';

/// 0.2.19: Chromecast in the player — button, picker, session
/// transitions and disconnect-resume, all through a MOCKED cast
/// service (injectable, like the update checker's client). No real
/// Cast device exists on the VM and the user owns none (confirmed
/// 2026-11-24), so these widget tests ARE the proof; real casting
/// is phone-test only, once he has a device.
///
/// Same harness as player_lock_test.dart: the real player is
/// constructed (real libmpv on the VM) but NO media is loaded —
/// the stream URL is the connection-refused
/// `https://127.0.0.1:9/ep1.m3u8`, which `TrailerPlayer.loadStream`
/// catches. The local player therefore never plays; the tests prove
/// the CAST wiring (which calls the fake records) and the resume
/// recording (which the store records).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // flutter_secure_storage has no Linux implementation: unmocked,
    // its channel never replies inside testWidgets (fake-time zone)
    // and SettingsStore.load() hangs on the secret reads. Answer
    // null — there are no secrets in tests.
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
    // media_kit_video's native controller registers its texture
    // through a MethodChannel with no test implementation: unmocked,
    // the VideoController init never completes and Player.open()
    // hangs on it. Simulate the native side instead (same mock as
    // player_lock_test.dart).
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
    id: 'cast-test',
    title: 'Cast Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for the Chromecast widget test.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  const String streamUrl = 'https://127.0.0.1:9/ep1.m3u8';

  late SettingsStore store;
  late TrailerPlayer trailer;
  late FakeCastService fake;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    String? url,
    bool withStream = true,
  }) async {
    store = await SettingsStore.load();
    fake = FakeCastService();
    await tester.runAsync(() async {
      trailer = TrailerPlayer();
    });
    // No tearDown dispose: the screen's dispose() calls back into
    // the shared trailer (backToInline), so the trailer must outlive
    // the screen — as in the app, where the Detail screen owns it.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    final List<Episode> episodes = mockEpisodes(anime);
    await tester.pumpWidget(
      MaterialApp(
        home: FullPlayerScreen(
          trailer: trailer,
          store: store,
          anime: anime,
          episodes: episodes,
          initialEpisode: episodes.first,
          stream: withStream
              ? ResolvedStream(
                  url: url ?? streamUrl,
                  label: 'Test 1080p',
                  source: 'Miruro',
                )
              : null,
          castService: fake,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  dynamic playerState(WidgetTester tester) =>
      tester.state(find.byType(FullPlayerScreen)) as dynamic;

  /// The Cast connect / disconnect chains run unawaited mpv commands
  /// whose round-trip runs in REAL time; fake pumps alone never let
  /// them finish. Give real time a chance, then render.
  Future<void> settleRealTime(WidgetTester tester) async {
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
  }

  /// Flush every pending fake timer (3 s auto-hide, 3 s snack
  /// banner) before the test ends — a pending Timer fails teardown
  /// ("A Timer is still pending").
  Future<void> flushTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
  }

  /// Open the picker and tap the fake TV. Leaves the test with a
  /// live cast (fake.loadCalls has the stream URL at position 0).
  Future<void> startCasting(WidgetTester tester) async {
    fake.devicesValue = <CastDevice>[
      const CastDevice(id: 'tv-1', name: 'Living Room TV'),
    ];
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Living Room TV'), findsOneWidget);
    await tester.tap(find.text('Living Room TV'));
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isTrue);
    expect(fake.loadCalls, hasLength(1));
    expect(fake.loadCalls.first.url, streamUrl);
    expect(fake.loadCalls.first.position, Duration.zero);
    // Dismiss the "TV pe chal raha hai" banner: it sits over the
    // top bar and would swallow the next tap on the Cast button.
    await tester.tap(find.text('Playing on TV'));
    await tester.pump();
  }

  testWidgets('Cast button sits in the top bar next to PiP',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    expect(find.byTooltip('Cast to TV'), findsOneWidget);
    expect(find.byTooltip('Picture-in-Picture'), findsOneWidget);
    expect(playerState(tester).castingForTest, isFalse);
    await flushTimers(tester);
  });

  testWidgets('picker opens and shows the no-devices state',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // While discovery is still running, the picker says so —
    // 'Searching…' — not 'No Cast devices found'.
    expect(find.text('Cast to TV'), findsWidgets);
    expect(find.text('Searching…'), findsOneWidget);
    expect(find.text('No Cast devices found'), findsNothing);
    expect(fake.discoveryStarted, isTrue);
    // After the 8 s search window with no device, the empty state
    // is the pink icon + 'No Cast devices found'.
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('No Cast devices found'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('device found after the picker opens appears in the list',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Nothing yet — still searching. This is the 0.2.19 bug: the
    // picker never showed a device that arrived late.
    expect(find.text('Searching…'), findsOneWidget);
    // The stick answers discovery after the picker is already open.
    fake.emitDevices(<CastDevice>[
      const CastDevice(id: 'dishhome-1', name: 'DishHome Streamer'),
    ]);
    await tester.pump();
    expect(find.text('DishHome Streamer'), findsOneWidget);
    expect(find.text('Searching…'), findsNothing);
    expect(find.text('No Cast devices found'), findsNothing);
    await flushTimers(tester);
  });

  testWidgets('picker lists devices; picking one connects and loads',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    fake.devicesValue = <CastDevice>[
      const CastDevice(id: 'tv-1', name: 'Living Room TV', model: 'Chromecast'),
    ];
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(find.text('Chromecast'), findsOneWidget);
    expect(find.text('No Cast devices found'), findsNothing);
    await tester.tap(find.text('Living Room TV'));
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isTrue);
    expect(playerState(tester).castDeviceForTest, 'Living Room TV');
    expect(
      find.byTooltip('Stop casting — Living Room TV'),
      findsOneWidget,
    );
    expect(find.text('Playing on TV'), findsOneWidget);
    await flushTimers(tester);
  });

  testWidgets('disconnect resumes local at the TV position and records it',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await startCasting(tester);
    // The TV played to 90 s of a 24-minute episode.
    fake.emitMediaState(
      const CastMediaState(
        playing: true,
        position: Duration(seconds: 90),
        duration: Duration(minutes: 24),
        volume: 1,
        ended: false,
      ),
    );
    await tester.pump();
    expect(
      playerState(tester).castStateForTest.position,
      const Duration(seconds: 90),
    );
    playerState(tester).showControlsForTest();
    await tester.pump();
    await tester.tap(find.byTooltip('Stop casting — Living Room TV'));
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isFalse);
    expect(fake.disconnectCalls, 1);
    // Continue Watching / resume recorded the TV position (90 s),
    // not the stale local pause point (0 s).
    await settleRealTime(tester);
    expect(store.resumePositionFor(anime, 1), 90);
    await flushTimers(tester);
  });

  testWidgets('TV ending the episode ends the cast and disconnects',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await startCasting(tester);
    fake.emitMediaState(
      const CastMediaState(
        playing: false,
        position: Duration(minutes: 24),
        duration: Duration(minutes: 24),
        volume: 1,
        ended: true,
      ),
    );
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isFalse);
    expect(fake.disconnectCalls, 1);
    await flushTimers(tester);
  });

  testWidgets('remote disconnect (TV app closed) ends the cast',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await startCasting(tester);
    fake.emitDisconnected();
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isFalse);
    expect(fake.disconnectCalls, 1);
    await flushTimers(tester);
  });

  testWidgets('TV load failure stays local with one short line',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    fake.loadShouldThrow = true;
    fake.devicesValue = <CastDevice>[
      const CastDevice(id: 'tv-1', name: 'Living Room TV'),
    ];
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Living Room TV'));
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isFalse);
    expect(fake.disconnectCalls, 1);
    expect(
      find.text('Could not play on TV — this link does not open on the TV.'),
      findsOneWidget,
    );
    await flushTimers(tester);
  });

  testWidgets('connect failure stays local with one short line',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    fake.connectResult = false;
    fake.devicesValue = <CastDevice>[
      const CastDevice(id: 'tv-1', name: 'Living Room TV'),
    ];
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Living Room TV'));
    await settleRealTime(tester);
    await tester.pump();
    await settleRealTime(tester);
    await tester.pump();
    expect(playerState(tester).castingForTest, isFalse);
    expect(fake.loadCalls, isEmpty);
    expect(
      find.text('Could not connect to the TV — please try again.'),
      findsOneWidget,
    );
    await flushTimers(tester);
  });

  testWidgets('center +10s seeks the TV while casting',
      (WidgetTester tester) async {
    await pumpPlayer(tester);
    await startCasting(tester);
    fake.emitMediaState(
      const CastMediaState(
        playing: true,
        position: Duration(seconds: 100),
        duration: Duration(minutes: 24),
        volume: 1,
        ended: false,
      ),
    );
    await tester.pump();
    playerState(tester).showControlsForTest();
    await tester.pump();
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await settleRealTime(tester);
    await tester.pump();
    expect(fake.seekCalls, contains(const Duration(seconds: 110)));
    expect(playerState(tester).castingForTest, isTrue);
    await flushTimers(tester);
  });

  testWidgets('local download (file://) cannot be cast',
      (WidgetTester tester) async {
    await pumpPlayer(tester, url: 'file:///tmp/ep1.mp4');
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('This video cannot be played on TV.'), findsOneWidget);
    // The picker never opened.
    expect(
      find.text('TV and phone must be on the same Wi-Fi'),
      findsNothing,
    );
    expect(fake.discoveryStarted, isFalse);
    await flushTimers(tester);
  });

  testWidgets('Cast with no video shows one short line',
      (WidgetTester tester) async {
    await pumpPlayer(tester, withStream: false);
    await tester.tap(find.byTooltip('Cast to TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('No video is playing right now.'), findsOneWidget);
    expect(
      find.text('TV and phone must be on the same Wi-Fi'),
      findsNothing,
    );
    await flushTimers(tester);
  });
}
