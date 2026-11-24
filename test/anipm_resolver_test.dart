import 'dart:convert';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/services/anipm_resolver.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.25: AniPM (anipm.pk) — WebView-embed source. The parsers
/// are tested against the REAL recorded responses (Jujutsu
/// Kaisen S1 + Demon Slayer S1, EP1 Sub, 2026-11-25, in
/// test/fixtures/anipm_*), and the full resolve runs end-to-end
/// against a MockClient that plays those recordings back.
///
/// The chain returns an EMBED URL (https://embed.settlar.io/…),
/// never a stream URL — the video plays inside the settlar embed
/// via MSE blob URLs, and the embed itself is Cloudflare-403
/// from the VM. So the mock proves the chain up to the embed
/// URL; the phone test is the only proof the embed plays.
/// The Dub path is checked with a MUTATED bootstrap fixture
/// (the recorded one was requested with lang=sub, so its
/// effectiveLanguage is 'sub' — a live Dub request returns
/// effectiveLanguage 'dub').
void main() {
  Map<String, dynamic> fixtureJson(String name) =>
      jsonDecode(File('test/fixtures/$name').readAsStringSync())
          as Map<String, dynamic>;

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

  const Anime ds = Anime(
    id: 'anilist-21',
    title: 'Demon Slayer',
    rating: 4.5,
    year: 2019,
    episodeCount: 26,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 21,
  );

  String anilistIdentityJson(String romaji, String english) =>
      jsonEncode(<String, Object>{
        'data': <String, Object>{
          'Media': <String, Object>{
            'title': <String, Object>{
              'romaji': romaji,
              'english': english,
              'native': 'テスト',
            },
            'seasonYear': 2020,
            'format': 'TV',
            'episodes': 24,
            'status': 'FINISHED',
          },
        },
      });

  group('parsers (recorded live responses)', () {
    test('search items: JJK settlar first', () {
      final List<AnipmSearchItem> items = AniPmResolver.parseSearchItems(
        fixtureJson('anipm_search_jjk.json'),
      );
      expect(items, isNotEmpty);
      expect(items.first.id, 1103);
      expect(items.first.source, 'settlar');
      expect(items.first.title, 'JUJUTSU KAISEN');
      expect(items.first.episodeCount, 24);
      // Second season is a separate settlar item.
      expect(items[1].id, 6542);
      expect(items[1].episodeCount, 23);
    });

    test('search items: Demon Slayer settlar first', () {
      final List<AnipmSearchItem> items = AniPmResolver.parseSearchItems(
        fixtureJson('anipm_search_ds.json'),
      );
      expect(items.first.id, 1551);
      expect(items.first.source, 'settlar');
      expect(items.first.episodeCount, 26);
    });

    test('search items: empty + malformed', () {
      expect(
        AniPmResolver.parseSearchItems(<String, dynamic>{'items': []}),
        isEmpty,
      );
      expect(
        AniPmResolver.parseSearchItems(<String, dynamic>{}),
        isEmpty,
      );
      expect(
        AniPmResolver.parseSearchItems(<String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{'id': 0, 'source': 'settlar', 'title': 'X'},
            <String, dynamic>{
              'id': 5,
              'source': '',
              'title': 'Y',
            },
            <String, dynamic>{
              'id': '7',
              'source': 'anilist',
              'title': 'Z',
            },
          ],
        }).map((AnipmSearchItem i) => i.id).toList(),
        <int>[7],
      );
    });

    test('bootstrap: JJK EP1 Sub parses', () {
      final dynamic boot = AniPmResolver.parseBootstrap(
        fixtureJson('anipm_bootstrap_1103_ep1.json'),
        lang: 'sub',
      );
      expect(boot, isNotNull);
    });

    test('bootstrap: wrong effective language is rejected', () {
      // The recorded bootstrap was requested with lang=sub, so
      // asking it for dub must fail — never silently play the
      // wrong language.
      expect(
        AniPmResolver.parseBootstrap(
          fixtureJson('anipm_bootstrap_1103_ep1.json'),
          lang: 'dub',
        ),
        isNull,
      );
    });

    test('bootstrap: Dub works on a mutated fixture', () {
      final Map<String, dynamic> mutated =
          fixtureJson('anipm_bootstrap_1103_ep1.json');
      mutated['requestedLanguage'] = 'dub';
      mutated['effectiveLanguage'] = 'dub';
      expect(
        AniPmResolver.parseBootstrap(mutated, lang: 'dub'),
        isNotNull,
      );
    });

    test('bootstrap: unavailable language is rejected', () {
      final Map<String, dynamic> mutated =
          fixtureJson('anipm_bootstrap_1103_ep1.json');
      (mutated['availability'] as Map<String, dynamic>)['sub'] = false;
      expect(
        AniPmResolver.parseBootstrap(mutated, lang: 'sub'),
        isNull,
      );
    });

    test('bootstrap: missing token is rejected', () {
      final Map<String, dynamic> mutated =
          fixtureJson('anipm_bootstrap_1103_ep1.json');
      mutated.remove('settlarSelection');
      expect(
        AniPmResolver.parseBootstrap(mutated, lang: 'sub'),
        isNull,
      );
    });

    test('session: JJK embed URL parses', () {
      final String? url = AniPmResolver.parseSessionEmbedUrl(
        fixtureJson('anipm_session_jjk_ep1.json'),
      );
      expect(url, isNotNull);
      expect(url, startsWith('https://embed.settlar.io/embed/v1?t='));
    });

    test('session: wrong host / scheme / empty rejected', () {
      expect(
        AniPmResolver.parseSessionEmbedUrl(
          <String, dynamic>{'embedUrl': 'https://evil.example/x'},
        ),
        isNull,
      );
      expect(
        AniPmResolver.parseSessionEmbedUrl(
          <String, dynamic>{'embedUrl': 'http://embed.settlar.io/x'},
        ),
        isNull,
      );
      expect(
        AniPmResolver.parseSessionEmbedUrl(<String, dynamic>{}),
        isNull,
      );
    });
  });

  group('full resolve (MockClient plays the recordings back)', () {
    MockClient recordedClient({
      required String searchFixture,
      required String bootstrapFixture,
      required String sessionFixture,
      bool dubBootstrap = false,
      bool noDub = false,
    }) {
      return MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('graphql.anilist.co')) {
          return http.Response(
            anilistIdentityJson('Jujutsu Kaisen', 'JUJUTSU KAISEN'),
            200,
          );
        }
        if (url.contains('/api/anime/search')) {
          // Response.bytes: the fixture carries non-ASCII titles
          // (Japanese / Thai / Arabic) and http.Response(String)
          // throws on non-Latin-1 bodies.
          return http.Response.bytes(
            utf8.encode(
              File(
                'test/fixtures/$searchFixture',
              ).readAsStringSync(),
            ),
            200,
          );
        }
        if (url.contains('/api/anime/playback-bootstrap/')) {
          final Map<String, dynamic> boot =
              fixtureJson(bootstrapFixture);
          if (dubBootstrap) {
            boot['requestedLanguage'] = 'dub';
            boot['effectiveLanguage'] = 'dub';
          }
          if (noDub) {
            (boot['availability'] as Map<String, dynamic>)['dub'] =
                false;
          }
          // Response.bytes: the bootstrap JSON carries non-ASCII
          // (native title) and http.Response(String) throws.
          return http.Response.bytes(utf8.encode(jsonEncode(boot)), 200);
        }
        if (url.contains('/api/anime/settlar/session')) {
          return http.Response.bytes(
            utf8.encode(
              File(
                'test/fixtures/$sessionFixture',
              ).readAsStringSync(),
            ),
            200,
          );
        }
        return http.Response('not found: $url', 404);
      });
    }

    test('JJK S1 EP1 Sub resolves to a settlar embed (webEmbed)',
        () async {
      final AniPmResolver resolver = AniPmResolver(
        client: recordedClient(
          searchFixture: 'anipm_search_jjk.json',
          bootstrapFixture: 'anipm_bootstrap_1103_ep1.json',
          sessionFixture: 'anipm_session_jjk_ep1.json',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull);
      expect(stream!.source, 'AniPM');
      expect(stream.playback, StreamPlayback.webEmbed);
      expect(stream.url, startsWith('https://embed.settlar.io/'));
      expect(stream.label, 'AniPM Sub');
      expect(stream.variants, isEmpty);
      expect(stream.subtitles, isEmpty);
    });

    test('Demon Slayer S1 EP1 Sub resolves to a settlar embed',
        () async {
      final AniPmResolver resolver = AniPmResolver(
        client: recordedClient(
          searchFixture: 'anipm_search_ds.json',
          bootstrapFixture: 'anipm_bootstrap_ds_ep1.json',
          sessionFixture: 'anipm_session_ds_ep1.json',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: ds,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull);
      expect(stream!.playback, StreamPlayback.webEmbed);
      expect(stream.url, startsWith('https://embed.settlar.io/'));
    });

    test('JJK S1 EP1 Dub resolves with a dub bootstrap', () async {
      final AniPmResolver resolver = AniPmResolver(
        client: recordedClient(
          searchFixture: 'anipm_search_jjk.json',
          bootstrapFixture: 'anipm_bootstrap_1103_ep1.json',
          sessionFixture: 'anipm_session_jjk_ep1.json',
          dubBootstrap: true,
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Dub',
      );
      expect(stream, isNotNull);
      expect(stream!.label, 'AniPM Dub');
    });

    test('Dub fails honestly when the bootstrap says no dub',
        () async {
      final AniPmResolver resolver = AniPmResolver(
        client: recordedClient(
          searchFixture: 'anipm_search_jjk.json',
          bootstrapFixture: 'anipm_bootstrap_1103_ep1.json',
          sessionFixture: 'anipm_session_jjk_ep1.json',
          noDub: true,
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Dub',
      );
      expect(stream, isNull);
      expect(resolver.lastError, contains('no Dub'));
    });

    test('unknown title fails honestly', () async {
      final AniPmResolver resolver = AniPmResolver(
        client: MockClient((http.Request req) async {
          final String url = req.url.toString();
          if (url.contains('graphql.anilist.co')) {
            return http.Response(
              anilistIdentityJson('No Such Anime', 'NO SUCH ANIME'),
              200,
            );
          }
          if (url.contains('/api/anime/search')) {
            return http.Response('{"items":[]}', 200);
          }
          return http.Response('not found', 404);
        }),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(resolver.lastError, contains('Could not find'));
    });
  });
}
