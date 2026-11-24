import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/screens/search_screen.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.12 item 9: "bohot sare anime movies dikh nhi rahe search se"
/// — The Garden of Words, Noblesse, Black Clover S2. Verified causes:
/// (1) a failed remote search was silent (`_postSafe` swallowed it,
/// so the screen showed a bare "No anime found" and movies — which
/// the 39-title local catalogue barely has — vanished); (2) season
/// suffixes ("S2") matched nothing on AniList or locally; (3) a
/// MOVIE with episodes null got episodeCount 0 (dead Detail).
/// Mocked AniList responses only — the VM cannot reach GraphQL
/// live (Cloudflare-blocked). No cover images in fixtures (a null
/// poster renders initials; a real URL would hang Image.network
/// in the VM).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 0.2.25: SearchScreen takes a SettingsStore (recent searches).
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async => null,
    );
  });

  Map<String, dynamic> media({
    required int id,
    required String english,
    String format = 'TV',
    int? episodes = 12,
  }) {
    return <String, dynamic>{
      'id': id,
      'idMal': null,
      'title': <String, dynamic>{'romaji': english, 'english': english},
      'format': format,
      'episodes': episodes,
      'seasonYear': 2020,
      'averageScore': 80,
      'genres': <String>['Drama'],
      'description': 'Test title.',
    };
  }

  Map<String, dynamic> pageJson(List<Map<String, dynamic>> m) {
    return <String, dynamic>{
      'data': <String, dynamic>{
        'Page': <String, dynamic>{'media': m},
      },
    };
  }

  MockClient clientFor(Map<String, List<Map<String, dynamic>>> byQuery) {
    return MockClient((http.Request req) async {
      // 0.2.15: the Kitsu fallback is a GET with no body — route it
      // to an empty Kitsu payload instead of parsing a body that
      // isn't there.
      if (req.url.host == 'kitsu.io') {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'data': <dynamic>[],
            'included': <dynamic>[],
          })),
          200,
        );
      }
      final Map<String, dynamic> body =
          jsonDecode(req.body) as Map<String, dynamic>;
      final String q =
          (body['variables'] as Map<String, dynamic>)['q'] as String;
      final List<Map<String, dynamic>> m = byQuery[q] ?? <Map<String, dynamic>>[];
      return http.Response.bytes(
        utf8.encode(jsonEncode(pageJson(m))),
        200,
      );
    });
  }

  Future<void> pumpSearch(
    WidgetTester tester,
    AniListService anilist,
    void Function(Anime) onOpen,
  ) async {
    final SettingsStore store = await SettingsStore.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchScreen(
            onOpenAnime: onOpen,
            anilist: anilist,
            store: store,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    // Debounce is 400 ms (fake time) + the mock call settles.
    // 0.2.13: a failed lookup retries once after 300 ms — pump
    // past that window too, or the retry never lands in the test.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('The Garden of Words (movie) appears from remote search',
      (WidgetTester tester) async {
    Anime? opened;
    await pumpSearch(
      tester,
      AniListService(
        client: clientFor(<String, List<Map<String, dynamic>>>{
          'The Garden of Words': <Map<String, dynamic>>[
            media(
              id: 10408,
              english: 'The Garden of Words',
              format: 'MOVIE',
              episodes: null,
            ),
          ],
        }),
      ),
      (Anime a) => opened = a,
    );
    await search(tester, 'The Garden of Words');
    expect(find.text('THE GARDEN OF WORDS'), findsWidgets);
    expect(find.text("No anime found. Try another search."), findsNothing);

    // Tapping opens Detail with a playable single-episode movie.
    // The card sits below the fold on the 800x600 test surface —
    // scroll it into view first (the tap point would otherwise be
    // off-screen and the tap would miss).
    await tester.ensureVisible(find.text('THE GARDEN OF WORDS').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('THE GARDEN OF WORDS').first);
    await tester.pump();
    expect(opened, isNotNull);
    expect(opened!.anilistId, 10408);
    expect(opened!.episodeCount, 1);
  });

  testWidgets('"Black Clover S2" finds Black Clover (local + remote)',
      (WidgetTester tester) async {
    await pumpSearch(
      tester,
      AniListService(
        client: clientFor(<String, List<Map<String, dynamic>>>{
          'Black Clover S2': <Map<String, dynamic>>[],
          'Black Clover': <Map<String, dynamic>>[
            media(id: 97940, english: 'Black Clover', episodes: 170),
          ],
        }),
      ),
      (_) {},
    );
    await search(tester, 'Black Clover S2');
    expect(find.text('BLACK CLOVER'), findsWidgets);
    expect(find.text("No anime found. Try another search."), findsNothing);
  });

  testWidgets('dead AniList shows the honest banner, local results stay',
      (WidgetTester tester) async {
    await pumpSearch(
      tester,
      AniListService(
        client: MockClient((http.Request req) async {
          return http.Response('rate limited', 429);
        }),
      ),
      (_) {},
    );
    await search(tester, 'Frieren');
    expect(
      find.text("Couldn't reach AniList — showing local results."),
      findsOneWidget,
    );
    // Frieren is in the local catalogue — it still shows.
    // (Catalogue title is the full 'Frieren: Beyond Journey's End'.)
    expect(find.text("FRIEREN: BEYOND JOURNEY'S END"), findsWidgets);
  });

  testWidgets('diagnostic line shows what AniList actually returned',
      (WidgetTester tester) async {
    // 0.2.13: the phone must be able to tell a dead lookup from a
    // genuine no-match — the line under the count says so.
    final AniListService anilist = AniListService(
      client: clientFor(<String, List<Map<String, dynamic>>>{
        'black clover': <Map<String, dynamic>>[
          media(id: 97940, english: 'Black Clover', episodes: 170),
          media(
            id: 142511,
            english: 'Black Clover: Sword of the Wizard King',
            format: 'MOVIE',
            episodes: null,
          ),
        ],
      }),
    );
    await pumpSearch(tester, anilist, (_) {});
    await search(tester, 'black clover');
    expect(find.text('AniList: ok · 2 from AniList'), findsOneWidget);
    expect(
      find.text('BLACK CLOVER: SWORD OF THE WIZARD KING'),
      findsWidgets,
    );
  });

  testWidgets('diagnostic line reports a failed lookup, not bare 0 results',
      (WidgetTester tester) async {
    final AniListService anilist = AniListService(
      client: MockClient((http.Request req) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{'data': null})),
          200,
        );
      }),
    );
    await pumpSearch(tester, anilist, (_) {});
    await search(tester, 'noblesse');
    expect(
      find.text("Couldn't reach AniList — showing local results."),
      findsOneWidget,
    );
    expect(
      find.text('AniList: failed (no data) · local only'),
      findsOneWidget,
    );
  });

  testWidgets('0.2.17: clear (X) button empties the field + results',
      (WidgetTester tester) async {
    final AniListService anilist = AniListService(
      client: clientFor(<String, List<Map<String, dynamic>>>{
        'monster': <Map<String, dynamic>>[
          media(id: 1, english: 'Monster', episodes: 74),
        ],
      }),
    );
    await pumpSearch(tester, anilist, (_) {});

    // No X on an empty field.
    expect(find.byTooltip('Clear search'), findsNothing);

    await search(tester, 'monster');
    expect(find.text('MONSTER'), findsWidgets);

    // X appears once the field is non-empty.
    expect(find.byTooltip('Clear search'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    await tester.pump();

    // Field empty, X gone, remote results cleared back to the
    // empty/search-home state (no results-count line).
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(find.byTooltip('Clear search'), findsNothing);
    expect(find.text('MONSTER'), findsNothing);
    expect(find.textContaining('results'), findsNothing);
  });
}
