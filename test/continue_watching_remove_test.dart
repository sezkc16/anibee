// 0.2.17: per-item removal from Continue Watching.
//
// User report 2026-11-24: the long-press sheet on a Continue
// Watching card had no way to drop ONE title — "Remove from list"
// only clears the list status, NOT the watch-history entry, so the
// card stayed in the row; only "Clear All" (wipes everything)
// existed. The sheet now has a red "Remove from Continue Watching"
// row that removes the history entry: the card leaves the row
// immediately and stays gone after a restart. "Remove from list"
// is unchanged (list only) — the second test pins that.
import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/screens/home_screen.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
  });

  // Mirrors the user's real case ("I'm Dating a Dark Summoner",
  // Episode 1) with a title that is NOT in the mock catalogue —
  // the real title also renders in the poster grid below, which
  // would make find.text(title) ambiguous.
  const Anime summoner = Anime(
    id: 'cw-remove-test',
    title: 'Continue Watching Test Anime',
    rating: 7.5,
    year: 2025,
    episodeCount: 12,
    genres: <String>['Fantasy'],
    synopsis: '',
    gradient: <Color>[Colors.black],
  );

  AniListService emptyService() {
    return AniListService(
      client: MockClient((http.Request req) async {
        // Movies: empty live list -> bundled fallback keeps the row.
        // Everything else: empty page (no airing entries).
        return http.Response(
          jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{
              'Page': <String, dynamic>{'media': <dynamic>[]},
            },
          }),
          200,
        );
      }),
    );
  }

  Future<SettingsStore> pumpHome(
    WidgetTester tester, {
    bool seed = true,
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final SettingsStore store = await SettingsStore.load();
    if (seed) {
      await store.recordWatch(
        anime: summoner,
        episode: 1,
        positionSeconds: 300,
        durationSeconds: 1400,
      );
    }
    final AniListService anilist = emptyService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            store: store,
            anilist: anilist,
            airing: AiringService(anilist: anilist),
            airingNotifications: null,
            onOpenAnime: (_) {},
            onWatchNow: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    return store;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.longPress(find.text(summoner.title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Remove from Continue Watching'), findsOneWidget);
    expect(find.text('Remove from list'), findsOneWidget);
  }

  testWidgets('long-press -> Remove from Continue Watching drops the card',
      (WidgetTester tester) async {
    final SettingsStore store = await pumpHome(tester);
    expect(find.text('CONTINUE WATCHING'), findsOneWidget);
    expect(find.text(summoner.title), findsOneWidget);
    expect(store.watchHistory, hasLength(1));

    await openSheet(tester);
    await tester.tap(find.text('Remove from Continue Watching'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Card gone from the row immediately...
    expect(find.text('CONTINUE WATCHING'), findsNothing);
    expect(find.text(summoner.title), findsNothing);
    expect(store.watchHistory, isEmpty);
    // ...and stays gone after a restart (persisted prefs).
    final SettingsStore reopened = await SettingsStore.load();
    expect(reopened.watchHistory, isEmpty);
  });

  testWidgets('Remove from list does NOT drop the card (list only)',
      (WidgetTester tester) async {
    final SettingsStore store = await pumpHome(tester);
    expect(find.text(summoner.title), findsOneWidget);

    await openSheet(tester);
    await tester.tap(find.text('Remove from list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The user's original confusion: this only clears the list
    // status. The card stays in Continue Watching.
    expect(find.text(summoner.title), findsOneWidget);
    expect(store.watchHistory, hasLength(1));
    expect(store.statusOf(summoner), isNull);
  });
}
