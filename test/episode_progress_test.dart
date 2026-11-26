import 'package:anibee/models.dart';
import 'package:anibee/settings_store.dart';
import 'package:anibee/widgets/episode_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.5: episode watch progress + completed state, from the real
/// persisted progress (resume position + duration) — never invented.
/// Cards show a thin accent progress bar + completed check; the
/// 5-column number grid shows a small watched tick in the corner
/// (number stays visible) + a small download state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (MethodCall call) async => null,
        );
  });

  const Anime anime = Anime(
    id: 'progress-test',
    anilistId: 999001,
    title: 'Progress Test Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime for episode progress.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  const Anime longAnime = Anime(
    id: 'progress-test-long',
    anilistId: 999002,
    title: 'Progress Test Long Anime',
    rating: 4.0,
    year: 2024,
    episodeCount: 47,
    genres: <String>['Action'],
    synopsis: 'Test anime for the grid watched tick.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  test('parseDurationString handles mm:ss and h:mm:ss', () {
    expect(SettingsStore.parseDurationString('23:12'), 1392);
    expect(SettingsStore.parseDurationString('1:02:30'), 3750);
    expect(SettingsStore.parseDurationString('xx'), isNull);
    expect(SettingsStore.parseDurationString('0:00'), isNull);
  });

  test('partial progress is the real resume fraction', () async {
    final SettingsStore store = await SettingsStore.load();
    final List<Episode> eps = mockEpisodes(anime);
    final String key = store.resumeKeyFor(anime, 1);
    await store.setResumeSeconds(key, 690);
    await store.setResumeDuration(key, 1380);
    expect(store.episodeProgressFor(anime, eps[0]), closeTo(0.5, 0.01));
    expect(store.isEpisodeCompleted(anime, eps[0]), isFalse);
  });

  test('completed marker makes progress 1.0', () async {
    final SettingsStore store = await SettingsStore.load();
    final List<Episode> eps = mockEpisodes(anime);
    final String key = store.resumeKeyFor(anime, 2);
    await store.markEpisodeCompleted(key);
    expect(store.isEpisodeCompleted(anime, eps[1]), isTrue);
    expect(store.episodeProgressFor(anime, eps[1]), 1.0);
  });

  test(
    'legacy inference: a later episode started completes earlier ones',
    () async {
      final SettingsStore store = await SettingsStore.load();
      final List<Episode> eps = mockEpisodes(anime);
      await store.markProgress(anime, 5);
      expect(store.isEpisodeCompleted(anime, eps[3]), isTrue);
      expect(store.episodeProgressFor(anime, eps[3]), 1.0);
      // The episode actually open is not completed.
      expect(store.isEpisodeCompleted(anime, eps[4]), isFalse);
      expect(store.episodeProgressFor(anime, eps[8]), 0);
    },
  );

  testWidgets('cards show a progress bar and a completed check', (
    WidgetTester tester,
  ) async {
    // Own anime id: the store tests above already wrote progress
    // for `anime` into the shared mock prefs.
    const Anime cardAnime = Anime(
      id: 'progress-test-cards',
      anilistId: 999011,
      title: 'Progress Test Cards Anime',
      rating: 4.0,
      year: 2024,
      episodeCount: 12,
      genres: <String>['Action'],
      synopsis: 'Test anime for card progress.',
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    );
    final SettingsStore store = await SettingsStore.load();
    final List<Episode> eps = mockEpisodes(cardAnime);
    await store.setResumeSeconds(store.resumeKeyFor(cardAnime, 1), 690);
    await store.setResumeDuration(store.resumeKeyFor(cardAnime, 1), 1380);
    await store.markEpisodeCompleted(store.resumeKeyFor(cardAnime, 2));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EpisodeSection(
              anime: cardAnime,
              episodes: eps,
              store: store,
              onPlay: (_) {},
              onToggleDownload: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // One thin bar per episode with real progress (partial + full).
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    // The completed card carries the check badge.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text('EP 1'), findsOneWidget);
    expect(find.text('EP 2'), findsOneWidget);
  });

  testWidgets('grid shows a small watched tick and download state', (
    WidgetTester tester,
  ) async {
    final SettingsStore store = await SettingsStore.load();
    final List<Episode> eps = mockEpisodes(longAnime);
    await store.markEpisodeCompleted(store.resumeKeyFor(longAnime, 3));
    await store.setDownloadStatus('progress-test-long:5', 'downloading');
    await store.setDownloadProgress('progress-test-long:5', 0.5);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EpisodeSection(
              anime: longAnime,
              episodes: eps,
              store: store,
              onPlay: (_) {},
              onToggleDownload: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Small watched tick on the completed cell; the number is still
    // there, not covered by a badge. The tick is the 12pt check —
    // the grid's Sub/Dub dropdown carries its own 16pt accent check
    // for the selected value (0.2.8), so scope the finder by size.
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Icon && w.icon == Icons.check_rounded && w.size == 12,
      ),
      findsOneWidget,
    );
    expect(find.text('3'), findsOneWidget);
    // Small download spinner on the downloading cell.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('grid long-press opens the episode options menu', (
    WidgetTester tester,
  ) async {
    final SettingsStore store = await SettingsStore.load();
    final List<Episode> eps = mockEpisodes(longAnime);
    final List<Episode> played = <Episode>[];
    final List<Episode> downloaded = <Episode>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EpisodeSection(
              anime: longAnime,
              episodes: eps,
              store: store,
              onPlay: played.add,
              onToggleDownload: downloaded.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('7'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Sheet title is "Episode N · <title>" with a real title; with
    // the 0.2.31 honest placeholders the title IS 'Episode 7', so
    // the header is just 'Episode 7' (no 'Episode 7 · Episode 7').
    expect(find.text('Episode 7'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(downloaded.map((Episode e) => e.number), <int>[7]);
    expect(played, isEmpty);
  });
}
