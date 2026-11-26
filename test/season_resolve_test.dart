import 'dart:convert';

import 'package:anibee/models.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/animesama_resolver.dart';
import 'package:anibee/services/anisuge_resolver.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.2.30 season-selector bug: selecting S2+ still played S1.
/// Root cause (code + live probe, 2026-11-27): the title-based
/// resolvers (AniKoto, AniSuge, Anime-Sama) search the site by
/// TITLE, and every season of a show shares the same AniList title
/// ("My Hero Academia"), so their exact/first-match pickers always
/// returned S1. Live proof: anikoto.cz lists "My Hero Academia"
/// first; justanime returns DIFFERENT streams for 21459 (S1) vs
/// 117193 (S5) EP5, so the id-based Miruro path was never the
/// culprit. The fix threads the selected season's chain position
/// (Anime.seasonNumber) into every resolver so the site's season
/// suffix ("Title 2", "Title 5th Season", "Title Season 6") is
/// matched instead.
void main() {
  const Anime mhaS1 = Anime(
    id: 'anilist-21459',
    title: 'My Hero Academia',
    rating: 4.0,
    year: 2016,
    episodeCount: 13,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 21459,
    seasonNumber: 1,
  );

  const Anime mhaS5 = Anime(
    id: 'anilist-117193',
    title: 'My Hero Academia',
    rating: 4.0,
    year: 2020,
    episodeCount: 25,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 117193,
    seasonNumber: 5,
  );

  const Anime mhaNoSeason = Anime(
    id: 'anilist-117193',
    title: 'My Hero Academia',
    rating: 4.0,
    year: 2020,
    episodeCount: 25,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 117193,
  );

  group('seasonTitleMatches (pure)', () {
    test('MHA: bare title is S1 only', () {
      expect(
        seasonTitleMatches('My Hero Academia', 'My Hero Academia', 1),
        isTrue,
      );
      expect(
        seasonTitleMatches('My Hero Academia', 'My Hero Academia', 5),
        isFalse,
      );
    });

    test('MHA: site season suffixes match their season', () {
      expect(
        seasonTitleMatches(
          'My Hero Academia 2',
          'My Hero Academia',
          2,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia 3',
          'My Hero Academia',
          3,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia 4',
          'My Hero Academia',
          4,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia 5th Season',
          'My Hero Academia',
          5,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia Season 6',
          'My Hero Academia',
          6,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia Season 7',
          'My Hero Academia',
          7,
        ),
        isTrue,
      );
    });

    test('MHA: suffixes do not match the wrong season', () {
      expect(
        seasonTitleMatches(
          'My Hero Academia 5th Season',
          'My Hero Academia',
          2,
        ),
        isFalse,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia 2',
          'My Hero Academia',
          5,
        ),
        isFalse,
      );
      expect(
        seasonTitleMatches(
          'My Hero Academia Season 6',
          'My Hero Academia',
          5,
        ),
        isFalse,
      );
    });

    test('MHA: specials and spinoffs match no season', () {
      for (final String title in <String>[
        'My Hero Academia ONA',
        'My Hero Academia: More',
        'My Hero Academia: Vigilantes',
        'My Hero Academia Final Season',
      ]) {
        for (int s = 1; s <= 7; s++) {
          expect(
            seasonTitleMatches(title, 'My Hero Academia', s),
            isFalse,
            reason: '$title must not match season $s',
          );
        }
      }
    });

    test('parens are stripped: "(TV)" still matches S1', () {
      expect(
        seasonTitleMatches(
          'My Hero Academia (TV)',
          'My Hero Academia',
          1,
        ),
        isTrue,
      );
    });

    test('base title carrying its own season number', () {
      expect(
        seasonTitleMatches(
          'Attack on Titan Season 2',
          'Attack on Titan Season 2',
          2,
        ),
        isTrue,
      );
      expect(
        seasonTitleMatches(
          'Attack on Titan Season 2',
          'Attack on Titan Season 2',
          1,
        ),
        isFalse,
      );
    });

    test('seasonNumberInTitle', () {
      expect(seasonNumberInTitle('Season 5'), 5);
      expect(seasonNumberInTitle('5th Season'), 5);
      expect(seasonNumberInTitle('My Hero Academia 2'), 2);
      expect(seasonNumberInTitle('Part 2'), 2);
      expect(seasonNumberInTitle('Cour 1'), 1);
      expect(seasonNumberInTitle('My Hero Academia'), isNull);
      expect(seasonNumberInTitle('My Hero Academia ONA'), isNull);
    });

    test('seasonNumberFor: chain position is 1-based', () {
      final List<SeasonInfo> chain = <SeasonInfo>[
        const SeasonInfo(
          id: 21459,
          title: 'My Hero Academia',
          format: 'TV',
          episodes: 13,
        ),
        const SeasonInfo(
          id: 21856,
          title: 'My Hero Academia Season 2',
          format: 'TV',
          episodes: 25,
        ),
        const SeasonInfo(
          id: 117193,
          title: 'My Hero Academia Season 5',
          format: 'TV',
          episodes: 25,
        ),
      ];
      expect(seasonNumberFor(21459, chain), 1);
      expect(seasonNumberFor(21856, chain), 2);
      expect(seasonNumberFor(117193, chain), 3);
      expect(seasonNumberFor(999999, chain), isNull);
    });
  });

  group('Anime.seasonNumber plumbing', () {
    test('copyWith keeps and sets seasonNumber', () {
      expect(mhaS5.copyWith().seasonNumber, 5);
      expect(mhaS1.copyWith(seasonNumber: 3).seasonNumber, 3);
      expect(mhaNoSeason.copyWith(seasonNumber: 5).seasonNumber, 5);
    });

    test('toJson/fromJson round-trips seasonNumber', () {
      final Anime back = Anime.fromJson(mhaS5.toJson())!;
      expect(back.seasonNumber, 5);
      expect(back.anilistId, 117193);
      expect(Anime.fromJson(mhaNoSeason.toJson())!.seasonNumber, isNull);
    });
  });

  // ---------------------------------------------------------- AniKoto
  //
  // Search page in the LIVE order from anikoto.cz (2026-11-27):
  // S1 first, then 2, 3, 4, ONA, More, Season 7, Season 6,
  // 5th Season, Vigilantes. The old code picked the first exact
  // title match — always S1.
  const String anikotoSearchHtml = '''
<div id="list-items">
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia"><img alt="My Hero Academia"></a></div><a class="name d-title">My Hero Academia</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-2"><img alt="My Hero Academia 2"></a></div><a class="name d-title">My Hero Academia 2</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-3"><img alt="My Hero Academia 3"></a></div><a class="name d-title">My Hero Academia 3</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-4"><img alt="My Hero Academia 4"></a></div><a class="name d-title">My Hero Academia 4</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-ona"><img alt="My Hero Academia ONA"></a></div><a class="name d-title">My Hero Academia ONA</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-more"><img alt="My Hero Academia: More"></a></div><a class="name d-title">My Hero Academia: More</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-season-7"><img alt="My Hero Academia Season 7"></a></div><a class="name d-title">My Hero Academia Season 7</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-season-6"><img alt="My Hero Academia Season 6"></a></div><a class="name d-title">My Hero Academia Season 6</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-5th-season"><img alt="My Hero Academia 5th Season"></a></div><a class="name d-title">My Hero Academia 5th Season</a></div>
  <div class="item"><div class="ani poster"><a href="/anime/my-hero-academia-vigilantes"><img alt="My Hero Academia: Vigilantes"></a></div><a class="name d-title">My Hero Academia: Vigilantes</a></div>
</div>
''';

  group('AniKoto season pick', () {
    test('season 5 picks the 5th Season watch page, not S1', () async {
      final List<String> requested = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        requested.add(req.url.toString());
        if (req.url.toString().contains('/filter?keyword=')) {
          return http.Response.bytes(
            utf8.encode(anikotoSearchHtml),
            200,
          );
        }
        // Watch page without data-anime-id: resolve stops here,
        // but the requested watch URL proves the pick.
        return http.Response('<html></html>', 200);
      });
      final MiruroResolver resolver = MiruroResolver(client: client);
      final ResolvedStream? stream = await resolver.resolveAnikoto(
        'My Hero Academia',
        5,
        'Sub',
        seasonNumber: 5,
      );
      expect(stream, isNull);
      expect(
        requested,
        contains('https://anikoto.cz/anime/my-hero-academia-5th-season'),
      );
      expect(
        requested,
        isNot(contains('https://anikoto.cz/anime/my-hero-academia')),
      );
    });

    test('no season number keeps the old S1 pick', () async {
      final List<String> requested = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        requested.add(req.url.toString());
        if (req.url.toString().contains('/filter?keyword=')) {
          return http.Response.bytes(
            utf8.encode(anikotoSearchHtml),
            200,
          );
        }
        return http.Response('<html></html>', 200);
      });
      final MiruroResolver resolver = MiruroResolver(client: client);
      await resolver.resolveAnikoto('My Hero Academia', 5, 'Sub');
      expect(
        requested,
        contains('https://anikoto.cz/anime/my-hero-academia'),
      );
    });

    test('season 1 still picks the bare title', () async {
      final List<String> requested = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        requested.add(req.url.toString());
        if (req.url.toString().contains('/filter?keyword=')) {
          return http.Response.bytes(
            utf8.encode(anikotoSearchHtml),
            200,
          );
        }
        return http.Response('<html></html>', 200);
      });
      final MiruroResolver resolver = MiruroResolver(client: client);
      await resolver.resolveAnikoto(
        'My Hero Academia',
        5,
        'Sub',
        seasonNumber: 1,
      );
      expect(
        requested,
        contains('https://anikoto.cz/anime/my-hero-academia'),
      );
      expect(
        requested,
        isNot(
          contains(
            'https://anikoto.cz/anime/my-hero-academia-5th-season',
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------- AniSuge
  //
  // Filter page in the LIVE anisuge.tv order (2026-11-27): the
  // exact "My Hero Academia" (S1) sits mid-list, and the romaji
  // query ("Boku no Hero Academia") matches nothing exactly — the
  // old code fell through to hits.first on that query.
  const String anisugeFilterHtml = '''
<div class="original anime main-card">
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-more"><img alt="My Hero Academia: More"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-season-7"><img alt="My Hero Academia Season 7"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-season-6"><img alt="My Hero Academia Season 6"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-ona"><img alt="My Hero Academia ONA"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia"><img alt="My Hero Academia"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-5th-season"><img alt="My Hero Academia 5th Season"></a></div></div>
  <div class="item"><div class="item-top"><a href="https://anisuge.tv/anime/my-hero-academia-4"><img alt="My Hero Academia 4"></a></div></div>
</div>
''';

  MockClient anisugeClient(List<String> requested) {
    return MockClient((http.Request req) async {
      requested.add(req.url.toString());
      final String url = req.url.toString();
      if (url.contains('graphql.anilist.co')) {
        return http.Response(
          jsonEncode(<String, Object>{
            'data': <String, Object>{
              'Media': <String, Object>{
                'title': <String, Object>{
                  'romaji': 'Boku no Hero Academia',
                  'english': 'My Hero Academia',
                  'native': '',
                },
                'seasonYear': 2020,
                'format': 'TV',
                'episodes': 25,
                'status': 'FINISHED',
              },
            },
          }),
          200,
        );
      }
      if (url.contains('/filter?keyword=')) {
        return http.Response.bytes(utf8.encode(anisugeFilterHtml), 200);
      }
      // Watch page without data-id: resolve stops here, but the
      // requested watch URL proves the pick.
      return http.Response('<div class="container watch-wrap"></div>', 200);
    });
  }

  group('AniSuge season pick', () {
    test('season 5 picks the 5th Season watch page', () async {
      final List<String> requested = <String>[];
      final MockClient client = anisugeClient(requested);
      final AnisugeResolver resolver = AnisugeResolver(
        client: client,
        anilist: AniListService(client: client),
        megaplay: MiruroResolver(client: client),
      );
      final ResolvedStream? stream = await resolver.resolve(
        anime: mhaS5,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(
        requested,
        contains(
          'https://anisuge.tv/anime/my-hero-academia-5th-season',
        ),
      );
      expect(
        requested,
        isNot(contains('https://anisuge.tv/anime/my-hero-academia-more')),
      );
    });

    test('season 1 still picks the bare title', () async {
      final List<String> requested = <String>[];
      final MockClient client = anisugeClient(requested);
      final AnisugeResolver resolver = AnisugeResolver(
        client: client,
        anilist: AniListService(client: client),
        megaplay: MiruroResolver(client: client),
      );
      await resolver.resolve(
        anime: mhaS1,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      expect(
        requested,
        contains('https://anisuge.tv/anime/my-hero-academia'),
      );
    });
  });

  // ---------------------------------------------------------- Miruro
  group('Miruro justanime is id-based', () {
    MockClient justAnimeClient(List<String> requested) {
      return MockClient((http.Request req) async {
        requested.add(req.url.toString());
        final String url = req.url.toString();
        final RegExpMatch? m =
            RegExp(r'/api/watch/(\d+)/episode/(\d+)/megaplay')
                .firstMatch(url);
        if (m != null) {
          final String id = m.group(1)!;
          return http.Response(
            jsonEncode(<String, Object>{
              'sub': <String, Object>{
                'sources': <Object>[
                  <String, Object>{
                    'url':
                        'https://cdn.example.com/$id-master.m3u8?token=x',
                    'quality': 'auto',
                    'isM3U8': true,
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
    }

    test('S5 resolves with the S5 id, S1 with the S1 id', () async {
      final List<String> requested = <String>[];
      final MockClient client = justAnimeClient(requested);
      final MiruroResolver resolver = MiruroResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      final ResolvedStream? s5 = await resolver.resolve(
        anime: mhaS5,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      expect(s5, isNotNull, reason: resolver.lastError);
      expect(
        requested,
        contains(
          'https://core.justanime.to/api/watch/117193/episode/5/megaplay',
        ),
      );
      expect(s5!.url, contains('117193-master.m3u8'));

      requested.clear();
      final ResolvedStream? s1 = await resolver.resolve(
        anime: mhaS1,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      expect(s1, isNotNull, reason: resolver.lastError);
      expect(
        requested,
        contains(
          'https://core.justanime.to/api/watch/21459/episode/5/megaplay',
        ),
      );
      expect(s1!.url, contains('21459-master.m3u8'));
      expect(s1.url, isNot(s5.url));
    });
  });

  // ------------------------------------------------------- Anime-Sama
  //
  // Series page lists saisons 1-5; saison 1 has 13 episodes,
  // saisons 2 and 5 have 25. The OLD _pickSeason fell back to the
  // episode-count match and took saison 2 first for a 25-episode
  // S5 entry. With seasonNumber 5 it must take saison 5 directly.
  String saisonPage(int episodes) {
    final String eps = List<String>.generate(
      episodes,
      (int i) => '"x${i + 1}"',
    ).join(',');
    return 'var epsJeton = "jeton";\n'
        'var languesDispo = ["vostfr"];\n'
        'var eps1 = [$eps];\n';
  }

  const String samaSeriesHtml = '''
panneauAnime("nom", "saison1/vostfr")
panneauAnime("nom", "url")
panneauAnime("Saison 1", "saison1/vostfr")
panneauAnime("Saison 2", "saison2/vostfr")
panneauAnime("Saison 3", "saison3/vostfr")
panneauAnime("Saison 4", "saison4/vostfr")
panneauAnime("Saison 5", "saison5/vostfr")
''';

  MockClient samaClient(List<String> requested) {
    return MockClient((http.Request req) async {
      requested.add(req.url.toString());
      final String url = req.url.toString();
      if (url.contains('graphql.anilist.co')) {
        return http.Response(
          jsonEncode(<String, Object>{
            'data': <String, Object>{
              'Media': <String, Object>{
                'title': <String, Object>{
                  'romaji': 'Boku no Hero Academia',
                  'english': 'My Hero Academia',
                  'native': '',
                },
                'seasonYear': 2020,
                'format': 'TV',
                'episodes': 25,
                'status': 'FINISHED',
              },
            },
          }),
          200,
        );
      }
      if (url.contains('template-php/defaut/fetch.php')) {
        return http.Response(
          '<a href="https://anime-sama.to/catalogue/my-hero-academia/" '
          'class="asn-search-result"><h3>My Hero Academia</h3></a>',
          200,
        );
      }
      if (url == 'https://anime-sama.to/catalogue/my-hero-academia/') {
        return http.Response(samaSeriesHtml, 200);
      }
      if (url.contains('/saison1/vostfr/')) {
        return http.Response(saisonPage(13), 200);
      }
      if (url.contains('/saison2/vostfr/')) {
        return http.Response(saisonPage(25), 200);
      }
      if (url.contains('/saison5/vostfr/')) {
        return http.Response(saisonPage(25), 200);
      }
      return http.Response('not found', 404);
    });
  }

  group('Anime-Sama season pick', () {
    test('season 5 picks saison 5, not saison 2', () async {
      final List<String> requested = <String>[];
      final MockClient client = samaClient(requested);
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      // Lecteurs carry no "lien:" entries, so resolve ends null —
      // the requested saison URL is the proof of the pick.
      final ResolvedStream? stream = await resolver.resolve(
        anime: mhaS5,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      expect(stream, isNull);
      expect(
        requested,
        contains(
          'https://anime-sama.to/catalogue/my-hero-academia/saison5/vostfr/',
        ),
      );
      expect(
        requested,
        isNot(
          contains(
            'https://anime-sama.to/catalogue/my-hero-academia/saison2/vostfr/',
          ),
        ),
      );
    });

    test('no season number falls back to the episode-count match',
        () async {
      final List<String> requested = <String>[];
      final MockClient client = samaClient(requested);
      final AnimeSamaResolver resolver = AnimeSamaResolver(
        client: client,
        anilist: AniListService(client: client),
      );
      await resolver.resolve(
        anime: mhaNoSeason,
        episodeNumber: 5,
        subDub: 'Sub',
      );
      // Old behaviour: saison 1 (13) misses, saison 2 (25) hits.
      expect(
        requested,
        contains(
          'https://anime-sama.to/catalogue/my-hero-academia/saison2/vostfr/',
        ),
      );
    });
  });
}
