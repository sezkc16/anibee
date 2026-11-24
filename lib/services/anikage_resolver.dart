import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'anilist_service.dart';
import 'miruro_resolver.dart';

/// AniKage (anikage.cc) — real on-device resolver (0.2.24).
///
/// SvelteKit site with a public JSON API (endpoints read from the
/// site's own JS chunks, 2026-11-24):
///   `GET /api/media/anime/browse?q=<title>&sort=popularity&limit=24&adult=false&page=1`
///     -> {data: [{slug, anilistId, malId,
///         title: {romaji, english, native}}], total}
///   `GET /api/media/anime/<slug>/episodes`
///     -> [{id, slug, number, seasonNumber, episodeInSeason,
///         title, ...}]
///   `GET /api/media/anime/<slug>/episodes/<ep>/servers`
///     -> {servers: [{id, providerId, default, subTypes,
///         urls?, embed?, label?}]}
///   `GET /api/media/anime/<slug>/episodes/<ep>/sources?provider=<id>&lang=sub|dub`
///     -> {sources: [{url (site-encrypted), isM3U8, quality}],
///         subtitles: [{file (site-encrypted)}],
///         mirrors: [...], embedOptions: [{key, url}]}
///
/// The `sources[].url` values are encrypted by the site (no key in
/// the public JS) and are NOT used. The usable path is
/// `embedOptions`: providers whose embed is a megaplay.buzz URL
/// (e.g. koto -> `https://megaplay.buzz/videojs/stream/s-2/<id>/sub`)
/// resolve through the existing megaplay chain in MiruroResolver
/// (getSources -> AES decrypt -> signed master). Providers whose
/// embed is vidcloud.se (kage — 403s from the VM, embed-only) or
/// ani.pm (pam — settlar embed only, no plain stream) are
/// skipped: no verified direct-stream path exists for them, so
/// they are never guessed.
///
/// anikage.cc is the baseUrl the ZORO plugin lists; mirrors
/// (.watch/.site/.my/.baby) exist but were not needed. Verified
/// live from the VM 2026-11-24 (Jujutsu Kaisen EP1 + Demon Slayer
/// EP1): browse finds the title, servers list the providers,
/// koto's embedOption resolves to a real signed megaplay master
/// with subtitles, and the first segment is real H.264 + AAC
/// (ffprobe).
class AnikageResolver {
  AnikageResolver({
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

  static const String _base = 'https://anikage.cc';
  static const String _megaplayHost = 'megaplay.buzz';
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
      final String? slug = await _searchSlug(anime);
      if (slug == null) {
        lastError = 'Could not find "${anime.title}" on AniKage.';
        return null;
      }
      final bool? hasEpisode = await _hasEpisode(slug, episodeNumber);
      if (hasEpisode == false) {
        lastError =
            'AniKage has no episode $episodeNumber for "${anime.title}".';
        return null;
      }
      final List<_AkServer> servers = await _servers(slug, episodeNumber);
      if (servers.isEmpty) {
        lastError =
            'AniKage has no servers for episode $episodeNumber.';
        return null;
      }
      final String lang = subDub == 'Dub' ? 'dub' : 'sub';
      final List<_AkServer> ordered = <_AkServer>[
        ...servers.where((_AkServer s) => s.isDefault),
        ...servers.where((_AkServer s) => !s.isDefault),
      ];
      final Set<String> seenEmbeds = <String>{};
      for (final _AkServer server in ordered) {
        if (!server.subTypes.contains(lang)) continue;
        // Candidate embeds: the sources call's embedOptions first
        // (the site's own resolution), then the server's direct
        // urls map. Only megaplay embeds resolve to a plain
        // stream — anything else is skipped, never guessed.
        final List<String> embedUrls = <String>[];
        try {
          final List<String> fromSources =
              await _sourceEmbeds(slug, episodeNumber, server.id, lang);
          for (final String u in fromSources) {
            if (seenEmbeds.add(u)) embedUrls.add(u);
          }
        } catch (_) {
          // Sources call failed — the direct urls map may still
          // carry a working embed.
        }
        final String? direct = server.urls?[lang];
        if (direct != null && seenEmbeds.add(direct)) {
          embedUrls.add(direct);
        }
        for (final String embedUrl in embedUrls) {
          final Uri? uri = Uri.tryParse(embedUrl);
          if (uri == null) continue;
          final String host = uri.host.toLowerCase();
          final bool isMegaplay = host == _megaplayHost ||
              host.endsWith('.$_megaplayHost');
          if (!isMegaplay) continue;
          final ResolvedStream? mega =
              await _megaplay.resolveMegaplayEmbed(
            embedUrl: embedUrl,
            subDub: subDub,
            watchUrl: '$_base/anime/watch/$slug?ep=$episodeNumber',
          );
          if (mega == null) continue;
          return ResolvedStream(
            url: mega.url,
            label: 'AniKage ${server.id} $subDub',
            source: 'AniKage',
            headers: mega.headers,
            variants: mega.variants,
            subtitles: mega.subtitles,
          );
        }
      }
      lastError =
          'AniKage could not play episode $episodeNumber — no working server.';
      return null;
    } catch (e) {
      lastError ??= 'AniKage failed: $e';
      return null;
    }
  }

  // ------------------------------------------------------------ search

  /// Browse-search each title variant (AniList romaji / english /
  /// native, then the catalogue title) and return the best-matching
  /// slug. An AniList-id match wins outright; otherwise the
  /// normalized-title rules from the AnimeWave chain apply
  /// (exact, then contains, then first result — never a guess
  /// when the list is empty).
  Future<String?> _searchSlug(Anime anime) async {
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
      for (final String q in queries) {
        final String? slug =
            await _browseOnce(q, anilistId: anilistId);
        if (slug != null) return slug;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<String?> _browseOnce(String query, {int? anilistId}) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/api/media/anime/browse'
            '?q=${Uri.encodeComponent(query.trim())}'
            '&sort=popularity&limit=24&adult=false&page=1',
          ),
          headers: _apiHeaders,
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final Map<String, dynamic> json =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<dynamic> data = json['data'] as List<dynamic>? ?? <dynamic>[];
    if (data.isEmpty) return null;
    final List<_AkHit> hits = <_AkHit>[];
    for (final dynamic raw in data) {
      final Map<String, dynamic> item = raw as Map<String, dynamic>;
      final String slug = item['slug'] as String? ?? '';
      if (slug.isEmpty) continue;
      final Map<String, dynamic> title =
          item['title'] as Map<String, dynamic>? ?? <String, dynamic>{};
      hits.add(
        _AkHit(
          slug: slug,
          anilistId: item['anilistId'] as int?,
          romaji: title['romaji'] as String? ?? '',
          english: title['english'] as String? ?? '',
        ),
      );
    }
    if (hits.isEmpty) return null;
    if (anilistId != null) {
      final _AkHit? byId =
          hits.where((_AkHit h) => h.anilistId == anilistId).firstOrNull;
      if (byId != null) return byId.slug;
    }
    final String normQ = normalizeTitle(query);
    String? pick(List<bool Function(_AkHit)> tests) {
      for (final bool Function(_AkHit) test in tests) {
        final _AkHit? hit = hits.where(test).firstOrNull;
        if (hit != null) return hit.slug;
      }
      return null;
    }
    return pick(<bool Function(_AkHit)>[
          (_AkHit h) =>
              normalizeTitle(h.romaji) == normQ ||
              normalizeTitle(h.english) == normQ,
          (_AkHit h) {
            final String r = normalizeTitle(h.romaji);
            final String e = normalizeTitle(h.english);
            return (r.isNotEmpty &&
                    (r.contains(normQ) || normQ.contains(r))) ||
                (e.isNotEmpty && (e.contains(normQ) || normQ.contains(e)));
          },
        ]) ??
        hits.first.slug;
  }

  // ------------------------------------------------------------ episodes

  /// True when the episode exists, false when the list loads and
  /// it does not, null when the list itself could not be fetched
  /// (the servers call then decides).
  Future<bool?> _hasEpisode(String slug, int episodeNumber) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse('$_base/api/media/anime/$slug/episodes'),
            headers: _apiHeaders,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final List<dynamic> list =
          jsonDecode(resp.body) as List<dynamic>;
      for (final dynamic raw in list) {
        final Map<String, dynamic> ep = raw as Map<String, dynamic>;
        if (ep['number'] == episodeNumber) return true;
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ servers

  Future<List<_AkServer>> _servers(String slug, int episode) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_base/api/media/anime/$slug/episodes/$episode/servers',
            ),
            headers: _apiHeaders,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <_AkServer>[];
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final List<dynamic> list =
          json['servers'] as List<dynamic>? ?? <dynamic>[];
      final List<_AkServer> out = <_AkServer>[];
      for (final dynamic raw in list) {
        final Map<String, dynamic> s = raw as Map<String, dynamic>;
        final String id = s['id'] as String? ?? '';
        if (id.isEmpty) continue;
        final List<dynamic> types =
            s['subTypes'] as List<dynamic>? ?? <dynamic>[];
        final Map<String, dynamic>? urls =
            s['urls'] as Map<String, dynamic>?;
        out.add(
          _AkServer(
            id: id,
            isDefault: s['default'] as bool? ?? false,
            subTypes: types
                .map((dynamic t) => (t as String).toLowerCase())
                .toSet(),
            urls: urls == null
                ? null
                : <String, String>{
                    for (final MapEntry<String, dynamic> e in urls.entries)
                      e.key.toLowerCase(): e.value as String,
                  },
          ),
        );
      }
      return out;
    } catch (_) {
      return <_AkServer>[];
    }
  }

  // ------------------------------------------------------------ sources

  /// The sources call's embedOptions URLs for one provider+lang.
  /// The encrypted `sources[].url` values are deliberately
  /// ignored — the megaplay embedOption is the verified path.
  Future<List<String>> _sourceEmbeds(
    String slug,
    int episode,
    String provider,
    String lang,
  ) async {
    final http.Response resp = await _client
        .get(
          Uri.parse(
            '$_base/api/media/anime/$slug/episodes/$episode/sources'
            '?provider=${Uri.encodeComponent(provider)}'
            '&lang=${Uri.encodeComponent(lang)}',
          ),
          headers: _apiHeaders,
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return <String>[];
    final Map<String, dynamic> json =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<dynamic> options =
        json['embedOptions'] as List<dynamic>? ?? <dynamic>[];
    final List<String> out = <String>[];
    for (final dynamic raw in options) {
      final Map<String, dynamic> opt = raw as Map<String, dynamic>;
      final String url = opt['url'] as String? ?? '';
      if (url.isNotEmpty) out.add(url);
    }
    return out;
  }

  Map<String, String> get _apiHeaders => <String, String>{
    'User-Agent': _ua,
    'Accept': 'application/json',
  };
}

class _AkHit {
  const _AkHit({
    required this.slug,
    required this.anilistId,
    required this.romaji,
    required this.english,
  });

  final String slug;
  final int? anilistId;
  final String romaji;
  final String english;
}

class _AkServer {
  const _AkServer({
    required this.id,
    required this.isDefault,
    required this.subTypes,
    required this.urls,
  });

  final String id;
  final bool isDefault;
  final Set<String> subTypes;

  /// Direct embed URLs by lang ('sub'/'dub'), when the server
  /// carries them (kage -> vidcloud, pam -> ani.pm).
  final Map<String, String>? urls;
}
