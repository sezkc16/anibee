import 'package:anibee/models.dart';
import 'package:anibee/widgets/episode_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_skip_times_harness.dart';

/// 0.2.10 in-player episode chooser: the 0.2.9 sheet was a fixed
/// 0.55 box PLUS SafeArea/chrome on top, so it rendered ~0.63 tall
/// on the phone — and for a short anime (11 eps = 3 grid rows) most
/// of that height was empty space. Now the sheet is CONTENT-DRIVEN
/// (shrink-wrapped, 0.55 max cap): a short anime gets a SHORT sheet,
/// and only a long list grows to the cap and scrolls. 0.2.11: short
/// anime (<= 12 eps) show the Detail-style episode CARDS (thumbnail
/// + EP badge + title + 2-line synopsis + date, scrollable list),
/// not the 0.2.10 single row of number boxes; more than 12 episodes
/// keep the 5-column grid. Title is one line with ellipsis. Accent
/// selected card + tap-to-select unchanged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(configureSkipTestBindings);

  const Anime shortAnime = Anime(
    id: 'sheet-demon-slayer',
    title: 'Demon Slayer: Kimetsu no Yaiba Entertainment District Arc',
    rating: 4.5,
    year: 2022,
    episodeCount: 11,
    genres: <String>['Action'],
    synopsis: 'Test anime for the short-anime single-row sheet.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  const Anime spy = Anime(
    id: 'sheet-spy',
    title: 'SPY x FAMILY',
    rating: 4.5,
    year: 2022,
    episodeCount: 20,
    genres: <String>['Comedy'],
    synopsis: 'Test anime for the episode sheet size test.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  const Anime longAnime = Anime(
    id: 'sheet-long',
    title: 'Long Test Anime',
    rating: 4.0,
    year: 2020,
    episodeCount: 47,
    genres: <String>['Action'],
    synopsis: 'Test anime for the long-anime grid sheet.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  Future<SkipPlayerHarness> openSheet(
    WidgetTester tester,
    Anime anime,
  ) async {
    final SkipPlayerHarness harness = SkipPlayerHarness();
    await harness.pumpPlayer(tester, anime: anime);

    // The top bar (Episodes button) lives in the controls layer —
    // make sure it is visible before tapping.
    if (!harness.playerState(tester).controlsVisibleForTest) {
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }
    expect(harness.playerState(tester).controlsVisibleForTest, isTrue);

    await tester.tap(find.byTooltip('Episodes'));
    // The tap's onTap fires during the first pump, which only
    // STARTS the sheet's entrance animation — a second pump with
    // duration is needed to advance it (otherwise the sheet sits
    // translated below the viewport and its cells are untappable).
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    return harness;
  }

  Future<void> closeSheetByTap(
    WidgetTester tester,
    String cell,
  ) async {
    // Same double-pump: the first pump processes the tap and starts
    // the sheet's exit animation; the second advances it to done.
    await tester.tap(find.text(cell));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(BottomSheet)).height;

  testWidgets('11 episodes: episode CARDS (Detail style), tap switches', (
    WidgetTester tester,
  ) async {
    final SkipPlayerHarness harness = await openSheet(tester, shortAnime);

    // Title is one line (ellipsis), not two.
    final Finder title = find.textContaining('Episodes — ');
    expect(title, findsOneWidget);
    expect(tester.getSize(title).height, lessThan(30));

    // Cards, not number boxes: EP badges + titles, same visuals as
    // the Detail screen (0.2.31: the placeholder title is the
    // honest 'Episode 1' — the M1 fake 'Infiltration Protocol' is
    // gone; real titles come from Kitsu on Detail).
    expect(find.byType(EpisodeCard), findsWidgets);
    expect(find.text('EP 1'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);

    // 11 cards grow to the 0.55 cap (330pt of the 600pt test
    // viewport) and scroll: the last card appears after scrolling.
    expect(sheetHeight(tester), closeTo(330.0, 1.0));
    await tester.scrollUntilVisible(find.text('EP 11'), 300);
    await tester.pump();
    expect(find.text('EP 11'), findsOneWidget);

    // Tap the last card — the sheet closes and the episode switches.
    await tester.tap(find.text('EP 11'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.textContaining('Episodes — '), findsNothing);
    expect(harness.playerState(tester).currentEpisodeForTest, 11);

    await harness.disposePlayer(tester);
  });

  testWidgets('20 episodes: 5-column grid, capped at 0.55, still selects',
      (WidgetTester tester) async {
    final SkipPlayerHarness harness = await openSheet(tester, spy);

    expect(find.text('Episodes — SPY x FAMILY'), findsOneWidget);
    // 4 grid rows of content would be ~420pt — capped at 0.55 of
    // the 600pt test viewport = 330pt.
    expect(sheetHeight(tester), closeTo(330.0, 1.0));
    // The grid still shows its episodes.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);

    await closeSheetByTap(tester, '5');
    expect(find.text('Episodes — SPY x FAMILY'), findsNothing);
    expect(harness.playerState(tester).currentEpisodeForTest, 5);

    await harness.disposePlayer(tester);
  });

  testWidgets('47 episodes: 5-column grid (not a single row)', (
    WidgetTester tester,
  ) async {
    final SkipPlayerHarness harness = await openSheet(tester, longAnime);

    // Grid layout: cells 1-5 share a row, cell 6 is on the next row.
    final double rowY = tester.getCenter(find.text('1')).dy;
    expect(tester.getCenter(find.text('5')).dy, rowY);
    expect(tester.getCenter(find.text('6')).dy, isNot(rowY));
    // Long list grows to the cap and scrolls.
    expect(sheetHeight(tester), closeTo(330.0, 1.0));

    await closeSheetByTap(tester, '5');
    expect(harness.playerState(tester).currentEpisodeForTest, 5);

    await harness.disposePlayer(tester);
  });
}
