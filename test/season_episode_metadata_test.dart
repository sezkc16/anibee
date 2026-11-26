import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/player/trailer_player.dart';
import 'package:anibee/screens/detail_screen.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/app_services.dart';
import 'package:anibee/services/debrid_service.dart';
import 'package:anibee/services/download_service.dart';
import 'package:anibee/services/kitsu_episodes.dart';
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

/// 0.2.31: the episode list showed the same fake M1 titles/dates on
/// every season (0.2.30 phone test: S5 selected, count right at 25,
/// cards all fake S1 data — "Infiltration Protocol", Sep 5 2026).
/// Real per-season metadata now comes from Kitsu, keyed by the
/// selected season's AniList id; the placeholder list is honestly
/// neutral ('Episode N') when Kitsu has nothing.
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

  group('Kitsu parsing (real MHA S5 data, live-probed 2026-11-27)', () {
    test('formatAirDate', () {
      expect(KitsuEpisodes.formatAirDate('2021-03-27'), 'Mar 27, 2021');
      expect(KitsuEpisodes.formatAirDate('2021-04-24'), 'Apr 24, 2021');
      expect(KitsuEpisodes.formatAirDate(null), isNull);
      expect(KitsuEpisodes.formatAirDate('garbage'), isNull);
      expect(KitsuEpisodes.formatAirDate('2021-13-01'), isNull);
      expect(KitsuEpisodes.formatAirDate('2021-02-30'), 'Feb 30, 2021');
    });

    test('parseEpisode maps the real EP1 fields', () {
      final KitsuEpisodeMeta? meta = KitsuEpisodes.parseEpisode(
        <String, dynamic>{
          'id': '278112',
          'type': 'episodes',
          'attributes': <String, dynamic>{
            'number': 1,
            'canonicalTitle': 'All Hands on Deck! Class 1-A',
            'synopsis': 'Class 1-A faces the joint training battle.',
            'airdate': '2021-03-27',
            'length': 24,
            'thumbnail': <String, dynamic>{
              'original':
                  'https://media.kitsu.app/episodes/thumbnails/278112/original.png',
            },
          },
        },
      );
      expect(meta, isNotNull);
      expect(meta!.number, 1);
      expect(meta.title, 'All Hands on Deck! Class 1-A');
      expect(meta.synopsis, 'Class 1-A faces the joint training battle.');
      expect(meta.airDate, 'Mar 27, 2021');
      expect(meta.lengthMinutes, 24);
      expect(meta.durationString, '24:00');
      expect(meta.thumbnailUrl, contains('media.kitsu.app'));
    });

    test('parseEpisode keeps unknowns null, never invents', () {
      final KitsuEpisodeMeta? meta = KitsuEpisodes.parseEpisode(
        <String, dynamic>{
          'attributes': <String, dynamic>{
            'number': 3,
            'canonicalTitle': '  ',
            'airdate': null,
          },
        },
      );
      expect(meta, isNotNull);
      expect(meta!.number, 3);
      expect(meta.title, isNull);
      expect(meta.synopsis, isNull);
      expect(meta.airDate, isNull);
      expect(meta.durationString, isNull);
      expect(KitsuEpisodes.parseEpisode(<String, dynamic>{'attributes': {}}),
          isNull);
      expect(
        KitsuEpisodes.parseEpisode(<String, dynamic>{
          'attributes': <String, dynamic>{'number': 0},
        }),
        isNull,
      );
    });

    test('parseMappingItemUrl', () {
      expect(
        KitsuEpisodes.parseMappingItemUrl(<String, dynamic>{
          'data': <Object>[
            <String, dynamic>{
              'relationships': <String, dynamic>{
                'item': <String, dynamic>{
                  'links': <String, dynamic>{
                    'related':
                        'https://kitsu.io/api/edge/mappings/258013/item',
                  },
                },
              },
            },
          ],
        }),
        'https://kitsu.io/api/edge/mappings/258013/item',
      );
      expect(KitsuEpisodes.parseMappingItemUrl(<String, dynamic>{'data': []}),
          isNull);
      expect(KitsuEpisodes.parseMappingItemUrl(null), isNull);
    });
  });

  group('Kitsu fetch (MockClient)', () {
    Map<String, dynamic> mappingsJson(int anilistId, int mappingId) {
      return <String, dynamic>{
        'data': <Object>[
          <String, dynamic>{
            'id': '$mappingId',
            'type': 'mappings',
            'attributes': <String, dynamic>{
              'externalSite': 'anilist/anime',
              'externalId': '$anilistId',
            },
            'relationships': <String, dynamic>{
              'item': <String, dynamic>{
                'links': <String, dynamic>{
                  'related':
                      'https://kitsu.io/api/edge/mappings/$mappingId/item',
                },
              },
            },
          },
        ],
      };
    }

    Map<String, dynamic> episodeJson(
      int number,
      String title,
      String airdate,
    ) {
      return <String, dynamic>{
        'id': '${1000 + number}',
        'type': 'episodes',
        'attributes': <String, dynamic>{
          'number': number,
          'canonicalTitle': title,
          'synopsis': 'Synopsis for episode $number.',
          'airdate': airdate,
          'length': 24,
          'thumbnail': <String, dynamic>{
            'original':
                'https://media.kitsu.app/episodes/thumbnails/${1000 + number}/original.png',
          },
        },
      };
    }

    MockClient twoPageClient({required List<String> requested}) {
      return MockClient((http.Request req) async {
        requested.add(req.url.toString());
        final String url = req.url.toString();
        if (url.contains('/mappings?')) {
          return http.Response(
            jsonEncode(mappingsJson(117193, 258013)),
            200,
          );
        }
        if (url.contains('/mappings/258013/item')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{'id': '43108', 'type': 'anime'},
            }),
            200,
          );
        }
        if (url.contains('/anime/43108/episodes')) {
          // Page 1: EP1-20 (real S5 EP1-5 titles), links.next -> p2.
          if (!url.contains('page%5Bnumber%5D=2') &&
              !url.contains('page[number]=2')) {
            final List<Map<String, dynamic>> eps =
                <Map<String, dynamic>>[
              episodeJson(1, 'All Hands on Deck! Class 1-A', '2021-03-27'),
              episodeJson(2, 'Vestiges', '2021-04-03'),
              episodeJson(3, 'Clash! Class A vs. Class B!', '2021-04-10'),
              episodeJson(4, 'Make It Happen, Shinso!', '2021-04-17'),
              episodeJson(5, 'Operation New Improv Moves', '2021-04-24'),
              for (int n = 6; n <= 20; n++)
                episodeJson(n, 'Kitsu Test Episode $n', '2021-05-01'),
            ];
            return http.Response(
              jsonEncode(<String, dynamic>{
                'data': eps,
                'links': <String, dynamic>{
                  'next':
                      'https://kitsu.io/api/edge/anime/43108/episodes?page%5Blimit%5D=20&page%5Bnumber%5D=2&sort=number',
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                for (int n = 21; n <= 25; n++)
                  episodeJson(n, 'Kitsu Test Episode $n', '2021-06-01'),
              ],
              'links': <String, dynamic>{},
            }),
            200,
          );
        }
        return http.Response('{"data":[]}', 200);
      });
    }

    test('fetch follows pagination and returns all 25 real episodes', () async {
      final List<String> requested = <String>[];
      final KitsuEpisodes service = KitsuEpisodes(
        client: twoPageClient(requested: requested),
      );
      final List<KitsuEpisodeMeta> metas = await service.fetchForAnilistId(
        117193,
        episodeCount: 25,
      );
      expect(metas.length, 25);
      expect(metas.first.title, 'All Hands on Deck! Class 1-A');
      expect(metas.first.airDate, 'Mar 27, 2021');
      expect(metas[4].title, 'Operation New Improv Moves');
      expect(metas.last.number, 25);
      expect(requested.length, 4); // mappings + item + 2 episode pages
      // Second call is cached — no new HTTP.
      await service.fetchForAnilistId(117193, episodeCount: 25);
      expect(requested.length, 4);
    });

    test('fetch returns [] on missing mapping / HTTP failure', () async {
      final KitsuEpisodes noMapping = KitsuEpisodes(
        client: MockClient((http.Request req) async {
          return http.Response('{"data":[]}', 200);
        }),
      );
      expect(await noMapping.fetchForAnilistId(999999), isEmpty);
      final KitsuEpisodes failing = KitsuEpisodes(
        client: MockClient((http.Request req) async {
          return http.Response('boom', 500);
        }),
      );
      expect(await failing.fetchForAnilistId(117193), isEmpty);
    });
  });

  group('placeholder list is honest', () {
    test('mockEpisodes has no fake titles, synopses or dates', () {
      const Anime anime = Anime(
        id: 'placeholder-test',
        title: 'Placeholder Test',
        rating: 4.0,
        year: 2024,
        episodeCount: 5,
        genres: <String>['Action'],
        synopsis: 'Test.',
        gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      );
      final List<Episode> eps = mockEpisodes(anime);
      expect(eps.length, 5);
      for (int i = 0; i < eps.length; i++) {
        expect(eps[i].title, 'Episode ${i + 1}');
        expect(eps[i].synopsis, isEmpty);
        expect(eps[i].airDate, isEmpty);
      }
      expect(
        eps.map((Episode e) => e.title).join(' '),
        isNot(contains('Infiltration')),
      );
    });
  });

  group('watched state is per-season, not per episode number', () {
    const Anime s1 = Anime(
      id: 'my-hero-academia',
      anilistId: 21459,
      title: 'My Hero Academia',
      rating: 4.0,
      year: 2016,
      episodeCount: 13,
      genres: <String>['Action'],
      synopsis: 'S1.',
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    );
    const Anime s5 = Anime(
      id: 'anilist-117193',
      anilistId: 117193,
      title: 'My Hero Academia',
      rating: 4.0,
      year: 2021,
      episodeCount: 25,
      genres: <String>['Action'],
      synopsis: 'S5.',
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    );

    test('completing S1 EP1 does not mark S5 EP1 completed', () async {
      final SettingsStore store = await SettingsStore.load();
      final List<Episode> s1eps = mockEpisodes(s1);
      final List<Episode> s5eps = mockEpisodes(s5);
      await store.markEpisodeCompleted(store.resumeKeyFor(s1, 1));
      expect(store.isEpisodeCompleted(s1, s1eps[0]), isTrue);
      expect(store.isEpisodeCompleted(s5, s5eps[0]), isFalse);
      expect(store.episodeProgressFor(s5, s5eps[0]), 0);
    });

    test('resume saved for S1 EP1 is invisible to S5 EP1', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.setResumeSeconds(store.resumeKeyFor(s1, 1), 690);
      await store.setResumeDuration(store.resumeKeyFor(s1, 1), 1380);
      expect(store.resumePositionFor(s5, 1), isNull);
    });
  });

  group('Detail list follows the selected season (widget)', () {
    const Anime mha = Anime(
      id: 'my-hero-academia',
      anilistId: 21459,
      title: 'My Hero Academia',
      rating: 4.0,
      year: 2016,
      episodeCount: 13,
      genres: <String>['Action'],
      synopsis: 'Test anime for the season metadata test.',
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    );

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

    AniListService mockAnilist() {
      return AniListService(
        client: MockClient((http.Request req) async {
          final String body = req.body;
          if (body.contains('Media(id:21459')) {
            return http.Response(
              jsonEncode(
                relationsJson(
                  id: 21459,
                  episodes: 13,
                  edges: <Map<String, dynamic>>[edge('SEQUEL', 21551, 12)],
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
                  episodes: 12,
                  edges: <Map<String, dynamic>>[edge('PREQUEL', 21459, 13)],
                ),
              ),
              200,
            );
          }
          return http.Response('{"data":{}}', 200);
        }),
      );
    }

    /// Mock Kitsu: S1 (AniList 21459 -> Kitsu 100) and S2 (21551 ->
    /// Kitsu 200) have distinct real-looking titles and dates.
    /// Thumbnails point at 127.0.0.1:9 (connection refused) so the
    /// card image fails fast instead of hanging the test on a real
    /// network fetch.
    MockClient mockKitsu() {
      Map<String, dynamic> episode(int n, String title, String airdate) {
        return <String, dynamic>{
          'id': '$n',
          'type': 'episodes',
          'attributes': <String, dynamic>{
            'number': n,
            'canonicalTitle': title,
            'synopsis': 'Synopsis $title.',
            'airdate': airdate,
            'length': 24,
            'thumbnail': <String, dynamic>{
              'original': 'http://127.0.0.1:9/$title.png',
            },
          },
        };
      }

      Map<String, dynamic> episodesPage(String season, int count) {
        // Distinct air date per episode (EP1 = Apr 3 / Apr 1), so
        // the widget test can assert one card's date exactly.
        final String base = season == 'S1' ? '2016-04' : '2017-04';
        return <String, dynamic>{
          'data': <Map<String, dynamic>>[
            for (int n = 1; n <= count; n++)
              episode(
                n,
                n == 1 ? '$season First Episode' : '$season Episode $n',
                '$base-${(n + 2).toString().padLeft(2, '0')}',
              ),
          ],
          'links': <String, dynamic>{},
        };
      }

      return MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('/mappings?')) {
          final String ext =
              req.url.queryParameters['filter[externalId]'] ?? '';
          final String mappingId = ext == '21551' ? '2' : '1';
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Object>[
                <String, dynamic>{
                  'relationships': <String, dynamic>{
                    'item': <String, dynamic>{
                      'links': <String, dynamic>{
                        'related':
                            'https://kitsu.io/api/edge/mappings/$mappingId/item',
                      },
                    },
                  },
                },
              ],
            }),
            200,
          );
        }
        if (url.contains('/mappings/1/item')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{'id': '100', 'type': 'anime'},
            }),
            200,
          );
        }
        if (url.contains('/mappings/2/item')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{'id': '200', 'type': 'anime'},
            }),
            200,
          );
        }
        if (url.contains('/anime/100/episodes')) {
          return http.Response(jsonEncode(episodesPage('S1', 13)), 200);
        }
        if (url.contains('/anime/200/episodes')) {
          return http.Response(jsonEncode(episodesPage('S2', 12)), 200);
        }
        return http.Response('{"data":[]}', 200);
      });
    }

    AppServices servicesFor(
      AniListService anilist,
      KitsuEpisodes kitsu,
    ) {
      return AppServices(
        anilist: anilist,
        miruro: MiruroResolver(anilist: anilist),
        debrid: DebridService(),
        oauth: OAuthService(),
        downloads: DownloadService(),
        airing: AiringService(anilist: anilist),
        airingNotifications: AiringNotifications(),
        kitsuEpisodes: kitsu,
      );
    }

    Future<void> pumpDetail(WidgetTester tester, AppServices services) async {
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
      for (int i = 0; i < 20; i++) {
        if (find.text('Season 1').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> waitFor(
      WidgetTester tester,
      String text,
    ) async {
      for (int i = 0; i < 20; i++) {
        if (find.text(text).evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
    }

    testWidgets('S1 list shows S1 metadata; S2 switch shows S2 metadata',
        (WidgetTester tester) async {
      await pumpDetail(
        tester,
        servicesFor(mockAnilist(), KitsuEpisodes(client: mockKitsu())),
      );
      await waitFor(tester, 'S1 First Episode');
      expect(find.text('S1 First Episode'), findsOneWidget);
      expect(find.text('Apr 3, 2016'), findsOneWidget);
      expect(find.text('S2 First Episode'), findsNothing);

      await tester.tap(find.text('Season 2'));
      await waitFor(tester, 'S2 First Episode');
      expect(find.text('S2 First Episode'), findsOneWidget);
      expect(find.text('Apr 3, 2017'), findsOneWidget);
      expect(find.text('S1 First Episode'), findsNothing);
      expect(find.text('Apr 3, 2016'), findsNothing);

      // Back to S1 restores the S1 list (cached Kitsu data).
      await tester.tap(find.text('Season 1'));
      await waitFor(tester, 'S1 First Episode');
      expect(find.text('S1 First Episode'), findsOneWidget);
      expect(find.text('S2 First Episode'), findsNothing);
    });

    testWidgets('Kitsu failure leaves the honest placeholder list',
        (WidgetTester tester) async {
      final KitsuEpisodes failing = KitsuEpisodes(
        client: MockClient((http.Request req) async {
          return http.Response('boom', 500);
        }),
      );
      await pumpDetail(tester, servicesFor(mockAnilist(), failing));
      await waitFor(tester, 'Episode 1');
      expect(find.text('Episode 1'), findsWidgets);
      expect(find.textContaining('Infiltration'), findsNothing);
    });
  });
}
