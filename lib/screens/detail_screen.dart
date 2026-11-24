import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reicon_flutter/reicon_flutter.dart';

import '../models.dart';
import '../player/trailer_player.dart';
import '../services/anilist_service.dart';
import '../services/app_services.dart';
import '../services/miruro_resolver.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../widgets/episode_list.dart';
import '../widgets/page_route.dart';
import '../widgets/poster.dart';
import '../widgets/premium_picker.dart';
import '../widgets/reicon_icon.dart';
import '../widgets/server_sheet.dart';
import '../widgets/top_notification.dart';
import 'anipm_web_player_screen.dart';
import 'full_player_screen.dart';

/// Detail screen.
/// Layout: banner -> title -> My List -> synopsis -> server row
/// (Anilili-style dropdown + SUB/DUB + status) -> episodes. The banner
/// is the poster image only (0.2.5: the YouTube trailer embed failed
/// on the phone with Error 153, so trailers are gone entirely).
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.anime,
    required this.store,
    required this.services,
    this.autoPlay = false,
    this.player,
  });

  final Anime anime;
  final SettingsStore store;
  final AppServices services;

  /// Home "Watch Now" opens straight into the full player.
  final bool autoPlay;

  /// Player engine, injected by tests (constructed in runAsync —
  /// Player()'s initializer handshake stalls in the fake-time zone).
  /// Production passes null and Detail creates its own.
  final TrailerPlayer? player;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final TrailerPlayer _trailer;
  late List<Episode> _episodes;

  /// The anime shown on this screen. Starts as the opened anime;
  /// the season selector (0.2.8) swaps it for another season's entry
  /// (same title family, own episodes) via mediaById.
  late Anime _anime;

  String _subDub = 'Sub';
  bool _connecting = false;
  Timer? _connectTimer;

  /// Season chain (0.2.8): AniList SEQUEL/PREQUEL relations. Empty =
  /// single season → no selector is shown.
  List<SeasonInfo> _seasons = <SeasonInfo>[];
  bool _selectingSeason = false;

  /// Debrid source selected in the server sheet ('torbox' |
  /// 'realdebrid'), or null for a normal Miruro/Anikoto server.
  String? _selectedDebrid;

  SettingsStore get _store => widget.store;
  AppServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _anime = widget.anime;
    _trailer = widget.player ?? TrailerPlayer();
    _episodes = mockEpisodes(_anime);
    unawaited(_loadDetails());
    unawaited(_loadSeasons());
    unawaited(_loadEpisodeThumbnails());
    if (widget.autoPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _episodes.isNotEmpty) _openFullPlayer();
      });
    }
  }

  /// Fill in what the opener didn't know (0.2.13): airing titles
  /// opened from Home/Search often arrive with an empty synopsis
  /// and episodeCount 0 (AniList `episodes` is null while a series
  /// airs), so Detail showed a blank synopsis and the generic "No
  /// episodes available yet". Fetch the full media entry and merge
  /// the synopsis, the aired episode count (nextAiringEpisode.episode
  /// - 1, via [animeFromMedia]) and the upcoming EP + air date.
  /// Best-effort — failure leaves the opener's data as-is. Runs
  /// before the thumbnails load so the merged anime is the one the
  /// thumbnail identity guard sees.
  Future<void> _loadDetails() async {
    if (_anime.synopsis.isNotEmpty &&
        _anime.episodeCount > 0 &&
        _anime.nextEpisode != null) {
      return;
    }
    final int? anilistId =
        _anime.anilistId ?? await _services.anilist.resolveId(_anime.title);
    if (anilistId == null) return;
    final Anime? full = await _services.anilist.mediaById(anilistId);
    if (!mounted || full == null) return;
    final bool needsSynopsis =
        _anime.synopsis.isEmpty && full.synopsis.isNotEmpty;
    final bool needsEpisodes =
        _anime.episodeCount == 0 && full.episodeCount > 0;
    final bool needsAiring =
        _anime.nextEpisode == null && full.nextEpisode != null;
    if (!needsSynopsis && !needsEpisodes && !needsAiring) return;
    setState(() {
      _anime = _anime.copyWith(
        synopsis: needsSynopsis ? full.synopsis : null,
        episodeCount: needsEpisodes ? full.episodeCount : null,
        nextEpisode: needsAiring ? full.nextEpisode : null,
        nextEpisodeIn: needsAiring ? full.nextEpisodeIn : null,
        nextEpisodeAt: needsAiring ? full.nextEpisodeAt : null,
      );
      if (needsEpisodes) _episodes = mockEpisodes(_anime);
    });
    if (needsEpisodes) unawaited(_loadEpisodeThumbnails());
  }

  /// Fetch the season chain for this anime (one GraphQL query when
  /// there is no sequel/prequel — the walk stops at the first hop).
  /// Failure = no selector; the episode list stays as-is.
  /// 0.2.9: most catalogue titles have NO stored anilistId (My Hero
  /// Academia didn't — the 0.2.8 phone test showed no selector), so
  /// resolve by title first, exactly like the Miruro resolver does.
  /// Unresolvable = no selector, episode list as-is.
  Future<void> _loadSeasons() async {
    int? anilistId = _anime.anilistId;
    anilistId ??= await _services.anilist.resolveId(_anime.title);
    if (anilistId == null) return;
    final List<SeasonInfo> seasons = await _services.anilist.fetchSeasons(
      anilistId,
    );
    if (!mounted) return;
    if (seasons.length > 1) setState(() => _seasons = seasons);
  }

  /// Per-episode thumbnails from AniList `streamingEpisodes` (0.2.9):
  /// same id resolution as _loadSeasons. Best-effort — failure or
  /// no thumbnails = poster fallback per episode. The map is
  /// applied to _episodes once (cached in the episode list
  /// itself), so scrolling never re-fetches. The identity guard
  /// drops a stale response if the user switched seasons mid-fetch.
  Future<void> _loadEpisodeThumbnails() async {
    final Anime animeAtCall = _anime;
    final int? anilistId =
        _anime.anilistId ?? await _services.anilist.resolveId(_anime.title);
    if (anilistId == null) return;
    final Map<int, String> thumbs = await _services.anilist
        .fetchEpisodeThumbnails(anilistId, episodeCount: _anime.episodeCount);
    if (!mounted || thumbs.isEmpty) return;
    if (!identical(_anime, animeAtCall)) return;
    setState(() {
      _episodes = _episodes
          .map(
            (Episode ep) => thumbs.containsKey(ep.number)
                ? ep.copyWith(thumbnailUrl: thumbs[ep.number])
                : ep,
          )
          .toList();
    });
  }

  /// Switch the episode list to another season: load that season's
  /// own AniList entry and rebuild the episodes through the existing
  /// path (mockEpisodes + the same resolver). The banner, title,
  /// synopsis and rating follow the season's own entry.
  Future<void> _selectSeason(SeasonInfo season) async {
    if (_selectingSeason || season.id == _anime.anilistId) return;
    setState(() => _selectingSeason = true);
    final Anime? next = await _services.anilist.mediaById(season.id);
    if (!mounted) return;
    if (next == null) {
      setState(() => _selectingSeason = false);
      TopNotification.show(context, 'Season load nahi hua — dobara try karo.');
      return;
    }
    setState(() {
      _anime = next;
      _episodes = mockEpisodes(next);
      _selectingSeason = false;
    });
    // The new season has its own episode thumbnails.
    unawaited(_loadEpisodeThumbnails());
  }

  @override
  void dispose() {
    _connectTimer?.cancel();
    _trailer.dispose();
    super.dispose();
  }

  /// Opens the Anilili-style server sheet; on pick, switches the
  /// preferred server and shows "Reconnecting..." briefly. A Debrid
  /// pick stores the debrid choice instead (playback resolves
  /// through the debrid API when PLAY is tapped).
  Future<void> _showServerSheet() async {
    final ({String server, String subDub, String? debrid})? result =
        await showServerSheet(
          context: context,
          store: _store,
          currentServer: _store.preferredServer,
          subDub: _subDub,
          currentDebrid: _selectedDebrid,
        );
    if (result == null) return;
    if (result.debrid != null) {
      await _store.setPreferredServer(result.server);
      setState(() {
        _subDub = result.subDub;
        _selectedDebrid = result.debrid;
        _connecting = true;
      });
    } else {
      await _store.setPreferredServer(result.server);
      setState(() {
        _subDub = result.subDub;
        _selectedDebrid = null;
        _connecting = true;
      });
    }
    _connectTimer?.cancel();
    _connectTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _connecting = false);
    });
  }

  /// Resolve a real stream for an episode, with a progress dialog
  /// (status text + Cancel). Returns null when resolve fails or the
  /// user cancels — the caller shows the error state, never a blank
  /// player.
  Future<ResolvedStream?> _resolveForEpisode(Episode episode) async {
    bool cancelled = false;
    bool dialogOpen = true;
    final ValueNotifier<String> status = ValueNotifier<String>(
      'Finding sources…',
    );
    final Future<ResolvedStream?> work = _services.resolveEpisode(
      anime: _anime,
      episode: episode.number,
      subDub: _subDub,
      store: _store,
      debrid: _selectedDebrid,
      // 0.2.11: the chosen server is actually routed now (before,
      // every non-debrid resolve silently went to Miruro).
      server: _store.preferredServer,
      onProgress: (String s) {
        if (!cancelled) status.value = s;
      },
      isCancelled: () => cancelled,
    );
    // Close the dialog the moment the work finishes.
    unawaited(
      work.then((_) {
        if (dialogOpen && mounted) Navigator.of(context).pop();
      }),
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(
              'Episode ${episode.number}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            content: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (BuildContext context, String value, Widget? _) {
                return Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(value)),
                  ],
                );
              },
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
    dialogOpen = false;
    status.dispose();
    if (cancelled) return null;
    return work;
  }

  /// Real-stream error dialog: Retry / Close. Never a blank player.
  Future<void> _showResolveError(String message, Episode episode) async {
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Couldn\'t load episode'),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop('retry'),
            child: const Text('Retry'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (choice == 'retry') {
      await _openFullPlayer(episode: episode);
    }
  }

  Future<void> _openFullPlayer({
    Episode? episode,
    bool markPlayed = true,
  }) async {
    // 0.2.13: nothing to play yet (unreleased season) — PLAY is
    // hidden in that state, but guard here too: `_episodes.first`
    // would throw on an empty list.
    if (_episodes.isEmpty) return;
    final Episode initial =
        episode ??
        _episodes.firstWhere(
          (Episode e) =>
              e.number ==
              (_store.progressEpisodeFor(_anime) ?? _anime.currentEpisode ?? 1),
          orElse: () => _episodes.first,
        );
    // M2: resolve a REAL stream first — never open the player on a
    // placeholder for an episode tap.
    final ResolvedStream? stream = await _resolveForEpisode(initial);
    if (stream == null) {
      if (!mounted) return;
      await _showResolveError(
        _services.anisuge.lastError ??
            _services.anikage.lastError ??
            _services.anipm.lastError ??
            _services.miruro.lastError ??
            'No sources found for episode ${initial.number}. '
                'Check your connection or try another server.',
        initial,
      );
      return;
    }
    if (markPlayed) {
      _store.markProgress(_anime, initial.number);
      _autoStatus(initial);
    }
    await _openPlayerWithStream(stream: stream, initial: initial);
  }

  /// The player picked another server: remember the choice (Detail's
  /// resolver reads these fields on the next resolve).
  Future<void> _onPlayerServerChanged(
    String server,
    String subDub,
    String? debrid,
  ) async {
    await _store.setPreferredServer(server);
    _subDub = subDub;
    _selectedDebrid = debrid;
  }

  Future<void> _openPlayerWithStream({
    required ResolvedStream stream,
    required Episode initial,
  }) async {
    // 0.2.25: AniPM returns a WebView embed, not an mpv stream —
    // it plays in the fullscreen WebView player with the site's
    // own controls, never in FullPlayerScreen.
    if (stream.playback == StreamPlayback.webEmbed) {
      await Navigator.of(context).push(
        SmoothPageRoute<void>(
          builder: (BuildContext context) => AnipmWebPlayerScreen(
            store: _store,
            anime: _anime,
            episodes: _episodes,
            initialEpisode: initial,
            initialEmbedUrl: stream.url,
            subDub: _subDub,
            onEpisodeChanged: _onPlayerEpisodeChanged,
            onResolveEpisode: (Episode episode) async {
              return _services.resolveEpisode(
                anime: _anime,
                episode: episode.number,
                subDub: _subDub,
                store: _store,
                debrid: _selectedDebrid,
                server: _store.preferredServer,
              );
            },
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      SmoothPageRoute<void>(
        builder: (BuildContext context) => FullPlayerScreen(
          trailer: _trailer,
          store: _store,
          anime: _anime,
          episodes: _episodes,
          initialEpisode: initial,
          stream: stream,
          onEpisodeChanged: _onPlayerEpisodeChanged,
          resolver: _services.miruro,
          anilist: _services.anilist,
          subDub: _subDub,
          currentDebrid: _selectedDebrid,
          onServerChanged: _onPlayerServerChanged,
          downloads: _services.downloads,
          onResolveEpisode: (Episode episode) async {
            return _services.resolveEpisode(
              anime: _anime,
              episode: episode.number,
              subDub: _subDub,
              store: _store,
              debrid: _selectedDebrid,
              server: _store.preferredServer,
            );
          },
        ),
      ),
    );
    // Back from a real stream: stop the player — the banner is a
    // poster now, nothing keeps playing here.
    await _trailer.stop();
  }

  void _onPlayerEpisodeChanged(Episode episode) {
    _store.markProgress(_anime, episode.number);
    _autoStatus(episode);
  }

  /// Playing an episode puts it in the Collection lists automatically:
  /// last episode → Finished, anything else → Watching. The status is
  /// also pushed to AniList + MAL when the user is logged in (M2).
  void _autoStatus(Episode episode) {
    final String status = episode.number >= _anime.episodeCount
        ? 'finished'
        : 'watching';
    _store.setListStatus(_anime, status);
    unawaited(
      _services.pushListStatus(store: _store, anime: _anime, status: status),
    );
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'watching':
        return 'Watching';
      case 'finished':
        return 'Finished';
      case 'plan':
        return 'To Be Watched';
      default:
        return 'Not in list';
    }
  }

  Future<void> _pickListStatus() async {
    final String? current = _store.statusOf(_anime);
    final String? picked = await showPremiumPicker<String>(
      context: context,
      title: 'My List',
      selected: current,
      options: const <PremiumPickerOption<String>>[
        PremiumPickerOption(value: 'plan', label: 'To Be Watched'),
        PremiumPickerOption(value: 'watching', label: 'Watching'),
        PremiumPickerOption(value: 'finished', label: 'Finished'),
        PremiumPickerOption(
          value: '',
          label: 'Remove from list',
          destructive: true,
        ),
      ],
    );
    if (picked == null) return;
    if (picked.isEmpty) {
      _store.setListStatus(_anime, null);
    } else {
      _store.setListStatus(_anime, picked);
      unawaited(
        _services.pushListStatus(store: _store, anime: _anime, status: picked),
      );
    }
  }

  /// Real download (0.2.5): resolve the episode's stream, then hand
  /// it to the app-lifetime DownloadService — a real HLS/file download
  /// with resume, not the old timer animation. Tapping again cancels
  /// (downloading) or deletes the file (downloaded).
  Future<void> _toggleDownload(Episode episode) async {
    final String key = '${_anime.id}:${episode.number}';
    final String? status = _store.downloadStatus[key];
    if (status == 'downloaded' || status == 'downloading') {
      await _services.downloads.removeDownload(key, _store);
      return;
    }
    final ResolvedStream? stream = await _resolveForEpisode(episode);
    if (stream == null || !mounted) return;
    final bool started = await _services.downloads.startDownload(
      anime: _anime,
      episode: episode,
      stream: stream,
      store: _store,
    );
    if (!mounted) return;
    if (_store.downloadStatus[key] == 'failed') {
      TopNotification.show(context, 'Download failed — tap again to retry.');
    } else if (!started && _store.downloadStatus[key] == 'paused') {
      // 0.2.11: Wi-Fi-only blocked the start on mobile data.
      TopNotification.show(
        context,
        'Wi-Fi only on hai — mobile data pe download nahi hoga.',
        detail: 'Wi-Fi pe aate hi dobara tap karo.',
      );
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

    return Scaffold(
      body: ListenableBuilder(
        listenable: _store,
        builder: (BuildContext context, Widget? _) {
          final bool saved = _store.isSaved(_anime);
          // 0.2.18: pinned header REVERTED — the whole page scrolls
          // again (0.2.16 behavior): banner/title/PLAY/synopsis/
          // server picker scroll away with the episode list.
          return ListView(
            padding: const EdgeInsets.only(bottom: 110),
            children: <Widget>[
              _PosterHero(
                anime: _anime,
                onBack: () => Navigator.of(context).pop(),
                onToggleSaved: () => _store.toggleSaved(_anime),
                saved: saved,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  _anime.title,
                  style: TextStyle(
                    color: primaryText,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: <Widget>[
                    Row(
                      children: List<Widget>.generate(
                        5,
                        (int i) => Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: i < 4
                              ? const Color(0xFFFFC531)
                              : const Color(0xFF3A3A48),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 0.2.17: the meta text is NOT fixed-width — on a
                    // narrow screen (and in the wide test font) the
                    // bare Text overflowed the row. Ellipsize it.
                    Flexible(
                      child: Text(
                        '${_anime.rating} • ${_anime.year} • '
                        '${_anime.episodeCount} eps • TV-13',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: secondaryText, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Row(
                  children: <Widget>[
                    // PLAY first (leftmost), same height as the genre
                    // pills — compact, fits the row. Hidden while no
                    // episodes exist (0.2.13: an unreleased season
                    // must not offer a PLAY that opens nothing).
                    if (_episodes.isNotEmpty)
                      InkWell(
                        onTap: () => _openFullPlayer(),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.play_arrow_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'PLAY',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_episodes.isNotEmpty) const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            ..._anime.genres.map(
                              (String g) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? AppTheme.cardDark
                                        : AppTheme.cardLight,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    g,
                                    style: TextStyle(
                                      color: primaryText,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
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
              // MY LIST — Collection status picker (Watching / Finished /
              // To Be Watched). Bookmarking also lands here (To Be Watched).
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: InkWell(
                  onTap: _pickListStatus,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.cardDark : AppTheme.cardLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.bookmark_rounded, color: accent, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          'My List',
                          style: TextStyle(
                            color: primaryText,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _statusLabel(_store.statusOf(_anime)),
                          style: TextStyle(color: secondaryText, fontSize: 13),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: secondaryText,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'SYNOPSIS',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _anime.synopsis,
                  style: TextStyle(
                    color: primaryText,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
              // Server row (Anilili style, above the episodes list):
              // compact dropdown + SUB/DUB pill + connection status.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Row(
                  children: <Widget>[
                    InkWell(
                      onTap: _showServerSheet,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.cardDark
                              : AppTheme.cardLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ReiconIcon(
                              Reicon.outline.download,
                              size: 18,
                              color: accent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _store.preferredServer,
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            ReiconIcon(
                              Reicon.outline.chevronDown,
                              size: 16,
                              color: secondaryText,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.cardDark : AppTheme.cardLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final String v in <String>['Sub', 'Dub'])
                            InkWell(
                              onTap: () => setState(() => _subDub = v),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _subDub == v
                                      ? accent
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  v.toUpperCase(),
                                  style: TextStyle(
                                    color: _subDub == v
                                        ? Colors.white
                                        : secondaryText,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _connecting
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: accent,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'Reconnecting ${_store.preferredServer}...',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 16,
                                  color: AppTheme.success,
                                ),
                                const SizedBox(width: 6),
                                // 0.2.17: same as the Reconnecting
                                // branch above — the bare Text
                                // overflowed the row on narrow
                                // screens (wide test font).
                                Flexible(
                                  child: Text(
                                    'Connected',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
              // Season selector (0.2.8): only when the anime has
              // more than one season (AniList SEQUEL/PREQUEL chain).
              // Switching loads that season's own entry and its
              // episodes through the existing path.
              if (_seasons.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            'SEASON',
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          if (_selectingSeason) ...<Widget>[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            for (int i = 0; i < _seasons.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: InkWell(
                                  onTap: () => _selectSeason(_seasons[i]),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _seasons[i].id == _anime.anilistId
                                          ? accent
                                          : (isDark
                                                ? AppTheme.cardDark
                                                : AppTheme.cardLight),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      'Season ${i + 1}',
                                      style: TextStyle(
                                        color:
                                            _seasons[i].id == _anime.anilistId
                                            ? Colors.white
                                            : primaryText,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              EpisodeSection(
                // A new season is a new anime: reset the episode
                // section's state (grid mode, range, highlight).
                key: ValueKey<String>(_anime.id),
                anime: _anime,
                episodes: _episodes,
                store: _store,
                audioFilter: _subDub,
                onAudioFilterChanged: (String v) {
                  if (v == 'Sub' || v == 'Dub') {
                    setState(() => _subDub = v);
                  }
                },
                onPlay: (Episode ep) {
                  _openFullPlayer(episode: ep);
                },
                onToggleDownload: _toggleDownload,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The detail banner (0.2.5): the poster image only. The YouTube
/// trailer embed is gone — it failed on the phone (Error 153) — so
/// there is no video, no TRAILER badge, no tap-to-play here.
class _PosterHero extends StatelessWidget {
  const _PosterHero({
    required this.anime,
    required this.onBack,
    required this.onToggleSaved,
    required this.saved,
  });

  final Anime anime;
  final VoidCallback onBack;
  final VoidCallback onToggleSaved;
  final bool saved;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
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
                  Colors.black.withValues(alpha: 0.35),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                ],
              ),
            ),
          ),
          Positioned(
            top: 48,
            left: 12,
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
              ),
              onPressed: onBack,
            ),
          ),
          Positioned(
            top: 48,
            right: 12,
            child: IconButton(
              icon: Icon(
                saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                color: Colors.white,
              ),
              onPressed: onToggleSaved,
            ),
          ),
        ],
      ),
    );
  }
}
