import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// AnimeKai (animekai.ro) — real on-device resolver (0.2.23).
///
/// Chain: AniList id -> title variants -> `GET /ajax/anime/search`
/// (JSON `{status, result:{html}}` — classic AnimeKai suggestion
/// list, 5 hits) -> title/year/format match -> `GET /anime/<slug>`
/// (the anime id from `data-id="…" data-fetch="true"`) ->
/// `GET /ajax/episode/list/<ani_id>` (`data-num` / `data-ids`
/// tokens) -> `GET /ajax/server/list?servers=<token>` (Sub/Dub
/// server buttons, `data-link-id` tokens) ->
/// `GET /ajax/server?get=<token>` (embed URL) -> megavid embed
/// (`#player-payload` JSON -> `/mal/<id>/<ep>/<sub|dub>/source`)
/// -> signed HLS master URL + English subtitle tracks.
///
/// Search notes (live, 2026-11-24): the site appends "(TV)" to
/// some display titles ("Jujutsu Kaisen (TV)") — the matcher
/// strips parenthetical qualifiers before comparing, or an exact
/// match scores 0.667 and is rejected. The suggestion endpoint
/// caps at 5 hits and big franchises crowd out their own base
/// series (plain "Demon Slayer: Kimetsu no Yaiba" never appears
/// for any "demon slayer" query) — when suggestions yield no
/// confident match, the resolver falls back to the full filter
/// page (`GET /filter?keyword=…`, the site's own search form
/// target), which does list the base series (page 1, type but
/// no year in its info block).
///
/// The ORIGINAL AnimeKai shut down May 10, 2026 (animekai.to is a
/// parking page) — animekai.ro is a different domain, a revival /
/// clone running the same Anikai front end. Verified live from the
/// VM 2026-11-24 (Solo Leveling EP1 sub): every step above returns
/// real data through the megavid source API (signed
/// `s-*.megavid.se/uwu/…/master.txt` + English track + chapters).
/// The media host itself (s-90.megavid.se) drops the VM's
/// connections (empty reply — the same anti-datacenter pattern as
/// ReAnime's VM 410), so the final playlist fetch is NOT proven
/// from the VM; the phone (residential IP) is the verdict. The
/// resolver never returns a fake URL: every failure sets
/// [lastError] and returns null.
///
/// Only the megavid embed host is extracted — other servers'
/// embeds are skipped (never guessed). The megavid stream goes
/// through the Cast relay (`megavid.se` is gated, Referer
/// `https://megavid.buzz/`) because the default receiver cannot
/// send a Referer.
class AnimeKaiResolver {
  AnimeKaiResolver({
    http.Client? client,
    AniListService? anilist,
    MiruroResolver? megaplay,
  })  : _client = client ?? http.Client(),
        _anilist = anilist ?? AniListService(),
        _megaplay = megaplay ?? MiruroResolver(client: client);

  final http.Client _client;
  final AniListService _anilist;

  /// Owns the megaplay embed chain (getSources -> AES decrypt ->
  /// signed master). Shares the caller's [http.Client] when one is
  /// injected (tests), so mock clients see its requests too.
  final MiruroResolver _megaplay;

  static const String _base = 'https://animekai.ro';
  static const String _megavidHost = 'megavid.buzz';
  static const String _megaplayHost = 'megaplay.buzz';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Confidence floor for the series match (same bar as AniZone).
  static const double kMinScore = 0.68;

  String? lastError;

  /// Resolve a playable stream for [anime] episode [episodeNumber].
  /// [subDub] is 'Sub' or 'Dub'. Returns null when nothing resolved.
  Future<ResolvedStream?> resolve({
    required Anime anime,
    required int episodeNumber,
    required String subDub,
  }) async {
    lastError = null;
    final int? anilistId;
    if (anime.anilistId != null) {
      anilistId = anime.anilistId;
    } else {
      final ({int? id, bool lookupFailed}) detail =
          await _anilist.resolveIdDetailed(anime.title);
      if (detail.lookupFailed) {
        lastError = 'AniList lookup failed — check your connection '
            'and try again.';
        return null;
      }
      anilistId = detail.id;
    }
    if (anilistId == null) {
      lastError = 'Could not find "${anime.title}" on AniList.';
      return null;
    }
    try {
      final AnilistIdentity? identity =
          await _anilist.mediaIdentity(anilistId);
      final List<String> titles = <String>[
        ...?identity?.titles,
        anime.title,
      ];
      final AnimeKaiCandidate? match = await _matchSeries(
        titles: titles,
        year: identity?.year ?? (anime.year > 0 ? anime.year : null),
        format: identity?.format,
      );
      if (match == null) return null;
      final int? aniId = await _animeId(match.slug);
      if (aniId == null) {
        lastError = 'AnimeKai could not open "${match.title}".';
        return null;
      }
      final List<AnimeKaiEpisode> episodes = await _episodeList(aniId);
      final AnimeKaiEpisode? episode = episodes
          .where((AnimeKaiEpisode e) => e.number == episodeNumber)
          .firstOrNull;
      if (episode == null) {
        lastError =
            'AnimeKai has no episode $episodeNumber for "${anime.title}".';
        return null;
      }
      final bool wantsDub = subDub == 'Dub';
      if (wantsDub && !episode.hasDub) {
        lastError = 'AnimeKai has no Dub for episode $episodeNumber.';
        return null;
      }
      if (!wantsDub && !episode.hasSub) {
        lastError = 'AnimeKai has no Sub for episode $episodeNumber.';
        return null;
      }
      final List<AnimeKaiServer> servers =
          await _serverList(episode.token, subDub: wantsDub ? 'dub' : 'sub');
      if (servers.isEmpty) {
        lastError =
            'AnimeKai has no ${wantsDub ? 'Dub' : 'Sub'} server for episode $episodeNumber.';
        return null;
      }
      for (final AnimeKaiServer server in servers) {
        final String? embedUrl = await _embedUrl(server.linkId);
        if (embedUrl == null) continue;
        final Uri? embedUri = Uri.tryParse(embedUrl);
        if (embedUri == null) continue;
        final String host = embedUri.host.toLowerCase();
        final bool isMegavid = host == _megavidHost ||
            host.endsWith('.$_megavidHost');
        final bool isMegaplay =
            host == _megaplayHost || host.endsWith('.$_megaplayHost');
        if (isMegaplay) {
          // Some titles serve megaplay embeds instead of megavid
          // (Demon Slayer EP1: megaplay.buzz/stream/s-2/1279/sub).
          // The megaplay chain lives in MiruroResolver — reuse it
          // rather than duplicating the decrypt/sign logic.
          final ResolvedStream? mega =
              await _megaplay.resolveMegaplayEmbed(
            embedUrl: embedUrl,
            subDub: subDub,
            watchUrl: '$_base/anime/${match.slug}',
          );
          if (mega == null) continue;
          return ResolvedStream(
            url: mega.url,
            label: 'AnimeKai ${server.name} $subDub',
            source: 'AnimeKai',
            headers: mega.headers,
            variants: mega.variants,
            subtitles: mega.subtitles,
          );
        }
        if (!isMegavid) {
          // Another embed host — its extraction is not verified;
          // skip it rather than guessing.
          continue;
        }
        final ({String master, List<SubtitleInfo> subtitles})? stream =
            await _extractMegavid(embedUrl);
        if (stream == null) continue;
        return ResolvedStream(
          url: stream.master,
          label: 'AnimeKai ${server.name} $subDub',
          source: 'AnimeKai',
          headers: <String, String>{
            'User-Agent': _ua,
            'Referer': 'https://$_megavidHost/',
          },
          subtitles: stream.subtitles,
        );
      }
      lastError =
          'AnimeKai could not play episode $episodeNumber — no working server.';
      return null;
    } catch (e) {
      lastError ??= 'AnimeKai failed: $e';
      return null;
    }
  }

  // ------------------------------------------------------------ search

  /// Search AnimeKai for each title variant (romaji first) and pick
  /// the best-scoring series. Null + [lastError] when nothing is
  /// confident enough — never a guess.
  ///
  /// Two search paths: the suggestion endpoint
  /// (`/ajax/anime/search`, 5 hits — the base series of a big
  /// franchise often does NOT surface there, e.g. plain "Demon
  /// Slayer: Kimetsu no Yaiba" is crowded out by its movies/arcs)
  /// and, when that yields no confident match, the full filter
  /// page (`/filter?keyword=…`, page 1 — the site's own search
  /// form target, 14+ hits, type but no year in its info block).
  Future<AnimeKaiCandidate?> _matchSeries({
    required List<String> titles,
    required int? year,
    required String? format,
  }) async {
    final Map<String, AnimeKaiCandidate> found = {};
    for (final String q in titles) {
      if (q.trim().isEmpty) continue;
      try {
        for (final AnimeKaiCandidate c in await _search(q)) {
          found.putIfAbsent(c.slug, () => c);
        }
      } catch (_) {
        // One bad search query must not kill the others.
        continue;
      }
      // An exact title hit on the first query is enough — the
      // remaining variants only add duplicates.
      if (found.values.any(
        (c) =>
            _plainTitle(c.title) == _plainTitle(titles.first),
      )) {
        break;
      }
    }
    AnimeKaiCandidate? confident = _bestMatch(
      found.values,
      titles: titles,
      year: year,
      format: format,
    );
    if (confident == null && titles.first.trim().isNotEmpty) {
      // Suggestion search came up empty-handed — try the full
      // filter page once with the first title variant.
      try {
        for (final AnimeKaiCandidate c in await _filterSearch(
          titles.first,
        )) {
          found.putIfAbsent(c.slug, () => c);
        }
        confident = _bestMatch(
          found.values,
          titles: titles,
          year: year,
          format: format,
        );
      } catch (_) {
        // Filter failure keeps the suggestion result (none).
      }
    }
    if (confident == null) {
      lastError = 'Could not find "${titles.last}" on AnimeKai.';
      return null;
    }
    return confident;
  }

  /// Best-scoring candidate over [candidates], or null when none is
  /// confident enough (floor + runner-up margin). Pure scoring —
  /// the search itself stays in [_matchSeries].
  AnimeKaiCandidate? _bestMatch(
    Iterable<AnimeKaiCandidate> candidates, {
    required List<String> titles,
    required int? year,
    required String? format,
  }) {
    final List<_Scored> scored = <_Scored>[];
    for (final AnimeKaiCandidate c in candidates) {
      final _Scored? s = _scoreCandidate(
        c,
        titles: titles,
        year: year,
        format: format,
      );
      if (s != null) scored.add(s);
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return null;
    final _Scored best = scored.first;
    final _Scored? runnerUp = scored.length > 1 ? scored[1] : null;
    if (best.score < kMinScore ||
        (runnerUp != null && best.score - runnerUp.score < 0.08)) {
      return null;
    }
    return best.candidate;
  }

  Future<List<AnimeKaiCandidate>> _search(String query) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/ajax/anime/search?keyword=${Uri.encodeQueryComponent(query)}',
          ),
          headers: _pageHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('AnimeKai search HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['status'] != 200) {
      throw Exception('AnimeKai search status ${data['status']}');
    }
    final dynamic result = data['result'];
    final String html = result is String
        ? result
        : (result as Map<String, dynamic>?)?['html'] as String? ?? '';
    return parseSearchResults(html);
  }

  /// The full search page (`/filter?keyword=…` — the site's own
  /// search form target). Page 1 only; its info block carries the
  /// type but no year, so those candidates score without a year
  /// bonus and are never year-vetoed.
  Future<List<AnimeKaiCandidate>> _filterSearch(String query) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/filter?keyword=${Uri.encodeQueryComponent(query)}',
          ),
          headers: _pageHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('AnimeKai filter HTTP ${resp.statusCode}');
    }
    return parseFilterResults(resp.body);
  }

  /// Parse the full filter/search page: one `div.aitem` per series
  /// with the slug + title in `a.title.d-title`, the Japanese title
  /// in `data-jp`, the type in `.info span.type b`. No year on this
  /// page (see [_filterSearch]). Pure — unit-tested.
  static List<AnimeKaiCandidate> parseFilterResults(String html) {
    final dom.Document doc = html_parser.parse(html);
    final List<AnimeKaiCandidate> out = <AnimeKaiCandidate>[];
    for (final dom.Element item in doc.querySelectorAll('div.aitem')) {
      final dom.Element? titleEl = item.querySelector('a.title');
      if (titleEl == null) continue;
      final String href = titleEl.attributes['href'] ?? '';
      final RegExpMatch? m =
          RegExp(r'/anime/([a-z0-9-]+)/?$').firstMatch(href);
      if (m == null) continue;
      final String title = (titleEl.text).trim();
      if (title.isEmpty) continue;
      final String? jpTitle = titleEl.attributes['data-jp'];
      final dom.Element? info = item.querySelector('.info');
      String type = (info?.querySelector('span.type b')?.text ?? '')
          .trim()
          .toUpperCase();
      if (type.isEmpty && info != null) {
        // Fallback: a bare TV/MOVIE/SPECIAL/OVA/ONA token in the
        // info text (never the first <b> — on this page that is
        // the episode count).
        final String infoText = info.text.toUpperCase();
        for (final String t in <String>[
          'TV',
          'MOVIE',
          'SPECIAL',
          'OVA',
          'ONA',
        ]) {
          if (RegExp('\\b$t\\b').hasMatch(infoText)) {
            type = t;
            break;
          }
        }
      }
      out.add(
        AnimeKaiCandidate(
          slug: m.group(1)!,
          title: title,
          jpTitle: (jpTitle ?? '').trim().isEmpty ? null : jpTitle!.trim(),
          type: type,
          year: null,
        ),
      );
    }
    return out;
  }

  /// A title with parenthetical qualifiers stripped
  /// ("Jujutsu Kaisen (TV)" -> "jujutsu kaisen"): the site
  /// disambiguates some series by appending "(TV)" / "(Dub)" to
  /// the display title, and that extra token must not sink an
  /// otherwise exact match. Pure — unit-tested.
  static String _plainTitle(String raw) {
    final String stripped =
        raw.replaceAll(RegExp(r'\([^)]*\)'), ' ').trim();
    return normalizeTitle(stripped);
  }
  static List<AnimeKaiCandidate> parseSearchResults(String html) {
    final dom.Document doc = html_parser.parse(html);
    final List<AnimeKaiCandidate> out = <AnimeKaiCandidate>[];
    for (final dom.Element a in doc.querySelectorAll('a.aitem')) {
      final String href = a.attributes['href'] ?? '';
      final RegExpMatch? m =
          RegExp(r'/anime/([a-z0-9-]+)/?$').firstMatch(href);
      if (m == null) continue;
      final String slug = m.group(1)!;
      final dom.Element? titleEl = a.querySelector('h6.title');
      final String title = (titleEl?.text ?? '').trim();
      if (title.isEmpty) continue;
      final String? jpTitle = titleEl?.attributes['data-jp'];
      String type = '';
      int? year;
      final dom.Element? info = a.querySelector('.info');
      if (info != null) {
        type = (info.querySelector('b')?.text ?? '').trim().toUpperCase();
        final List<dom.Element> spans = info.querySelectorAll('span');
        for (final dom.Element span in spans.reversed) {
          final String text = span.text.trim();
          final int? y = int.tryParse(text);
          if (y != null && y >= 1900 && y <= 2100) {
            year = y;
            break;
          }
        }
      }
      out.add(
        AnimeKaiCandidate(
          slug: slug,
          title: title,
          jpTitle: (jpTitle ?? '').trim().isEmpty ? null : jpTitle!.trim(),
          type: type,
          year: year,
        ),
      );
    }
    return out;
  }

  /// Score one search candidate: title similarity + format + year.
  /// Null when rejected outright. Pure — unit-tested.
  static _Scored? _scoreCandidate(
    AnimeKaiCandidate c, {
    required List<String> titles,
    required int? year,
    required String? format,
  }) {
    final double titleScore = _titleScore(titles, c);
    if (titleScore < kMinScore) return null;
    final String expectedType = _expectedType(format);
    if (expectedType.isNotEmpty &&
        c.type.isNotEmpty &&
        c.type != expectedType) {
      return null;
    }
    if (year != null && c.year != null && year != c.year) return null;
    double score = titleScore * 0.86;
    if (expectedType.isNotEmpty && c.type == expectedType) score += 0.08;
    if (year != null && c.year == year) score += 0.06;
    return _Scored(candidate: c, titleScore: titleScore, score: score);
  }

  /// Best title similarity over all (AniList title × candidate
  /// title) pairs. 1.0 on a normalized exact match, else word-set
  /// Jaccard. Pure — unit-tested.
  static double _titleScore(List<String> titles, AnimeKaiCandidate c) {
    double best = 0;
    final List<String> cTitles = <String>[
      c.title,
      if (c.jpTitle != null) c.jpTitle!,
    ];
    for (final String a in titles) {
      final String na = _plainTitle(a);
      if (na.isEmpty) continue;
      for (final String b in cTitles) {
        final String nb = _plainTitle(b);
        if (nb.isEmpty) continue;
        if (na == nb) return 1.0;
        final Set<String> aw = na.split(' ').toSet();
        final Set<String> bw = nb.split(' ').toSet();
        final int inter = aw.intersection(bw).length;
        final int union = aw.union(bw).length;
        final double j = union == 0 ? 0 : inter / union;
        if (j > best) best = j;
      }
    }
    return best;
  }

  /// AniList format -> AnimeKai type token ('TV' / 'MOVIE' /
  /// 'SPECIAL' / 'OVA' / 'ONA'). Empty when the format maps to
  /// nothing the search list shows — then the type gate is skipped.
  static String _expectedType(String? format) {
    final String f = (format ?? '').toUpperCase();
    if (f.contains('MOVIE')) return 'MOVIE';
    if (f.contains('SPECIAL')) return 'SPECIAL';
    if (f.contains('OVA')) return 'OVA';
    if (f.contains('ONA')) return 'ONA';
    if (f.contains('TV')) return 'TV';
    return '';
  }

  // ------------------------------------------------------------ series

  /// The numeric anime id for [slug], from the anime page's
  /// `data-id="…" data-fetch="true"` hook (the episode-list
  /// endpoint needs it). Null when the page has no such hook.
  Future<int?> _animeId(String slug) async {
    final http.Response resp = await _client
        .get(Uri.parse('$_base/anime/$slug'), headers: _pageHeaders())
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    return parseAnimeId(resp.body);
  }

  /// Parse the anime id out of an anime page. Pure — unit-tested.
  static int? parseAnimeId(String html) {
    final RegExpMatch? m = RegExp(
      r'data-id="(\d+)"\s+data-fetch="true"',
    ).firstMatch(html);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Episode tokens for [aniId], in list order. Each item carries
  /// its number (`data-num`), its server-list token (`data-ids`)
  /// and its Sub/Dub availability.
  Future<List<AnimeKaiEpisode>> _episodeList(int aniId) async {
    final http.Response resp = await _client
        .get(
          Uri.parse('$_base/ajax/episode/list/$aniId'),
          headers: _pageHeaders(referer: '$_base/'),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('AnimeKai episode list HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['status'] != 200) {
      throw Exception('AnimeKai episode list status ${data['status']}');
    }
    final dynamic result = data['result'];
    final String html = result is String
        ? result
        : (result as Map<String, dynamic>?)?['html'] as String? ?? '';
    return parseEpisodeList(html);
  }

  /// Parse the episode-list HTML. Pure — unit-tested.
  static List<AnimeKaiEpisode> parseEpisodeList(String html) {
    final dom.Document doc = html_parser.parse(html);
    final List<AnimeKaiEpisode> out = <AnimeKaiEpisode>[];
    for (final dom.Element a in doc.querySelectorAll('a[data-num]')) {
      final int? number = int.tryParse(a.attributes['data-num'] ?? '');
      final String token = a.attributes['data-ids'] ?? '';
      if (number == null || number < 1 || token.isEmpty) continue;
      out.add(
        AnimeKaiEpisode(
          number: number,
          token: token,
          hasSub: a.attributes['data-sub'] == '1',
          hasDub: a.attributes['data-dub'] == '1',
        ),
      );
    }
    return out;
  }

  // ------------------------------------------------------------ servers

  /// Servers for one episode, in listed order, for the [subDub]
  /// group ('sub' | 'dub').
  Future<List<AnimeKaiServer>> _serverList(
    String episodeToken, {
    required String subDub,
  }) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/ajax/server/list?servers=${Uri.encodeQueryComponent(episodeToken)}',
          ),
          headers: _pageHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('AnimeKai server list HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['status'] != 200) {
      throw Exception('AnimeKai server list status ${data['status']}');
    }
    final dynamic result = data['result'];
    final String html = result is String
        ? result
        : (result as Map<String, dynamic>?)?['html'] as String? ?? '';
    return parseServerList(html, subDub: subDub);
  }

  /// Parse the server-list HTML: the buttons of the [subDub] group
  /// (`.server-items[data-type="<subDub>"] .server-btn`), in listed
  /// order. Pure — unit-tested.
  static List<AnimeKaiServer> parseServerList(
    String html, {
    required String subDub,
  }) {
    final dom.Document doc = html_parser.parse(html);
    final List<AnimeKaiServer> out = <AnimeKaiServer>[];
    for (final dom.Element li in doc.querySelectorAll(
      '.server-items[data-type="$subDub"] .server-btn',
    )) {
      final String linkId = li.attributes['data-link-id'] ?? '';
      if (linkId.isEmpty) continue;
      final String name = li.text.trim();
      out.add(
        AnimeKaiServer(
          name: name.isEmpty ? 'Server' : name,
          linkId: linkId,
        ),
      );
    }
    return out;
  }

  /// The embed URL for one server token. Null when the call fails
  /// or carries no URL.
  Future<String?> _embedUrl(String linkId) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_base/ajax/server?get=${Uri.encodeQueryComponent(linkId)}',
            ),
            headers: _pageHeaders(),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> data =
          jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 200) return null;
      final Map<String, dynamic>? result =
          data['result'] as Map<String, dynamic>?;
      final String? url = result?['url'] as String?;
      return (url == null || url.isEmpty) ? null : url;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ megavid

  /// Extract the stream from a megavid embed URL: the embed page's
  /// `#player-payload` JSON names the source API path; the source
  /// API returns the signed HLS master URL + subtitle tracks.
  /// Null when any step fails — the caller tries the next server.
  Future<({String master, List<SubtitleInfo> subtitles})?>
      _extractMegavid(String embedUrl) async {
    try {
      final http.Response embedResp = await _client
          .get(
            Uri.parse(embedUrl),
            headers: _pageHeaders(referer: '$_base/'),
          )
          .timeout(const Duration(seconds: 15));
      if (embedResp.statusCode != 200) return null;
      final String? sourcePath = parseMegavidSourceUrl(embedResp.body);
      if (sourcePath == null) return null;
      final Uri sourceUri = Uri.parse(embedUrl).resolve(sourcePath);
      final http.Response srcResp = await _client
          .get(
            sourceUri,
            headers: <String, String>{
              'User-Agent': _ua,
              'Referer': embedUrl,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (srcResp.statusCode != 200) return null;
      final Map<String, dynamic> data =
          jsonDecode(srcResp.body) as Map<String, dynamic>;
      if (data['status'] != 'ok') return null;
      final String? master = data['source'] as String?;
      if (master == null || master.isEmpty) return null;
      final List<SubtitleInfo> subtitles = <SubtitleInfo>[];
      final List<dynamic> tracks =
          data['tracks'] as List<dynamic>? ?? <dynamic>[];
      for (final dynamic raw in tracks) {
        final Map<String, dynamic>? t = raw as Map<String, dynamic>?;
        final String? file = t?['file'] as String?;
        if (file == null || file.isEmpty) continue;
        final String kind = (t?['kind'] as String?) ?? '';
        if (kind.isNotEmpty && kind != 'captions') continue;
        subtitles.add(
          SubtitleInfo(
            label: (t?['label'] as String?)?.isNotEmpty ?? false
                ? t!['label'] as String
                : 'English',
            url: file,
          ),
        );
      }
      return (master: master, subtitles: subtitles);
    } catch (_) {
      return null;
    }
  }

  /// The megavid source-API path from an embed page: the
  /// `#player-payload` JSON's `sourceUrl` field. Pure — unit-tested.
  static String? parseMegavidSourceUrl(String embedHtml) {
    try {
      final dom.Document doc = html_parser.parse(embedHtml);
      final dom.Element? payload = doc.getElementById('player-payload');
      if (payload == null) return null;
      final Map<String, dynamic> data =
          jsonDecode(payload.text) as Map<String, dynamic>;
      final String? sourceUrl = data['sourceUrl'] as String?;
      return (sourceUrl == null || sourceUrl.isEmpty) ? null : sourceUrl;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _pageHeaders({String? referer}) {
    return <String, String>{
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
          '*/*;q=0.8',
      'Referer': referer ?? '$_base/',
    };
  }
}

/// One AnimeKai search hit.
class AnimeKaiCandidate {
  const AnimeKaiCandidate({
    required this.slug,
    required this.title,
    required this.jpTitle,
    required this.type,
    required this.year,
  });

  /// URL slug, e.g. `solo-leveling-tlz7of`.
  final String slug;

  final String title;

  /// Japanese title from `data-jp`, null when absent.
  final String? jpTitle;

  /// 'TV' | 'MOVIE' | 'SPECIAL' | … ('' when unknown).
  final String type;

  /// Release year, null when the list shows '?'.
  final int? year;
}

/// One episode from the episode list.
class AnimeKaiEpisode {
  const AnimeKaiEpisode({
    required this.number,
    required this.token,
    required this.hasSub,
    required this.hasDub,
  });

  final int number;

  /// The `data-ids` token for the server-list call.
  final String token;

  final bool hasSub;
  final bool hasDub;
}

/// One server button from the server list.
class AnimeKaiServer {
  const AnimeKaiServer({required this.name, required this.linkId});

  /// Display name, e.g. 'Ani-HD'.
  final String name;

  /// The `data-link-id` token for the server-get call.
  final String linkId;
}

class _Scored {
  const _Scored({
    required this.candidate,
    required this.titleScore,
    required this.score,
  });

  final AnimeKaiCandidate candidate;
  final double titleScore;
  final double score;
}
