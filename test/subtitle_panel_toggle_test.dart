import 'package:anibee/models.dart';
import 'package:anibee/player/trailer_player.dart';
import 'package:anibee/screens/full_player_screen.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 0.2.28: the Auto-Adjust toggle in the Subtitles panel rendered
// as one flat green pill with NO white knob when ON (user
// screenshot, 2026-11-25: "pura green chotasa"). Root cause: the
// shared _toggleRow set only activeThumbColor: accent (green), so
// the thumb was green on the green track. The fix: white knob on
// the accent track when ON, white knob on a muted track when OFF.
// This test pumps the real panel and asserts the rendered Switch
// colours — not just that a switch is present (a presence-only
// assertion would have passed on the broken build too).
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
    id: 'toggle-test',
    title: 'Toggle Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for the 0.2.28 toggle fix.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  /// The Switch rendered for the toggle row labelled [label].
  Switch switchFor(WidgetTester tester, String label) {
    final Finder tile = find.ancestor(
      of: find.text(label),
      matching: find.byType(SwitchListTile),
    );
    expect(tile, findsOneWidget, reason: 'no toggle row for $label');
    return tester.widget<Switch>(
      find.descendant(of: tile, matching: find.byType(Switch)),
    );
  }

  testWidgets('Auto-Adjust ON: white knob on the accent track',
      (WidgetTester tester) async {
    final SettingsStore store = await SettingsStore.load();
    // Default is ON (subAutoAdjust defaults to true).
    expect(store.subAutoAdjust, isTrue);
    late TrailerPlayer trailer;
    await tester.runAsync(() async {
      trailer = TrailerPlayer();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FullPlayerScreen(
          trailer: trailer,
          store: store,
          anime: anime,
          episodes: mockEpisodes(anime),
          initialEpisode: mockEpisodes(anime).first,
        ),
      ),
    );
    await tester.pump();

    // Open the Subtitles panel (controls start visible).
    await tester.tap(find.byTooltip('Subtitles'));
    await tester.pump();

    final Color accent =
        Theme.of(tester.element(find.byType(FullPlayerScreen)))
            .colorScheme
            .primary;

    // Auto-Adjust ON: the knob must be white and must differ from
    // the track — the broken build had a green thumb on a green
    // track (one flat green pill, no knob).
    final Switch autoAdjust = switchFor(tester, 'Auto-Adjust');
    expect(autoAdjust.value, isTrue);
    expect(autoAdjust.activeThumbColor, Colors.white);
    expect(autoAdjust.activeTrackColor, accent);
    expect(autoAdjust.activeThumbColor, isNot(autoAdjust.activeTrackColor));

    // The Bold toggle shares the same _toggleRow — it had the
    // same broken rendering and must be fixed too.
    final Switch bold = switchFor(tester, 'Bold');
    expect(bold.activeThumbColor, Colors.white);
    expect(bold.activeTrackColor, accent);
    expect(bold.activeThumbColor, isNot(bold.activeTrackColor));

    // OFF state: white knob on a MUTED track — clearly different
    // from the green ON track, not another flat green pill.
    // The row sits below the fold in the scrollable panel — bring
    // it into view first, or the tap misses (hit-test warning).
    await tester.ensureVisible(find.text('Auto-Adjust'));
    await tester.pump();
    await tester.tap(
      find.ancestor(
        of: find.text('Auto-Adjust'),
        matching: find.byType(SwitchListTile),
      ),
    );
    await tester.pump();
    final Switch off = switchFor(tester, 'Auto-Adjust');
    expect(off.value, isFalse);
    expect(store.subAutoAdjust, isFalse);
    expect(off.inactiveThumbColor, Colors.white);
    expect(off.inactiveTrackColor, Colors.white24);
    expect(off.inactiveTrackColor, isNot(accent));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    trailer.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
