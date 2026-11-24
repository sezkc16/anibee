import 'dart:convert';
import 'dart:io';

import 'package:anibee/models.dart';
import 'package:anibee/services/animesama_resolver.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.25: Anime-Sama (anime-sama.to). The parsers are tested
/// against the REAL recorded responses (Jujutsu Kaisen + Demon
/// Slayer, 2026-11-25, in test/fixtures/animesama_*), and the
/// full resolve runs end-to-end against a MockClient that plays
/// those recordings back.
///
/// Live facts the tests encode:
/// - Search is POST /template-php/defaut/fetch.php (form
///   `query=`), results are `a.asn-search-result[href]`.
/// - The series page lists seasons via inline
///   `panneauAnime("Saison 1", "saison1/vostfr")` calls.
/// - The season page embeds `var eps1 = ["lien:4658", …]` (one
///   array per lecteur), `var epsMeta`, `var epsJeton`, and
///   `var languesDispo = ["vostfr","vf"]`.
/// - `GET /api/lien.php?j=<jeton>&l=<id>` returns
///   `{"u": "<embed url>"}`.
/// - The Vidmoly embed page carries a plain
///   `sources: [{ file: '…master.m3u8' }]`; the master has
///   1080p + 480p variants. JJK's master + segment were
///   ffprobe-verified to real H.264 + AAC from the VM; Demon
///   Slayer's edge (prx-1476-ant.vmpx.online) serves the master
///   + variants but 403s SEGMENTS from the VM — the resolver
///   only fetches the master, so the mock proves the chain, and
///   the phone is the proof for DS playback.
/// - VOSTFR subtitles are burned in (no SUBTITLES group in the
///   master, only h264 + aac in the segment) — no subtitle
///   tracks are returned.
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
    test('search results: JJK + DS', () {
      final List<AnimeSamaHit> jjkHits = AnimeSamaResolver
          .parseSearchResults(fixture('animesama_search_jjk.html'));
      expect(jjkHits, isNotEmpty);
      expect(jjkHits.first.title, 'Jujutsu Kaisen');
      expect(
        jjkHits.first.href,
        'https://anime-sama.to/catalogue/jujutsu-kaisen/',
      );
      final List<AnimeSamaHit> dsHits = AnimeSamaResolver
          .parseSearchResults(fixture('animesama_search_ds.html'));
      expect(dsHits.first.title, 'Demon Slayer');
      expect(
        dsHits.first.href,
        'https://anime-sama.to/catalogue/demon-slayer/',
      );
    });

    test('seasons: JJK series page', () {
      final List<AnimeSamaSeason> seasons = AnimeSamaResolver
          .parseSeasons(fixture('animesama_series_jjk.html'), 'vostfr');
      expect(
        seasons.map((AnimeSamaSeason s) => s.name).toList(),
        <String>['Saison 1', 'Film', 'Saison 2', 'Saison 3'],
      );
      expect(seasons[0].path, 'saison1/vostfr');
      expect(seasons[0].number, 1);
      // JJK's film path is a bare "film/vostfr" (no number).
      expect(seasons[1].path, 'film/vostfr');
      expect(seasons[1].number, 1001);
      // Dub swaps the language in the path.
      final List<AnimeSamaSeason> dub = AnimeSamaResolver
          .parseSeasons(fixture('animesama_series_jjk.html'), 'vf');
      expect(dub[0].path, 'saison1/vf');
    });

    test('seasons: Demon Slayer series page', () {
      final List<AnimeSamaSeason> seasons = AnimeSamaResolver
          .parseSeasons(fixture('animesama_series_ds.html'), 'vostfr');
      // S1, film1, "saison1hs" (special — counts as season 1),
      // S2, S3, S4, film2.
      expect(
        seasons.map((AnimeSamaSeason s) => s.number).toList(),
        <int>[1, 1001, 1, 2, 3, 4, 1002],
      );
    });

    test('season page: JJK S1 VOSTFR', () {
      final AnimeSamaSeasonPage? page = AnimeSamaResolver
          .parseSeasonPage(fixture('animesama_s1_vostfr_jjk.html'));
      expect(page, isNotNull);
      expect(page!.languages, <String>['vostfr', 'vf']);
      expect(page.jeton, isNotEmpty);
      expect(page.lecteurs.length, 4);
      expect(page.episodeCount, 24);
      expect(page.lecteurs[0][0], 'lien:4658');
      expect(page.lecteurs[1][0], 'lien:4659');
      expect(page.lecteurs[2][0], 'lien:4657');
      expect(page.lecteurs[3][0], 'lien:4660');
    });

    test('season page: JJK S1 VF', () {
      final AnimeSamaSeasonPage? page = AnimeSamaResolver
          .parseSeasonPage(fixture('animesama_s1_vf_jjk.html'));
      expect(page, isNotNull);
      expect(page!.languages, <String>['vostfr', 'vf']);
      expect(page.episodeCount, 24);
    });

    test('season page: Demon Slayer S1 VOSTFR', () {
      final AnimeSamaSeasonPage? page = AnimeSamaResolver
          .parseSeasonPage(fixture('animesama_s1_vostfr_ds.html'));
      expect(page, isNotNull);
      expect(page!.episodeCount, 26);
      expect(page.lecteurs[0][0], 'lien:26623');
    });

    test('Vidmoly file extraction', () {
      expect(
        AnimeSamaResolver.extractVidmolyFile(
          fixture('animesama_vidmoly_jjk.html'),
        ),
        contains('hg9srndukcud'),
      );
      expect(
        AnimeSamaResolver.extractVidmolyFile(
          fixture('animesama_vidmoly_jjk.html'),
        ),
        contains('master.m3u8'),
      );
      expect(
        AnimeSamaResolver.extractVidmolyFile(
          fixture('animesama_vidmoly_ds.html'),
        ),
        contains('7b0h8hsq9le6'),
      );
    });

    test('master variants: JJK 1080p + 480p', () {
      final List<StreamVariant> variants = AnimeSamaResolver
          .parseMasterVariants(fixture('animesama_master_jjk.m3u8'));
      expect(
        variants.map((StreamVariant v) => v.qualityLabel).toList(),
        <String>['1080p', '480p'],
      );
      expect(variants[0].url, contains('hg9srndukcud_n'));
      expect(variants[1].url, contains('hg9srndukcud_l'));
    });
  });

  group('full resolve (MockClient plays the recordings back)', () {
    MockClient recordedClient({
      required String searchFixture,
      required String seriesFixture,
      required String seasonFixture,
      required String lienFixture,
      required String embedFixture,
      required String masterFixture,
      String? seasonFixtureVf,
    }) {
      return MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('graphql.anilist.co')) {
          return http.Response(
            anilistIdentityJson('Jujutsu Kaisen', 'JUJUTSU KAISEN'),
            200,
          );
        }
        if (url.contains('/template-php/defaut/fetch.php')) {
          return http.Response.bytes(
            utf8.encode(fixture(searchFixture)),
            200,
          );
        }
        // Season URLs contain the series URL as a prefix — check
        // the longer (season) URL first.
        if (url.contains('/saison1/vf/')) {
          return http.Response.bytes(
            utf8.encode(
              fixture(seasonFixtureVf ?? seasonFixture),
            ),
            200,
          );
        }
        if (url.contains('/saison1/vostfr/')) {
          return http.Response.bytes(
            utf8.encode(fixture(seasonFixture)),
            200,
          );
        }
        if (url.contains('/catalogue/jujutsu-kaisen/') ||
            url.contains('/catalogue/demon-slayer/')) {
          return http.Response.bytes(
            utf8.encode(fixture(seriesFixture)),
            200,
          );
        }
        if (url.contains('/api/lien.php')) {
          return http.Response.bytes(
            utf8.encode(fixture(lienFixture)),
            200,
          );
        }
        if (url.contains('ansembed.net/embed-')) {
          return http.Response.bytes(
            utf8.encode(fixture(embedFixture)),
            200,
          );
        }
        if (url.contains('master.m3u8')) {
          return http.Response.bytes(
            utf8.encode(fixture(masterFixture)),
            200,
          );
        }
        return http.Response('not found: $url', 404);
      });
    }

    test('JJK S1 EP1 Sub resolves to Vidmoly HLS', () async {
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: recordedClient(
          searchFixture: 'animesama_search_jjk.html',
          seriesFixture: 'animesama_series_jjk.html',
          seasonFixture: 'animesama_s1_vostfr_jjk.html',
          lienFixture: 'animesama_lien_4658.json',
          embedFixture: 'animesama_vidmoly_jjk.html',
          masterFixture: 'animesama_master_jjk.m3u8',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull);
      expect(stream!.source, 'Anime-Sama');
      // Best URL is the 1080p variant, not the master playlist.
      expect(stream.url, isNot(contains('master.m3u8')));
      expect(stream.url, contains('hg9srndukcud_n'));
      expect(stream.label, contains('1080p'));
      expect(stream.playback, StreamPlayback.mpv);
      expect(stream.subtitles, isEmpty,
          reason: 'VOSTFR subs are burned in — no subtitle tracks');
      expect(
        stream.variants.map((StreamVariant v) => v.qualityLabel).toList(),
        <String>['1080p', '480p'],
      );
    });

    test('Demon Slayer S1 EP1 Sub resolves (episode-count season match)',
        () async {
      // "Demon Slayer" carries no "Season N" in any title, so
      // the resolver must pick saison1 by its 26-episode count.
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: recordedClient(
          searchFixture: 'animesama_search_ds.html',
          seriesFixture: 'animesama_series_ds.html',
          seasonFixture: 'animesama_s1_vostfr_ds.html',
          lienFixture: 'animesama_lien_ds.json',
          embedFixture: 'animesama_vidmoly_ds.html',
          masterFixture: 'animesama_master_ds.m3u8',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: ds,
        episodeNumber: 1,
        subDub: 'Sub',
      );
      expect(stream, isNotNull);
      expect(stream!.source, 'Anime-Sama');
      expect(stream.url, contains('7b0h8hsq9le6_n'));
    });

    test('JJK S1 EP1 Dub uses the VF season page', () async {
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: recordedClient(
          searchFixture: 'animesama_search_jjk.html',
          seriesFixture: 'animesama_series_jjk.html',
          seasonFixture: 'animesama_s1_vostfr_jjk.html',
          lienFixture: 'animesama_lien_4658.json',
          embedFixture: 'animesama_vidmoly_jjk.html',
          masterFixture: 'animesama_master_jjk.m3u8',
          // The VF page is a different recording (same episode
          // count, same lecteur layout); the mock returns the
          // same lien/embed fixtures, which proves the Dub path
          // reaches the VF page + the same extraction code.
          seasonFixtureVf: 'animesama_s1_vf_jjk.html',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 1,
        subDub: 'Dub',
      );
      expect(stream, isNotNull);
      expect(stream!.source, 'Anime-Sama');
    });

    test('episode beyond the season count fails honestly', () async {
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: recordedClient(
          searchFixture: 'animesama_search_jjk.html',
          seriesFixture: 'animesama_series_jjk.html',
          seasonFixture: 'animesama_s1_vostfr_jjk.html',
          lienFixture: 'animesama_lien_4658.json',
          embedFixture: 'animesama_vidmoly_jjk.html',
          masterFixture: 'animesama_master_jjk.m3u8',
        ),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: jjk,
        episodeNumber: 99,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(resolver.lastError, contains('no episode 99'));
    });

    test('unknown title fails honestly', () async {
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: MockClient((http.Request req) async {
          final String url = req.url.toString();
          if (url.contains('graphql.anilist.co')) {
            return http.Response(
              anilistIdentityJson('No Such Anime', 'NO SUCH ANIME'),
              200,
            );
          }
          if (url.contains('/template-php/defaut/fetch.php')) {
            return http.Response('', 200);
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
