import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/anilist_service.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../widgets/poster.dart';
import '../widgets/premium_picker.dart';

/// Search: field + genre chips + poster grid.
///
/// M2: live AniList GraphQL search (debounced 400 ms) + the local
/// 39-title catalogue as instant fallback. Local results show
/// immediately on every keystroke; remote results merge in below
/// (deduped by title). When AniList is unreachable the local results
/// stay and a note says so — search never shows a dead empty state.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.onOpenAnime,
    required this.anilist,
    required this.store,
  });

  final ValueChanged<Anime> onOpenAnime;
  final AniListService anilist;

  /// Owns the recent-searches list (0.2.25).
  final SettingsStore store;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';
  String _genre = 'All';
  // 0.2.11 filters: genre (chips) + year / status / format (pickers).
  // They apply to the live AniList search; locally only genre + year
  // can filter (the bundled catalogue carries no airing status or
  // format field).
  int? _year;
  String _status = 'All';
  String _format = 'All';
  Timer? _debounce;
  List<Anime> _remote = <Anime>[];
  bool _searching = false;
  bool _remoteFailed = false;

  static const List<String> _genres = <String>[
    'All',
    'Action',
    'Romance',
    'Sci-Fi',
    'Fantasy',
    'Horror',
    'Adventure',
  ];

  static const List<String> _statuses = <String>[
    'All',
    'Airing',
    'Finished',
    'Not Yet Aired',
  ];

  static const List<String> _formats = <String>['All', 'TV', 'Movie'];

  bool get _filtersActive =>
      _genre != 'All' || _year != null || _status != 'All' || _format != 'All';

  String? get _statusFilter => switch (_status) {
    'Airing' => 'RELEASING',
    'Finished' => 'FINISHED',
    'Not Yet Aired' => 'NOT_YET_RELEASED',
    _ => null,
  };

  String? get _formatFilter => switch (_format) {
    'TV' => 'TV',
    'Movie' => 'MOVIE',
    _ => null,
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _remote = <Anime>[];
        _searching = false;
        _remoteFailed = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_runRemoteSearch()),
    );
  }

  /// Live AniList search with the current filters. Re-runs when a
  /// filter changes while a query is active.
  ///
  /// 0.2.12: uses [searchAnimeDetailed] so a dead AniList (network
  /// / rate limit) shows "Couldn't reach AniList" instead of a
  /// bare "No anime found" — the old swallowing search made a
  /// failed remote lookup indistinguishable from no results, which
  /// is why movies (local-catalogue has almost none) seemed to
  /// vanish from search whenever the remote call failed.
  Future<void> _runRemoteSearch() async {
    final String q = _controller.text.trim();
    if (q.length < 2) return;
    try {
      final ({List<Anime> results, bool lookupFailed}) r =
          await widget.anilist.searchAnimeDetailed(
        q,
        genre: _genre == 'All' ? null : _genre,
        year: _year,
        status: _statusFilter,
        format: _formatFilter,
      );
      if (!mounted || _controller.text.trim() != q) return;
      setState(() {
        _remote = r.results;
        _searching = false;
        _remoteFailed = r.lookupFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _remoteFailed = true;
      });
    }
  }

  /// 0.2.17: clear (X) button — one tap clears the whole query
  /// and resets results to the empty/search-home state. Cancels
  /// any pending debounce + remote search first.
  void _clearQuery() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _remote = <Anime>[];
      _searching = false;
      _remoteFailed = false;
    });
  }

  /// 0.2.25: a SUBMITTED search (keyboard Search key) records
  /// the term in recent searches. Typing never records anything —
  /// the debounced live search is not a submission. Runs the
  /// remote search immediately instead of waiting for the
  /// debounce.
  void _submitSearch(String value) {
    final String term = value.trim();
    if (term.length < 2) return;
    unawaited(widget.store.addRecentSearch(term));
    _debounce?.cancel();
    setState(() => _searching = true);
    unawaited(_runRemoteSearch());
  }

  /// 0.2.25: re-run a recent search — fill the field and search
  /// it (same path as typing it again).
  void _runRecentSearch(String term) {
    _controller.text = term;
    _onQueryChanged(term);
  }

  void _onFilterChanged() {
    if (_controller.text.trim().length >= 2) {
      setState(() => _searching = true);
      unawaited(_runRemoteSearch());
    } else {
      setState(() {});
    }
  }

  List<Anime> _localResults() {
    final String q = _query.toLowerCase();
    // 0.2.12: match the season-stripped query too — "Black Clover
    // S2" must find the local "Black Clover" entry (the raw
    // `contains` never matches a suffixed query).
    final String stripped =
        AniListService.stripSeasonSuffix(_query).toLowerCase();
    return mockCatalogue().where((Anime a) {
      final String title = a.title.toLowerCase();
      final bool matchesQuery =
          _query.isEmpty ||
          title.contains(q) ||
          (stripped != q && title.contains(stripped)) ||
          a.genres.any((String g) => g.toLowerCase().contains(q));
      final bool matchesGenre = _genre == 'All' || a.genres.contains(_genre);
      final bool matchesYear = _year == null || a.year == _year;
      return matchesQuery && matchesGenre && matchesYear;
    }).toList();
  }

  List<Anime> _mergedResults(List<Anime> local) {
    if (_query.trim().length < 2) return local;
    final Set<String> seen = local
        .map((Anime a) => a.title.toLowerCase())
        .toSet();
    final List<Anime> merged = List<Anime>.of(local);
    for (final Anime a in _remote) {
      if (seen.add(a.title.toLowerCase())) merged.add(a);
    }
    return merged;
  }

  Future<void> _pickYear(BuildContext context) async {
    final int nowYear = DateTime.now().year;
    final int? picked = await showPremiumPicker<int>(
      context: context,
      title: 'Year',
      selected: _year ?? 0,
      options: <PremiumPickerOption<int>>[
        const PremiumPickerOption<int>(value: 0, label: 'All years'),
        for (int y = nowYear; y >= 2000; y--)
          PremiumPickerOption<int>(value: y, label: '$y'),
      ],
    );
    if (picked == null) return;
    setState(() => _year = picked == 0 ? null : picked);
    _onFilterChanged();
  }

  Future<void> _pickStatus(BuildContext context) async {
    final String? picked = await showPremiumPicker<String>(
      context: context,
      title: 'Status',
      selected: _status,
      options: <PremiumPickerOption<String>>[
        for (final String s in _statuses)
          PremiumPickerOption<String>(value: s, label: s),
      ],
    );
    if (picked == null) return;
    setState(() => _status = picked);
    _onFilterChanged();
  }

  Future<void> _pickFormat(BuildContext context) async {
    final String? picked = await showPremiumPicker<String>(
      context: context,
      title: 'Format',
      selected: _format,
      options: <PremiumPickerOption<String>>[
        for (final String f in _formats)
          PremiumPickerOption<String>(value: f, label: f),
      ],
    );
    if (picked == null) return;
    setState(() => _format = picked);
    _onFilterChanged();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color primaryText = isDark
        ? AppTheme.textPrimaryDark
        : AppTheme.textPrimaryLight;
    final Color secondaryText = isDark
        ? AppTheme.textSecondaryDark
        : AppTheme.textSecondaryLight;

    final List<Anime> results = _mergedResults(_localResults());

    return ListView(
      padding: const EdgeInsets.only(bottom: 110),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 56, 16, 12),
          child: Text(
            'Search',
            style: TextStyle(
              color: primaryText,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _controller,
            onChanged: _onQueryChanged,
            onSubmitted: _submitSearch,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: primaryText),
            decoration: InputDecoration(
              hintText: 'Search anime...',
              hintStyle: TextStyle(color: secondaryText),
              prefixIcon: Icon(Icons.search_rounded, color: secondaryText),
              suffixIcon: _searching
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      ),
                    )
                  // 0.2.17: clear (X) button, only while the field
                  // is non-empty (the spinner owns the slot while
                  // a search is in flight).
                  : _query.isNotEmpty
                      ? IconButton(
                          tooltip: 'Clear search',
                          onPressed: _clearQuery,
                          icon: Icon(
                            Icons.clear_rounded,
                            color: secondaryText,
                          ),
                        )
                      : null,
              filled: true,
              fillColor: isDark ? AppTheme.cardDark : AppTheme.cardLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _genres.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              final String genre = _genres[index];
              final bool selected = genre == _genre;
              return ChoiceChip(
                label: Text(genre),
                selected: selected,
                selectedColor: accent,
                backgroundColor: isDark
                    ? AppTheme.cardDark
                    : AppTheme.cardLight,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : primaryText,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) {
                  setState(() => _genre = genre);
                  _onFilterChanged();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        // 0.2.11 filters: year / status / format pickers. Each opens
        // the premium picker; 'All' clears that filter.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              _FilterButton(
                label: 'Year',
                value: _year == null ? 'All' : '$_year',
                active: _year != null,
                accent: accent,
                onTap: () => _pickYear(context),
              ),
              const SizedBox(width: 8),
              _FilterButton(
                label: 'Status',
                value: _status,
                active: _status != 'All',
                accent: accent,
                onTap: () => _pickStatus(context),
              ),
              const SizedBox(width: 8),
              _FilterButton(
                label: 'Format',
                value: _format,
                active: _format != 'All',
                accent: accent,
                onTap: () => _pickFormat(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 0.2.25: recent searches — only when the query is empty
        // (the section is the search-home state). Tapping a term
        // re-runs it; X removes one term; "Clear all" empties the
        // list. Only SUBMITTED searches are recorded, never
        // keystrokes.
        if (_query.isEmpty && widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Recent searches',
                      style: TextStyle(
                        color: primaryText,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        await widget.store.clearRecentSearches();
                        if (mounted) setState(() {});
                      },
                      child: Text(
                        'Clear all',
                        style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final String term in widget.store.recentSearches)
                  InkWell(
                    onTap: () => _runRecentSearch(term),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.history_rounded,
                            color: secondaryText,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              term,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () async {
                              await widget.store.removeRecentSearch(term);
                              if (mounted) setState(() {});
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                color: secondaryText,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (_query.isNotEmpty || _filtersActive)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '${results.length} result${results.length == 1 ? '' : 's'}'
              '${_query.isNotEmpty ? " for '$_query'" : ''}'
              '${_searching ? ' • searching AniList…' : ''}',
              style: TextStyle(color: secondaryText, fontSize: 13),
            ),
          ),
        if (_remoteFailed && _query.trim().length >= 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Couldn\'t reach AniList — showing local results.',
              style: TextStyle(color: secondaryText, fontSize: 12),
            ),
          ),
        // 0.2.13: phone-visible search diagnostic — what the last
        // AniList lookup actually returned ("ok · 12 from AniList"
        // / "failed (HTTP 403) · local only"). A dead lookup and a
        // genuine no-match must never look the same again.
        if (_query.trim().length >= 2 && !_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'AniList: ${widget.anilist.lastSearchDiagnostic?.summary ?? 'not searched yet'}',
              style: TextStyle(color: secondaryText, fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
            ),
            itemCount: results.length,
            itemBuilder: (BuildContext context, int index) {
              final Anime anime = results[index];
              return PosterCard(
                anime: anime,
                width: double.infinity,
                onTap: () {
                  // 0.2.25: acting on a search result records the
                  // search — the user found what they wanted.
                  // Typing alone never records anything.
                  if (_query.trim().length >= 2) {
                    unawaited(widget.store.addRecentSearch(_query.trim()));
                  }
                  widget.onOpenAnime(anime);
                },
              );
            },
          ),
        ),
        if (results.isEmpty && !_searching)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'No anime found. Try another search.',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryText, fontSize: 14),
            ),
          ),
      ],
    );
  }
}

/// One filter pill (0.2.11): "Year · 2024" — tap opens the picker.
/// Active filters (not 'All') carry the accent border.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.value,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool active;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color card = isDark ? AppTheme.cardDark : AppTheme.cardLight;
    final Color primaryText =
        isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight;
    final Color secondaryText =
        isDark ? AppTheme.textSecondaryDark : AppTheme.textSecondaryLight;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(10),
            border: active ? Border.all(color: accent, width: 1.5) : null,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$label · $value',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? accent : primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: secondaryText,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
