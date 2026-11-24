import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reicon_flutter/reicon_flutter.dart';

import '../models.dart';
import '../services/airing_notifications.dart';
import '../services/airing_service.dart';
import '../services/anilist_service.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../widgets/poster.dart';
import '../widgets/premium_picker.dart';
import '../widgets/reicon_icon.dart';
import '../widgets/top_notification.dart';

/// Home — Anilili layout (ref anilili-home-reference.jpg), AniBee
/// branding (name, Frost Glass dark design, Settings accent color).
///
/// Header (AniBee wordmark + bell + search) -> genre chips -> hero
/// carousel (EP badge, page indicator, meta, title, genre pill,
/// Details / Watch Now, dots) -> Continue Watching (long-press hint +
/// cards) -> NEWEST / POPULAR / TRENDING / TOP RATED tab bar -> poster
/// grid with score badges. Genre chips + tabs filter the grid.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    required this.anilist,
    this.airing,
    this.airingNotifications,
    required this.onOpenAnime,
    required this.onWatchNow,
  });

  final SettingsStore store;
  final AniListService anilist;

  /// Upcoming-airing service (0.2.10). Null in tests / when not
  /// wired — Home builds a default one from [anilist].
  final AiringService? airing;

  /// Local airing alerts (0.2.10). Null in tests — no permission
  /// prompt and no scheduling there.
  final AiringNotifications? airingNotifications;

  final ValueChanged<Anime> onOpenAnime;

  /// Hero "Watch Now" opens the Detail screen straight into the player.
  final ValueChanged<Anime> onWatchNow;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<String> _tabs = <String>[
    'NEWEST',
    'POPULAR',
    'TRENDING',
    'TOP RATED',
  ];

  final PageController _pageController = PageController();
  Timer? _autoTimer;
  int _page = 0;
  String _genre = 'All';
  int _tab = 2; // TRENDING, like the reference.

  /// MOVIES row (0.2.9, last section on Home): starts on the bundled
  /// list so the row is never blank, then swaps in the live AniList
  /// popular movies when the query answers. Fixed bottom section —
  /// it ignores the genre chips and the tab bar.
  List<Anime> _movies = mockMovies();

  /// AIRING SOON (0.2.10): upcoming episodes for followed titles
  /// (AniList list when connected, Continue Watching ids, else
  /// trending airing). Hidden when empty.
  List<AiringEntry> _airing = <AiringEntry>[];

  /// Ticks the countdown text once a minute while airings show.
  Timer? _countdownTimer;

  /// AniList-connected state at the last airing load — a login /
  /// logout flips the airing source, so reload then.
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMovies());
    unawaited(_loadAiring());
    _wasConnected = widget.store.anilistConnected;
    widget.store.addListener(_onStoreChanged);
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (Timer t) {
      if (!mounted || _airing.isEmpty) return;
      setState(() {});
    });
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) {
      if (!mounted) return;
      final int next = (_page + 1) % _heroItems.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _countdownTimer?.cancel();
    widget.store.removeListener(_onStoreChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    if (widget.store.anilistConnected != _wasConnected) {
      _wasConnected = widget.store.anilistConnected;
      unawaited(_loadAiring());
    }
  }

  /// Upcoming airings for this user (0.2.10): AniList list when
  /// connected, else the Continue Watching AniList ids, else
  /// trending airing titles. Empty on failure — the row hides.
  Future<void> _loadAiring() async {
    final AiringService svc =
        widget.airing ?? AiringService(anilist: widget.anilist);
    final List<int> followed = widget.store.watchHistory
        .map((WatchEntry e) => e.anilistId)
        .whereType<int>()
        .toList();
    final List<AiringEntry> entries = await svc.fetchAiring(
      token: widget.store.anilistToken,
      followedIds: followed,
    );
    if (!mounted) return;
    setState(() => _airing = entries);
    unawaited(_maybeScheduleAiring());
  }

  /// After a fresh airing fetch: ask the iOS notification
  /// permission ONCE at first use (never on every launch), then
  /// schedule the alerts. Only when AniList is connected and the
  /// toggle is on; the bell in the section header re-asks manually.
  Future<void> _maybeScheduleAiring() async {
    final AiringNotifications? notifications = widget.airingNotifications;
    if (notifications == null ||
        _airing.isEmpty ||
        !widget.store.anilistConnected ||
        !widget.store.airingNotifications) {
      return;
    }
    if (!widget.store.airingPermissionAsked) {
      await widget.store.setAiringPermissionAsked(true);
      final bool granted = await notifications.requestPermission();
      if (!granted || !mounted) return;
    }
    await notifications.scheduleAiring(_airing);
  }

  /// Bell in the AIRING SOON header: (re-)ask permission and
  /// schedule the alerts, with a short banner as confirmation.
  Future<void> _onAiringBell() async {
    final AiringNotifications? notifications = widget.airingNotifications;
    if (notifications == null || !mounted) return;
    if (!widget.store.anilistConnected) {
      TopNotification.show(
        context,
        'Connect AniList to get airing alerts',
        neutral: true,
      );
      return;
    }
    final bool granted = await notifications.requestPermission();
    if (!mounted) return;
    if (granted) {
      await widget.store.setAiringNotifications(true);
      await notifications.scheduleAiring(_airing);
      if (!mounted) return;
      TopNotification.show(
        context,
        'Airing alerts on — 15 min before each episode',
        success: true,
      );
    } else {
      TopNotification.show(
        context,
        'Notifications are off — enable them in iOS Settings',
        neutral: true,
      );
    }
  }

  List<Anime> get _catalogue => mockCatalogue();

  List<Anime> get _heroItems => _catalogue.sublist(0, 6);

  List<String> get _genres {
    final List<String> out = <String>['All'];
    for (final Anime a in _catalogue) {
      for (final String g in a.genres) {
        if (!out.contains(g)) out.add(g);
      }
    }
    return out.take(13).toList();
  }

  List<Anime> get _gridItems {
    List<Anime> list;
    switch (_tab) {
      case 0: // NEWEST
        list = List<Anime>.of(_catalogue)
          ..sort((Anime a, Anime b) => b.year.compareTo(a.year));
      case 1: // POPULAR
        list = _catalogue.sublist(13, 25);
      case 3: // TOP RATED
        list = List<Anime>.of(_catalogue)
          ..sort((Anime a, Anime b) => b.rating.compareTo(a.rating));
      case 2: // TRENDING
      default:
        list = _catalogue.sublist(1, 13);
    }
    if (_genre != 'All') {
      list = list.where((Anime a) => a.genres.contains(_genre)).toList();
    }
    return list;
  }

  /// Live popular movies from AniList (0.2.9). A failed or empty
  /// query keeps the bundled list — the row never goes blank.
  Future<void> _loadMovies() async {
    final List<Anime> live = await widget.anilist.fetchMovies();
    if (!mounted || live.isEmpty) return;
    setState(() => _movies = live);
  }

  Future<void> _confirmClearWatchHistory() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF17171F),
          title: const Text(
            'Clear Continue Watching?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          content: const Text(
            'This removes all your saved watch progress from the Home row.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Clear All',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await widget.store.clearWatchHistory();
    }
  }

  /// Value of the "Remove from Continue Watching" picker row (0.2.17).
  static const String _removeFromContinueWatching = 'remove-cw';

  Future<void> _showListSheet(WatchEntry entry) async {
    final Anime anime = entry.toAnime();
    final String? current = widget.store.statusOf(anime);
    final String? picked = await showPremiumPicker<String>(
      context: context,
      title: anime.title,
      selected: current,
      options: const <PremiumPickerOption<String>>[
        PremiumPickerOption(value: 'watching', label: 'Move to Watching'),
        PremiumPickerOption(value: 'finished', label: 'Move to Finished'),
        PremiumPickerOption(value: 'plan', label: 'Move to To Be Watched'),
        PremiumPickerOption(
          value: '',
          label: 'Remove from list',
          destructive: true,
        ),
        // 0.2.17: per-item removal from Continue Watching. Until
        // now the only way out was "Clear All" — "Remove from list"
        // only clears the list status, NOT the watch-history entry,
        // so the card stayed in the row (user report 2026-11-24).
        // This row removes the history entry, so the card leaves
        // the row immediately and stays gone after a restart.
        PremiumPickerOption(
          value: _removeFromContinueWatching,
          label: 'Remove from Continue Watching',
          destructive: true,
        ),
      ],
    );
    if (picked == null) return;
    if (picked == _removeFromContinueWatching) {
      await widget.store.removeWatchEntry(entry.key);
      return;
    }
    if (picked.isEmpty) {
      await widget.store.setListStatus(anime, null);
    } else {
      await widget.store.setListStatus(anime, picked);
    }
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
    final Color card = isDark ? AppTheme.cardDark : AppTheme.cardLight;

    final List<Anime> gridItems = _gridItems;

    // Header + genre chips are PINNED: they stay fixed at the top
    // while only the content below scrolls (Anilili home behaviour).
    return Column(
      children: <Widget>[
        // Header: AniBee wordmark left, bell right. (0.2.25: the
        // search button is removed — Search lives in the bottom
        // nav tab. The bell stays.)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 56, 16, 12),
          child: Row(
            children: <Widget>[
              Text.rich(
                TextSpan(
                  children: <TextSpan>[
                    TextSpan(
                      text: 'Ani',
                      style: TextStyle(
                        color: primaryText,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    TextSpan(
                      text: 'Bee',
                      style: TextStyle(
                        color: accent,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                icon: ReiconIcon(
                  Reicon.outline.bell,
                  size: 24,
                  color: secondaryText,
                ),
                tooltip: 'Notifications',
                onPressed: () {
                  // 0.2.9: an empty state is not a warning — neutral
                  // banner (grey info icon), never the yellow error.
                  TopNotification.show(
                    context,
                    'No notifications yet',
                    neutral: true,
                  );
                },
              ),
            ],
          ),
        ),
        // Genre chips.
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _genres.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              final String genre = _genres[index];
              final bool selected = genre == _genre;
              return InkWell(
                onTap: () => setState(() => _genre = genre),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? accent : card,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    genre,
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : (isDark
                                ? AppTheme.textSecondaryDark
                                : AppTheme.textSecondaryLight),
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 110),
            children: <Widget>[
              // Hero carousel.
              SizedBox(
                height: 360,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _heroItems.length,
                  onPageChanged: (int i) => setState(() => _page = i),
                  itemBuilder: (BuildContext context, int index) {
                    final Anime anime = _heroItems[index];
                    return _HeroPage(
                      anime: anime,
                      index: index,
                      total: _heroItems.length,
                      accent: accent,
                      onDetails: () => widget.onOpenAnime(anime),
                      onWatchNow: () => widget.onWatchNow(anime),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              // Carousel dots.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  for (int i = 0; i < _heroItems.length; i++)
                    Container(
                      width: i == _page ? 16 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _page
                            ? accent
                            : (isDark
                                  ? const Color(0xFF3A3A48)
                                  : const Color(0xFFD5D5DE)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              // Continue Watching — driven by REAL persisted progress
              // (0.2.3): the mock catalogue's currentEpisode/minutesLeft
              // no longer feed this row. Hidden when nothing was
              // watched yet. Tapping a card resumes that episode at
              // the saved position.
              ListenableBuilder(
                listenable: widget.store,
                builder: (BuildContext context, Widget? _) {
                  final List<WatchEntry> history = widget.store.watchHistory;
                  if (history.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 4,
                              height: 18,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'CONTINUE WATCHING',
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _confirmClearWatchHistory,
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              label: const Text(
                                'Clear All',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 158,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: history.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (BuildContext context, int index) {
                            final WatchEntry entry = history[index];
                            return _ContinueWatchingCard(
                              entry: entry,
                              accent: accent,
                              onTap: () => widget.onWatchNow(entry.toAnime()),
                              onLongPress: () => _showListSheet(entry),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              // NEWEST / POPULAR / TRENDING / TOP RATED tab bar.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    for (int i = 0; i < _tabs.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: i == 0 ? 0 : 3,
                            right: i == _tabs.length - 1 ? 0 : 3,
                          ),
                          child: InkWell(
                            onTap: () => setState(() => _tab = i),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: i == _tab ? accent : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _tabs[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: i == _tab
                                      ? Colors.white
                                      : secondaryText,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Poster grid with score badges.
              if (gridItems.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      'No $_genre titles here yet',
                      style: TextStyle(color: secondaryText, fontSize: 14),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.66,
                        ),
                    itemCount: gridItems.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Anime anime = gridItems[index];
                      return _GridCard(
                        anime: anime,
                        onTap: () => widget.onOpenAnime(anime),
                      );
                    },
                  ),
                ),
              // AIRING SOON (0.2.10): upcoming episodes for followed
              // titles, soonest first, with a live countdown. Same
              // header style as MOVIES; the bell asks the iOS
              // notification permission / schedules the alerts.
              // Hidden when there is nothing airing. Sits above
              // MOVIES, below the poster grid.
              if (_airing.isNotEmpty) ...<Widget>[
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 4,
                        height: 18,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'AIRING SOON',
                        style: TextStyle(
                          color: primaryText,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: ReiconIcon(
                          Reicon.outline.bell,
                          size: 20,
                          color: secondaryText,
                        ),
                        tooltip: 'Airing alerts',
                        onPressed: _onAiringBell,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 212,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _airing.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (BuildContext context, int index) {
                      final AiringEntry entry = _airing[index];
                      return SizedBox(
                        width: 120,
                        child: _AiringCard(
                          entry: entry,
                          // 0.2.13: the airing info travels WITH the
                          // Anime into Detail — before, episodeCount
                          // was AniList `episodes` (null while a
                          // series airs → 0) and the next EP + air
                          // date were dropped, so Detail showed the
                          // generic "No episodes available yet" with
                          // no upcoming episode and no synopsis.
                          // Aired count = next episode - 1 (EP 9
                          // airs next → 8 aired; EP 1 next → 0).
                          onTap: () => widget.onOpenAnime(
                            Anime(
                              id: 'anilist-${entry.anilistId}',
                              anilistId: entry.anilistId,
                              title: entry.title,
                              rating: 0,
                              year: 0,
                              episodeCount: entry.airedCount,
                              genres: const <String>[],
                              synopsis: '',
                              gradient: const <Color>[
                                Color(0xFF3B2A6B),
                                Color(0xFF120E24),
                              ],
                              posterUrl: entry.posterUrl,
                              nextEpisode: entry.episode,
                              nextEpisodeIn:
                                  formatAiringCountdown(entry.airingAt),
                              nextEpisodeAt:
                                  formatAiringDate(entry.airingAt),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              // MOVIES (0.2.9): fixed last section on Home, below the
              // grid — it ignores the genre chips and the tab bar.
              // Horizontal poster row, same PosterCard style as the
              // grid; a tap opens the normal Detail screen and the
              // movie plays as a single episode.
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 4,
                      height: 18,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'MOVIES',
                      style: TextStyle(
                        color: primaryText,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 212,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _movies.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (BuildContext context, int index) {
                    final Anime movie = _movies[index];
                    return SizedBox(
                      width: 120,
                      child: _MovieCard(
                        anime: movie,
                        onTap: () => widget.onOpenAnime(movie),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroPage extends StatelessWidget {
  const _HeroPage({
    required this.anime,
    required this.index,
    required this.total,
    required this.accent,
    required this.onDetails,
    required this.onWatchNow,
  });

  final Anime anime;
  final int index;
  final int total;
  final Color accent;
  final VoidCallback onDetails;
  final VoidCallback onWatchNow;

  @override
  Widget build(BuildContext context) {
    final String epBadge = anime.nextEpisode != null
        ? 'EP ${anime.nextEpisode} ${(anime.nextEpisodeIn ?? '').toUpperCase()}'
        : 'EP ${anime.currentEpisode ?? anime.episodeCount}';
    final String durationMin = mockEpisodes(anime).first.duration
        .split(':')
        .first;
    final String meta =
        'TV  •  ★ ${anime.rating.toStringAsFixed(1)}  •  $durationMin min';
    final String genrePill = anime.genres.take(3).join('  •  ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PosterArt(anime: anime, borderRadius: 0, showTitle: false),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.30),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.78),
                  ],
                  stops: const <double>[0.0, 0.35, 0.6, 1.0],
                ),
              ),
            ),
            // EP badge top-left.
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.schedule_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      epBadge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Page indicator top-right.
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${index + 1}/$total',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            // Title block, centered at the bottom.
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                children: <Widget>[
                  Text(
                    meta,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    anime.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      genrePill,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      ElevatedButton.icon(
                        onPressed: onDetails,
                        icon: const Icon(Icons.info_outline_rounded, size: 18),
                        label: const Text(
                          'Details',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.55),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: onWatchNow,
                        icon: const Icon(
                          Icons.play_arrow_rounded,
                          size: 20,
                          color: Colors.black,
                        ),
                        label: const Text(
                          'Watch Now',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Continue Watching card (0.2.3, Zeus Home reference): wide
/// LANDSCAPE card over the poster — position/total badge top-right,
/// accent circular play button bottom-left, title + "Resume · X left"
/// next to it, accent progress bar along the bottom edge. The
/// reference's gold is Zeus's accent; here the button/bar use
/// AniBee's Settings accent.
class _ContinueWatchingCard extends StatelessWidget {
  const _ContinueWatchingCard({
    required this.entry,
    required this.accent,
    required this.onTap,
    required this.onLongPress,
  });

  final WatchEntry entry;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  String _clock(int seconds) {
    final int h = seconds ~/ 3600;
    final int m = (seconds % 3600) ~/ 60;
    final int s = seconds % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  String _total(int seconds) {
    final int h = seconds ~/ 3600;
    final int m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '${seconds}s';
  }

  String _left(int minutesLeft) {
    if (minutesLeft >= 60) {
      return '${minutesLeft ~/ 60}h ${minutesLeft % 60}m left';
    }
    return '${minutesLeft}m left';
  }

  @override
  Widget build(BuildContext context) {
    final Anime anime = entry.toAnime();
    final int posSeconds = entry.positionSeconds.round();
    final int durSeconds = entry.durationSeconds.round();
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 280,
        height: 158,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              PosterArt(anime: anime, borderRadius: 0, showTitle: false),
              Container(color: Colors.black.withValues(alpha: 0.28)),
              // Position / total badge, top-right.
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_clock(posSeconds)} / ${_total(durSeconds)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // Play button + title + resume, bottom-left.
              Positioned(
                left: 12,
                right: 12,
                bottom: 14,
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Episode ${entry.episode} · Resume · ${_left(entry.minutesLeft)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Progress bar along the bottom edge.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: entry.progress.clamp(0, 1),
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                  minHeight: 3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridCard extends StatelessWidget {
  const _GridCard({required this.anime, required this.onTap});

  final Anime anime;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final int score = (anime.rating * 10).round();
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PosterArt(anime: anime, borderRadius: 0, showTitle: false),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.star_rounded,
                            color: Colors.white,
                            size: 13,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$score%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            anime.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark
                  ? AppTheme.textPrimaryDark
                  : AppTheme.textPrimaryLight,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${anime.year} • ${anime.episodeCount} eps',
            style: TextStyle(
              color: isDark
                  ? AppTheme.textSecondaryDark
                  : AppTheme.textSecondaryLight,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// MOVIES row card (0.2.9): same PosterCard style as the grid card
/// (poster + score badge + title) — the meta line says "Movie"
/// instead of an episode count, since a movie is one episode.
class _MovieCard extends StatelessWidget {
  const _MovieCard({required this.anime, required this.onTap});

  final Anime anime;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final int score = (anime.rating * 10).round();
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PosterArt(anime: anime, borderRadius: 0, showTitle: false),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.star_rounded,
                            color: Colors.white,
                            size: 13,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$score%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            anime.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark
                  ? AppTheme.textPrimaryDark
                  : AppTheme.textPrimaryLight,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${anime.year} • Movie',
            style: TextStyle(
              color: isDark
                  ? AppTheme.textSecondaryDark
                  : AppTheme.textSecondaryLight,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// AIRING SOON card (0.2.10): same PosterCard shape as the MOVIES
/// row — poster + title — with an accent "EP n · in 2d 4h" countdown
/// line instead of a score. Tap opens the normal Detail screen.
class _AiringCard extends StatelessWidget {
  const _AiringCard({required this.entry, required this.onTap});

  final AiringEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Anime anime = Anime(
      id: 'anilist-${entry.anilistId}',
      anilistId: entry.anilistId,
      title: entry.title,
      rating: 0,
      year: 0,
      episodeCount: entry.episodeCount,
      genres: const <String>[],
      synopsis: '',
      gradient: const <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      posterUrl: entry.posterUrl,
    );
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: PosterArt(anime: anime, borderRadius: 0, showTitle: false),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark
                  ? AppTheme.textPrimaryDark
                  : AppTheme.textPrimaryLight,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'EP ${entry.episode} · ${formatAiringCountdown(entry.airingAt)}',
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
