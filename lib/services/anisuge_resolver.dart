import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// AniSuge (anisuge.tv) — real on-device resolver (0.2.24).
///
/// Chain (verified live from the VM, 2026-11-24):
///   `GET /filter?keyword=<title>` (HTML — results are
///   `div.item` cards: poster `a[href]` + `img[alt]` title,
///   NOT the anikoto.cz `#list-items` layout)
///   -> watch page (anime id is `data-id` on the
///   `div.watch-wrap` container, NOT `data-anime-id`)
///   -> `GET /ajax/episode/list/<id>` (JSON `result` HTML:
///   anchors carry `data-slug` = episode NUMBER,
///   `data-ids` = server token, `data-sub`/`data-dub` flags;
///   `data-num` here is the episode TITLE, not the number)
///   -> `GET /ajax/server/list?servers=<token>` (JSON `result`
///   HTML: `div.type[data-type]` -> `div.server[data-link-id]`,
///   name in the inner `<span>` — NOT `li` elements)
///   -> `GET /ajax/server?get=<linkId>` (JSON `result.url` =
///   megaplay.buzz embed, plus `result.skip_data`)
///   -> megaplay embed -> getSources -> AES decrypt -> signed
///   master (the chain lives in MiruroResolver; reused here
///   exactly like AniKage does).
///
/// The site is an AnimeWave-family clone ("a variant for
/// animewave" per the ZORO repo's plugins.json: baseUrl
/// `https://anisuge.tv`) and the AJAX backend IS the same as
/// AniKoto's — but the search page, watch page, episode anchors
/// and server list markup all differ, so AniSuge has its own
/// parsers here instead of sharing AniKoto's chain. (The
/// original AnimeSuge .to is dead as of Oct 2026 — ACE/MPA court
/// action, domains seized one by one; surviving .to/.co.in
/// addresses are unrelated copies. anisuge.tv is the address the
/// ZORO plugin points at, and it answers live.)
///
/// Titles carry a "(TV)" qualifier on this site ("Jujutsu Kaisen
/// (TV)") — the matcher strips parenthetical qualifiers before
/// comparing.
class AnisugeResolver {
  AnisugeResolver({
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

  static const String _base = 'https://anisuge.tv';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  String? lastError;

  /// Resolve a playable stream for [anime] episode [episodeNumber].
  /// [subDub] is 'Sub' or 'Dub'. Returns null when nothing resolved.
  Future<ResolvedStream?> resolve({
    required Anime anime,
    required int episodeNumber,
    required String subDub,
  }) async {
    lastError = null;
    try {
      final String? watchUrl = await _searchWatchUrl(anime);
      if (watchUrl == null) {
        lastError = 'Could not find "${anime.title}" on AniSuge.';
        return null;
      }
      final String? animeId = await _animeId(watchUrl);
      if (animeId == null) {
        lastError = 'AniSuge could not open "${anime.title}".';
        return null;
      }
      final _AsEpisode? episode =
          await _episodeToken(watchUrl, animeId, episodeNumber);
      if (episode == null) {
        lastError =
            'AniSuge has no episode $episodeNumber for "${anime.title}".';
        return null;
      }
      final bool wantsDub = subDub == 'Dub';
      if (wantsDub && !episode.hasDub) {
        lastError = 'AniSuge has no Dub for episode $episodeNumber.';
        return null;
      }
      if (!wantsDub && !episode.hasSub) {
        lastError = 'AniSuge has no Sub for episode $episodeNumber.';
        return null;
      }
      final List<_AsServer> servers =
          await _servers(watchUrl, episode.token);
      if (servers.isEmpty) {
        lastError =
            'AniSuge has no servers for episode $episodeNumber.';
        return null;
      }
      final List<String> wantTypes =
          wantsDub ? <String>['dub', 'sub'] : <String>['sub', 'dub'];
      final Set<String> seenEmbeds = <String>{};
      for (final String wantType in wantTypes) {
        final List<_AsServer> typed = servers
            .where((_AsServer s) => s.type == wantType)
            .toList();
        typed.sort((a, b) {
          final bool aHd = a.name.toLowerCase().contains('hd-1');
          final bool bHd = b.name.toLowerCase().contains('hd-1');
          if (aHd != bHd) return aHd ? -1 : 1;
          return servers.indexOf(a).compareTo(servers.indexOf(b));
        });
        for (final _AsServer server in typed) {
          try {
            final String? embedUrl =
                await _serverEmbed(watchUrl, server.linkId);
            if (embedUrl == null || !seenEmbeds.add(embedUrl)) continue;
            final Uri? uri = Uri.tryParse(embedUrl);
            if (uri == null) continue;
            final String host = uri.host.toLowerCase();
            final bool isMegaplay = host == 'megaplay.buzz' ||
                host.endsWith('.megaplay.buzz');
            if (!isMegaplay) continue;
            final ResolvedStream? mega =
                await _megaplay.resolveMegaplayEmbed(
              embedUrl: embedUrl,
              subDub: subDub,
              watchUrl: watchUrl,
            );
            if (mega == null) continue;
            return ResolvedStream(
              url: mega.url,
              label: 'AniSuge ${server.name} $subDub',
              source: 'AniSuge',
              headers: mega.headers,
              variants: mega.variants,
              subtitles: mega.subtitles,
            );
          } catch (_) {
            continue;
          }
        }
      }
      lastError =
          'AniSuge could not play episode $episodeNumber — no working server.';
      return null;
    } catch (e) {
      lastError ??= 'AniSuge failed: $e';
      return null;
    }
  }

  // ------------------------------------------------------------ search

  /// Search each title variant (AniList romaji / english / native,
  /// then the catalogue title) and return the best-matching watch
  /// URL. Parenthetical qualifiers ("(TV)") are stripped before
  /// comparing — the site appends them to display titles.
  /// 0.2.30: two passes when [Anime.seasonNumber] is set — a
  /// season-aware pass first (a bare title match is always S1, so
  /// an early query must never short-circuit with the wrong
  /// season), then the old behaviour as a fallback.
  Future<String?> _searchWatchUrl(Anime anime) async {
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
    final int? season = anime.seasonNumber;
    if (season != null) {
      for (final String q in queries) {
        final String? url = await _filterOnce(q, seasonNumber: season);
        if (url != null) return url;
      }
    }
    for (final String q in queries) {
      final String? url = await _filterOnce(q);
      if (url != null) return url;
    }
    return null;
  }

  Future<String?> _filterOnce(String query, {int? seasonNumber}) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/filter?keyword=${Uri.encodeComponent(query.trim())}',
          ),
          headers: _pageHeaders(null),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final List<AnisugeHit> hits = parseSearchResults(resp.body);
    if (hits.isEmpty) return null;
    if (seasonNumber != null) {
      // Season-aware only: no match for this query means "try the
      // next query", never a fallback to the bare title (S1).
      for (final AnisugeHit h in hits) {
        if (seasonTitleMatches(h.title, query, seasonNumber)) {
          return h.href;
        }
      }
      return null;
    }
    final String normQ = normalizeTitle(_stripParens(query));
    String? pick(bool Function(AnisugeHit) test) =>
        hits.where(test).map((AnisugeHit h) => h.href).firstOrNull;
    return pick(
          (AnisugeHit h) => normalizeTitle(_stripParens(h.title)) == normQ,
        ) ??
        pick((AnisugeHit h) {
          final String n = normalizeTitle(_stripParens(h.title));
          return n.contains(normQ) || normQ.contains(n);
        }) ??
        hits.first.href;
  }

  /// Parse the /filter results page. Pure — unit-tested against
  /// the recorded response. Cards are `div.item` (under
  /// `div.original.anime.main-card`): poster `a[href]` +
  /// `img[alt]`; the `.name` div text is the fallback title.
  static List<AnisugeHit> parseSearchResults(String html) {
    final dom.Document doc = html_parser.parse(html);
    List<dom.Element> items = doc.querySelectorAll(
      'div.original.anime.main-card div.item',
    );
    if (items.isEmpty) {
      items = doc.querySelectorAll('div.item');
    }
    final List<AnisugeHit> out = <AnisugeHit>[];
    for (final dom.Element item in items) {
      final dom.Element? posterA =
          item.querySelector('div.item-top a[href]');
      if (posterA == null) continue;
      final String href = posterA.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      final String title =
          posterA.querySelector('img')?.attributes['alt']?.trim() ??
          item.querySelector('div.item-bottom div.name')?.text.trim() ??
          '';
      if (title.isEmpty) continue;
      out.add(AnisugeHit(title: title, href: href));
    }
    return out;
  }

  static String _stripParens(String s) =>
      s.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

  // ------------------------------------------------------------ watch

  /// The anime id is `data-id` on the `div.watch-wrap`
  /// container of the watch page.
  Future<String?> _animeId(String watchUrl) async {
    try {
      final http.Response resp = await _client
          .get(Uri.parse(watchUrl), headers: _pageHeaders(null))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final dom.Document doc = html_parser.parse(resp.body);
      final String? id = doc
          .querySelector('div.watch-wrap[data-id]')
          ?.attributes['data-id']
          ?.trim();
      return id?.isEmpty == true ? null : id;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ episodes

  /// The episode token for [episodeNumber]: anchors carry
  /// `data-slug` = episode number, `data-ids` = server token,
  /// `data-sub`/`data-dub` = availability flags. (`data-num` is
  /// the episode TITLE on this site — never the number.)
  Future<_AsEpisode?> _episodeToken(
    String watchUrl,
    String animeId,
    int episodeNumber,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse('$_base/ajax/episode/list/$animeId'),
            headers: _ajaxHeaders(watchUrl),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final String? html = json['result'] as String?;
      if (html == null) return null;
      final dom.Document doc = html_parser.parse(html);
      for (final dom.Element a in doc.querySelectorAll(
        'a[data-slug][data-ids]',
      )) {
        if (int.tryParse(a.attributes['data-slug'] ?? '') ==
            episodeNumber) {
          final String token = a.attributes['data-ids']?.trim() ?? '';
          if (token.isEmpty) return null;
          return _AsEpisode(
            token: token,
            hasSub: a.attributes['data-sub'] == '1',
            hasDub: a.attributes['data-dub'] == '1',
          );
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  // ------------------------------------------------------------ servers

  Future<List<_AsServer>> _servers(
    String watchUrl,
    String token,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_base/ajax/server/list?servers=${Uri.encodeComponent(token)}',
            ),
            headers: _ajaxHeaders(watchUrl),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <_AsServer>[];
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final String? html = json['result'] as String?;
      if (html == null) return <_AsServer>[];
      final dom.Document doc = html_parser.parse(html);
      final List<_AsServer> out = <_AsServer>[];
      for (final dom.Element typeDiv in doc.querySelectorAll(
        'div.type[data-type]',
      )) {
        final String type = (typeDiv.attributes['data-type'] ?? '')
            .trim()
            .toLowerCase();
        for (final dom.Element div in typeDiv.querySelectorAll(
          'div.server[data-link-id]',
        )) {
          final String linkId =
              div.attributes['data-link-id']?.trim() ?? '';
          if (linkId.isEmpty) continue;
          out.add(
            _AsServer(
              type: type,
              name: div.text.trim(),
              linkId: linkId,
            ),
          );
        }
      }
      return out;
    } catch (_) {
      return <_AsServer>[];
    }
  }

  Future<String?> _serverEmbed(String watchUrl, String linkId) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_base/ajax/server?get=${Uri.encodeComponent(linkId)}',
            ),
            headers: _ajaxHeaders(watchUrl),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final Map<String, dynamic>? result =
          json['result'] as Map<String, dynamic>?;
      final String? url = result?['url'] as String?;
      return url?.trim().isEmpty == true ? null : url?.trim();
    } catch (_) {
      return null;
    }
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

  Map<String, String> _ajaxHeaders(String? referer) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': _ua,
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    };
    if (referer != null) headers['Referer'] = referer;
    return headers;
  }
}

class AnisugeHit {
  const AnisugeHit({required this.title, required this.href});

  final String title;
  final String href;
}

class _AsEpisode {
  const _AsEpisode({
    required this.token,
    required this.hasSub,
    required this.hasDub,
  });

  final String token;
  final bool hasSub;
  final bool hasDub;
}

class _AsServer {
  const _AsServer({
    required this.type,
    required this.name,
    required this.linkId,
  });

  final String type;
  final String name;
  final String linkId;
}
