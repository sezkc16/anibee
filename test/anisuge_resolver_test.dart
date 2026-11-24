import 'dart:convert';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/anisuge_resolver.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.24: AniSuge (anisuge.tv). The parsers are tested against
/// the REAL recorded responses (Jujutsu Kaisen, 2026-11-24, in
/// test/fixtures/anisuge_*), and the full resolve runs end-to-end
/// against a MockClient that plays those recordings back. The
/// site's search page, watch page, episode anchors and server
/// list markup ALL differ from anikoto.cz (same AJAX backend,
/// different front end) — see AnisugeResolver's doc comment. The
/// final playlist fetch is NOT proven here (the mock master 404s,
/// so the test proves the chain produces the real signed HLS URL
/// the phone will fetch); the live probe test proves real
/// playability end-to-end.
void main() {
  String fixture(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  const Anime jjk = Anime(
    id: 'anilist-113415',
    title: 'Jujutsu Kaisen',
    rating: 4.5,
    year: 2020,
    episodeCount: 24,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 113415,
  );

  const String watchHtml =
      '<div class="container watch-wrap" data-id="1103" '
      'data-url="https://anisuge.tv/anime/jujutsu-kaisen-tv-8ssye" '
      'data-ep-name="1" data-ep-type=""></div>';

  const String megaEmbedHtml =
      '<div id="megaplay-player" data-id="10789"></div>';

  MockClient recordedClient() {
    return MockClient((http.Request req) async {
      final String url = req.url.toString();
      if (url.contains('graphql.anilist.co')) {
        return http.Response(
          jsonEncode(<String, Object>{
            'data': <String, Object>{
              'Media': <String, Object>{
                'title': <String, Object>{
                  'romaji': 'Jujutsu Kaisen',
                  'english': 'JUJUTSU KAISEN',
                  'native': '呪術廻戦',
                },
                'seasonYear': 2020,
                'format': 'TV',
                'episodes': 24,
                'status': 'FINISHED',
              },
            },
          }),
          200,
        );
      }
      if (url.contains('/filter?keyword=')) {
        return http.Response.bytes(
          utf8.encode(fixture('anisuge_filter_jjk.html')),
          200,
        );
      }
      if (url.contains('/anime/jujutsu-kaisen-tv-8ssye/')) {
        return http.Response.bytes(utf8.encode(watchHtml), 200);
      }
      if (url.contains('/ajax/episode/list/1103')) {
        return http.Response.bytes(
          utf8.encode(fixture('anisuge_episodes_jjk.json')),
          200,
        );
      }
      if (url.contains('/ajax/server/list')) {
        return http.Response.bytes(
          utf8.encode(fixture('anisuge_servers_jjk.json')),
          200,
        );
      }
      if (url.contains('/ajax/server?get=')) {
        return http.Response.bytes(
          utf8.encode(fixture('anisuge_server_get_jjk.json')),
          200,
        );
      }
      if (url.contains('megaplay.buzz/stream/s-2/10789')) {
        return http.Response.bytes(utf8.encode(megaEmbedHtml), 200);
      }
      if (url.contains('/stream/getSources')) {
        return http.Response(
          jsonEncode(<String, Object>{
            'sources': <String, Object>{
              'file':
                  'https://cdn.example.com/67c6a1e7ce56d3d6fa748ab6d9af3fd7'
                  '/a912be556efe4092b6a7dad91807d1ee/master.m3u8',
            },
            'tracks': <Object>[
              <String, Object>{
                'kind': 'captions',
                'label': 'English',
                'file': 'https://cdn.example.com/en.vtt',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });
  }

  group('parseSearchResults (recorded response)', () {
    test('finds Jujutsu Kaisen (TV) among 10 hits', () {
      final List<AnisugeHit> found =
          AnisugeResolver.parseSearchResults(
            fixture('anisuge_filter_jjk.html'),
          );
      expect(found.length, 10);
      final AnisugeHit tv = found.firstWhere(
        (AnisugeHit h) => h.title == 'Jujutsu Kaisen (TV)',
      );
      expect(
        tv.href,
        'https://anisuge.tv/anime/jujutsu-kaisen-tv-8ssye/ep-24',
      );
      // The "(TV)" qualifier is part of the display title — the
      // matcher strips it, it is NOT stripped here.
      expect(
        found
            .where((AnisugeHit h) => h.title.startsWith('Jujutsu Kaisen'))
            .length,
        6,
      );
    });

    test('empty html returns no hits', () {
      expect(AnisugeResolver.parseSearchResults(''), isEmpty);
      expect(
        AnisugeResolver.parseSearchResults('<div></div>'),
        isEmpty,
      );
    });
  });

  group('resolve (recorded responses)', () {
    test('JJK EP1 sub → signed megaplay HLS + English subs', () async {
      final MockClient client = recordedClient();
      final AnisugeResolver resolver = AnisugeResolver(
        client: client,
        anilist: AniListService(client: client),
        megaplay: MiruroResolver(client: client),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull, reason: resolver.lastError);
      expect(stream!.source, 'AniSuge');
      expect(stream.label, 'AniSuge HD-1 Sub');
      // Signed master (the mock master 404s, so no variant
      // expansion — the URL itself is the proof).
      expect(
        stream.url,
        startsWith(
          'https://cdn.example.com/67c6a1e7ce56d3d6fa748ab6d9af3fd7'
          '/a912be556efe4092b6a7dad91807d1ee/master.m3u8?token=',
        ),
      );
      expect(stream.headers['Referer'], 'https://megaplay.buzz/');
      expect(stream.subtitles.map((s) => s.label), contains('English'));
    });

    test('unknown title → null + lastError', () async {
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.toString().contains('graphql.anilist.co')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <String, Object>{
                'Media': <String, Object>{
                  'title': <String, Object>{
                    'romaji': 'No Such Anime Ever',
                    'english': 'No Such Anime Ever',
                    'native': '',
                  },
                  'seasonYear': 2026,
                  'format': 'TV',
                  'episodes': 1,
                  'status': 'FINISHED',
                },
              },
            }),
            200,
          );
        }
        // The filter page has no matching title at all.
        return http.Response.bytes(
          utf8.encode('<div class="original anime main-card"></div>'),
          200,
        );
      });
      final AnisugeResolver resolver = AnisugeResolver(
        client: client,
        anilist: AniListService(client: client),
        megaplay: MiruroResolver(client: client),
      );
      const Anime missing = Anime(
        id: 'anilist-1',
        title: 'No Such Anime Ever',
        rating: 4.5,
        year: 2026,
        episodeCount: 1,
        genres: <String>['Action'],
        synopsis: 'Test anime.',
        gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
        anilistId: 1,
      );
      expect(
        await resolver.resolve(
          anime: missing,
          episodeNumber: 1,
          subDub: 'Sub',
        ),
        isNull,
      );
      expect(resolver.lastError, contains('Could not find'));
    });
  });
}
