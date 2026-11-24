import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// Anime-Sama (anime-sama.to) — real on-device resolver (0.2.25).
///
/// French anime site (free, no signup). VF = French dub,
/// VOSTFR = Japanese audio + French subtitles. The site's domain
/// changes often (blocked in France) — the base URL comes from
/// the remote provider config (`animesama` mirrors) with a
/// bundled fallback to anime-sama.to (verified live 2026-11-25;
/// anime-sama.tv and anime-sama.si both 301 to .to).
///
/// Chain (verified live from the VM, 2026-11-25):
///   `POST /template-php/defaut/fetch.php` (form `query=<title>`)
///   -> HTML: `a.asn-search-result[href]` = series page
///   (`/catalogue/<slug>/`), title in the inner `h3`
///   -> series page: inline `panneauAnime("Saison 1",
///   "saison1/vostfr")` calls list the seasons (and films:
///   `panneauAnime("Film - …", "film1/vostfr")`)
///   -> season page (`/catalogue/<slug>/saison<n>/vostfr/` or
///   `…/vf/`): inline `var eps1 = ["lien:4658", …]` (one array
///   per video host — "lecteur"), `var epsMeta = {"4658":
///   ["ansembed.net"], …}` (host per link id), `var epsJeton =
///   "159.…" (per-page token), `var languesDispo =
///   ["vostfr","vf"]`
///   -> `GET /api/lien.php?j=<jeton>&l=<id>` -> JSON
///   `{"u": "<embed url>"}` (the real video-host URL)
///   -> embed page -> stream URL.
///
/// Hosts (from the season page's `lecteursInfos` map): Vidmoly
/// (ansembed.net / vidmoly.*), Earnvids (smoothpre.com …),
/// VOE (voe.sx + rotating mirror domains), Uqload (uqload.vc),
/// Sendvid / Sibnet / VK / Dailymotion / YouTube / Google Drive
/// / OK.ru (mostly dead — `mort: true` in the map).
///
/// v1 extracts ONLY Vidmoly: its embed page carries a plain
/// `sources: [{ file: '…/master.m3u8?…' }]` (signed HLS, 1080p
/// + 480p variants, H.264 + AAC — verified end-to-end with
/// ffprobe on Jujutsu Kaisen S1 EP1: real 852×480 H.264 + AAC
/// segment). Uqload hides its URL in a Dean-Edwards-packed
/// `eval(...)` block and VOE bounces through rotating mirror
/// domains with a JS challenge page — neither is decoded in v1;
/// the lecteur loop skips hosts it cannot extract instead of
/// faking a stream.
///
/// Language facts (verified live):
/// - VOSTFR subtitles are BURNED INTO the video (the Vidmoly
///   HLS master carries no SUBTITLES group and the segment has
///   only h264 + aac streams), so no subtitle tracks are
///   returned — the player just plays the file.
/// - VF is a French dub (no subtitles needed).
/// - There is NO English audio and NO English subtitle track on
///   this site. The app's Sub/Dub switch maps to VOSTFR/VF.
///   If the requested language is not in the season page's
///   `languesDispo`, resolve FAILS honestly — it never silently
///   plays the other language.
///
/// Season matching: the site groups every season under ONE
/// series slug, so the resolver must pick the saison. Order:
/// (1) a season number parsed from the title variants
/// ("Season 2" / "Saison 2" / "Part 2" -> saison 2);
/// (2) episode-count match — the saison whose `eps1` length
/// equals the Anime entry's `episodeCount` (e.g. Demon Slayer
/// S2 "Entertainment District Arc" has no "Season 2" in any
/// title, but 11 episodes = saison2's 11);
/// (3) saison 1. Films (`film<n>`) are candidates only when
/// the title says movie/film or `episodeCount == 1`.
///
/// Caveat (verified live 2026-11-25): the Vidmoly CDN edge
/// that serves Demon Slayer (`prx-1476-ant.vmpx.online`)
/// returns 403 for SEGMENT fetches from this VM while its
/// master + variant playlists serve 200 — and the Jujutsu
/// Kaisen edge (`prx-1351-ant-20.vmget.online`) serves
/// segments fine (200, ffprobe-verified). So the chain is
/// proven, but per-title edge gating from a datacenter IP is
/// real; the phone (residential IP) is the proof for any title
/// whose edge 403s the VM. The resolver returns the signed
/// master URL either way and never claims a segment it did
/// not fetch.
class AnimeSamaResolver {
  AnimeSamaResolver({
    http.Client? client,
    AniListService? anilist,
    String? baseUrl,
  })  : _client = client ?? http.Client(),
        _anilist = anilist ?? AniListService(),
        _base = (baseUrl ?? _defaultBase).replaceAll(RegExp(r'/$'), '');

  final http.Client _client;
  final AniListService _anilist;

  /// Bundled fallback — the live-verified domain. The remote
  /// provider config (`animesama` mirrors) overrides this.
  static const String _defaultBase = 'https://anime-sama.to';

  /// The base URL this resolver is actually using (config
  /// override or the bundled fallback).
  String get baseUrl => _base;
  final String _base;

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  String? lastError;

  /// Resolve a playable stream for [anime] episode [episodeNumber].
  /// [subDub] is 'Sub' (VOSTFR) or 'Dub' (VF). Returns null when
  /// nothing resolved.
  Future<ResolvedStream?> resolve({
    required Anime anime,
    required int episodeNumber,
    required String subDub,
  }) async {
    lastError = null;
    try {
      final bool wantsDub = subDub == 'Dub';
      final String lang = wantsDub ? 'vf' : 'vostfr';
      final String? seriesUrl = await _searchSeriesUrl(anime);
      if (seriesUrl == null) {
        lastError = 'Could not find "${anime.title}" on Anime-Sama.';
        return null;
      }
      final List<AnimeSamaSeason> seasons =
          await _seasons(seriesUrl, lang);
      if (seasons.isEmpty) {
        lastError = 'Anime-Sama has no $lang seasons for "${anime.title}".';
        return null;
      }
      final AnimeSamaSeason? season =
          await _pickSeason(seriesUrl, seasons, anime);
      if (season == null) {
        lastError = 'Anime-Sama has no season for "${anime.title}".';
        return null;
      }
      final String seasonUrl = '$seriesUrl${season.path}/';
      final AnimeSamaSeasonPage? page = await _seasonPage(seasonUrl);
      if (page == null) {
        lastError = 'Anime-Sama could not open "${anime.title}".';
        return null;
      }
      if (!page.languages.contains(lang)) {
        lastError = 'Anime-Sama has no ${wantsDub ? 'Dub' : 'Sub'} '
            'for "${anime.title}".';
        return null;
      }
      if (episodeNumber < 1 || episodeNumber > page.episodeCount) {
        lastError = 'Anime-Sama has no episode $episodeNumber '
            'for "${anime.title}".';
        return null;
      }
      // Lecteurs in site order (eps1 first — Vidmoly on every
      // title checked so far). Each lecteur is one host; try
      // them in order and take the first that yields a stream.
      for (int k = 0; k < page.lecteurs.length; k++) {
        final List<String> links = page.lecteurs[k];
        if (episodeNumber > links.length) continue;
        final String repere = links[episodeNumber - 1];
        if (!repere.startsWith('lien:')) continue;
        final String linkId = repere.substring(5);
        try {
          final String? embedUrl = await _resolveLien(
            seasonUrl,
            page.jeton,
            linkId,
          );
          if (embedUrl == null) continue;
          final ResolvedStream? stream = await _streamFromEmbed(
            embedUrl: embedUrl,
            seasonUrl: seasonUrl,
          );
          if (stream != null) return stream;
        } catch (_) {
          continue;
        }
      }
      lastError = 'Anime-Sama could not play episode $episodeNumber — '
          'no working lecteur.';
      return null;
    } catch (e) {
      lastError ??= 'Anime-Sama failed: $e';
      return null;
    }
  }

  // ------------------------------------------------------------ search

  /// Search each title variant (AniList romaji / english / native,
  /// then the catalogue title) and return the best-matching series
  /// URL. The site's own search is already fuzzy-ranked, so the
  /// match is: exact normalized title -> contains either way ->
  /// first hit.
  Future<String?> _searchSeriesUrl(Anime anime) async {
    final List<String> queries = <String>[];
    try {
      final int? anilistId =
          anime.anilistId ??
          (await _anilist.resolveIdDetailed(anime.title)).id;
      final AnilistIdentity? identity = anilistId == null
          ? null
          : await _anilist.mediaIdentity(anilistId);
      for (final String t in <String>[
        ...?identity?.titles,
        anime.title,
      ]) {
        if (t.trim().isNotEmpty && !queries.contains(t)) queries.add(t);
      }
    } catch (_) {
      if (queries.isEmpty) queries.add(anime.title);
    }
    for (final String q in queries) {
      final String? url = await _searchOnce(q);
      if (url != null) return url;
    }
    return null;
  }

  Future<String?> _searchOnce(String query) async {
    try {
      final http.Response resp = await _client
          .post(
            Uri.parse('$_base/template-php/defaut/fetch.php'),
            headers: <String, String>{
              'User-Agent': _ua,
              'Accept': 'text/html, */*; q=0.01',
              'Referer': '$_base/',
            },
            body: <String, String>{'query': query.trim()},
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final List<AnimeSamaHit> hits = parseSearchResults(resp.body);
      if (hits.isEmpty) return null;
      final String normQ = normalizeTitle(_stripParens(query));
      String? pick(bool Function(AnimeSamaHit) test) =>
          hits.where(test).map((AnimeSamaHit h) => h.href).firstOrNull;
      return pick(
            (AnimeSamaHit h) =>
                normalizeTitle(_stripParens(h.title)) == normQ,
          ) ??
          pick((AnimeSamaHit h) {
            final String n = normalizeTitle(_stripParens(h.title));
            return n.contains(normQ) || normQ.contains(n);
          }) ??
          hits.first.href;
    } catch (_) {
      return null;
    }
  }

  /// Parse the fetch.php search response. Pure — unit-tested
  /// against the recorded response. Results are
  /// `a.asn-search-result[href]` with the title in the inner
  /// `h3` (the search term itself is wrapped in `<mark>`).
  static List<AnimeSamaHit> parseSearchResults(String html) {
    final dom.Document doc = html_parser.parse(html);
    final List<AnimeSamaHit> out = <AnimeSamaHit>[];
    for (final dom.Element a
        in doc.querySelectorAll('a.asn-search-result[href]')) {
      final String href = a.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      final String title = a.querySelector('h3')?.text.trim() ?? '';
      if (title.isEmpty) continue;
      out.add(AnimeSamaHit(title: title, href: href));
    }
    return out;
  }

  static String _stripParens(String s) =>
      s.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

  // ------------------------------------------------------------ series

  /// The seasons (and films) of a series, from the inline
  /// `panneauAnime("Name", "path")` calls on the series page.
  /// [lang] is 'vostfr' or 'vf' — the calls always carry the
  /// vostfr path, so it is swapped when Dub was asked for.
  Future<List<AnimeSamaSeason>> _seasons(
    String seriesUrl,
    String lang,
  ) async {
    try {
      final http.Response resp = await _client
          .get(Uri.parse(seriesUrl), headers: _pageHeaders('$_base/'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <AnimeSamaSeason>[];
      return parseSeasons(resp.body, lang);
    } catch (_) {
      return <AnimeSamaSeason>[];
    }
  }

  /// Parse the series page's `panneauAnime("Name", "path")`
  /// calls. Pure — unit-tested against the recorded page.
  /// The first two calls in the page source are the commented
  /// examples (`panneauAnime("nom", "saison1/vostfr")` and
  /// `panneauAnime("nom", "url")`) — they are skipped.
  static List<AnimeSamaSeason> parseSeasons(String html, String lang) {
    final RegExp re =
        RegExp(r'panneauAnime\("([^"]+)",\s*"([^"]+)"\)');
    final List<AnimeSamaSeason> out = <AnimeSamaSeason>[];
    for (final RegExpMatch m in re.allMatches(html)) {
      final String name = m.group(1)!.trim();
      final String path = m.group(2)!.trim();
      if (name == 'nom') continue;
      if (!path.startsWith('saison') && !path.startsWith('film')) {
        continue;
      }
      final String langPath =
          lang == 'vf' ? path.replaceAll('vostfr', 'vf') : path;
      final int number = _seasonNumber(name, path);
      out.add(
        AnimeSamaSeason(name: name, path: langPath, number: number),
      );
    }
    return out;
  }

  /// Season number for matching: `saison2` -> 2, `film1` ->
  /// 1001 (films sort after every season and only match by
  /// episode count, never by a "Season N" title). A bare `film`
  /// path (no number, e.g. JJK's `film/vostfr`) is film 1.
  /// `saison1hs` (hors-série / special) counts as season 1.
  static int _seasonNumber(String name, String path) {
    final RegExpMatch? m = RegExp(r'^saison(\d+)').firstMatch(path);
    if (m != null) return int.parse(m.group(1)!);
    final RegExpMatch? f = RegExp(r'^film(\d*)').firstMatch(path);
    if (f != null) {
      final String n = f.group(1) ?? '';
      return 1000 + (n.isEmpty ? 1 : int.parse(n));
    }
    final RegExpMatch? n = RegExp(r'(\d+)').firstMatch(name);
    return n == null ? 0 : int.parse(n.group(1)!);
  }

  /// Pick the saison for [anime]: (1) season number parsed
  /// from any title variant ("Season 2" / "Saison 2" / "Part 2");
  /// (2) episode-count match against each saison's page
  /// (`eps1` length == `anime.episodeCount`); (3) the first
  /// saison. Films are only candidates when the title says
  /// movie/film or the entry has a single episode.
  Future<AnimeSamaSeason?> _pickSeason(
    String seriesUrl,
    List<AnimeSamaSeason> seasons,
    Anime anime,
  ) async {
    final bool movieish = anime.episodeCount == 1 ||
        RegExp(r'\bmovie\b|\bfilm\b', caseSensitive: false)
            .hasMatch(anime.title);
    final List<AnimeSamaSeason> candidates = seasons
        .where(
          (AnimeSamaSeason s) =>
              s.number < 1000 || movieish,
        )
        .toList();
    if (candidates.isEmpty) return null;

    // (1) Season number from the title variants.
    final List<String> titles = <String>[anime.title];
    try {
      final int? anilistId =
          anime.anilistId ??
          (await _anilist.resolveIdDetailed(anime.title)).id;
      final AnilistIdentity? identity = anilistId == null
          ? null
          : await _anilist.mediaIdentity(anilistId);
      if (identity != null) {
        for (final String t in identity.titles) {
          if (!titles.contains(t)) titles.add(t);
        }
      }
    } catch (_) {
      // Title variants are a best-effort hint; fall through.
    }
    for (final String t in titles) {
      final RegExpMatch? m = RegExp(
        r'(?:season|saison|part|cour)\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(t);
      if (m == null) continue;
      final int want = int.parse(m.group(1)!);
      for (final AnimeSamaSeason s in candidates) {
        if (s.number == want) return s;
      }
    }

    // (2) Episode-count match — one season-page fetch per
    // candidate, stopping at the first match. Bounded: the
    // site rarely lists more than a handful of saisons.
    if (anime.episodeCount > 0) {
      for (final AnimeSamaSeason s in candidates.take(6)) {
        try {
          final AnimeSamaSeasonPage? page =
              await _seasonPage('$seriesUrl${s.path}/');
          if (page != null && page.episodeCount == anime.episodeCount) {
            return s;
          }
        } catch (_) {
          continue;
        }
      }
    }

    // (3) First saison (or first film for a movie entry).
    return candidates.first;
  }

  // ------------------------------------------------------------ season

  Future<AnimeSamaSeasonPage?> _seasonPage(String seasonUrl) async {
    try {
      final http.Response resp = await _client
          .get(Uri.parse(seasonUrl), headers: _pageHeaders(seasonUrl))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      return parseSeasonPage(resp.body);
    } catch (_) {
      return null;
    }
  }

  /// Parse a season page: the `eps<n>` lecteur arrays, the
  /// per-page `epsJeton`, and `languesDispo`. Pure — unit-tested
  /// against the recorded pages (JJK S1 VOSTFR + VF, Demon
  /// Slayer S1 VOSTFR).
  static AnimeSamaSeasonPage? parseSeasonPage(String html) {
    final RegExpMatch? jetonMatch =
        RegExp(r'var epsJeton = "([^"]+)"').firstMatch(html);
    if (jetonMatch == null) return null;
    final String jeton = jetonMatch.group(1)!;
    final RegExpMatch? langMatch =
        RegExp(r'var languesDispo = \[([^\]]*)\]').firstMatch(html);
    final List<String> languages = langMatch == null
        ? <String>[]
        : RegExp(r'"([^"]+)"')
            .allMatches(langMatch.group(1)!)
            .map((RegExpMatch m) => m.group(1)!)
            .toList();
    final List<List<String>> lecteurs = <List<String>>[];
    for (int k = 1; k <= 8; k++) {
      final RegExpMatch? m = RegExp(
        'var eps$k = \\[(.*?)\\];',
        dotAll: true,
      ).firstMatch(html);
      if (m == null) break;
      lecteurs.add(
        RegExp(r'"([^"]*)"')
            .allMatches(m.group(1)!)
            .map((RegExpMatch e) => e.group(1)!)
            .toList(),
      );
    }
    if (lecteurs.isEmpty) return null;
    return AnimeSamaSeasonPage(
      jeton: jeton,
      languages: languages,
      lecteurs: lecteurs,
    );
  }

  // ------------------------------------------------------------ lien

  /// `GET /api/lien.php?j=<jeton>&l=<id>` -> `{"u": "<embed>"}`.
  /// The jeton is per season page and expires after ~24h, so it
  /// is always taken from the page fetched in this same resolve
  /// (never cached across resolves).
  Future<String?> _resolveLien(
    String referer,
    String jeton,
    String linkId,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_base/api/lien.php?j=${Uri.encodeComponent(jeton)}'
              '&l=${Uri.encodeComponent(linkId)}',
            ),
            headers: _pageHeaders(referer),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final String? url = json['u'] as String?;
      return url?.trim().isEmpty == true ? null : url?.trim();
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ embed

  /// Turn an embed URL into a playable stream. v1 handles ONLY
  /// Vidmoly (ansembed.net / vidmoly.*): a plain
  /// `sources: [{ file: '…master.m3u8' }]` in the embed page.
  /// Uqload (packed eval), VOE (rotating-mirror JS challenge)
  /// and Earnvids are NOT decoded — returns null for them so
  /// the lecteur loop tries the next host instead of faking a
  /// stream. The master playlist is fetched once to expand the
  /// quality variants (1080p/480p).
  Future<ResolvedStream?> _streamFromEmbed({
    required String embedUrl,
    required String seasonUrl,
  }) async {
    final Uri? uri = Uri.tryParse(embedUrl);
    if (uri == null) return null;
    final String host = uri.host.toLowerCase();
    final bool isVidmoly = host == 'ansembed.net' ||
        host.endsWith('.ansembed.net') ||
        host.contains('vidmoly.');
    if (!isVidmoly) return null;
    try {
      final http.Response resp = await _client
          .get(Uri.parse(embedUrl), headers: _pageHeaders(seasonUrl))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final String? master = extractVidmolyFile(resp.body);
      if (master == null) return null;
      final List<StreamVariant> variants = await _variants(master);
      final String best = variants.isNotEmpty
          ? variants.first.url
          : master;
      final String bestLabel = variants.isNotEmpty
          ? variants.first.qualityLabel
          : '1080p';
      return ResolvedStream(
        url: best,
        label: 'Anime-Sama Vidmoly $bestLabel',
        source: 'Anime-Sama',
        // The signed HLS also answers with no Referer at all
        // (verified live), but the embed Referer + browser UA
        // are sent anyway — same belt-and-braces as Miruro.
        headers: <String, String>{
          'User-Agent': _ua,
          'Referer': embedUrl,
        },
        variants: variants,
      );
    } catch (_) {
      return null;
    }
  }

  /// The Vidmoly file URL from an embed page. Pure —
  /// unit-tested against the recorded embed pages.
  /// `sources: [{ file: 'https://…/master.m3u8?…' }]`.
  static String? extractVidmolyFile(String html) {
    final RegExpMatch? m = RegExp(
      r"""sources:\s*\[\{\s*file:\s*'([^']+)'""",
    ).firstMatch(html);
    if (m != null) return m.group(1);
    final RegExpMatch? d = RegExp(
      r'''sources:\s*\[\{\s*file:\s*"([^"]+)"''',
    ).firstMatch(html);
    return d?.group(1);
  }

  /// Expand a master playlist into quality variants. Pure
  /// parsing except for the single master fetch — the variants
  /// are the `#EXT-X-STREAM-INF` lines (RESOLUTION + the URL
  /// on the next line), best quality first.
  Future<List<StreamVariant>> _variants(String masterUrl) async {
    try {
      final http.Response resp = await _client
          .get(Uri.parse(masterUrl), headers: _pageHeaders(null))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <StreamVariant>[];
      return parseMasterVariants(resp.body);
    } catch (_) {
      return <StreamVariant>[];
    }
  }

  /// Parse `#EXT-X-STREAM-INF` variants from a master playlist.
  /// Pure — unit-tested against the recorded masters.
  static List<StreamVariant> parseMasterVariants(String m3u8) {
    final List<String> lines = m3u8.split('\n');
    final List<StreamVariant> out = <StreamVariant>[];
    for (int i = 0; i + 1 < lines.length; i++) {
      final String line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final RegExpMatch? res =
          RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
      if (res == null) continue;
      final String url = lines[i + 1].trim();
      if (url.isEmpty || url.startsWith('#')) continue;
      out.add(
        StreamVariant(url: url, qualityLabel: '${res.group(2)}p'),
      );
    }
    return out;
  }

  Map<String, String> _pageHeaders(String? referer) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': _ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    };
    if (referer != null) headers['Referer'] = referer;
    return headers;
  }
}

class AnimeSamaHit {
  const AnimeSamaHit({required this.title, required this.href});

  final String title;
  final String href;
}

class AnimeSamaSeason {
  const AnimeSamaSeason({
    required this.name,
    required this.path,
    required this.number,
  });

  /// Display name, e.g. "Saison 1" / "Film - Train de l'infini".
  final String name;

  /// Relative path from the series page, e.g.
  /// "saison1/vostfr" (already swapped to "vf" for Dub).
  final String path;

  /// Season number (saison2 -> 2); films are 1000 + n.
  final int number;
}

class AnimeSamaSeasonPage {
  const AnimeSamaSeasonPage({
    required this.jeton,
    required this.languages,
    required this.lecteurs,
  });

  /// Per-page token for /api/lien.php (expires ~24h).
  final String jeton;

  /// e.g. ["vostfr", "vf"] from `languesDispo`.
  final List<String> languages;

  /// One list per lecteur (eps1, eps2, …), each entry a
  /// "lien:{id}" (or "" when that lecteur lacks the episode).
  final List<List<String>> lecteurs;

  /// Episode count = length of the first lecteur's list.
  int get episodeCount => lecteurs.isEmpty ? 0 : lecteurs.first.length;
}
