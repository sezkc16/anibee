import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// AniPM (anipm.pk) — WebView-embed source (0.2.25).
///
/// Chain (verified live from the VM, 2026-11-25 — Jujutsu Kaisen
/// S1 + Demon Slayer S1, EP1 Sub, both paths):
///   `GET /api/anime/search?q=<title>&sfw=1` (JSON `items`:
///   `id`, `source` ("settlar" | "anilist"), `slug`, `title`,
///   `episodeCount`, `subCount`, `dubCount`)
///   -> `GET /api/anime/playback-bootstrap/{source}/{id}?ep={n}
///   &lang=sub|dub` (JSON: `settlarSelection` — the opaque
///   session token — `availability` {sub, dub},
///   `effectiveLanguage`, `anipmPackages.episodes["{n}"]`)
///   -> `GET /api/anime/settlar/session?selection={token}
///   &provider=anipm&ep={n}&channel=sub|dub&telemetry=0`
///   (JSON: `embedUrl` = `https://embed.settlar.io/embed/v1?t=…`,
///   `expiresAt`, `provider`)
///
/// There is NO stream URL anywhere in this chain — the video
/// plays inside the settlar embed via MSE blob URLs, and the
/// embed itself is Cloudflare-403 from the VM even with full
/// browser headers + a fresh token. So this resolver returns the
/// EMBED URL with [StreamPlayback.webEmbed], and the app plays it
/// in a fullscreen WebView ([AnipmWebPlayerScreen]) with the
/// site's own controls. The VM can verify the chain up to the
/// embed URL (a real, fresh, expiring URL) but CANNOT verify the
/// embed actually plays — the phone test is the only proof.
///
/// What AniPM does NOT get in v1 (stated here so nobody wires
/// it up by accident): no mpv subtitle overlay, no PiP, no Cast,
/// no downloads, no skip-intro, no resume position — the embed
/// owns all playback. The returned stream carries no variants
/// and no subtitles.
///
/// Title matching: AniList romaji/english/native first (via
/// [AniListService.mediaIdentity]), then the catalogue title.
/// Settlar items are preferred (their id goes straight into the
/// bootstrap); anilist items fall back to the
/// `playback-bootstrap/anilist/<anilistId>` path, which also
/// returns a `settlarSelection` (verified live).
/// Channel is plain "sub"/"dub" — the site only switches to the
/// "subhard"/"dubhard" channels when the user prefers hardsubs
/// (a localStorage setting the app does not have).
class AniPmResolver {
  AniPmResolver({http.Client? client, AniListService? anilist})
    : _client = client ?? http.Client(),
      _anilist = anilist ?? AniListService();

  final http.Client _client;
  final AniListService _anilist;

  static const String _api = 'https://anipm.pk/api/anime';

  /// iPhone Safari — the site is a web app; its API answers a
  /// real browser UA. (A datacenter UA is not needed here: the
  /// API itself is not Cloudflare-gated from the VM, only the
  /// settlar embed is.)
  static const String _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
      'Mobile/15E148 Safari/604.1';

  String? lastError;

  /// Resolve the settlar embed URL for [anime] episode
  /// [episodeNumber]. [subDub] is 'Sub' or 'Dub'. Returns null
  /// when nothing resolved.
  Future<ResolvedStream?> resolve({
    required Anime anime,
    required int episodeNumber,
    required String subDub,
  }) async {
    lastError = null;
    try {
      final _AnipmTitle? title = await _searchTitle(anime);
      if (title == null) {
        lastError = 'Could not find "${anime.title}" on AniPM.';
        return null;
      }
      final String lang = subDub == 'Dub' ? 'dub' : 'sub';
      final AnipmBootstrap? boot = await _bootstrap(
        title,
        episodeNumber,
        lang,
      );
      if (boot == null) {
        lastError =
            'AniPM has no ${subDub == 'Dub' ? 'Dub' : 'Sub'} for '
            'episode $episodeNumber of "${anime.title}".';
        return null;
      }
      final String? embedUrl = await _session(
        boot.selection,
        episodeNumber,
        lang,
      );
      if (embedUrl == null) {
        lastError = 'AniPM could not start episode $episodeNumber.';
        return null;
      }
      return ResolvedStream(
        url: embedUrl,
        label: 'AniPM $subDub',
        source: 'AniPM',
        playback: StreamPlayback.webEmbed,
      );
    } catch (e) {
      lastError ??= 'AniPM failed: $e';
      return null;
    }
  }

  // ------------------------------------------------------------ search

  /// Search each title variant and return the best-matching
  /// title. Settlar items win (their id is the bootstrap id);
  /// anilist items are the fallback.
  Future<_AnipmTitle?> _searchTitle(Anime anime) async {
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
      final _AnipmTitle? title = await _searchOnce(q);
      if (title != null) return title;
    }
    return null;
  }

  Future<_AnipmTitle?> _searchOnce(String query) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_api/search?q=${Uri.encodeComponent(query.trim())}&sfw=1',
          ),
          headers: _headers(),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final Map<String, dynamic> json =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<AnipmSearchItem> items = parseSearchItems(json);
    if (items.isEmpty) return null;
    final String normQ = normalizeTitle(query);
    _AnipmTitle? pick(bool Function(AnipmSearchItem) test) {
      final AnipmSearchItem? hit = items
          .where(test)
          .firstOrNull;
      return hit == null
          ? null
          : _AnipmTitle(id: hit.id, source: hit.source);
    }

    // Exact title match, settlar first.
    return pick(
          (AnipmSearchItem h) =>
              h.source == 'settlar' &&
              normalizeTitle(h.title) == normQ,
        ) ??
        pick(
          (AnipmSearchItem h) => normalizeTitle(h.title) == normQ,
        ) ??
        pick(
          (AnipmSearchItem h) =>
              h.source == 'settlar' &&
              (normalizeTitle(h.title).contains(normQ) ||
                  normQ.contains(normalizeTitle(h.title))),
        ) ??
        pick(
          (AnipmSearchItem h) =>
              normalizeTitle(h.title).contains(normQ) ||
              normQ.contains(normalizeTitle(h.title)),
        ) ??
        // No match at all — the first settlar item, else the
        // first item of any source.
        pick((AnipmSearchItem h) => h.source == 'settlar') ??
        _AnipmTitle(id: items.first.id, source: items.first.source);
  }

  /// Parse the /api/anime/search response. Pure — unit-tested
  /// against the recorded live response.
  static List<AnipmSearchItem> parseSearchItems(
    Map<String, dynamic> json,
  ) {
    final List<dynamic>? raw = json['items'] as List<dynamic>?;
    if (raw == null) return <AnipmSearchItem>[];
    final List<AnipmSearchItem> out = <AnipmSearchItem>[];
    for (final dynamic e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final Object? id = e['id'];
      final String title = (e['title'] as String? ?? '').trim();
      final String source = (e['source'] as String? ?? '').trim();
      if (id == null || title.isEmpty || source.isEmpty) continue;
      out.add(
        AnipmSearchItem(
          id: id is int ? id : int.tryParse('$id') ?? -1,
          source: source,
          title: title,
          episodeCount: e['episodeCount'] as int?,
        ),
      );
    }
    return out.where((AnipmSearchItem i) => i.id > 0).toList();
  }

  // ------------------------------------------------------------ bootstrap

  /// The playback-bootstrap for [title] episode [episodeNumber]
  /// in [lang] ('sub' | 'dub'). Returns the settlar session
  /// token, or null when the episode/language is unavailable.
  Future<AnipmBootstrap?> _bootstrap(
    _AnipmTitle title,
    int episodeNumber,
    String lang,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_api/playback-bootstrap/${title.source}/${title.id}'
              '?ep=$episodeNumber&lang=$lang',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      return parseBootstrap(json, lang: lang);
    } catch (_) {
      return null;
    }
  }

  /// Parse the playback-bootstrap response. Pure — unit-tested
  /// against the recorded live response. Null when the token is
  /// missing or the requested language is not available for this
  /// episode (availability map, or an effective language that
  /// differs from the request — never silently play the wrong
  /// language).
  static AnipmBootstrap? parseBootstrap(
    Map<String, dynamic> json, {
    required String lang,
  }) {
    final String selection =
        (json['settlarSelection'] as String? ?? '').trim();
    if (selection.isEmpty) return null;
    final Map<String, dynamic>? availability =
        json['availability'] as Map<String, dynamic>?;
    if (availability != null && availability[lang] != true) return null;
    final String effective =
        (json['effectiveLanguage'] as String? ?? '').trim();
    if (effective.isNotEmpty && effective != lang) return null;
    return AnipmBootstrap(selection: selection);
  }

  // ------------------------------------------------------------ session

  /// The settlar session for one episode: returns the embed URL.
  Future<String?> _session(
    String selection,
    int episodeNumber,
    String channel,
  ) async {
    try {
      final Uri uri = Uri.parse('$_api/settlar/session').replace(
        queryParameters: <String, String>{
          'selection': selection,
          'provider': 'anipm',
          'ep': '$episodeNumber',
          'channel': channel,
          'telemetry': '0',
        },
      );
      final http.Response resp = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      return parseSessionEmbedUrl(json);
    } catch (_) {
      return null;
    }
  }

  /// Parse the settlar-session response. Pure — unit-tested
  /// against the recorded live response. Only an https URL on
  /// the settlar embed host counts; anything else is not an
  /// embed the WebView player can load.
  static String? parseSessionEmbedUrl(Map<String, dynamic> json) {
    final String embedUrl = (json['embedUrl'] as String? ?? '').trim();
    if (embedUrl.isEmpty) return null;
    final Uri? uri = Uri.tryParse(embedUrl);
    if (uri == null || uri.scheme != 'https') return null;
    final String host = uri.host.toLowerCase();
    if (host != 'embed.settlar.io' && !host.endsWith('.settlar.io')) {
      return null;
    }
    return embedUrl;
  }

  Map<String, String> _headers() => <String, String>{
    'User-Agent': _ua,
    'Accept': 'application/json',
    'Referer': 'https://anipm.pk/',
  };
}

/// One search hit from /api/anime/search.
class AnipmSearchItem {
  const AnipmSearchItem({
    required this.id,
    required this.source,
    required this.title,
    this.episodeCount,
  });

  /// Settlar id (e.g. 1103) or AniList id (e.g. 113415) —
  /// the bootstrap id for [source].
  final int id;

  /// 'settlar' | 'anilist'.
  final String source;
  final String title;
  final int? episodeCount;
}

class _AnipmTitle {
  const _AnipmTitle({required this.id, required this.source});

  final int id;
  final String source;
}

class AnipmBootstrap {
  const AnipmBootstrap({required this.selection});

  /// Opaque settlar session token from playback-bootstrap.
  final String selection;
}
