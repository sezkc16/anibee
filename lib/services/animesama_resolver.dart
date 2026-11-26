import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// Anime-Sama (anime-sama.to) — real on-device resolver (0.2.25,
/// Uqload + preflight in 0.2.26).
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
/// v2 extracts TWO hosts:
/// - Vidmoly: its embed page carries a plain
///   `sources: [{ file: '…/master.m3u8?…' }]` (signed HLS, 1080p
///   + 480p variants, H.264 + AAC — verified end-to-end with
///   ffprobe on Jujutsu Kaisen S1 EP1: real 852×480 H.264 + AAC
///   segment).
/// - Uqload (0.2.26): its embed page hides the URL in a
///   Dean-Edwards-packed `eval(...)` block — unpacked in Dart
///   ([extractUqloadFile]) to the same signed-HLS shape
///   (1080p/720p/360p, verified end-to-end with ffprobe on JJK
///   S1 EP1 and Demon Slayer S1 EP1: real 1920×1080 H.264 + AAC
///   segments from `strm15`/`strm7.uqload.vc`).
/// VOE (rotating-mirror JS challenge) and Earnvids are still
/// NOT decoded; the lecteur loop skips hosts it cannot extract
/// instead of faking a stream.
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
/// Why the preflight (0.2.26): the Vidmoly CDN edges gate
/// per-IP, and the gate is per title. Verified live 2026-11-25:
/// Demon Slayer's edge (`prx-1476-ant.vmpx.online`) returns
/// 403 for SEGMENT fetches from this VM while its master +
/// variant playlists serve 200 — and its Dub edge
/// (`prx-1353-ant-23.vmpx.online`) 403s even the master.
/// Jujutsu Kaisen's edge (`prx-1351-ant-20.vmget.online`)
/// serves segments fine from the VM (200, ffprobe-verified,
/// and the VM's mpv plays the URL) — yet the user's phone
/// (VPN on, 2026-11-25 01:10 recording) resolved JJK S1 EP1
/// Sub, opened the player, and got "Couldn't load episode".
/// Edge hosts are STABLE per title (4+ re-resolves of JJK
/// Sub all returned prx-1351), so re-resolving cannot help,
/// and the player path is clean (headers reach mpv — verified
/// in code; VM mpv plays the URL). The only explanation that
/// fits every datapoint is the edge gating the phone's
/// network/IP (the VPN exit IP, same class of IP the VM has).
/// So the resolver now PREFLIGHTS every candidate stream:
/// it fetches the first segment from THIS device before
/// returning the stream, and if the edge refuses it, tries
/// the next lecteur (a different CDN — Uqload) instead of
/// opening a player that cannot load. When every lecteur
/// fails, resolve returns null with an honest error naming
/// the network block, instead of a player that opens and
/// fails. The phone test is still the proof for any title —
/// a preflight that passes on the VM does not prove the
/// phone's network, and vice versa.
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
      // them in order and take the first that yields a stream
      // whose first segment ACTUALLY fetches from this device
      // (0.2.26 preflight — see [_preflight]). A lecteur whose
      // host is not extractable (VOE / Earnvids / dead mirrors)
      // is skipped without a network call.
      for (int k = 0; k < page.lecteurs.length; k++) {
        final List<String> links = page.lecteurs[k];
        if (episodeNumber > links.length) continue;
        final String repere = links[episodeNumber - 1];
        if (!repere.startsWith('lien:')) continue;
        final String linkId = repere.substring(5);
        final String host = page.hosts[linkId] ?? '';
        if (host.isNotEmpty && !_isExtractableHost(host)) continue;
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
          if (stream == null) continue;
          // The URL looks fine but the edge may still refuse
          // THIS device (per-IP gating — the 0.2.25 phone
          // failure). Prove the first segment fetches before
          // handing the stream to mpv; on refusal try the next
          // lecteur (a different CDN) instead of opening a
          // player that cannot load.
          if (await _preflight(stream)) return stream;
        } catch (_) {
          continue;
        }
      }
      lastError = 'Anime-Sama could not play episode $episodeNumber — '
          'the video host is blocked on this network. '
          'Try turning your VPN off, or pick another server.';
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

    // (1) Season number: the selected season's chain position
    // (0.2.30 — AniList titles carry no season number, so parsing
    // the title could never find it; the old title parse stays as
    // a fallback for entries that never carried a number).
    int? want = anime.seasonNumber;
    if (want == null) {
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
        want = int.parse(m.group(1)!);
        break;
      }
    }
    if (want != null) {
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
  /// per-page `epsJeton`, `languesDispo`, and the `epsMeta`
  /// host map (link id -> host, e.g. "4658" -> "ansembed.net").
  /// Pure — unit-tested against the recorded pages (JJK S1
  /// VOSTFR + VF, Demon Slayer S1 VOSTFR).
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
    final Map<String, String> hosts = <String, String>{};
    final RegExpMatch? metaMatch = RegExp(
      r'var epsMeta = \{(.*?)\};',
      dotAll: true,
    ).firstMatch(html);
    if (metaMatch != null) {
      for (final RegExpMatch m in RegExp(
        r'"(\d+)":\["([^"]+)"',
      ).allMatches(metaMatch.group(1)!)) {
        hosts[m.group(1)!] = m.group(2)!;
      }
    }
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
      hosts: hosts,
    );
  }

  /// Hosts this resolver can extract a stream from: Vidmoly
  /// (ansembed.net / vidmoly.*) and Uqload (uqload.vc). VOE,
  /// Earnvids and the dead mirrors are skipped — no verified
  /// extraction path exists for them.
  static bool _isExtractableHost(String host) {
    final String h = host.toLowerCase();
    return h == 'ansembed.net' ||
        h.endsWith('.ansembed.net') ||
        h.contains('vidmoly.') ||
        h == 'uqload.vc' ||
        h.endsWith('.uqload.vc');
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

  /// Turn an embed URL into a playable stream. Handles TWO
  /// hosts (0.2.26): Vidmoly (ansembed.net / vidmoly.* — a
  /// plain `sources: [{ file: '…master.m3u8' }]` in the embed
  /// page) and Uqload (uqload.vc — the file URL hides in a
  /// Dean-Edwards-packed `eval(...)` block, unpacked by
  /// [extractUqloadFile]). Anything else returns null so the
  /// lecteur loop tries the next host instead of faking a
  /// stream. The master playlist is fetched once to expand the
  /// quality variants (best first).
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
    final bool isUqload =
        host == 'uqload.vc' || host.endsWith('.uqload.vc');
    if (!isVidmoly && !isUqload) return null;
    try {
      final http.Response resp = await _client
          .get(Uri.parse(embedUrl), headers: _pageHeaders(seasonUrl))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final String? master = isVidmoly
          ? extractVidmolyFile(resp.body)
          : extractUqloadFile(resp.body);
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
        label: 'Anime-Sama ${isVidmoly ? 'Vidmoly' : 'Uqload'} $bestLabel',
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

  /// Prove a candidate stream actually plays on THIS device
  /// before handing it to mpv (0.2.26 — the 0.2.25 phone
  /// failure: Vidmoly's edge gates per-IP, so a signed URL
  /// that serves the VM can still refuse the phone).
  /// Fetches the best variant's media playlist, then the first
  /// segment with a 1 KiB Range (a 200/206 proves the edge
  /// serves this device; a 403/timeout proves it does not).
  /// Returns false on ANY failure — the lecteur loop then
  /// tries the next host (a different CDN) instead of opening
  /// a player that cannot load.
  Future<bool> _preflight(ResolvedStream stream) async {
    try {
      final http.Response pl = await _client
          .get(Uri.parse(stream.url), headers: stream.headers)
          .timeout(const Duration(seconds: 10));
      if (pl.statusCode != 200) return false;
      String? segUrl;
      if (pl.body.contains('#EXT-X-STREAM-INF')) {
        // Urlset master (variants failed to expand): take the
        // best variant, then its first segment.
        final List<StreamVariant> vs = parseMasterVariants(pl.body);
        if (vs.isEmpty) return false;
        final http.Response vp = await _client
            .get(Uri.parse(vs.first.url), headers: stream.headers)
            .timeout(const Duration(seconds: 10));
        if (vp.statusCode != 200) return false;
        segUrl = _firstMediaUri(vp.body, vs.first.url);
      } else {
        segUrl = _firstMediaUri(pl.body, stream.url);
      }
      if (segUrl == null || segUrl.isEmpty) return false;
      final http.Response seg = await _client
          .get(
            Uri.parse(segUrl),
            headers: <String, String>{
              ...stream.headers,
              'Range': 'bytes=0-1023',
            },
          )
          .timeout(const Duration(seconds: 10));
      return seg.statusCode == 200 || seg.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// First non-directive line of a media playlist, resolved
  /// against the playlist URL. Pure — unit-tested.
  static String? _firstMediaUri(String m3u8, String base) {
    for (final String line in m3u8.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      if (t.startsWith('http')) return t;
      return Uri.parse(base).resolve(t).toString();
    }
    return null;
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

  /// The Uqload file URL from an embed page (0.2.26). Pure —
  /// unit-tested against the recorded embed pages (JJK + DS).
  /// Uqload hides the jwplayer setup in a Dean-Edwards-packed
  /// `eval(function(p,a,c,k,e,d){…}('…',36,N,'…'.split('|'),0,{}))`
  /// block; unpack it, then read the same
  /// `sources:[{file:"…master.m3u8…"}]` shape as Vidmoly.
  /// A page can carry OTHER packed blocks (ad scripts — the
  /// Vidmoly pages do, one with radix 61); every match is
  /// tried in order and the first one that unpacks to a file
  /// URL wins, the rest are skipped. Returns null when no
  /// block yields a file URL.
  static String? extractUqloadFile(String html) {
    // The decoder call is `}('…',36,N,'…'.split('|'))` — some
    // packer variants append `,0,{}` after the split, some do
    // not; the pattern stops after the split so both match.
    final RegExp packedRe = RegExp(
      r"""eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)""",
      dotAll: true,
    );
    for (final RegExpMatch m in packedRe.allMatches(html)) {
      final int radix = int.tryParse(m.group(2)!) ?? 0;
      final int count = int.tryParse(m.group(3)!) ?? 0;
      if (radix < 2 || radix > 62 || count <= 0) continue;
      late final String unpacked;
      try {
        unpacked = unpackPackedEval(
          _decodeJsString(m.group(1)!),
          radix,
          count,
          m.group(4)!.split('|'),
        );
      } catch (_) {
        continue;
      }
      final RegExpMatch? f = RegExp(
        r'''sources:\s*\[\{\s*file:\s*"([^"]+)"''',
      ).firstMatch(unpacked);
      if (f != null) return f.group(1);
      final RegExpMatch? s = RegExp(
        r"""sources:\s*\[\{\s*file:\s*'([^']+)'""",
      ).firstMatch(unpacked);
      if (s != null) return s.group(1);
    }
    return null;
  }

  /// Dean-Edwards packer unpack (the `eval(function(p,a,c,k,e,d)
  /// {...})` shape Uqload uses). Replaces each base-[radix]
  /// token (word-boundary match) in [packed] with
  /// `keywords[i]`, highest index first — the same algorithm
  /// the packer's own decoder runs. Radix 2..36 uses
  /// `toRadixString`; 37..62 uses the packer's `0-9a-zA-Z`
  /// alphabet (some packer variants encode past base 36).
  /// Pure — unit-tested with a synthetic packed block.
  static String unpackPackedEval(
    String packed,
    int radix,
    int count,
    List<String> keywords,
  ) {
    if (radix < 2 || radix > 62) {
      throw ArgumentError.value(radix, 'radix', 'must be 2..62');
    }
    const String digits =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    String encode(int value) {
      if (radix <= 36) return value.toRadixString(radix);
      if (value == 0) return '0';
      String out = '';
      int v = value;
      while (v > 0) {
        out = digits[v % radix] + out;
        v ~/= radix;
      }
      return out;
    }

    String out = packed;
    for (int i = count - 1; i >= 0; i--) {
      if (i >= keywords.length || keywords[i].isEmpty) continue;
      final String token = encode(i);
      // replaceAllMapped (not replaceAll): a keyword can
      // contain '$', which replaceAll would read as a group
      // reference.
      final String keyword = keywords[i];
      out = out.replaceAllMapped(
        RegExp('\\b$token\\b'),
        (_) => keyword,
      );
    }
    return out;
  }

  /// Decode the escapes of a JS single-quoted string literal
  /// (`\'`, `\\`, `\n`, `\xHH`, `\uHHHH`, …). Only what the
  /// packed payload uses; unknown escapes keep their char.
  static String _decodeJsString(String s) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final String c = s[i];
      if (c != '\\' || i + 1 >= s.length) {
        out.write(c);
        continue;
      }
      final String n = s[i + 1];
      switch (n) {
        case 'n':
          out.write('\n');
          i++;
        case 'r':
          out.write('\r');
          i++;
        case 't':
          out.write('\t');
          i++;
        case 'b':
          out.write('\b');
          i++;
        case 'f':
          out.write('\f');
          i++;
        case 'v':
          out.write('\v');
          i++;
        case '0':
          out.write(String.fromCharCode(0));
          i++;
        case 'x':
          if (i + 3 < s.length) {
            final int? v = int.tryParse(s.substring(i + 2, i + 4), radix: 16);
            if (v != null) {
              out.write(String.fromCharCode(v));
              i += 3;
              break;
            }
          }
          out.write(n);
          i++;
        case 'u':
          if (i + 5 < s.length) {
            final int? v = int.tryParse(s.substring(i + 2, i + 6), radix: 16);
            if (v != null) {
              out.write(String.fromCharCode(v));
              i += 5;
              break;
            }
          }
          out.write(n);
          i++;
        default:
          // \' \" \\ \/ and anything else: the char itself.
          out.write(n);
          i++;
      }
    }
    return out.toString();
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
  /// Pure — unit-tested against the recorded masters. Sorted
  /// best-first by height: Vidmoly lists 1080p first, but
  /// Uqload lists 360p first — the caller takes `first` as the
  /// best URL, so the sort must not depend on the CDN's order.
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
    out.sort((StreamVariant a, StreamVariant b) {
      final int ha =
          int.tryParse(a.qualityLabel.replaceAll('p', '')) ?? 0;
      final int hb =
          int.tryParse(b.qualityLabel.replaceAll('p', '')) ?? 0;
      return hb.compareTo(ha);
    });
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
    this.hosts = const <String, String>{},
  });

  /// Per-page token for /api/lien.php (expires ~24h).
  final String jeton;

  /// e.g. ["vostfr", "vf"] from `languesDispo`.
  final List<String> languages;

  /// One list per lecteur (eps1, eps2, …), each entry a
  /// "lien:{id}" (or "" when that lecteur lacks the episode).
  final List<List<String>> lecteurs;

  /// Host per link id from `epsMeta`, e.g. "4658" ->
  /// "ansembed.net", "4657" -> "uqload.vc". Empty when the
  /// page carries no epsMeta — then every lecteur is tried.
  final Map<String, String> hosts;

  /// Episode count = length of the first lecteur's list.
  int get episodeCount => lecteurs.isEmpty ? 0 : lecteurs.first.length;
}
