import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'airing_format.dart';
import 'kitsu_search.dart';
import '../models.dart';

/// AniList GraphQL — metadata, search, lists, progress sync.
/// Public queries need no key; user sync needs an OAuth token (M2).
/// Endpoint: https://graphql.anilist.co (30 req/min, no key).

/// One entry of the user's AniList list (0.2.11 two-way sync).
typedef AnilistListEntry = ({Anime anime, String status, int progress});

/// Title variants + year + format for one AniList id (0.2.12) —
/// what the title matchers need (see [AniListService.mediaIdentity]).
class AnilistIdentity {
  const AnilistIdentity({
    required this.titles,
    this.year,
    this.format,
    this.episodes,
    this.status,
  });

  /// romaji / english / native, in that order, non-empty only.
  final List<String> titles;
  final int? year;
  final String? format;
  final int? episodes;
  final String? status;
}

/// What the last AniList search lookup actually did (0.2.13) —
/// shown on the Search screen so the phone test can tell a dead
/// lookup from a genuine no-match: `ok: false` = the lookup
/// itself failed ([error] says why); `rawMediaCount` is what
/// AniList returned before mapping, `mappedCount` what survived
/// `animeFromMedia`.
class SearchDiagnostic {
  const SearchDiagnostic({
    required this.query,
    required this.ok,
    this.error,
    this.rawMediaCount = 0,
    this.mappedCount = 0,
    required this.attempts,
    this.source = 'anilist',
    this.variables,
    this.droppedCount = 0,
  });

  final String query;
  final bool ok;
  final String? error;
  final int rawMediaCount;
  final int mappedCount;
  final int attempts;

  /// Which path produced the results (0.2.15): 'anilist' (the full
  /// filtered query), 'anilist-simplified' (the minimal retry),
  /// 'kitsu' (the Kitsu fallback), 'none' (every path came back
  /// empty — a genuine no-match).
  final String source;

  /// The exact variables the primary AniList call was sent with
  /// (0.2.15), e.g. "q=noblesse · genre=All · year=All ·
  /// status=All · format=All" — shown when the primary returns 0,
  /// so the phone can prove what was asked for.
  final String? variables;

  /// Kitsu entries dropped for having no AniList id (0.2.15) —
  /// shown, never silently hidden.
  final int droppedCount;

  /// One short line for the Search screen, e.g. "ok · 12 from
  /// AniList" / "failed (HTTP 403) · local only". The plain primary
  /// path keeps its exact 0.2.13 text; every other path names
  /// itself so the phone can tell them apart.
  String get summary {
    if (!ok) return 'failed (${error ?? 'unknown'}) · local only';
    if (source == 'anilist-simplified') {
      return 'ok · $mappedCount from AniList (simplified retry)';
    }
    if (source == 'kitsu') {
      final String why = error == null
          ? 'AniList empty'
          : 'AniList failed: $error';
      final String dropped =
          droppedCount > 0 ? ' · $droppedCount unmapped' : '';
      return 'ok · $mappedCount from Kitsu ($why)$dropped';
    }
    if (rawMediaCount == mappedCount) {
      if (mappedCount == 0 && variables != null) {
        return 'ok · 0 from AniList · $variables';
      }
      return 'ok · $mappedCount from AniList';
    }
    return 'ok · $mappedCount shown ($rawMediaCount from AniList)';
  }
}

class AniListService {
  AniListService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String graphqlUrl = 'https://graphql.anilist.co';
  static const String _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) AniBee/0.2.1';

  /// What the LAST AniList search lookup actually did (0.2.13) —
  /// the phone-visible diagnostic. `ok: false` means the lookup
  /// itself failed (see [error]); `rawMediaCount` is what AniList
  /// returned before mapping, `mappedCount` what survived
  /// `animeFromMedia` — if raw > mapped, entries were dropped by
  /// the mapper; if raw == 0, AniList genuinely returned nothing.
  SearchDiagnostic? _lastSearchDiagnostic;

  /// The last search diagnostic, or null before any search.
  SearchDiagnostic? get lastSearchDiagnostic => _lastSearchDiagnostic;

  /// Search AniList by title, with optional filters (0.2.11).
  /// Filters map to AniList's own args: genre, seasonYear, status
  /// (FINISHED / RELEASING / NOT_YET_RELEASED), format (TV / MOVIE).
  /// Null = no filter. Returns Anime objects with anilistId,
  /// poster, rating, year, episode count, genres, synopsis (HTML
  /// stripped) and MAL id when present.
  ///
  /// 0.2.12: a season suffix in the query ("Black Clover S2",
  /// "Jujutsu Kaisen Season 2") matches poorly on AniList AND in
  /// the local catalogue — so when the first search finds no
  /// result for the base title, the stripped query is searched too
  /// and the results merged (dedup by anilistId). Never throws:
  /// on any failure it returns an empty list (see
  /// [searchAnimeDetailed] for the honest variant).
  Future<List<Anime>> searchAnime(
    String query, {
    int page = 1,
    String? genre,
    int? year,
    String? status,
    String? format,
  }) async {
    final ({List<Anime> results, bool lookupFailed}) r =
        await searchAnimeDetailed(
      query,
      page: page,
      genre: genre,
      year: year,
      status: status,
      format: format,
    );
    return r.results;
  }

  /// Like [searchAnime] but honest about WHY it failed (0.2.12):
  /// [lookupFailed] is true when the AniList call itself could not
  /// be reached (network / rate limit / Cloudflare), so the search
  /// screen can say so instead of showing a bare "No anime found".
  /// A genuine no-match returns `lookupFailed: false` with empty
  /// results. The season-suffix fallback (see [searchAnime]) runs
  /// inside here too — it only fires when the primary search
  /// succeeded but found nothing for the base title.
  ///
  /// 0.2.15: four paths, in order — (1) the full filtered query
  /// (one 300 ms retry on failure); (2) if AniList is DEAD, the
  /// Kitsu fallback before giving up; (3) if AniList answered but
  /// returned NOTHING, one simplified retry (minimal query, no
  /// filters at all); (4) if that is empty too, the Kitsu fallback.
  /// The final [SearchDiagnostic] names the path that produced the
  /// results (or the variables the primary call was sent with when
  /// everything came back empty), so the phone can prove what
  /// happened. [lookupFailed] is true only when AniList failed AND
  /// Kitsu had nothing either.
  Future<({List<Anime> results, bool lookupFailed})> searchAnimeDetailed(
    String query, {
    int page = 1,
    String? genre,
    int? year,
    String? status,
    String? format,
  }) async {
    final String variables = _variablesSummary(
      query,
      genre: genre,
      year: year,
      status: status,
      format: format,
    );
    // 1. PRIMARY — the full filtered query, one 300 ms retry on
    // failure (0.2.13: a single dropped request must not wipe the
    // whole search; attempts: 2 tells the phone a retry happened).
    ({List<Anime> results, bool failed, String? error, int raw, int mapped})
        primary = await _searchOnce(
      query,
      page: page,
      genre: genre,
      year: year,
      status: status,
      format: format,
    );
    int attempts = 1;
    if (primary.failed) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      primary = await _searchOnce(
        query,
        page: page,
        genre: genre,
        year: year,
        status: status,
        format: format,
      );
      attempts = 2;
    }
    String source = 'anilist';
    List<Anime> results = primary.results;
    int raw = primary.raw;
    int mapped = primary.mapped;
    int dropped = 0;
    final String? anilistError = primary.error;
    if (primary.failed) {
      // 2. AniList DEAD → Kitsu fallback before giving up. If Kitsu
      // answers, the search still succeeds — the screen shows the
      // Kitsu results and the diagnostic names the path.
      final kitsu = await KitsuSearch.search(query, client: _client);
      if (kitsu.results.isNotEmpty) {
        _writeDiagnostic(
          query: query,
          ok: true,
          error: anilistError,
          rawMediaCount: kitsu.results.length + kitsu.dropped,
          mappedCount: kitsu.results.length,
          attempts: attempts,
          source: 'kitsu',
          variables: variables,
          droppedCount: kitsu.dropped,
        );
        return (results: kitsu.results, lookupFailed: false);
      }
      _writeDiagnostic(
        query: query,
        ok: false,
        error: anilistError ?? 'unknown',
        attempts: attempts,
        source: 'anilist',
        variables: variables,
      );
      return (results: <Anime>[], lookupFailed: true);
    }
    if (results.isEmpty) {
      // 3. SIMPLIFIED RETRY — the primary call succeeded but
      // returned nothing (the 0.2.13 phone symptom: "noblesse" →
      // "ok · 0 from AniList"). Retry once with a MINIMAL query —
      // only `search` + `type:ANIME`, no filter args at all, no null
      // filter variables sent — in case some filter combination
      // makes AniList return empty.
      final simplified = await _searchOnceMinimal(query, page: page);
      if (!simplified.failed && simplified.results.isNotEmpty) {
        results = simplified.results;
        raw = simplified.raw;
        mapped = simplified.mapped;
        source = 'anilist-simplified';
      } else {
        // 4. KITSU FALLBACK — AniList genuinely has nothing for
        // this title (or the simplified retry failed too).
        final kitsu = await KitsuSearch.search(query, client: _client);
        if (kitsu.results.isNotEmpty) {
          results = kitsu.results;
          raw = kitsu.results.length + kitsu.dropped;
          mapped = kitsu.results.length;
          dropped = kitsu.dropped;
          source = 'kitsu';
        } else {
          source = 'none';
        }
      }
    }
    // 5. Season-suffix fallback (0.2.12, unchanged): "Black Clover
    // S2" has no separate AniList entry — when the results hold no
    // base-title match, search the stripped query too and merge.
    final String stripped = stripSeasonSuffix(query);
    if (stripped != query.trim()) {
      final String base = normalizeTitle(stripped);
      final bool hasBase = results.any((Anime a) {
        final String n = normalizeTitle(a.title);
        return n.contains(base) || base.contains(n);
      });
      if (!hasBase) {
        final ({List<Anime> results, bool failed, String? error, int raw, int mapped})
            extra = await _searchOnce(
          stripped,
          page: page,
          genre: genre,
          year: year,
          status: status,
          format: format,
        );
        if (!extra.failed) {
          final Set<int?> seen =
              results.map((Anime a) => a.anilistId).toSet();
          for (final Anime a in extra.results) {
            if (seen.add(a.anilistId)) results.add(a);
          }
        }
      }
    }
    _writeDiagnostic(
      query: query,
      ok: true,
      error: source == 'kitsu' ? anilistError : null,
      rawMediaCount: raw,
      mappedCount: mapped,
      attempts: attempts,
      source: source,
      variables: variables,
      droppedCount: dropped,
    );
    return (results: results, lookupFailed: false);
  }

  /// The exact variables the primary AniList call was sent with, as
  /// one short line for the diagnostic (0.2.15). Null filters read
  /// as 'All' — the UI state — so the phone can prove no filter was
  /// excluding the title.
  static String _variablesSummary(
    String query, {
    String? genre,
    int? year,
    String? status,
    String? format,
  }) {
    return 'q=${query.trim()} · genre=${genre ?? 'All'} · '
        'year=${year?.toString() ?? 'All'} · status=${status ?? 'All'} · '
        'format=${format ?? 'All'}';
  }

  /// Record the final search diagnostic (0.2.15): one write per
  /// [searchAnimeDetailed] call, naming the path that produced the
  /// results — the per-call writes used to live inside [_searchOnce],
  /// which made the diagnostic lie about multi-path searches.
  void _writeDiagnostic({
    required String query,
    required bool ok,
    String? error,
    int rawMediaCount = 0,
    int mappedCount = 0,
    required int attempts,
    String source = 'anilist',
    String? variables,
    int droppedCount = 0,
  }) {
    _lastSearchDiagnostic = SearchDiagnostic(
      query: query,
      ok: ok,
      error: error,
      rawMediaCount: rawMediaCount,
      mappedCount: mappedCount,
      attempts: attempts,
      source: source,
      variables: variables,
      droppedCount: droppedCount,
    );
  }

  /// One AniList search page with the full filtered query. Returns
  /// `failed: true` (empty results) when the GraphQL call throws —
  /// the caller decides what the failure means.
  ///
  /// 0.2.13: a null `data` (or a missing `Page`) is ALSO a failure.
  /// Before, `_post` returning null data — a 200 with no `data`
  /// key — fell through to `media = []` and came back as an empty
  /// SUCCESS, which is exactly the 0.2.12 phone symptom ("noblesse"
  /// = 0 results, no "Couldn't reach AniList" banner): the lookup
  /// had failed, but the screen was told it succeeded with nothing.
  ///
  /// 0.2.15: the diagnostic is NO LONGER written here — one search
  /// can take up to four paths (primary / retry / simplified /
  /// Kitsu) and only [searchAnimeDetailed] knows which one won, so
  /// it writes the single final diagnostic. This method just
  /// reports its own outcome (error / raw / mapped counts).
  Future<({List<Anime> results, bool failed, String? error, int raw, int mapped})>
      _searchOnce(
    String query, {
    int page = 1,
    String? genre,
    int? year,
    String? status,
    String? format,
  }) async {
    return _executeSearch(
      _searchQuery,
      searchVariables(
        query,
        page: page,
        genre: genre,
        year: year,
        status: status,
        format: format,
      ),
    );
  }

  /// Minimal search (0.2.15): only `search` + `type:ANIME` — no
  /// filter args at all, and NO null filter variables are sent. The
  /// simplified retry when the full filtered query returns 0: if
  /// some filter combination makes AniList return empty, this is
  /// the query that proves it.
  Future<({List<Anime> results, bool failed, String? error, int raw, int mapped})>
      _searchOnceMinimal(String query, {int page = 1}) async {
    return _executeSearch(
      _searchQueryMinimal,
      <String, Object?>{'p': page, 'n': 20, 'q': query.trim()},
    );
  }

  /// Run one AniList search page and map it. Shared by [_searchOnce]
  /// and [_searchOnceMinimal] so the two queries cannot drift apart
  /// in failure handling.
  Future<({List<Anime> results, bool failed, String? error, int raw, int mapped})>
      _executeSearch(
    String queryString,
    Map<String, Object?> variables,
  ) async {
    late final Map<String, dynamic>? data;
    try {
      data = await _post(queryString, variables);
    } catch (e) {
      return (
        results: <Anime>[],
        failed: true,
        error: _shortSearchError(e),
        raw: 0,
        mapped: 0,
      );
    }
    final List<dynamic>? media =
        (data?['Page'] as Map<String, dynamic>?)?['media']
            as List<dynamic>?;
    if (data == null || media == null) {
      // A 200 with no data / no Page is a broken lookup, not a
      // genuine no-match — report it as a failure so the screen
      // shows the "Couldn't reach AniList" banner instead of a
      // bare "0 results".
      return (
        results: <Anime>[],
        failed: true,
        error: 'no data',
        raw: 0,
        mapped: 0,
      );
    }
    final List<Anime> mapped = media
        .map((dynamic e) => animeFromMedia(e as Map<String, dynamic>))
        .whereType<Anime>()
        .toList();
    return (
      results: mapped,
      failed: false,
      error: null,
      raw: media.length,
      mapped: mapped.length,
    );
  }

  /// Short human-readable cause for a search failure, for the
  /// phone-visible diagnostic ("HTTP 403", "rate limited",
  /// "timeout", "network"). Pure.
  static String _shortSearchError(Object e) {
    if (e is AniListException) {
      final String m = e.message;
      if (m.startsWith('AniList HTTP ')) return m.substring('AniList '.length);
      if (m.startsWith('Rate limited')) return 'rate limited';
      return m;
    }
    if (e is TimeoutException) return 'timeout';
    return 'network';
  }

  /// Strip a trailing season marker from a search query (0.2.12):
  /// "Black Clover S2" / "S02" / "Season 2" / "2nd Season" /
  /// "Part 2" → "Black Clover". AniList's fuzzy `search:` and the
  /// local `contains` match both miss on the suffix, and "Black
  /// Clover S2" has no separate AniList entry (one 170-episode
  /// series + an upcoming season entry under the base name). Pure —
  /// unit-tested. Only a TRAILING marker is stripped; a bare
  /// trailing number ("Black Clover 2") is left alone — it can be
  /// a different title.
  static String stripSeasonSuffix(String query) {
    String q = query.trim();
    // "2nd Season" / "3rd Season" (also without the space: "2ndSeason").
    q = q.replaceAll(
      RegExp(r'\s*\d+(?:st|nd|rd|th)\s*Season$', caseSensitive: false),
      '',
    );
    // "Season 2" / "Season2".
    q = q.replaceAll(
      RegExp(r'\s*Season\s*\d{1,2}$', caseSensitive: false),
      '',
    );
    // "S2" / "S02" (word-boundary so "Class S2" keeps its meaning…
    // it doesn't: "S2" alone at the end is always a season marker
    // in a search box; "Naruto S2" means season 2 of Naruto).
    q = q.replaceAll(RegExp(r'\s+S\d{1,2}$', caseSensitive: false), '');
    // "Part 2" / "Part2" — e.g. "Attack on Titan Final Season Part 2"
    // is filed under the base title + part, not under "Part 2".
    q = q.replaceAll(
      RegExp(r'\s*Part\s*\d{1,2}$', caseSensitive: false),
      '',
    );
    return q.trim();
  }

  static const String _searchQuery =
      r'query($p:Int,$n:Int,$q:String,$g:String,$y:Int,$s:MediaStatus,'
      r'$f:MediaFormat){Page(page:$p,perPage:$n)'
      r'{pageInfo{hasNextPage}media(search:$q,type:ANIME,isAdult:false,'
      r'genre:$g,seasonYear:$y,status:$s,format:$f)'
      r'{id idMal title{romaji english}coverImage{large extraLarge}'
      r' format episodes seasonYear averageScore genres description}}}';

  /// Minimal search query (0.2.15): only `search` + `type:ANIME`.
  /// Same fields as [_searchQuery] so results map identically —
  /// the ONLY difference is the missing filter args (and no null
  /// filter variables sent at all).
  static const String _searchQueryMinimal =
      r'query($p:Int,$n:Int,$q:String){Page(page:$p,perPage:$n)'
      r'{pageInfo{hasNextPage}media(search:$q,type:ANIME)'
      r'{id idMal title{romaji english}coverImage{large extraLarge}'
      r' format episodes seasonYear averageScore genres description}}}';

  /// Variables for [searchAnime]. Pure — unit-tested. Null filter
  /// values are sent as null, which AniList treats as "not set".
  static Map<String, Object?> searchVariables(
    String query, {
    int page = 1,
    String? genre,
    int? year,
    String? status,
    String? format,
  }) {
    return <String, Object?>{
      'p': page,
      'n': 20,
      'q': query.trim(),
      'g': genre,
      'y': year,
      's': status,
      'f': format,
    };
  }

  /// Popular anime movies for the Home MOVIES row (0.2.9): AniList
  /// MOVIE-format entries by popularity, 12 per page. A movie is
  /// one "episode" — the API sometimes reports episodes 0/null, so
  /// those are forced to 1 here (Detail/player treat a movie like
  /// any single-episode title). Empty on any failure — the caller
  /// falls back to the bundled list.
  Future<List<Anime>> fetchMovies() async {
    const String q =
        r'query($p:Int,$n:Int){Page(page:$p,perPage:$n)'
        r'{media(type:ANIME,format:MOVIE,sort:POPULARITY_DESC)'
        r'{id idMal title{romaji english}coverImage{large extraLarge}'
        r' format episodes seasonYear averageScore genres description}}}';
    final Map<String, dynamic>? data = await _postSafe(q, <String, Object?>{
      'p': 1,
      'n': 12,
    });
    final List<dynamic> media =
        (data?['Page'] as Map<String, dynamic>?)?['media'] as List<dynamic>? ??
        <dynamic>[];
    return media
        .map((dynamic e) => animeFromMedia(e as Map<String, dynamic>))
        .whereType<Anime>()
        .map(
          (Anime a) => a.episodeCount <= 0 ? a.copyWith(episodeCount: 1) : a,
        )
        .toList();
  }

  /// Per-episode thumbnails for one AniList id (0.2.9): the
  /// `streamingEpisodes` field carries a thumbnail per episode
  /// (titles like "Episode 1"). Returns episode number →
  /// thumbnail URL, only for entries that actually have one.
  /// Empty on any failure — the caller falls back to the anime
  /// poster per episode. [episodeCount] bounds the order-fallback
  /// for unnumbered entries; 0 = no bound.
  Future<Map<int, String>> fetchEpisodeThumbnails(
    int anilistId, {
    int episodeCount = 0,
  }) async {
    const String q =
        r'query($id:Int){Media(id:$id,type:ANIME)'
        r'{streamingEpisodes{title thumbnail url site}}}';
    final Map<String, dynamic>? data = await _postSafe(q, <String, Object?>{
      'id': anilistId,
    });
    final List<dynamic> eps =
        (data?['Media'] as Map<String, dynamic>?)?['streamingEpisodes']
                as List<dynamic>? ??
            <dynamic>[];
    return matchEpisodeThumbnails(
      eps.map((dynamic e) => e as Map<String, dynamic>).toList(),
      episodeCount: episodeCount,
    );
  }

  /// Match AniList `streamingEpisodes` entries to episode numbers.
  /// Pure — unit-tested. Numbered titles ("Episode 1", "Ep. 12",
  /// "12") map to that number; unnumbered entries fill the lowest
  /// unclaimed episode numbers in list order (AniList usually
  /// returns them in episode order). Entries without a thumbnail
  /// are skipped (→ null, poster fallback); out-of-range numbers
  /// are ignored; the first entry wins a duplicate number.
  static Map<int, String> matchEpisodeThumbnails(
    List<Map<String, dynamic>> streaming, {
    int episodeCount = 0,
  }) {
    final Map<int, String> byNumber = <int, String>{};
    final List<String> unnumbered = <String>[];
    for (final Map<String, dynamic> entry in streaming) {
      final String? thumb = entry['thumbnail'] as String?;
      if (thumb == null || thumb.isEmpty) continue;
      final int? number = _episodeNumberFromTitle(
        entry['title'] as String? ?? '',
      );
      if (number != null && number > 0) {
        if (episodeCount > 0 && number > episodeCount) continue;
        byNumber.putIfAbsent(number, () => thumb);
      } else {
        unnumbered.add(thumb);
      }
    }
    if (unnumbered.isNotEmpty && episodeCount > 0) {
      int next = 1;
      for (final String thumb in unnumbered) {
        while (next <= episodeCount && byNumber.containsKey(next)) {
          next++;
        }
        if (next > episodeCount) break;
        byNumber[next] = thumb;
        next++;
      }
    }
    return byNumber;
  }

  /// "Episode 1" → 1, "Ep. 12" → 12, "12" → 12, anything else → null.
  static int? _episodeNumberFromTitle(String title) {
    final RegExpMatch? m = RegExp(
      r'(?:episode|ep\.?)\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(title);
    if (m != null) return int.tryParse(m.group(1)!);
    return int.tryParse(title.trim());
  }

  /// Full detail for one AniList id (includes idMal, episode count rule
  /// inputs, banner). Returns null when the id is unknown.
  Future<Anime?> mediaById(int anilistId) async {
    final String q =
        '{Media(id:$anilistId,type:ANIME){id idMal title{romaji english native}'
        ' coverImage{large extraLarge} bannerImage description status episodes'
        ' nextAiringEpisode{episode airingAt} genres seasonYear format averageScore}}';
    final Map<String, dynamic>? data = await _post(q, <String, Object?>{});
    final Map<String, dynamic>? media = data?['Media'] as Map<String, dynamic>?;
    if (media == null) return null;
    return animeFromMedia(media);
  }

  /// Title variants + year + format for one AniList id (0.2.12):
  /// the title matchers need romaji/english/native together
  /// (animeFromMedia keeps only the preferred title) plus the year
  /// and format to tell Naruto (2002) from Shippuuden (2007) and
  /// Boruto (2017). Null on any failure — the caller treats it as
  /// "match on the catalogue title alone".
  Future<AnilistIdentity?> mediaIdentity(int anilistId) async {
    const String q =
        r'query($id:Int){Media(id:$id,type:ANIME){title{romaji english native}'
        r' seasonYear format episodes status}}';
    final Map<String, dynamic>? data = await _postSafe(q, <String, Object?>{
      'id': anilistId,
    });
    final Map<String, dynamic>? media = data?['Media'] as Map<String, dynamic>?;
    if (media == null) return null;
    final Map<String, dynamic>? t = media['title'] as Map<String, dynamic>?;
    final List<String> titles = <String?>[
      t?['romaji'] as String?,
      t?['english'] as String?,
      t?['native'] as String?,
    ].whereType<String>().where((String s) => s.isNotEmpty).toList();
    if (titles.isEmpty) return null;
    return AnilistIdentity(
      titles: titles,
      year: (media['seasonYear'] as num?)?.toInt(),
      format: media['format'] as String?,
      episodes: (media['episodes'] as num?)?.toInt(),
      status: media['status'] as String?,
    );
  }

  /// Season chain for an anime (0.2.8): seasons are separate AniList
  /// entries linked by SEQUEL/PREQUEL relations (e.g. My Hero Academia
  /// S1 → S2 → S3…). Walks the relations both ways from [anilistId]
  /// and returns the ordered chain, current entry included. Only TV /
  /// TV_SHORT entries with at least one episode count as seasons
  /// (movies, specials, OVAs are not seasons). Returns an empty list
  /// on any failure — the detail screen then shows no selector and
  /// the episode list stays as-is. Each hop is one public GraphQL
  /// query; the walk caps at 12 hops per direction.
  Future<List<SeasonInfo>> fetchSeasons(int anilistId) async {
    try {
      final Map<int, SeasonNode> byId = <int, SeasonNode>{};
      // Walk PREQUELs back to the first season, then SEQUELs forward.
      int? current = anilistId;
      int hops = 0;
      while (current != null && hops < 12 && !byId.containsKey(current)) {
        final SeasonNode? node = await _seasonRelations(current);
        if (node == null) break;
        byId[current] = node;
        current = node.prequelId;
        hops++;
      }
      final List<int> ordered = <int>[];
      int? first = anilistId;
      while (byId[first]?.prequelId != null) {
        first = byId[first]!.prequelId;
      }
      current = first;
      hops = 0;
      while (current != null && hops < 12) {
        final SeasonNode? node = byId[current];
        if (node == null) {
          final SeasonNode? fetched = await _seasonRelations(current);
          if (fetched == null) break;
          byId[current] = fetched;
        }
        ordered.add(current);
        current = byId[current]!.sequelId;
        hops++;
      }
      return buildSeasonChain(anilistId, byId);
    } catch (_) {
      return <SeasonInfo>[];
    }
  }

  /// One hop of the season walk: this entry's own season info plus
  /// the ids of its TV PREQUEL / SEQUEL neighbours (null when none).
  /// Null on any failure (the caller treats it as the end of the chain).
  Future<SeasonNode?> _seasonRelations(int anilistId) async {
    final String q =
        '{Media(id:$anilistId,type:ANIME){id title{romaji english} format'
        ' episodes seasonYear relations{edges{relationType node{id'
        ' title{romaji english} format episodes seasonYear}}}}}';
    final Map<String, dynamic>? data = await _postSafe(q, <String, Object?>{});
    final Map<String, dynamic>? media = data?['Media'] as Map<String, dynamic>?;
    if (media == null) return null;
    final Map<String, dynamic>? title = media['title'] as Map<String, dynamic>?;
    final String name = preferredTitle(title);
    final String format = media['format'] as String? ?? '';
    final int episodes = (media['episodes'] as num?)?.toInt() ?? 0;
    final int? year = (media['seasonYear'] as num?)?.toInt();
    int? prequelId;
    int? sequelId;
    final List<dynamic> edges =
        (media['relations'] as Map<String, dynamic>?)?['edges']
            as List<dynamic>? ??
        <dynamic>[];
    for (final dynamic edge in edges) {
      final Map<String, dynamic> e = edge as Map<String, dynamic>;
      final Map<String, dynamic>? node = e['node'] as Map<String, dynamic>?;
      if (node == null) continue;
      // Record the neighbour whatever its format: a movie can sit
      // between two TV seasons in the relation graph, and the walk
      // passes through it — buildSeasonChain drops non-TV entries
      // from the displayed chain.
      final int? nodeId = (node['id'] as num?)?.toInt();
      if (nodeId == null) continue;
      if (e['relationType'] == 'PREQUEL') {
        prequelId ??= nodeId;
      } else if (e['relationType'] == 'SEQUEL') {
        sequelId ??= nodeId;
      }
    }
    return SeasonNode(
      info: SeasonInfo(
        id: (media['id'] as num).toInt(),
        title: name,
        format: format,
        episodes: episodes,
        year: year,
      ),
      prequelId: prequelId,
      sequelId: sequelId,
    );
  }

  /// Order a walked season map into the chain, current entry included.
  /// Pure — unit-tested. Entries that are not TV seasons or have no
  /// episodes are dropped; a chain of fewer than two entries means
  /// "no selector" (the caller shows nothing).
  static List<SeasonInfo> buildSeasonChain(
    int currentId,
    Map<int, SeasonNode> byId,
  ) {
    int? first = currentId;
    final Set<int> seen = <int>{};
    while (byId[first]?.prequelId != null && !seen.contains(first)) {
      seen.add(first!);
      first = byId[first]!.prequelId;
    }
    final List<SeasonInfo> chain = <SeasonInfo>[];
    int? id = first;
    seen.clear();
    while (id != null && !seen.contains(id)) {
      seen.add(id);
      final SeasonNode? node = byId[id];
      if (node == null) break;
      final SeasonInfo info = node.info;
      if ((info.format == 'TV' || info.format == 'TV_SHORT') &&
          info.episodes > 0) {
        chain.add(info);
      }
      id = node.sequelId;
    }
    if (chain.length < 2) return <SeasonInfo>[];
    return chain;
  }

  /// Resolve an AniList id for a catalogue title (titles without a
  /// stored anilistId). Normalized exact match first, then a contains
  /// match, else the first result. Null when nothing matches.
  Future<int?> resolveId(String title) async {
    final List<Anime> results = await searchAnime(title);
    if (results.isEmpty) return null;
    final String norm = normalizeTitle(title);
    for (final Anime a in results) {
      if (normalizeTitle(a.title) == norm && a.anilistId != null) {
        return a.anilistId;
      }
    }
    for (final Anime a in results) {
      final String n = normalizeTitle(a.title);
      if ((n.contains(norm) || norm.contains(n)) && a.anilistId != null) {
        return a.anilistId;
      }
    }
    return results.first.anilistId;
  }

  /// Like [resolveId] but honest about WHY it failed (0.2.12): the
  /// resolvers show a different message when AniList itself could
  /// not be reached (network / rate limit) than when the title
  /// genuinely has no AniList entry. [lookupFailed] is true only
  /// when the GraphQL call threw; `id` is null in both failure
  /// cases. Uses [_post] (throwing) instead of [searchAnime]'s
  /// swallowing [_postSafe], so a dead network is visible.
  Future<({int? id, bool lookupFailed})> resolveIdDetailed(
    String title,
  ) async {
    late final Map<String, dynamic>? data;
    try {
      data = await _post(_searchQuery, searchVariables(title));
    } catch (_) {
      return (id: null, lookupFailed: true);
    }
    final List<dynamic> media =
        (data?['Page'] as Map<String, dynamic>?)?['media'] as List<dynamic>? ??
        <dynamic>[];
    final List<Anime> results = media
        .map((dynamic e) => animeFromMedia(e as Map<String, dynamic>))
        .whereType<Anime>()
        .toList();
    if (results.isEmpty) return (id: null, lookupFailed: false);
    final String norm = normalizeTitle(title);
    for (final Anime a in results) {
      if (normalizeTitle(a.title) == norm && a.anilistId != null) {
        return (id: a.anilistId, lookupFailed: false);
      }
    }
    for (final Anime a in results) {
      final String n = normalizeTitle(a.title);
      if ((n.contains(norm) || norm.contains(n)) && a.anilistId != null) {
        return (id: a.anilistId, lookupFailed: false);
      }
    }
    return (id: results.first.anilistId, lookupFailed: false);
  }

  /// Logged-in viewer (name + id). Throws on 401 / network failure.
  Future<({int id, String name})> viewer(String token) async {
    const String q = '{Viewer{id name}}';
    final Map<String, dynamic>? data = await _post(
      q,
      <String, Object?>{},
      token: token,
    );
    final Map<String, dynamic>? viewer =
        data?['Viewer'] as Map<String, dynamic>?;
    if (viewer == null) throw const AniListException('No viewer in response');
    return (
      id: (viewer['id'] as num).toInt(),
      name: viewer['name'] as String? ?? 'AniList user',
    );
  }

  /// Push a Collection status to the user's AniList list
  /// ('CURRENT' | 'COMPLETED' | 'PLANNING'). [progress] is the
  /// episode number just finished (0.2.11) — when given, the
  /// mutation also sets the entry's progress, so AniList shows
  /// e.g. 5/12 instead of just "Watching". Best-effort: failures are
  /// swallowed so a list tap never breaks the local Collection.
  Future<bool> saveListEntry(
    String token,
    int mediaId,
    String anilistStatus, {
    int? progress,
  }) async {
    final String mutation = progress == null
        ? r'mutation($id:Int,$status:MediaListStatus){SaveMediaListEntry'
              r'(mediaId:$id,status:$status){id status}}'
        : r'mutation($id:Int,$status:MediaListStatus,$p:Int)'
              r'{SaveMediaListEntry(mediaId:$id,status:$status,progress:$p)'
              r'{id status progress}}';
    final Map<String, Object?> variables = <String, Object?>{
      'id': mediaId,
      'status': anilistStatus,
    };
    if (progress != null) variables['p'] = progress;
    try {
      await _post(mutation, variables, token: token);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// One entry of the user's AniList list: the title, its AniList
  /// list status, and the episode progress (0 = not started).
  static List<AnilistListEntry> parseUserListEntries(
    Map<String, dynamic> data,
  ) {
    final List<AnilistListEntry> out = <AnilistListEntry>[];
    final Map<String, dynamic>? collection =
        data['MediaListCollection'] as Map<String, dynamic>?;
    final List<dynamic> lists =
        collection?['lists'] as List<dynamic>? ?? <dynamic>[];
    for (final dynamic list in lists) {
      final List<dynamic> entries =
          (list as Map<String, dynamic>)['entries'] as List<dynamic>? ??
          <dynamic>[];
      for (final dynamic e in entries) {
        final Map<String, dynamic> entry = e as Map<String, dynamic>;
        final Map<String, dynamic>? media =
            entry['media'] as Map<String, dynamic>?;
        if (media == null) continue;
        final Anime? anime = animeFromMedia(media);
        if (anime == null) continue;
        final String status = entry['status'] as String? ?? '';
        if (status.isEmpty) continue;
        out.add(
          (
            anime: anime,
            status: status,
            progress: (entry['progress'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    return out;
  }

  /// Fetch the user's AniList list (CURRENT / COMPLETED / PLANNING
  /// only — PAUSED / DROPPED are out of scope). Returns the parsed
  /// entries; empty on any failure (best-effort, never throws).
  Future<List<AnilistListEntry>> fetchUserList(String token) async {
    try {
      final ({int id, String name}) me = await viewer(token);
      const String q =
          r'query($u:Int){MediaListCollection(userId:$u,type:ANIME,'
          r'status_in:[CURRENT,COMPLETED,PLANNING]){lists{entries{'
          r'status progress media{id idMal title{romaji english native}'
          r'coverImage{large extraLarge}format episodes seasonYear'
          r'averageScore genres description status}}}}';
      final Map<String, dynamic>? data = await _post(
        q,
        <String, Object?>{'u': me.id},
        token: token,
      );
      if (data == null) return <AnilistListEntry>[];
      return parseUserListEntries(data);
    } catch (_) {
      return <AnilistListEntry>[];
    }
  }

  /// Run a raw GraphQL query (feature services, e.g. airing).
  /// Returns decoded `data`, or null on any failure — never throws.
  Future<Map<String, dynamic>?> queryGraphQL(
    String query,
    Map<String, Object?> variables, {
    String? token,
  }) async {
    try {
      return await _post(query, variables, token: token);
    } catch (_) {
      return null;
    }
  }

  /// Search must never throw: on any failure (rate limit, network,
  /// bad body) it returns an empty list and the search screen falls
  /// back to the local catalogue.
  Future<Map<String, dynamic>?> _postSafe(
    String query,
    Map<String, Object?> variables,
  ) async {
    try {
      return await _post(query, variables);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(
    String query,
    Map<String, Object?> variables, {
    String? token,
  }) async {
    final http.Response resp = await _client
        .post(
          Uri.parse(graphqlUrl),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': _ua,
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode(<String, Object>{
            'query': query,
            'variables': variables,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 429) {
      throw const AniListException('Rate limited — try again in a minute');
    }
    if (resp.statusCode != 200) {
      throw AniListException('AniList HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> decoded =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['errors'] != null) {
      final List<dynamic> errors = decoded['errors'] as List<dynamic>;
      final String message = errors.isNotEmpty
          ? (errors.first as Map<String, dynamic>)['message'] as String? ??
                'AniList error'
          : 'AniList error';
      throw AniListException(message);
    }
    return decoded['data'] as Map<String, dynamic>?;
  }

  /// Map one AniList Media object to an [Anime]. Null when the media
  /// has no usable id/title. Pure — unit-tested.
  static Anime? animeFromMedia(Map<String, dynamic> m) {
    final int? id = (m['id'] as num?)?.toInt();
    final Map<String, dynamic>? title = m['title'] as Map<String, dynamic>?;
    final String name = preferredTitle(title);
    if (id == null || name.isEmpty || name == 'Unknown') return null;
    final Map<String, dynamic>? cover =
        m['coverImage'] as Map<String, dynamic>?;
    final String? poster =
        cover?['extraLarge'] as String? ?? cover?['large'] as String?;
    final int? score = (m['averageScore'] as num?)?.toInt();
    final String format = (m['format'] as String?) ?? '';
    // 0.2.13: next-airing info (Detail's upcoming-EP line + the
    // aired count). AniList `episodes` is null while a series is
    // still airing, so the aired count is derived — episode N airs
    // next means N-1 have aired. Without this, every airing title
    // opened from Search (not just AIRING SOON) arrived at Detail
    // with 0 episodes and no upcoming info.
    final Map<String, dynamic>? next =
        m['nextAiringEpisode'] as Map<String, dynamic>?;
    int? nextEpisode;
    String? nextEpisodeIn;
    String? nextEpisodeAt;
    if (next != null) {
      nextEpisode = (next['episode'] as num?)?.toInt();
      final int? airingAt = (next['airingAt'] as num?)?.toInt();
      if (airingAt != null) {
        final DateTime at = DateTime.fromMillisecondsSinceEpoch(
          airingAt * 1000,
          isUtc: true,
        );
        nextEpisodeIn = formatAiringCountdown(at);
        nextEpisodeAt = formatAiringDate(at);
      }
    }
    int episodes = (m['episodes'] as num?)?.toInt() ?? 0;
    if (episodes <= 0 && nextEpisode != null && nextEpisode > 1) {
      episodes = nextEpisode - 1;
    }
    // 0.2.12: a movie is one "episode" — AniList reports episodes
    // null/0 for some movies (The Garden of Words), and episodeCount
    // 0 made Detail show the dead "No episodes yet" state with no
    // way to play. Same force-to-1 `fetchMovies` already did; now
    // every search path gets it. TV keeps its real count (0 = the
    // airing empty state from item 1).
    if (format == 'MOVIE' && episodes <= 0) episodes = 1;
    final int year = (m['seasonYear'] as num?)?.toInt() ?? 0;
    final List<String> genres =
        (m['genres'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        <String>[];
    return Anime(
      id: 'anilist-$id',
      anilistId: id,
      malId: (m['idMal'] as num?)?.toInt(),
      title: name,
      rating: score != null ? score / 20.0 : 0,
      year: year,
      episodeCount: episodes,
      genres: genres,
      synopsis: cleanDescription(m['description'] as String?),
      posterUrl: poster,
      gradient: const <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      nextEpisode: nextEpisode,
      nextEpisodeIn: nextEpisodeIn,
      nextEpisodeAt: nextEpisodeAt,
    );
  }

  static String preferredTitle(Map<String, dynamic>? t) {
    if (t == null) return 'Unknown';
    final String? english = t['english'] as String?;
    if (english != null && english.isNotEmpty) return english;
    final String? romaji = t['romaji'] as String?;
    if (romaji != null && romaji.isNotEmpty) return romaji;
    final String? native = t['native'] as String?;
    if (native != null && native.isNotEmpty) return native;
    return 'Unknown';
  }

  /// Strip HTML tags + collapse whitespace. Pure — unit-tested.
  static String cleanDescription(String? raw) {
    if (raw == null) return '';
    return raw
        .replaceAll(RegExp('<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

/// One season in a season chain (0.2.8): a separate AniList entry
/// linked by SEQUEL/PREQUEL relations. The label is positional
/// ("Season 1", "Season 2"…) — AniList has no season number field.
class SeasonInfo {
  const SeasonInfo({
    required this.id,
    required this.title,
    required this.format,
    required this.episodes,
    this.year,
  });

  final int id;
  final String title;
  final String format;
  final int episodes;
  final int? year;
}

/// One hop of the season walk: the entry's own info plus its TV
/// PREQUEL / SEQUEL neighbour ids.
class SeasonNode {
  const SeasonNode({required this.info, this.prequelId, this.sequelId});

  final SeasonInfo info;
  final int? prequelId;
  final int? sequelId;
}

/// Lowercase, strip punctuation — title matching for resolveId.
String normalizeTitle(String raw) {
  return raw
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class AniListException implements Exception {
  const AniListException(this.message);
  final String message;
  @override
  String toString() => 'AniListException: $message';
}
