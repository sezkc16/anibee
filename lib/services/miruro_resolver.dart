import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../models.dart';
import 'anilist_service.dart';

/// A resolved playable stream: one best URL (or quality variants),
/// playback headers, and subtitle tracks. Every source returns a
/// real media URL for the mpv player.
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.label,
    required this.source,
    this.headers = const <String, String>{},
    this.variants = const <StreamVariant>[],
    this.subtitles = const <SubtitleInfo>[],
  });

  /// Best (highest-quality) playable URL.
  final String url;

  /// Human label, e.g. "Miruro MegaPlay 1080p" / "TorBox Cached 1080p".
  final String label;

  /// 'Miruro' | 'Anikoto' | 'AniSuge' | 'AniKage' |
  /// 'Anime-Sama' | 'TorBox' | 'Real-Debrid'.
  final String source;

  /// Headers the player must send (Referer / Origin / UA).
  final Map<String, String> headers;

  /// Quality variants (same stream, other renditions). Empty when the
  /// source is a single file.
  final List<StreamVariant> variants;

  final List<SubtitleInfo> subtitles;
}

class StreamVariant {
  const StreamVariant({required this.url, required this.qualityLabel});

  final String url;

  /// e.g. "1080p".
  final String qualityLabel;
}

class SubtitleInfo {
  const SubtitleInfo({required this.label, required this.url});

  final String label;
  final String url;
}

/// Miruro stream resolution — Dart port of the TojiX Miruro v7 plugin
/// (proven working on the user's phone).
///
/// Chain: AniList id -> justanime core API (megaplay, then animegg) ->
/// Anikoto fallback (anikoto.cz AJAX -> megaplay.buzz embed ->
/// getSources/getSourcesNew -> AES-256-CBC decrypt -> master m3u8 ->
/// HMAC ?token= signing -> variant expansion).
///
/// Miruro's own SvelteKit pipe API is Cloudflare-403 even on-device —
/// it is NOT used. Resolve happens ON-DEVICE (Cloudflare blocks
/// datacenter IPs). Every step is isolated: one failure never throws
/// out of [resolve]; the caller gets null + [lastError].
class MiruroResolver {
  MiruroResolver({http.Client? client, AniListService? anilist})
    : _client = client ?? http.Client(),
      _anilist = anilist ?? AniListService(client: client);

  final http.Client _client;
  final AniListService _anilist;

  static const String _justAnimeApi = 'https://core.justanime.to/api/watch';
  static const String _anikotoUrl = 'https://anikoto.cz';
  static const String _megaHost = 'https://megaplay.buzz';
  static const String _megaReferer = 'https://megaplay.buzz/';

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// AES key/IV for megaplay's getSources "enc" (same pair as the
  /// Anikoto v3 plugin). Key is zero-padded to 32 bytes (AES-256).
  static const String megaKey = 'i?LMTAx0Q6,:}50U';
  static const String megaIv = "W0;27ToaUpl_P%'c";

  /// HMAC secret for the ?token= signature on megaplay master URLs.
  static const String megaTokenSecret =
      'MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s';

  String? lastError;

  /// True when a subtitle label is English ('English', 'English [SDH]',
  /// 'en', 'eng', ...). Pure — unit-tested. Single source of truth:
  /// the player default picker uses this too.
  static bool isEnglishLabel(String? label) {
    final String l = (label ?? '').trim().toLowerCase();
    if (l.isEmpty) return false;
    return l.contains('english') ||
        l == 'en' ||
        l == 'eng' ||
        l.startsWith('en ') ||
        l.startsWith('en-') ||
        l.startsWith('eng ') ||
        l.startsWith('[en') ||
        l.startsWith('(en');
  }

  /// Fetch subtitle tracks for an episode WITHOUT resolving video —
  /// used by the player when the playing stream has no English track
  /// (0.2.1: JJK's stream carried only Arabic). Hits the justanime
  /// providers (megaplay, then animegg) and returns the merged track
  /// lists. Best-effort: empty list on any failure.
  Future<List<SubtitleInfo>> fetchSubtitlesOnly({
    required Anime anime,
    required int episodeNumber,
    String subDub = 'Sub',
  }) async {
    final int? anilistId =
        anime.anilistId ?? await _anilist.resolveId(anime.title);
    if (anilistId == null) return <SubtitleInfo>[];
    final List<SubtitleInfo> out = <SubtitleInfo>[];
    final Set<String> seen = <String>{};
    for (final String provider in <String>['megaplay', 'animegg']) {
      try {
        final Map<String, dynamic>? data = await _justAnimeWatch(
          anilistId,
          episodeNumber,
          provider,
        );
        if (data == null) continue;
        final List<String> audios = subDub == 'Dub'
            ? <String>['dub', 'sub']
            : <String>['sub', 'dub'];
        for (final String audio in audios) {
          final Map<String, dynamic>? typeData =
              data[audio] as Map<String, dynamic>?;
          if (typeData == null) continue;
          for (final SubtitleInfo s in _parseJustAnimeTracks(typeData)) {
            if (seen.add('${s.label}|${s.url}')) out.add(s);
          }
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Resolve a playable stream for [anime] episode [episodeNumber].
  /// [subDub] is 'Sub' or 'Dub'. [server] is the chosen source:
  /// 'Miruro' = justanime chain first (megaplay, then animegg);
  /// 'AniKoto' = the anikoto.cz chain only. When [fallback] is true
  /// (the user's fallback-providers setting) and the chosen server
  /// fails, the other server is tried once — the played stream's
  /// `source` always says which one actually resolved.
  /// Returns null when nothing resolved.
  Future<ResolvedStream?> resolve({
    required Anime anime,
    required int episodeNumber,
    required String subDub,
    String server = 'Miruro',
    bool fallback = true,
  }) async {
    lastError = null;
    if (server == 'AniKoto') {
      final ResolvedStream? stream = await _tryAnikoto(
        anime.title,
        episodeNumber,
        subDub,
        seasonNumber: anime.seasonNumber,
      );
      if (stream != null) return stream;
      if (!fallback) {
        lastError ??= 'AniKoto has no sources for episode $episodeNumber.';
        return null;
      }
      // Chosen server failed and fallback is on: try Miruro once.
      final int? anilistId =
          anime.anilistId ?? await _anilist.resolveId(anime.title);
      if (anilistId != null) {
        final ResolvedStream? miruroStream = await _tryJustAnime(
          anilistId,
          episodeNumber,
          subDub,
        );
        if (miruroStream != null) return miruroStream;
      }
      lastError ??= 'No sources found for episode $episodeNumber.';
      return null;
    }
    final int? anilistId;
    if (anime.anilistId != null) {
      anilistId = anime.anilistId;
    } else {
      // 0.2.12: the lookup can fail two ways — AniList unreachable
      // (network/rate limit) vs the title genuinely not on AniList —
      // and the dialog must not blame the title for a dead network.
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
    // justanime first: megaplay (HLS, usually 1080p), then animegg.
    final ResolvedStream? justAnime = await _tryJustAnime(
      anilistId,
      episodeNumber,
      subDub,
    );
    if (justAnime != null) return justAnime;
    if (!fallback) {
      lastError ??= 'No sources found for episode $episodeNumber.';
      return null;
    }
    // justanime unreachable on this network: Anikoto fallback by title.
    final ResolvedStream? anikoto = await _tryAnikoto(
      anime.title,
      episodeNumber,
      subDub,
      seasonNumber: anime.seasonNumber,
    );
    if (anikoto != null) return anikoto;
    lastError ??= 'No sources found for episode $episodeNumber.';
    return null;
  }

  /// JustAnime chain only (megaplay, then animegg). Null on failure.
  Future<ResolvedStream?> _tryJustAnime(
    int anilistId,
    int episodeNumber,
    String subDub,
  ) async {
    for (final String provider in <String>['megaplay', 'animegg']) {
      try {
        final ResolvedStream? stream = await _resolveJustAnime(
          anilistId,
          episodeNumber,
          provider,
          subDub,
        );
        if (stream != null) return stream;
      } catch (_) {
        // Provider failed — move on.
      }
    }
    return null;
  }

  /// Anikoto chain only, by title. Null on failure. [seasonNumber]
  /// (0.2.30) is the selected season's chain position — without it
  /// every season resolves to S1, because every season shares the
  /// AniList title and the site's bare title IS season 1.
  Future<ResolvedStream?> _tryAnikoto(
    String title,
    int episode,
    String subDub, {
    int? seasonNumber,
  }) async {
    try {
      return await resolveAnikoto(
        title,
        episode,
        subDub,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return null;
    }
  }

  /// The anikoto.cz chain as its own selectable resolver (0.2.11):
  /// search by title -> watch page -> episode token -> server list ->
  /// megaplay embed -> getSources -> AES-256-CBC decrypt -> master
  /// m3u8 -> signed variants. Previously this only ran as Miruro's
  /// hidden fallback; now the server picker can choose it directly.

  // ------------------------------------------------------------ justanime

  /// One justanime watch call: GET the episode JSON for a provider.
  /// Null on HTTP error / API error. Shared by resolve + subtitle-only
  /// fetch so both parse the same shape.
  Future<Map<String, dynamic>?> _justAnimeWatch(
    int anilistId,
    int episode,
    String provider,
  ) async {
    final Uri uri = Uri.parse(
      '$_justAnimeApi/$anilistId/episode/$episode/$provider',
    );
    final http.Response resp = await _client
        .get(
          uri,
          headers: <String, String>{
            'User-Agent': _ua,
            'Origin': 'https://justanime.to',
            'Referer': 'https://justanime.to/',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['error'] != null) return null;
    return data;
  }

  /// Subtitle tracks out of one justanime audio block ('sub'/'dub').
  /// Accepts 'subtitles' or 'tracks', kind 'captions'/'subtitles' (or
  /// empty). Pure — unit-tested.
  static List<SubtitleInfo> _parseJustAnimeTracks(
    Map<String, dynamic> typeData,
  ) {
    final List<SubtitleInfo> subtitles = <SubtitleInfo>[];
    final List<dynamic> tracks =
        (typeData['subtitles'] as List<dynamic>?) ??
        (typeData['tracks'] as List<dynamic>?) ??
        <dynamic>[];
    for (final dynamic t in tracks) {
      final Map<String, dynamic> track = t as Map<String, dynamic>;
      final String kind = track['kind'] as String? ?? '';
      if (kind.isNotEmpty && kind != 'captions' && kind != 'subtitles') {
        continue;
      }
      final String? file =
          track['file'] as String? ??
          track['src'] as String? ??
          track['url'] as String?;
      if (file == null || file.isEmpty) continue;
      subtitles.add(
        SubtitleInfo(
          label: track['label'] as String? ?? 'Unknown',
          url: file,
        ),
      );
    }
    return subtitles;
  }

  Future<ResolvedStream?> _resolveJustAnime(
    int anilistId,
    int episode,
    String provider,
    String subDub,
  ) async {
    final Map<String, dynamic>? data = await _justAnimeWatch(
      anilistId,
      episode,
      provider,
    );
    if (data == null) return null;
    final String referer = provider == 'megaplay'
        ? _megaReferer
        : 'https://www.animegg.org/';
    final List<StreamVariant> variants = <StreamVariant>[];
    final List<SubtitleInfo> subtitles = <SubtitleInfo>[];
    String? bestUrl;
    String bestLabel = 'Miruro';

    // Preferred audio first (sub or dub), then the other.
    final List<String> audios = subDub == 'Dub'
        ? <String>['dub', 'sub']
        : <String>['sub', 'dub'];
    for (final String audio in audios) {
      final Map<String, dynamic>? typeData =
          data[audio] as Map<String, dynamic>?;
      if (typeData == null) continue;
      subtitles.addAll(_parseJustAnimeTracks(typeData));
      final List<dynamic> sources =
          typeData['sources'] as List<dynamic>? ?? <dynamic>[];
      for (final dynamic s in sources) {
        final Map<String, dynamic> source = s as Map<String, dynamic>;
        final String? url = source['url'] as String?;
        if (url == null || url.isEmpty) continue;
        final bool isM3u8 =
            source['isM3U8'] == true || url.contains('.m3u8');
        final String? quality = source['quality'] as String?;
        if (provider == 'megaplay' &&
            isM3u8 &&
            (quality == null || quality == 'auto')) {
          final List<StreamVariant> expanded = await resolveMasterPlaylist(
            url,
            referer,
          );
          if (expanded.isNotEmpty) {
            variants.addAll(expanded);
            bestUrl ??= expanded.first.url;
            bestLabel = 'Miruro MegaPlay ${expanded.first.qualityLabel}';
            continue;
          }
        }
        bestUrl ??= url;
        bestLabel =
            'Miruro ${provider == 'megaplay' ? 'MegaPlay' : 'AnimeGG'}'
            '${quality != null && quality.isNotEmpty ? ' $quality' : ''}';
      }
      if (bestUrl != null) break;
    }
    if (bestUrl == null) return null;
    return ResolvedStream(
      url: bestUrl,
      label: bestLabel,
      source: 'Miruro',
      headers: <String, String>{
        'User-Agent': _ua,
        'Referer': referer,
        'Origin': provider == 'megaplay'
            ? _megaHost
            : 'https://www.animegg.org',
      },
      variants: variants,
      subtitles: subtitles,
    );
  }

  /// Fetch a master .m3u8 and expand it into quality variants.
  /// Variant URLs are relative to the master; the master's ?token= is
  /// only needed for the master request itself.
  Future<List<StreamVariant>> resolveMasterPlaylist(
    String masterUrl,
    String referer,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(masterUrl),
            headers: <String, String>{
              'User-Agent': _ua,
              'Referer': referer,
            },
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <StreamVariant>[];
      return parseMasterPlaylist(resp.body, masterUrl);
    } catch (_) {
      return <StreamVariant>[];
    }
  }

  /// Parse a master playlist body into variants. Pure — unit-tested.
  static List<StreamVariant> parseMasterPlaylist(
    String body,
    String masterUrl,
  ) {
    if (!body.contains('#EXT-X-STREAM-INF')) return <StreamVariant>[];
    final List<StreamVariant> variants = <StreamVariant>[];
    final List<String> lines = body.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final RegExpMatch? m = RegExp(
        r'RESOLUTION=\d+x(\d+)',
      ).firstMatch(line);
      final int? height = m == null ? null : int.tryParse(m.group(1)!);
      for (int j = i + 1; j < lines.length; j++) {
        final String u = lines[j].trim();
        if (u.isEmpty || u.startsWith('#')) continue;
        final String full = u.startsWith('http')
            ? u
            : Uri.parse(masterUrl).resolve(u).toString();
        variants.add(
          StreamVariant(
            url: full,
            qualityLabel: height != null ? '${height}p' : 'Auto',
          ),
        );
        break;
      }
    }
    variants.sort((StreamVariant a, StreamVariant b) {
      final int qa = int.tryParse(a.qualityLabel.replaceAll('p', '')) ?? 0;
      final int qb = int.tryParse(b.qualityLabel.replaceAll('p', '')) ?? 0;
      return qb.compareTo(qa);
    });
    return variants;
  }

  // ------------------------------------------------------------- Anikoto

  Future<ResolvedStream?> resolveAnikoto(
    String title,
    int episode,
    String subDub, {
    int? seasonNumber,
  }) async {
    // 1. Search anikoto.cz by title.
    final http.Response searchResp = await _client
        .get(
          Uri.parse(
            '$_anikotoUrl/filter?keyword=${Uri.encodeComponent(title.trim())}',
          ),
          headers: _akPageHeaders(null),
        )
        .timeout(const Duration(seconds: 12));
    if (searchResp.statusCode != 200) return null;
    final dom.Document searchDoc = html_parser.parse(searchResp.body);
    final List<({String title, String href})> results =
        <({String title, String href})>[];
    for (final dom.Element item in searchDoc.querySelectorAll(
      'div#list-items div.item',
    )) {
      final dom.Element? posterA = item.querySelector(
        'div.ani.poster a[href]',
      );
      if (posterA == null) continue;
      String href = posterA.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      href = href.split('/ep-').first;
      final String t =
          item.querySelector('a.name.d-title')?.text.trim() ??
          posterA.querySelector('img')?.attributes['alt']?.trim() ??
          '';
      if (t.isEmpty) continue;
      results.add((title: t, href: href));
    }
    if (results.isEmpty) return null;
    final String normQ = normalizeTitle(title);
    String? watchHref;
    if (seasonNumber != null) {
      // 0.2.30: every season shares the AniList title, so the bare
      // title match below is always S1 — match the site's season
      // suffix ("Title 2", "Title 5th Season", "Title Season 6")
      // first. No season match here = fall through to the old
      // rules, never a dead end.
      watchHref = results
          .where((r) => seasonTitleMatches(r.title, title, seasonNumber))
          .map((r) => r.href)
          .firstOrNull;
    }
    watchHref ??= results
            .where((r) => normalizeTitle(r.title) == normQ)
            .map((r) => r.href)
            .firstOrNull ??
        results
            .where((r) {
              final String n = normalizeTitle(r.title);
              return n.contains(normQ) || normQ.contains(n);
            })
            .map((r) => r.href)
            .firstOrNull ??
        results.first.href;
    final String watchUrl = watchHref.startsWith('http')
        ? watchHref
        : _anikotoUrl + watchHref;

    // 2. Watch page -> animeId.
    final http.Response watchResp = await _client
        .get(Uri.parse(watchUrl), headers: _akPageHeaders(null))
        .timeout(const Duration(seconds: 12));
    if (watchResp.statusCode != 200) return null;
    final dom.Document watchDoc = html_parser.parse(watchResp.body);
    final String? animeId = watchDoc
        .querySelector('[data-anime-id]')
        ?.attributes['data-anime-id']
        ?.trim();
    if (animeId == null || animeId.isEmpty) return null;

    // 3. Episode list -> data-ids token for this episode.
    final String? token = await _akEpisodeToken(watchUrl, animeId, episode);
    if (token == null) return null;

    // 4. Server list -> SUB first (HD-1 first), else DUB.
    final List<_AkServer> servers = await _akServers(watchUrl, token);
    if (servers.isEmpty) return null;
    final Set<String> seenEmbeds = <String>{};
    final List<String> wantTypes = subDub == 'Dub'
        ? <String>['dub', 'sub']
        : <String>['sub', 'dub'];
    for (final String wantType in wantTypes) {
      final List<_AkServer> typed = servers
          .where((s) => s.type == wantType)
          .toList();
      typed.sort((a, b) {
        final bool aHd = a.name.toLowerCase().contains('hd-1');
        final bool bHd = b.name.toLowerCase().contains('hd-1');
        if (aHd != bHd) return aHd ? -1 : 1;
        return servers.indexOf(a).compareTo(servers.indexOf(b));
      });
      for (final _AkServer server in typed) {
        try {
          final String? embedUrl = await _akServerEmbed(
            watchUrl,
            server.linkId,
          );
          if (embedUrl == null || !seenEmbeds.add(embedUrl)) continue;
          final ResolvedStream? stream = await _resolveMegaplayEmbed(
            embedUrl,
            watchUrl,
            wantType == 'dub' ? 'DUB' : 'SUB',
          );
          if (stream != null) return stream;
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  Future<String?> _akEpisodeToken(
    String watchUrl,
    String animeId,
    int episode,
  ) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse('$_anikotoUrl/ajax/episode/list/$animeId'),
            headers: _akAjaxHeaders(watchUrl),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final String? html = json['result'] as String?;
      if (html == null) return null;
      final dom.Document doc = html_parser.parse(html);
      for (final dom.Element a in doc.querySelectorAll(
        'a[data-id][data-num][data-ids]',
      )) {
        if (int.tryParse(a.attributes['data-num'] ?? '') == episode) {
          final String ids = a.attributes['data-ids']?.trim() ?? '';
          if (ids.isNotEmpty) return ids;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<List<_AkServer>> _akServers(String watchUrl, String token) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_anikotoUrl/ajax/server/list?servers=${Uri.encodeComponent(token)}',
            ),
            headers: _akAjaxHeaders(watchUrl),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return <_AkServer>[];
      final Map<String, dynamic> json =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final String? html = json['result'] as String?;
      if (html == null) return <_AkServer>[];
      final dom.Document doc = html_parser.parse(html);
      final List<_AkServer> out = <_AkServer>[];
      for (final dom.Element typeDiv in doc.querySelectorAll(
        'div.type[data-type]',
      )) {
        final String type = (typeDiv.attributes['data-type'] ?? '')
            .trim()
            .toLowerCase();
        for (final dom.Element li in typeDiv.querySelectorAll(
          'li[data-link-id]',
        )) {
          final String linkId = li.attributes['data-link-id']?.trim() ?? '';
          if (linkId.isEmpty) continue;
          out.add(
            _AkServer(type: type, name: li.text.trim(), linkId: linkId),
          );
        }
      }
      return out;
    } catch (_) {
      return <_AkServer>[];
    }
  }

  Future<String?> _akServerEmbed(String watchUrl, String linkId) async {
    try {
      final http.Response resp = await _client
          .get(
            Uri.parse(
              '$_anikotoUrl/ajax/server?get=${Uri.encodeComponent(linkId)}',
            ),
            headers: _akAjaxHeaders(watchUrl),
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

  /// Resolve one megaplay embed URL to a playable stream. Public
  /// so the AniSuge / AniKage resolvers can reuse it — some of
  /// their titles serve megaplay embeds (e.g. Demon Slayer EP1
  /// sub: `megaplay.buzz/stream/s-2/1279/sub`), and the megaplay
  /// chain (getSources -> AES decrypt -> signed master) lives
  /// here, in one place. [watchUrl] is the Referer for the
  /// embed-page fetch. The returned stream carries Miruro's
  /// label/source — callers re-label it.
  Future<ResolvedStream?> resolveMegaplayEmbed({
    required String embedUrl,
    required String subDub,
    String? watchUrl,
  }) =>
      _resolveMegaplayEmbed(
        embedUrl,
        watchUrl ?? embedUrl,
        subDub == 'Dub' ? 'DUB' : 'SUB',
      );

  /// Resolve one megaplay embed URL: getSources THEN getSourcesNew,
  /// "sources" first else AES-decrypted "enc" -> master -> sign ->
  /// expand into quality variants.
  Future<ResolvedStream?> _resolveMegaplayEmbed(
    String embedUrl,
    String watchUrl,
    String tag,
  ) async {
    final http.Response embedResp = await _client
        .get(Uri.parse(embedUrl), headers: _akPageHeaders(watchUrl))
        .timeout(const Duration(seconds: 12));
    if (embedResp.statusCode != 200) return null;
    final dom.Document doc = html_parser.parse(embedResp.body);
    final dom.Element? player = doc.querySelector('#megaplay-player');
    if (player == null) return null;
    final List<String> ids = <String>[
      player.attributes['data-id']?.trim() ?? '',
      player.attributes['data-realid']?.trim() ?? '',
    ].where((s) => s.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return null;
    final String type = tag == 'DUB' ? 'dub' : 'sub';
    final String host = () {
      try {
        return 'https://${Uri.parse(embedUrl).host}';
      } catch (_) {
        return _megaHost;
      }
    }();
    final List<String> endpoints = host.contains('megaplay.buzz')
        ? <String>['/stream/getSources', '/stream/getSourcesNew']
        : <String>['/stream/getSourcesNew', '/stream/getSources'];
    for (final String id in ids) {
      for (final String path in endpoints) {
        try {
          final http.Response resp = await _client
              .get(
                Uri.parse('$host$path?id=$id&type=$type'),
                headers: _megaAjaxHeaders(embedUrl),
              )
              .timeout(const Duration(seconds: 12));
          if (resp.statusCode != 200) continue;
          final Map<String, dynamic> json =
              jsonDecode(resp.body) as Map<String, dynamic>;
          String? file;
          final Object? sources = json['sources'];
          if (sources is Map<String, dynamic>) {
            final String f = sources['file'] as String? ?? '';
            if (f.isNotEmpty) file = f;
          } else if (sources is List<dynamic> && sources.isNotEmpty) {
            final Map<String, dynamic>? first =
                sources.first as Map<String, dynamic>?;
            final String f = first?['file'] as String? ?? '';
            if (f.isNotEmpty) file = f;
          }
          if (file == null) {
            final String enc = json['enc'] as String? ?? '';
            if (enc.isNotEmpty) {
              final String? plain = decryptMegaplay(enc);
              if (plain != null) file = fileFromJsonText(plain);
            }
          }
          final String master = file?.trim() ?? '';
          if (master.isEmpty) continue;
          final String signed = signMegaPlayUrl(master);
          final List<SubtitleInfo> subtitles = <SubtitleInfo>[];
          final List<dynamic> tracks =
              json['tracks'] as List<dynamic>? ?? <dynamic>[];
          for (final dynamic t in tracks) {
            final Map<String, dynamic> track = t as Map<String, dynamic>;
            final String kind = track['kind'] as String? ?? '';
            // Same rule as the justanime path: empty kind is a
            // subtitle track too (0.2.3 — the strict filter dropped
            // tracks here that the justanime path kept).
            if (kind.isNotEmpty &&
                kind != 'captions' &&
                kind != 'subtitles') {
              continue;
            }
            final String f =
                (track['file'] as String? ?? '').isNotEmpty
                    ? track['file'] as String
                    : (track['src'] as String? ??
                          track['url'] as String? ??
                          '');
            if (f.isEmpty) continue;
            subtitles.add(
              SubtitleInfo(
                label: track['label'] as String? ?? 'Unknown',
                url: f,
              ),
            );
          }
          final List<StreamVariant> variants = await resolveMasterPlaylist(
            signed,
            _megaReferer,
          );
          final Map<String, String> headers = <String, String>{
            'User-Agent': _ua,
            'Accept': '*/*',
            'Origin': _megaHost,
            'Referer': _megaReferer,
          };
          if (variants.isNotEmpty) {
            return ResolvedStream(
              url: variants.first.url,
              label: 'Miruro MegaPlay [$tag] ${variants.first.qualityLabel}',
              source: 'Anikoto',
              headers: headers,
              variants: variants,
              subtitles: subtitles,
            );
          }
          return ResolvedStream(
            url: signed,
            label: 'Miruro MegaPlay [$tag] 1080p',
            source: 'Anikoto',
            headers: headers,
            subtitles: subtitles,
          );
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  Map<String, String> _akPageHeaders(String? referer) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': _ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    };
    if (referer != null) headers['Referer'] = referer;
    return headers;
  }

  Map<String, String> _akAjaxHeaders(String? referer) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': _ua,
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    };
    if (referer != null) headers['Referer'] = referer;
    return headers;
  }

  Map<String, String> _megaAjaxHeaders(String embedUrl) {
    return <String, String>{
      'User-Agent': _ua,
      'Accept': '*/*',
      'X-Requested-With': 'XMLHttpRequest',
      'Origin': _megaHost,
      'Referer': embedUrl,
    };
  }

  // ------------------------------------------------------------ crypto

  /// AES-256-CBC decrypt of megaplay's getSources "enc" (base64url).
  /// Normalizes the base64url alphabet + pads before decoding.
  /// Pure — unit-tested (round-trip).
  static String? decryptMegaplay(String enc) {
    try {
      final String normalized = enc.replaceAll('-', '+').replaceAll('_', '/');
      final String padded =
          normalized + '=' * ((4 - normalized.length % 4) % 4);
      final Uint8List ct = base64Decode(padded);
      // Zero-pad the 17-byte key to 32 bytes (AES-256).
      final Uint8List key = Uint8List(32);
      final List<int> rawKey = utf8.encode(megaKey);
      key.setRange(0, rawKey.length, rawKey);
      final Uint8List iv = Uint8List.fromList(utf8.encode(megaIv));
      final PaddedBlockCipherImpl cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      );
      cipher.init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
      final Uint8List plain = cipher.process(ct);
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// AES-256-CBC encrypt (test helper + symmetry check). Not used at
  /// runtime.
  static String encryptMegaplay(String plain) {
    final Uint8List key = Uint8List(32);
    final List<int> rawKey = utf8.encode(megaKey);
    key.setRange(0, rawKey.length, rawKey);
    final Uint8List iv = Uint8List.fromList(utf8.encode(megaIv));
    final PaddedBlockCipherImpl cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
    final Uint8List ct = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return base64UrlEncode(ct).replaceAll('=', '');
  }

  /// Pull the "file" (master .m3u8) out of a getSources JSON text.
  /// Pure — unit-tested.
  static String? fileFromJsonText(String json) {
    try {
      final String trimmed = json.trim();
      if (trimmed.startsWith('[')) {
        final List<dynamic> arr = jsonDecode(trimmed) as List<dynamic>;
        if (arr.isEmpty) return null;
        final String? file =
            (arr.first as Map<String, dynamic>?)?['file'] as String?;
        return file?.isEmpty == true ? null : file;
      }
      final Map<String, dynamic> obj =
          jsonDecode(trimmed) as Map<String, dynamic>;
      final String? file = obj['file'] as String?;
      return file?.isEmpty == true ? null : file;
    } catch (_) {
      return null;
    }
  }

  /// HMAC-SHA256 signature on a megaplay master URL (Anikoto v3 /
  /// Phisher signMegaPlayUrl). Payload = "`<expiry>|<hash1>/<hash2>`"
  /// (expiry = now + 90 s); token = base64url(payload) + "."
  /// + base64url(HMAC-SHA256(payload)). Pure — unit-tested.
  static String signMegaPlayUrl(String url, {int? nowSeconds}) {
    try {
      if (url.contains('token=')) return url;
      final RegExpMatch? m = RegExp(
        r'/([a-f0-9]{32})/([a-f0-9]{32})/',
        caseSensitive: false,
      ).firstMatch(url);
      if (m == null) return url;
      final int expiry =
          (nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000) + 90;
      final String payload = '$expiry|${m.group(1)}/${m.group(2)}';
      final Hmac hmac = Hmac(
        sha256,
        utf8.encode(megaTokenSecret),
      );
      final List<int> sig = hmac.convert(utf8.encode(payload)).bytes;
      final String payloadB64 = base64UrlEncode(
        utf8.encode(payload),
      ).replaceAll('=', '');
      final String sigB64 = base64UrlEncode(sig).replaceAll('=', '');
      final String token = '$payloadB64.$sigB64';
      final String sep = url.contains('?') ? '&' : '?';
      return '$url${sep}token=$token';
    } catch (_) {
      return url;
    }
  }
}

class _AkServer {
  const _AkServer({required this.type, required this.name, required this.linkId});

  final String type;
  final String name;
  final String linkId;
}
