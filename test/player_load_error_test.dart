import 'package:anibee/player/trailer_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 0.2.27: the player error state was a false positive (phone-proven
// 2026-11-25 — JJK EP3 via Anime-Sama: "Couldn't load episode"
// while the episode's AUDIO kept playing, and the audio kept
// playing after going back; then the SAME error mid-playback on
// Miruro and AniKoto after ~10–15 min; the exact repro turned out
// to be PAUSE → app backgrounded → return).
//
// Root cause: media_kit forwards EVERY mpv log line at level
// `error` (ffmpeg/tcp segment errors, vd/ad/cplayer errors) into
// `player.stream.error` — including TRANSIENT ones a healthy
// playback survives. The old code treated the first such event as
// a fatal load failure and the full player REMOVED the Video
// widget, so the video could never come back even after mpv
// recovered (the VM probe saw `hls: Failed to open segment 2`
// while mpv played 300 frames fine, and curl saw transient
// connection failures on segments that succeed on retry).
// Now an error event surfaces only after a 3 s grace AND only
// when playback is not advancing; an error while playback is
// advancing is swallowed; a surfaced error clears itself if
// playback recovers; and an error while PAUSED (after having
// played) is held — it only starts its grace window when a play
// is attempted. A load that never started playing is a genuine
// load failure: its grace window runs and it surfaces.
//
// The mpv errors are fed through the real handler via
// [TrailerPlayer.simulatePlayerErrorForTest] (same code path as
// the real `player.stream.error` subscription).
//
// VM LIMIT (proven by probe, 2026-11-25): mpv's time-pos NEVER
// advances headless (no audio output, mocked video output —
// playing=true, duration=5 s, position stuck at 0 for 6+ s even
// with an AAC track), AND only the FIRST real-mpv load in a
// flutter_tester process ever reports a duration — a second load
// never arrives (probed: load 1 in 9.6 s, load 2 still 0 after
// 60 s). So these logic tests use a bare TrailerPlayer (no
// screen, no clip — no mpv load at all) and force the
// "playback is advancing" signal through
// [TrailerPlayer.advancingOverrideForTest] and the recovery tick
// through [TrailerPlayer.simulatePlaybackAdvancedForTest]; the
// phone is the authority for the real signal. The tests that
// need a real load live in their own files, one load per file:
// player_audio_leak_test.dart, player_stale_load_test.dart,
// player_reconnect_test.dart, player_retry_resolve_test.dart.
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
      (MethodCall call) async => null,
    );
  });

  late TrailerPlayer trailer;

  setUp(() {
    trailer = TrailerPlayer();
  });

  tearDown(() {
    trailer.dispose();
  });

  testWidgets('error while playback is advancing is swallowed',
      (WidgetTester tester) async {
    // The phone case, verbatim: a segment fetch fails mid-play.
    // Playback IS advancing (forced — the VM cannot produce the
    // signal, see the file header).
    trailer.advancingOverrideForTest = true;
    trailer.simulatePlayerErrorForTest(
      'ffmpeg tcp: http://example.invalid/seg-42.ts: '
      'HTTP error 403 Forbidden',
    );
    // Past the whole grace window — the error must never appear.
    await tester.pump(const Duration(seconds: 4));
    expect(trailer.loadError, isNull);
  });

  testWidgets('error while idle surfaces only after the grace window',
      (WidgetTester tester) async {
    expect(trailer.loadError, isNull);
    trailer.simulatePlayerErrorForTest('cplayer: Failed to load media');
    // Inside the grace window: no error yet.
    await tester.pump(const Duration(seconds: 1));
    expect(trailer.loadError, isNull);
    // Past the grace window with nothing playing: the error shows.
    await tester.pump(const Duration(seconds: 3));
    expect(trailer.loadError, isNotNull);
  });

  testWidgets('error while paused is held, not surfaced',
      (WidgetTester tester) async {
    // The player HAS played (modelled by the advancing tick) and
    // is now paused (never started a new load): an error arriving
    // now must be HELD, not surfaced — a paused player has
    // nothing to fail (the 02:30 phone repro: pause → background
    // → return).
    trailer.simulatePlaybackAdvancedForTest();
    trailer.advancingOverrideForTest = null;
    trailer.simulatePlayerErrorForTest('cplayer: Failed to load media');
    await tester.pump(const Duration(seconds: 5));
    expect(trailer.loadError, isNull);
    // A play attempt whose playback advances drops the held
    // error, never showing it.
    trailer.advancingOverrideForTest = true;
    trailer.simulatePlaybackAdvancedForTest();
    await tester.pump(const Duration(seconds: 1));
    expect(trailer.loadError, isNull);
  });

  testWidgets('surfaced error clears itself when playback recovers',
      (WidgetTester tester) async {
    trailer.simulatePlayerErrorForTest('cplayer: Failed to load media');
    await tester.pump(const Duration(seconds: 4));
    expect(trailer.loadError, isNotNull);
    // Playback recovers (advancing forced): the recovery tick
    // clears the error (the old code kept the error screen
    // forever, with audio playing behind it).
    trailer.advancingOverrideForTest = true;
    trailer.simulatePlaybackAdvancedForTest();
    await tester.pump();
    expect(trailer.loadError, isNull);
  });

  testWidgets('error while paused but never played still surfaces',
      (WidgetTester tester) async {
    // The other paused state: a load that NEVER started playing
    // (spinner on a dead stream) is a genuine load failure —
    // its grace window runs and it surfaces. (Distinguished
    // from the held case by [_everPlayed]: false here.)
    trailer.simulatePlayerErrorForTest('cplayer: Failed to load media');
    await tester.pump(const Duration(seconds: 4));
    expect(trailer.loadError, isNotNull);
  });
}
