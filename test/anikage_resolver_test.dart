import 'dart:convert';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/services/anikage_resolver.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.24: AniKage (anikage.cc). The full resolve runs end-to-end
/// against a MockClient that plays back the REAL recorded API
/// responses (Jujutsu Kaisen, 2026-11-24, in
/// test/fixtures/anikage_*). The final playlist fetch is NOT
/// proven here (the mock master 404s, so the test proves the
/// chain produces the real signed HLS URL the phone will fetch);
/// the live probe test proves real playability end-to-end.
/// The encrypted `sources[].url` values are deliberately NOT
/// used — the megaplay `embedOptions` URL is the verified path
/// (see AnikageResolver's doc comment).
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

  const String megaEmbedHtml =
      '<div id="megaplay-player" data-id="10789"></div>';

  MockClient recordedClient({
    String Function(String url)? sourcesOverride,
  }) {
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
      if (url.contains('/api/media/anime/browse')) {
        return http.Response.bytes(
          utf8.encode(fixture('anikage_browse_jjk.json')),
          200,
        );
      }
      if (url.contains('/episodes/1/servers')) {
        return http.Response.bytes(
          utf8.encode(fixture('anikage_servers_jjk.json')),
          200,
        );
      }
      if (url.contains('/episodes/1/sources')) {
        if (sourcesOverride != null) {
          return http.Response(sourcesOverride(url), 200);
        }
        return http.Response.bytes(
          utf8.encode(fixture('anikage_sources_koto_jjk.json')),
          200,
        );
      }
      if (url.endsWith('/episodes')) {
        return http.Response.bytes(
          utf8.encode(fixture('anikage_episodes_jjk.json')),
          200,
        );
      }
      if (url.contains('megaplay.buzz/videojs/stream/s-2/10789')) {
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

  group('resolve (recorded responses)', () {
    test('JJK EP1 sub → signed megaplay HLS + English subs', () async {
      final MockClient client = recordedClient();
      final AnikageResolver resolver = AnikageResolver(
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
      expect(stream!.source, 'AniKage');
      expect(stream.label, 'AniKage koto Sub');
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

    test('embed-only providers are skipped, never guessed', () async {
      // koto's sources call returns ONLY a vidcloud embed (no
      // megaplay option) — the resolver must not invent a stream
      // from it, and must keep trying the other servers (which
      // the mock also answers with the same vidcloud-only
      // response) before giving up.
      final MockClient client = recordedClient(
        sourcesOverride: (String url) => jsonEncode(<String, Object>{
          'sources': <Object>[],
          'subtitles': <Object>[],
          'embedOptions': <Object>[
            <String, Object>{
              'key': 'kage',
              'url': 'https://vidcloud.se/s-1/189123/1/sub',
            },
          ],
        }),
      );
      final AnikageResolver resolver = AnikageResolver(
        client: client,
        anilist: AniListService(client: client),
        megaplay: MiruroResolver(client: client),
      );
      expect(
        await resolver.resolve(
          anime: jjk,
          episodeNumber: 1,
          subDub: 'Sub',
        ),
        isNull,
      );
      expect(resolver.lastError, contains('no working server'));
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
        if (req.url.toString().contains('/api/media/anime/browse')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <Object>[],
              'total': 0,
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final AnikageResolver resolver = AnikageResolver(
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
