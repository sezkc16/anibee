import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/player/trailer_player.dart';
import 'package:anibee/screens/detail_screen.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anikage_resolver.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/animesama_resolver.dart';
import 'package:anibee/services/anisuge_resolver.dart';
import 'package:anibee/services/app_services.dart';
import 'package:anibee/services/debrid_service.dart';
import 'package:anibee/services/download_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/services/oauth_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.9 season selector: the 0.2.8 phone test showed NO selector on
/// My Hero Academia because the catalogue entry had no stored
/// anilistId and `_loadSeasons` returned immediately. It now resolves
/// the id by title first (same helper as the Miruro resolver), then
/// walks the SEQUEL/PREQUEL chain.
///
/// Harness copied from detail_poster_test.dart.
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

  // MHA exactly as the catalogue had it in 0.2.8: NO anilistId.
  const Anime mha = Anime(
    id: 'my-hero-academia',
    title: 'My Hero Academia',
    rating: 4.0,
    year: 2016,
    episodeCount: 138,
    genres: <String>['Action'],
    synopsis: 'Test anime for the season selector test.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
  );

  Map<String, dynamic> mediaJson({
    required int id,
    int? idMal,
    int episodes = 12,
  }) {
    return <String, dynamic>{
      'id': id,
      'idMal': idMal,
      'title': <String, dynamic>{
        'romaji': 'My Hero Academia',
        'english': 'My Hero Academia',
      },
      'coverImage': <String, dynamic>{
        'large': 'https://cdn.example.com/large.jpg',
        'extraLarge': 'https://cdn.example.com/xl.jpg',
      },
      'format': 'TV',
      'episodes': episodes,
      'seasonYear': 2016,
      'averageScore': 80,
      'genres': <String>['Action'],
      'description': 'A hero rises.',
    };
  }

  Map<String, dynamic> relationsJson({
    required int id,
    required int episodes,
    List<Map<String, dynamic>> edges = const <Map<String, dynamic>>[],
  }) {
    return <String, dynamic>{
      'data': <String, dynamic>{
        'Media': <String, dynamic>{
          'id': id,
          'title': <String, dynamic>{
            'romaji': 'My Hero Academia',
            'english': 'My Hero Academia',
          },
          'format': 'TV',
          'episodes': episodes,
          'seasonYear': 2016,
          'relations': <String, dynamic>{'edges': edges},
        },
      },
    };
  }

  Map<String, dynamic> edge(String type, int id, int episodes) {
    return <String, dynamic>{
      'relationType': type,
      'node': <String, dynamic>{
        'id': id,
        'title': <String, dynamic>{
          'romaji': 'My Hero Academia',
          'english': 'My Hero Academia',
        },
        'format': 'TV',
        'episodes': episodes,
        'seasonYear': 2017,
      },
    };
  }

  /// Mock AniList: search resolves MHA -> 21459; the relations walk
  /// gives a 3-season chain (21459 -> 21551 -> 21612).
  AniListService mockAnilist({bool resolveTitle = true}) {
    return AniListService(
      client: MockClient((http.Request req) async {
        final String body = req.body;
        if (body.contains('media(search:')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{
                'Page': <String, dynamic>{
                  'media': resolveTitle
                      ? <Object>[mediaJson(id: 21459, idMal: 31964)]
                      : <Object>[],
                },
              },
            }),
            200,
          );
        }
        if (body.contains('Media(id:21459')) {
          return http.Response(
            jsonEncode(
              relationsJson(
                id: 21459,
                episodes: 138,
                edges: <Map<String, dynamic>>[edge('SEQUEL', 21551, 25)],
              ),
            ),
            200,
          );
        }
        if (body.contains('Media(id:21551')) {
          return http.Response(
            jsonEncode(
              relationsJson(
                id: 21551,
                episodes: 25,
                edges: <Map<String, dynamic>>[
                  edge('PREQUEL', 21459, 138),
                  edge('SEQUEL', 21612, 25),
                ],
              ),
            ),
            200,
          );
        }
        if (body.contains('Media(id:21612')) {
          return http.Response(
            jsonEncode(
              relationsJson(
                id: 21612,
                episodes: 25,
                edges: <Map<String, dynamic>>[edge('PREQUEL', 21551, 25)],
              ),
            ),
            200,
          );
        }
        return http.Response('{"data":{}}', 200);
      }),
    );
  }

  AppServices servicesFor(
    AniListService anilist, {
    http.Client? streamClient,
  }) {
    // 0.2.30: with a streamClient every resolver is backed by it, so
    // a resolve test never touches the real network — the mock 404s
    // everything and the error dialog appears instead of the player.
    return AppServices(
      anilist: anilist,
      miruro: MiruroResolver(anilist: anilist, client: streamClient),
      anisuge: streamClient == null
          ? null
          : AnisugeResolver(
              client: streamClient,
              anilist: anilist,
              megaplay: MiruroResolver(client: streamClient),
            ),
      anikage: streamClient == null
          ? null
          : AnikageResolver(
              client: streamClient,
              anilist: anilist,
              megaplay: MiruroResolver(client: streamClient),
            ),
      animesama: streamClient == null
          ? null
          : AnimeSamaResolver(client: streamClient, anilist: anilist),
      debrid: DebridService(),
      oauth: OAuthService(),
      downloads: DownloadService(),
      airing: AiringService(anilist: anilist),
      airingNotifications: AiringNotifications(),
    );
  }

  Future<void> pumpDetail(
    WidgetTester tester,
    AppServices services,
  ) async {
    // Tall viewport: DetailScreen's body is a lazy ListView — at the
    // default 600pt height the season selector + episode section
    // below the fold never build, so no finder can see them.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final SettingsStore store = await SettingsStore.load();
    late TrailerPlayer trailer;
    await tester.runAsync(() async {
      trailer = TrailerPlayer();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          anime: mha,
          store: store,
          services: services,
          player: trailer,
        ),
      ),
    );
    await tester.pump();
    // The season load is async (search + 3 relation hops on the
    // mock client). A single fixed wait is not enough in fake async
    // — each hop needs a pump to progress, like the player tests'
    // waitForSkip loop: alternate a real-time delay (lets the mock
    // HTTP chain run) with a pump (renders the setState) until the
    // selector appears or the loop is exhausted.
    for (int i = 0; i < 20; i++) {
      if (find.text('Season 1').evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('MHA without anilistId shows the season selector', (
    WidgetTester tester,
  ) async {
    await pumpDetail(tester, servicesFor(mockAnilist()));
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('Season 3'), findsOneWidget);
  });

  testWidgets('unresolvable title shows no selector, list as-is', (
    WidgetTester tester,
  ) async {
    await pumpDetail(tester, servicesFor(mockAnilist(resolveTitle: false)));
    expect(find.text('Season 1'), findsNothing);
    expect(find.text('Season 2'), findsNothing);
    // The episode list is still there (header is 'EPISODES').
    expect(find.text('EPISODES'), findsWidgets);
  });

  testWidgets('tapping Season 2 switches the episode list to that season', (
    WidgetTester tester,
  ) async {
    await pumpDetail(tester, servicesFor(mockAnilist()));
    // S1: 138 episodes, first range 001-100, cell 100 present.
    expect(find.text('001-100'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    await tester.tap(find.text('Season 2'));
    // _selectSeason fetches the S2 episode list async — wait for
    // the S2 range label like pumpDetail waits for the selector.
    for (int i = 0; i < 20; i++) {
      if (find.text('001-025').evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    expect(find.text('001-025'), findsOneWidget);
    expect(find.text('100'), findsNothing);
    expect(find.text('25'), findsOneWidget);
    // Back to S1 restores the S1 list.
    await tester.tap(find.text('Season 1'));
    for (int i = 0; i < 20; i++) {
      if (find.text('001-100').evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    expect(find.text('001-100'), findsOneWidget);
  });

  testWidgets(
    '0.2.30: tapping an S2 episode resolves with the S2 id, not S1',
    (WidgetTester tester) async {
      final List<String> requested = <String>[];
      final MockClient streamClient = MockClient((http.Request req) async {
        requested.add(req.url.toString());
        // Every resolver 404s: the resolve ends null and the error
        // dialog appears instead of the player — the requested
        // justanime URL is the proof of which id was resolved.
        return http.Response('not found', 404);
      });
      await pumpDetail(
        tester,
        servicesFor(mockAnilist(), streamClient: streamClient),
      );
      await tester.tap(find.text('Season 2'));
      for (int i = 0; i < 20; i++) {
        if (find.text('001-025').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      expect(find.text('001-025'), findsOneWidget);
      await tester.tap(find.text('1'));
      for (int i = 0; i < 20; i++) {
        if (requested.any(
          (String u) => u.contains('core.justanime.to'),
        )) {
          break;
        }
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      expect(
        requested,
        contains(
          'https://core.justanime.to/api/watch/21551/episode/1/megaplay',
        ),
      );
      expect(
        requested,
        isNot(
          contains(
            'https://core.justanime.to/api/watch/21459/episode/1/megaplay',
          ),
        ),
      );
      await tester.pump();
      expect(find.text("Couldn't load episode"), findsOneWidget);
    },
  );
}
