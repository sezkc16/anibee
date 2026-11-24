// AIRING SOON (0.2.10): Home section above MOVIES, fed by a mocked
// AniListService — renders soonest-first entries with a live
// countdown, tapping a card opens Detail; hidden when nothing airs.
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

  // Tall viewport so the whole Home list (hero + grid + AIRING SOON +
  // MOVIES) is built without scrolling. The hero has a 5 s auto-timer
  // — use explicit pumps, never pumpAndSettle.

  Map<String, dynamic> airingMedia({
    required int id,
    required String title,
    required int airingAt,
    required int episode,
  }) {
    return <String, dynamic>{
      'id': id,
      'title': <String, dynamic>{
        'romaji': title,
        'english': null,
        'userPreferred': title,
      },
      'nextAiringEpisode': <String, dynamic>{
        'airingAt': airingAt,
        'episode': episode,
      },
      'episodes': 100,
      // No posterUrl on purpose: a real Image.network URL hangs the
      // VM test host; the card renders its placeholder instead.
      'coverImage': <String, dynamic>{'large': null},
    };
  }

  http.Response airingPage(List<Map<String, dynamic>> media) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'data': <String, dynamic>{
          'Page': <String, dynamic>{'media': media},
        },
      }),
      200,
    );
  }

  AniListService serviceWithAiring(List<Map<String, dynamic>> media) {
    return AniListService(
      client: MockClient((http.Request req) async {
        if (req.body.contains('format:MOVIE')) {
          // Movies: empty live list -> bundled fallback keeps the row.
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{
                'Page': <String, dynamic>{'media': <dynamic>[]},
              },
            }),
            200,
          );
        }
        return airingPage(media);
      }),
    );
  }

  Future<void> pumpHome(
    WidgetTester tester,
    AniListService anilist, {
    Anime? opened,
    required void Function(Anime) onOpen,
  }) async {
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
            airing: AiringService(anilist: anilist),
            airingNotifications: null,
            onOpenAnime: onOpen,
            onWatchNow: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('HomeScreen AIRING SOON section', () {
    testWidgets('renders entries with countdown, tap opens Detail', (
      WidgetTester tester,
    ) async {
      final DateTime now = DateTime.now();
      final int firstAt = now
          .add(const Duration(days: 2, hours: 4, minutes: 30))
          .millisecondsSinceEpoch ~/
          1000;
      final int secondAt =
          now.add(const Duration(hours: 5)).millisecondsSinceEpoch ~/ 1000;
      Anime? opened;
      await pumpHome(
        tester,
        serviceWithAiring(<Map<String, dynamic>>[
          airingMedia(
            id: 21,
            title: 'Airing Show One',
            airingAt: firstAt,
            episode: 12,
          ),
          airingMedia(
            id: 22,
            title: 'Airing Show Two',
            airingAt: secondAt,
            episode: 4,
          ),
        ]),
        onOpen: (Anime a) => opened = a,
      );

      expect(find.text('AIRING SOON'), findsOneWidget);
      expect(find.text('Airing Show One'), findsOneWidget);
      expect(find.text('Airing Show Two'), findsOneWidget);
      // 2d 4h 30m from now: the countdown text is robust to the few
      // seconds the pumps take.
      expect(find.textContaining('EP 12 · in 2d 4h'), findsOneWidget);
      expect(find.textContaining('EP 4 · in'), findsOneWidget);
      // The section sits above MOVIES.
      final Offset airingTop = tester.getTopLeft(find.text('AIRING SOON'));
      final Offset moviesTop = tester.getTopLeft(find.text('MOVIES'));
      expect(airingTop.dy, lessThan(moviesTop.dy));

      await tester.tap(find.text('Airing Show One'));
      await tester.pump();
      expect(opened, isNotNull);
      expect(opened!.anilistId, 21);
      expect(opened!.title, 'Airing Show One');
      // 0.2.13: the aired count travels with the Anime (EP 12 airs
      // next → 11 aired), plus the upcoming EP + air date — the
      // old behaviour passed AniList `episodes` (100) straight
      // through, which is wrong for a still-airing show.
      expect(opened!.episodeCount, 11);
      expect(opened!.nextEpisode, 12);
      expect(opened!.nextEpisodeIn, 'in 2d 4h');
      expect(opened!.nextEpisodeAt, isNotNull);
    });

    testWidgets('hidden when nothing is airing', (
      WidgetTester tester,
    ) async {
      await pumpHome(
        tester,
        serviceWithAiring(<Map<String, dynamic>>[]),
        onOpen: (_) {},
      );
      expect(find.text('AIRING SOON'), findsNothing);
      expect(find.text('MOVIES'), findsOneWidget);
    });

    testWidgets('offline: section hidden, Home still works', (
      WidgetTester tester,
    ) async {
      final AniListService failing = AniListService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      await pumpHome(tester, failing, onOpen: (_) {});
      expect(find.text('AIRING SOON'), findsNothing);
      expect(find.text('MOVIES'), findsOneWidget);
      expect(find.text('Your Name'), findsOneWidget);
    });
  });
}
