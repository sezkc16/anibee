import 'dart:convert';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/animekai_resolver.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.23: AnimeKai (animekai.ro) — the revival clone. The pure
/// parsers are tested against the REAL recorded responses (Solo
/// Leveling, 2026-11-24, in test/fixtures/animekai_*), and the full
/// resolve runs end-to-end against a MockClient that plays those
/// recordings back. The media host (s-90.megavid.se) drops the
/// VM's connections, so the final playlist fetch is NOT proven
/// here — the test proves the chain produces the real signed HLS
/// URL the phone will fetch.
void main() {
  String fixture(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  const Anime soloLeveling = Anime(
    id: 'anilist-151807',
    title: 'Solo Leveling',
    rating: 4.5,
    year: 2024,
    episodeCount: 12,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 151807,
  );

  group('parseSearchResults (recorded response)', () {
    test('finds Solo Leveling (TV, 2024) among 5 hits', () {
      final Map<String, dynamic> data =
          jsonDecode(fixture('animekai_search.json')) as Map<String, dynamic>;
      final String html =
          (data['result'] as Map<String, dynamic>)['html'] as String;
      final List<AnimeKaiCandidate> found =
          AnimeKaiResolver.parseSearchResults(html);
      expect(found.length, 5);
      final AnimeKaiCandidate tv = found.firstWhere(
        (AnimeKaiCandidate c) => c.slug == 'solo-leveling-tlz7of',
      );
      expect(tv.title, 'Solo Leveling');
      expect(tv.jpTitle, 'Ore dake Level Up na Ken');
      expect(tv.type, 'TV');
      expect(tv.year, 2024);
      // The movie and the specials are separate entries — the
      // format gate must tell them apart.
      expect(
        found
            .firstWhere(
              (AnimeKaiCandidate c) =>
                  c.slug == 'solo-leveling-beyond-the-system-zzpng0',
            )
            .type,
        'MOVIE',
      );
      expect(
        found
            .firstWhere(
              (AnimeKaiCandidate c) =>
                  c.slug == 'solo-leveling-specials-vpnpkd',
            )
            .type,
        'SPECIAL',
      );
    });

    test('empty html returns no candidates', () {
      expect(AnimeKaiResolver.parseSearchResults(''), isEmpty);
      expect(AnimeKaiResolver.parseSearchResults('<div></div>'), isEmpty);
    });
  });

  group('parseEpisodeList (recorded response)', () {
    test('12 episodes with tokens and sub/dub flags', () {
      final Map<String, dynamic> data = jsonDecode(
        fixture('animekai_episodes.json'),
      ) as Map<String, dynamic>;
      final List<AnimeKaiEpisode> eps =
          AnimeKaiResolver.parseEpisodeList(data['result'] as String);
      expect(eps.length, 12);
      final AnimeKaiEpisode ep1 =
          eps.firstWhere((AnimeKaiEpisode e) => e.number == 1);
      expect(
        ep1.token,
        'ODE5MzAuNWE3NmI0MTQzZDJkZGY2NWY1MmY2ODgxYzE1MWU3ZDI',
      );
      expect(ep1.hasSub, isTrue);
      expect(ep1.hasDub, isTrue);
      expect(eps.map((AnimeKaiEpisode e) => e.number).toList(),
          List<int>.generate(12, (int i) => i + 1));
    });
  });

  group('parseServerList (recorded response)', () {
    test('sub group lists Ani-HD, HD, HD-1 in order', () {
      final Map<String, dynamic> data =
          jsonDecode(fixture('animekai_servers.json')) as Map<String, dynamic>;
      final List<AnimeKaiServer> sub = AnimeKaiResolver.parseServerList(
        data['result'] as String,
        subDub: 'sub',
      );
      expect(sub.map((AnimeKaiServer s) => s.name).toList(),
          <String>['Ani-HD', 'HD', 'HD-1']);
      expect(
        sub.first.linkId,
        'ODE5MzAuMS5zdWJ-ZmVjMmQxODM1ZWUyOTc2NjYwNmQ1YWU1MTVhMjc4YzM',
      );
    });

    test('dub group is separate (Ani-HD dub first)', () {
      final Map<String, dynamic> data =
          jsonDecode(fixture('animekai_servers.json')) as Map<String, dynamic>;
      final List<AnimeKaiServer> dub = AnimeKaiResolver.parseServerList(
        data['result'] as String,
        subDub: 'dub',
      );
      expect(dub, isNotEmpty);
      expect(dub.first.name, 'Ani-HD');
      expect(
        dub.first.linkId,
        'ODE5MzAuMS5kdWJ-M2NiMzI4YzI5ZDlhMjRmZmUyZDVhYTk0Yzk1MzZmYjk',
      );
    });
  });

  group('parseAnimeId (recorded page)', () {
    test('finds 5574 from the data-fetch hook', () {
      expect(
        AnimeKaiResolver.parseAnimeId(fixture('animekai_anime_page.html')),
        5574,
      );
      expect(AnimeKaiResolver.parseAnimeId('<div></div>'), isNull);
    });
  });

  group('parseMegavidSourceUrl (recorded embed)', () {
    test('finds the source API path in the player payload', () {
      expect(
        AnimeKaiResolver.parseMegavidSourceUrl(
          fixture('animekai_megavid_embed.html'),
        ),
        '/mal/52299/1/sub/source',
      );
      expect(
        AnimeKaiResolver.parseMegavidSourceUrl('<html></html>'),
        isNull,
      );
    });
  });

  group('resolve() — full chain against recorded responses', () {
    late List<String> requestedServerTokens;

    MockClient recordedClient() {
      requestedServerTokens = <String>[];
      return MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('graphql.anilist.co')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <String, Object>{
                'Media': <String, Object>{
                  'title': <String, Object>{
                    'romaji': 'Solo Leveling',
                    'english': 'Solo Leveling',
                    'native': '俺だけレベルアップな件',
                  },
                  'seasonYear': 2024,
                  'format': 'TV',
                  'episodes': 12,
                  'status': 'FINISHED',
                },
              },
            }),
            200,
          );
        }
        if (url.contains('/ajax/anime/search')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_search.json')), 200);
        }
        if (url.contains('/anime/solo-leveling-tlz7of')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_anime_page.html')), 200);
        }
        if (url.contains('/ajax/episode/list/5574')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_episodes.json')), 200);
        }
        if (url.contains('/ajax/server/list')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_servers.json')), 200);
        }
        if (url.contains('/ajax/server?get=')) {
          requestedServerTokens.add(req.url.queryParameters['get'] ?? '');
          return http.Response.bytes(utf8.encode(fixture('animekai_server.json')), 200);
        }
        if (url.startsWith('https://megavid.buzz/mal/52299/1/')) {
          if (url.endsWith('/source')) {
            return http.Response.bytes(
              utf8.encode(fixture('animekai_megavid_source.json')),
              200,
            );
          }
          return http.Response.bytes(utf8.encode(fixture('animekai_megavid_embed.html')), 200);
        }
        return http.Response('not found', 404);
      });
    }

    test('Solo Leveling EP1 sub → signed megavid HLS + English subs',
        () async {
      final MockClient client = recordedClient();
      final AnimeKaiResolver resolver = AnimeKaiResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: soloLeveling,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull);
      expect(
        stream!.url,
        startsWith('https://s-90.megavid.se/uwu/'),
      );
      expect(stream.url, endsWith('/master.txt'));
      expect(stream.source, 'AnimeKai');
      expect(stream.label, 'AnimeKai Ani-HD Sub');
      expect(stream.subtitles, isNotEmpty);
      expect(stream.subtitles.first.label, 'English');
      expect(
        stream.headers['Referer'],
        'https://megavid.buzz/',
      );
      // The first server tried is the sub Ani-HD token.
      expect(
        requestedServerTokens.first,
        'ODE5MzAuMS5zdWJ-ZmVjMmQxODM1ZWUyOTc2NjYwNmQ1YWU1MTVhMjc4YzM',
      );
    });

    test('Dub routes through the dub server group', () async {
      final MockClient client = recordedClient();
      final AnimeKaiResolver resolver = AnimeKaiResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: soloLeveling,
        episodeNumber: 1,
        subDub: 'Dub',
      );
      expect(stream, isNotNull);
      expect(stream!.label, 'AnimeKai Ani-HD Dub');
      expect(
        requestedServerTokens.first,
        'ODE5MzAuMS5kdWJ-M2NiMzI4YzI5ZDlhMjRmZmUyZDVhYTk0Yzk1MzZmYjk',
      );
    });

    test('unknown title fails honestly, never a guess', () async {
      final MockClient client = MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('graphql.anilist.co')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <String, Object>{
                'Media': <String, Object>{
                  'title': <String, Object>{
                    'romaji': 'No Such Anime Xyz',
                    'english': 'No Such Anime Xyz',
                  },
                  'seasonYear': 2024,
                  'format': 'TV',
                  'episodes': 12,
                  'status': 'FINISHED',
                },
              },
            }),
            200,
          );
        }
        if (url.contains('/ajax/anime/search')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'status': 200,
              'result': <String, Object>{'html': '<div></div>'},
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final AnimeKaiResolver resolver = AnimeKaiResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      const Anime missing = Anime(
        id: 'anilist-999999',
        title: 'No Such Anime Xyz',
        rating: 0,
        year: 2024,
        episodeCount: 12,
        genres: <String>['Action'],
        synopsis: '',
        gradient: <Color>[Color(0xFF000000), Color(0xFF000000)],
        anilistId: 999999,
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: missing,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(resolver.lastError, contains('Could not find'));
    });

    test('a non-megavid embed is skipped, never guessed', () async {
      final MockClient client = MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('graphql.anilist.co')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <String, Object>{
                'Media': <String, Object>{
                  'title': <String, Object>{
                    'romaji': 'Solo Leveling',
                    'english': 'Solo Leveling',
                  },
                  'seasonYear': 2024,
                  'format': 'TV',
                  'episodes': 12,
                  'status': 'FINISHED',
                },
              },
            }),
            200,
          );
        }
        if (url.contains('/ajax/anime/search')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_search.json')), 200);
        }
        if (url.contains('/anime/solo-leveling-tlz7of')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_anime_page.html')), 200);
        }
        if (url.contains('/ajax/episode/list/5574')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_episodes.json')), 200);
        }
        if (url.contains('/ajax/server/list')) {
          return http.Response.bytes(utf8.encode(fixture('animekai_servers.json')), 200);
        }
        if (url.contains('/ajax/server?get=')) {
          // Every server points at an embed host with no verified
          // extractor — the resolver must give up, not guess.
          return http.Response(
            jsonEncode(<String, Object>{
              'status': 200,
              'result': <String, Object?>{
                'url': 'https://vidtube.example/e/12345',
                'type': 'iframe',
                'skip_data': null,
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final AnimeKaiResolver resolver = AnimeKaiResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: soloLeveling,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(resolver.lastError, contains('no working server'));
    });
  });
}
