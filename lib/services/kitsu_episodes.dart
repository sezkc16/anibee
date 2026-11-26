import 'dart:convert';

import 'package:http/http.dart' as http;

/// Real per-season episode metadata from Kitsu (0.2.31).
///
/// WHY: the Detail episode list was built from [mockEpisodes], so
/// every season showed the same fake rotating titles/synopses/dates
/// ("Infiltration Protocol", Sep 5 2026, ...) — the 0.2.30 phone
/// test proved it (S5 selected, count right at 25, cards all S1's
/// fake data). AniList has no real episode titles — its
/// `streamingEpisodes` titles are just "Episode 1" — and no air
/// dates per episode. Kitsu (`kitsu.io/api/edge`) is public,
/// keyless, and VERIFIED LIVE from the VM for the exact failing
/// case: AniList 117193 (MHA S5) maps to Kitsu anime 43108
/// ("Boku no Hero Academia 5", 25 eps), EP1 "All Hands on Deck!
/// Class 1-A", 2021-03-27, with a real still thumbnail.
///
/// Flow: mappings (AniList id -> Kitsu anime id) -> episodes
/// (paged, sort=number). Never throws — any failure returns an
/// empty list and the caller keeps the neutral 'Episode N'
/// placeholders. Never fabricates a title, synopsis or date.
class KitsuEpisodes {
  KitsuEpisodes({this._client});

  static const String _host = 'kitsu.io';

  /// In-memory cache by AniList id. Only non-empty results are
  /// cached — a failed first call (offline) must not poison the
  /// list for the rest of the session.
  final Map<int, List<KitsuEpisodeMeta>> _cache =
      <int, List<KitsuEpisodeMeta>>{};

  final http.Client? _client;

  Future<List<KitsuEpisodeMeta>> fetchForAnilistId(
    int anilistId, {
    int episodeCount = 0,
  }) async {
    final List<KitsuEpisodeMeta>? cached = _cache[anilistId];
    if (cached != null) return cached;
    final List<KitsuEpisodeMeta> metas =
        await _fetchUncached(anilistId, episodeCount: episodeCount);
    if (metas.isNotEmpty) _cache[anilistId] = metas;
    return metas;
  }

  Future<List<KitsuEpisodeMeta>> _fetchUncached(
    int anilistId, {
    int episodeCount = 0,
  }) async {
    final http.Client client = _client ?? http.Client();
    try {
      final String? itemUrl = await _mappingItemUrl(client, anilistId);
      if (itemUrl == null) return <KitsuEpisodeMeta>[];
      final Map<String, dynamic>? item =
          await _getJson(client, Uri.parse(itemUrl));
      final String? kitsuId = (item?['data'] as Map<String, dynamic>?)?['id']
          as String?;
      if (kitsuId == null || kitsuId.isEmpty) {
        return <KitsuEpisodeMeta>[];
      }
      // Awaited (not returned directly): the finally below closes
      // the owned client, which must happen AFTER the fetch.
      return await _fetchEpisodes(client, kitsuId, episodeCount: episodeCount);
    } catch (_) {
      return <KitsuEpisodeMeta>[];
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Mappings lookup: first `anilist/anime` mapping for this
  /// AniList id -> its `item` (the Kitsu anime) URL. Null when
  /// Kitsu has no mapping for the id.
  Future<String?> _mappingItemUrl(http.Client client, int anilistId) async {
    final Map<String, dynamic>? json = await _getJson(
      client,
      Uri.https(_host, '/api/edge/mappings', <String, String>{
        'filter[externalSite]': 'anilist/anime',
        'filter[externalId]': '$anilistId',
      }),
    );
    return parseMappingItemUrl(json);
  }

  /// Episodes for one Kitsu anime id, in number order. Pages of 20
  /// until the season's episode count is covered (or 6 pages —
  /// 120 episodes — whichever comes first; the card list only
  /// renders for seasons of 24 or fewer, the grid needs no titles).
  Future<List<KitsuEpisodeMeta>> _fetchEpisodes(
    http.Client client,
    String kitsuId, {
    int episodeCount = 0,
  }) async {
    final int target = episodeCount > 0 ? episodeCount : 20;
    final List<KitsuEpisodeMeta> metas = <KitsuEpisodeMeta>[];
    Uri? next = Uri.https(
      _host,
      '/api/edge/anime/$kitsuId/episodes',
      <String, String>{'page[limit]': '20', 'sort': 'number'},
    );
    int pages = 0;
    while (next != null && metas.length < target && pages < 6) {
      pages++;
      final Map<String, dynamic>? json = await _getJson(client, next);
      if (json == null) break;
      final List<dynamic> data = json['data'] as List<dynamic>? ?? <dynamic>[];
      for (final dynamic raw in data) {
        if (raw is Map<String, dynamic>) {
          final KitsuEpisodeMeta? meta = parseEpisode(raw);
          if (meta != null) metas.add(meta);
        }
      }
      final String? nextUrl =
          (json['links'] as Map<String, dynamic>?)?['next'] as String?;
      next = nextUrl == null || nextUrl.isEmpty ? null : Uri.parse(nextUrl);
    }
    metas.sort((KitsuEpisodeMeta a, KitsuEpisodeMeta b) =>
        a.number.compareTo(b.number));
    final Map<int, KitsuEpisodeMeta> byNumber = <int, KitsuEpisodeMeta>{};
    for (final KitsuEpisodeMeta meta in metas) {
      byNumber.putIfAbsent(meta.number, () => meta);
    }
    return byNumber.values.toList()
      ..sort((KitsuEpisodeMeta a, KitsuEpisodeMeta b) =>
          a.number.compareTo(b.number));
  }

  Future<Map<String, dynamic>?> _getJson(http.Client client, Uri uri) async {
    final http.Response resp = await client
        .get(uri, headers: <String, String>{'Accept': 'application/vnd.api+json'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final dynamic decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  /// Pure — unit-tested. First mapping's `item` related URL, or
  /// null when the mappings response has no usable entry.
  static String? parseMappingItemUrl(Map<String, dynamic>? json) {
    final List<dynamic> data = json?['data'] as List<dynamic>? ?? <dynamic>[];
    if (data.isEmpty) return null;
    final dynamic first = data.first;
    if (first is! Map<String, dynamic>) return null;
    final Map<String, dynamic>? item =
        (first['relationships'] as Map<String, dynamic>?)?['item']
            as Map<String, dynamic>?;
    final String? url =
        (item?['links'] as Map<String, dynamic>?)?['related'] as String?;
    return url == null || url.isEmpty ? null : url;
  }

  /// Pure — unit-tested. One Kitsu episode JSON object -> metadata,
  /// or null when it has no usable episode number. A missing title
  /// / synopsis / air date stays null (the caller keeps the
  /// neutral 'Episode N' placeholder) — never invented.
  static KitsuEpisodeMeta? parseEpisode(Map<String, dynamic> raw) {
    final dynamic attrsRaw = raw['attributes'];
    if (attrsRaw is! Map) return null;
    final Map<String, dynamic> attrs = Map<String, dynamic>.from(attrsRaw);
    final int? number = (attrs['number'] as num?)?.toInt();
    if (number == null || number <= 0) return null;
    String? text(dynamic value) {
      if (value is! String) return null;
      final String trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final dynamic thumbRaw = attrs['thumbnail'];
    final String? thumb = thumbRaw is Map
        ? Map<String, dynamic>.from(thumbRaw)['original'] as String?
        : null;
    return KitsuEpisodeMeta(
      number: number,
      title: text(attrs['canonicalTitle']),
      synopsis: text(attrs['synopsis']) ?? text(attrs['description']),
      airDate: formatAirDate(attrs['airdate'] as String?),
      thumbnailUrl: thumb == null || thumb.isEmpty ? null : thumb,
      lengthMinutes: (attrs['length'] as num?)?.toInt(),
    );
  }

  /// Pure — unit-tested. '2021-03-27' -> 'Mar 27, 2021' (the
  /// format the episode cards already use). Null on any bad input.
  static String? formatAirDate(String? raw) {
    if (raw == null || raw.length < 10) return null;
    final int? year = int.tryParse(raw.substring(0, 4));
    final int? month = int.tryParse(raw.substring(5, 7));
    final int? day = int.tryParse(raw.substring(8, 10));
    if (year == null ||
        month == null ||
        day == null ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      return null;
    }
    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[month - 1]} $day, $year';
  }
}

/// One episode's real metadata from Kitsu. Every field except
/// [number] is nullable — null means Kitsu has no data for it, and
/// the caller must keep the neutral placeholder, never invent one.
class KitsuEpisodeMeta {
  const KitsuEpisodeMeta({
    required this.number,
    this.title,
    this.synopsis,
    this.airDate,
    this.thumbnailUrl,
    this.lengthMinutes,
  });

  final int number;
  final String? title;
  final String? synopsis;

  /// Formatted air date, e.g. 'Mar 27, 2021'. Null = unknown.
  final String? airDate;
  final String? thumbnailUrl;

  /// Episode length in whole minutes (Kitsu `length`). Null =
  /// unknown.
  final int? lengthMinutes;

  /// 'mm:ss' duration for the Episode model, e.g. 24 -> '24:00'.
  /// Null when the length is unknown (the placeholder default
  /// stays).
  String? get durationString =>
      lengthMinutes == null ? null : '$lengthMinutes:00';
}
