import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'player/trailer_player.dart';
import 'screens/full_player_screen.dart';
import 'services/app_services.dart';
import 'services/miruro_resolver.dart';
import 'services/provider_config.dart';
import 'services/update_service.dart';
import 'settings_store.dart';
import 'widgets/top_notification.dart';
import 'screens/collection_screen.dart';
import 'screens/detail_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/glass_nav.dart';
import 'widgets/page_route.dart';

/// Root tab shell: 4 tabs under the liquid-glass nav pill.
/// The pill is Positioned directly on the Stack (never wrapped in
/// Transform/Padding — Zeus b90 lesson).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    required this.configService,
    required this.services,
    this.checkForUpdate,
  });

  final SettingsStore store;
  final ProviderConfigService configService;
  final AppServices services;

  /// Update check (0.2.17): override for tests — a function that
  /// returns the newer release, or null. Production passes nothing
  /// and the real [UpdateService.checkForUpdate] runs.
  final Future<UpdateAvailable?> Function()? checkForUpdate;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 0.2.17: update check on cold start — fire-and-forget after
    // the first frame, never blocking launch. Any failure is
    // silent inside the service (offline / private repo).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowUpdateDialog());
    });
  }

  /// Show "A new version is available" once per cold start when a newer
  /// release exists and the user has not dismissed that version
  /// with "Later". Download opens the release page in the
  /// browser (iOS cannot install an IPA from inside the app).
  Future<void> _maybeShowUpdateDialog() async {
    if (!mounted) return;
    final UpdateAvailable? update =
        await (widget.checkForUpdate ?? UpdateService.checkForUpdate)();
    if (!mounted || update == null) return;
    if (widget.store.skippedUpdateVersion == update.tag) return;
    final bool? download = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF17171F),
          title: Text(
            'A new version is available — ${update.tag}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: const Text(
            'Download the new AniBee version and install it with eSign.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                'Later',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Download',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (download == true) {
      await launchUrl(
        Uri.parse(update.url),
        mode: LaunchMode.externalApplication,
      );
    } else {
      await widget.store.skipUpdateVersion(update.tag);
    }
  }

  void _openAnime(Anime anime, {bool autoPlay = false}) {
    Navigator.of(context).push(
      SmoothPageRoute<void>(
        builder: (BuildContext context) => DetailScreen(
          anime: anime,
          store: widget.store,
          services: widget.services,
          autoPlay: autoPlay,
        ),
      ),
    );
  }

  /// Play a completed download offline (0.2.5): rebuild the anime
  /// from the download record, open the local file in the full
  /// player. Episode switches inside the player prefer the local
  /// file when that episode is downloaded, else resolve online.
  void _playOffline(String key) {
    final Map<String, dynamic>? record = widget.store.downloadRecordFor(key);
    if (record == null) {
      TopNotification.show(
        context,
        'Download not found — please download it again.',
      );
      return;
    }
    final String status = widget.store.downloadStatus[key] ?? '';
    if (status == 'downloading') {
      TopNotification.show(context, 'Still downloading — please wait.');
      return;
    }
    if (status == 'failed') {
      TopNotification.show(
        context,
        'Download failed — re-download it from the episode list.',
      );
      return;
    }
    final Anime anime = Anime(
      id: record['animeId'] as String? ?? '',
      anilistId: (record['anilistId'] as num?)?.toInt(),
      title: record['title'] as String? ?? 'Unknown',
      rating: 0,
      year: 0,
      episodeCount: (record['episodeCount'] as num?)?.toInt() ?? 0,
      genres: const <String>[],
      synopsis: '',
      gradient: const <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      posterUrl: record['posterUrl'] as String?,
    );
    final List<Episode> episodes = mockEpisodes(anime);
    final int epNum = (record['episode'] as num?)?.toInt() ?? 1;
    final Episode initial = episodes.firstWhere(
      (Episode e) => e.number == epNum,
      orElse: () => episodes.first,
    );
    final ResolvedStream? local = widget.services.downloads.localStreamFor(
      key,
      widget.store,
    );
    if (local == null) {
      TopNotification.show(
        context,
        'Download file not found — please download it again.',
      );
      return;
    }
    final TrailerPlayer trailer = TrailerPlayer();
    Navigator.of(context)
        .push(
          SmoothPageRoute<void>(
            builder: (BuildContext context) => FullPlayerScreen(
              trailer: trailer,
              store: widget.store,
              anime: anime,
              episodes: episodes,
              initialEpisode: initial,
              stream: local,
              onEpisodeChanged: (Episode ep) =>
                  widget.store.markProgress(anime, ep.number),
              resolver: widget.services.miruro,
              anilist: widget.services.anilist,
              subDub: 'Sub',
              onResolveEpisode: (Episode episode) async {
                final String k = '${anime.id}:${episode.number}';
                final ResolvedStream? offline = widget.services.downloads
                    .localStreamFor(k, widget.store);
                if (offline != null) return offline;
                return widget.services.resolveEpisode(
                  anime: anime,
                  episode: episode.number,
                  subDub: 'Sub',
                  store: widget.store,
                );
              },
            ),
          ),
        )
        .then((_) => trailer.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          IndexedStack(
            index: _tab,
            children: <Widget>[
              _TabFade(
                active: _tab == 0,
                child: HomeScreen(
                  store: widget.store,
                  anilist: widget.services.anilist,
                  airing: widget.services.airing,
                  airingNotifications: widget.services.airingNotifications,
                  onOpenAnime: _openAnime,
                  onOpenSearch: () => setState(() => _tab = 1),
                  onWatchNow: (Anime anime) =>
                      _openAnime(anime, autoPlay: true),
                ),
              ),
              _TabFade(
                active: _tab == 1,
                child: SearchScreen(
                  onOpenAnime: _openAnime,
                  anilist: widget.services.anilist,
                ),
              ),
              _TabFade(
                active: _tab == 2,
                child: CollectionScreen(
                  store: widget.store,
                  services: widget.services,
                  onOpenAnime: _openAnime,
                  onBrowse: () => setState(() => _tab = 1),
                ),
              ),
              _TabFade(
                active: _tab == 3,
                child: DownloadsScreen(
                  store: widget.store,
                  services: widget.services,
                  onPlayDownload: _playOffline,
                  embedded: true,
                ),
              ),
              _TabFade(
                active: _tab == 4,
                child: SettingsScreen(
                  store: widget.store,
                  configService: widget.configService,
                  services: widget.services,
                  onPlayDownload: _playOffline,
                ),
              ),
            ],
          ),
          // 0.2.16: hide the nav pill entirely while the keyboard is
          // open. The Scaffold resizes for the keyboard, so the
          // bottom-Positioned pill used to ride up and sit ON TOP of
          // the Search results, overlapping the poster grid and
          // hiding titles (user 2026-11-24 01:51, Search screenshot
          // with the keyboard open). `viewInsets.bottom > 0` is the
          // keyboard signal; the pill returns the moment it closes.
          // Covers both nav styles and all 5 tabs — the pill is the
          // only thing hidden, tab state is untouched.
          if (MediaQuery.of(context).viewInsets.bottom <= 0)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              // ListenableBuilder so the pill restyles the moment the
              // Navigation Style is tapped in Settings.
              child: ListenableBuilder(
                listenable: widget.store,
                builder: (BuildContext context, Widget? _) => GlassNavBar(
                  currentIndex: _tab,
                  onTap: (int i) => setState(() => _tab = i),
                  accent: accent,
                  isDark: isDark,
                  navStyle: widget.store.navStyle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fade + slight rise when a tab becomes active: tab switches feel
/// smooth instead of snapping (IndexedStack alone swaps instantly).
/// State is preserved — IndexedStack keeps every tab alive; this only
/// animates the incoming tab's opacity on activation.
class _TabFade extends StatefulWidget {
  const _TabFade({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<_TabFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.015),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant _TabFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
