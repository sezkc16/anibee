import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/screens/home_screen.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.9 MOVIES row: the last section on Home, below the main poster
/// grid — header "MOVIES", horizontal poster row, tapping a movie
/// opens the normal Detail screen (one "episode"). Live from AniList
/// (type ANIME, format MOVIE, POPULARITY_DESC); a failed or empty
/// query keeps the bundled list so the row is never blank. The row
/// ignores the genre chips and the tab bar.
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

  // Tall viewport so the whole Home list (hero + grid + MOVIES row)
  // is built without scrolling. The hero has a 5 s auto-timer — use
  // explicit pumps, never pumpAndSettle.

  Map<String, dynamic> movieJson({
    required int id,
    required String title,
    int? episodes,
    int? idMal,
  }) {
    return <String, dynamic>{
      'id': id,
      'idMal': idMal,
      'title': <String, dynamic>{'romaji': title, 'english': title},
      'coverImage': <String, dynamic>{
        'large': 'https://cdn.example.com/large.jpg',
        'extraLarge': 'https://cdn.example.com/xl.jpg',
      },
      'format': 'MOVIE',
      'episodes': episodes,
      'seasonYear': 2016,
      'averageScore': 89,
      'genres': <String>['Romance', 'Drama'],
      'description': 'A movie.',
    };
  }

  http.Response moviesPage(List<Map<String, dynamic>> media) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'data': <String, dynamic>{
          'Page': <String, dynamic>{'media': media},
        },
      }),
      200,
    );
  }

  group('AniListService.fetchMovies', () {
    test('maps MOVIE page to display items, episodes forced to 1', () async {
      final AniListService svc = AniListService(
        client: MockClient((http.Request req) async {
          expect(req.body, contains('format:MOVIE'));
          return moviesPage(<Map<String, dynamic>>[
            movieJson(id: 21519, title: 'Your Name', episodes: 1),
            movieJson(id: 199, title: 'Spirited Away', episodes: 0),
            movieJson(id: 20934, title: 'A Silent Voice', episodes: null),
          ]);
        }),
      );
      final List<Anime> movies = await svc.fetchMovies();
      expect(movies.length, 3);
      expect(movies[0].title, 'Your Name');
      expect(movies[0].anilistId, 21519);
      expect(movies[0].episodeCount, 1);
      // The API reports 0 / null episodes for movies — forced to 1
      // so Detail/player treat them like any single-episode title.
      expect(movies[1].episodeCount, 1);
      expect(movies[2].episodeCount, 1);
      expect(movies[0].posterUrl, 'https://cdn.example.com/xl.jpg');
    });

    test('failure returns an empty list (caller falls back)', () async {
      final AniListService svc = AniListService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      expect(await svc.fetchMovies(), isEmpty);
    });
  });

  group('HomeScreen MOVIES row', () {
    Future<void> pumpHome(
      WidgetTester tester,
      AniListService anilist,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final SettingsStore store = await SettingsStore.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(
              store: store,
              anilist: anilist,
              onOpenAnime: (_) {},
              onWatchNow: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('offline: bundled movies render, row never blank', (
      WidgetTester tester,
    ) async {
      final AniListService failing = AniListService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      await pumpHome(tester, failing);
      expect(find.text('MOVIES'), findsOneWidget);
      expect(find.text('Your Name'), findsOneWidget);
      expect(find.text('Spirited Away'), findsOneWidget);
      expect(find.text('Demon Slayer: Mugen Train'), findsOneWidget);
      // A movie card shows "Movie" in its meta line, not an
      // episode count.
      expect(find.textContaining('Movie'), findsWidgets);
    });

    testWidgets('live movies replace the bundled list', (
      WidgetTester tester,
    ) async {
      final AniListService live = AniListService(
        client: MockClient((http.Request req) async {
          return moviesPage(<Map<String, dynamic>>[
            movieJson(id: 21519, title: 'Your Name', episodes: 1),
            movieJson(id: 99999, title: 'Test Movie Live', episodes: 1),
          ]);
        }),
      );
      await pumpHome(tester, live);
      expect(find.text('MOVIES'), findsOneWidget);
      expect(find.text('Test Movie Live'), findsOneWidget);
      // Bundled-only titles are gone once the live list lands.
      expect(find.text('Spirited Away'), findsNothing);
    });

    testWidgets('MOVIES row ignores the genre-chip filter', (
      WidgetTester tester,
    ) async {
      final AniListService failing = AniListService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      await pumpHome(tester, failing);
      expect(find.text('MOVIES'), findsOneWidget);
      expect(find.text('Your Name'), findsOneWidget);
      // Frieren is in the TRENDING grid but is NOT Action.
      expect(find.text("Frieren: Beyond Journey's End"), findsOneWidget);
      // The 'Action' chip lives in the horizontal chips row (the
      // MOVIES row has no 'Action' text, the hero pill is a PageView).
      final Finder actionChip = find.descendant(
        of: find.byWidgetPredicate(
          (Widget w) =>
              w is ListView && w.scrollDirection == Axis.horizontal,
        ),
        matching: find.text('Action'),
      );
      await tester.tap(actionChip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // The grid filtered (Frieren gone) but the MOVIES row stays.
      expect(find.text("Frieren: Beyond Journey's End"), findsNothing);
      expect(find.text('MOVIES'), findsOneWidget);
      expect(find.text('Your Name'), findsOneWidget);
    });

    testWidgets('tapping a movie opens Detail via onOpenAnime', (
      WidgetTester tester,
    ) async {
      final AniListService failing = AniListService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      Anime? opened;
      final SettingsStore store = await SettingsStore.load();
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(
              store: store,
              anilist: failing,
              onOpenAnime: (Anime a) => opened = a,
              onWatchNow: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Your Name').first);
      await tester.pump();
      expect(opened, isNotNull);
      expect(opened!.title, 'Your Name');
      expect(opened!.episodeCount, 1);
    });
  });
}
