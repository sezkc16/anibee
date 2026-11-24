import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models.dart';
import '../services/miruro_resolver.dart';
import '../settings_store.dart';
import '../widgets/top_notification.dart';

/// AniPM WebView player (0.2.25).
///
/// AniPM has no plain stream URL: its video plays inside the
/// settlar embed (`https://embed.settlar.io/embed/v1?t=…`) via MSE
/// blob URLs, and the embed itself is Cloudflare-gated from
/// datacenter IPs. So AniPM episodes play HERE — a fullscreen
/// WebView loading the embed — never in the mpv player. The
/// WebView is a real browser (WKWebView), so the embed sees a
/// genuine browser environment, unlike the VM's curl probes.
///
/// What this screen does NOT do (v1, stated plainly — do not
/// wire these up for AniPM):
/// - no mpv subtitle overlay (the embed has its own subtitles),
/// - no PiP, no Cast, no downloads, no skip-intro, no resume
///   position — the embed owns all playback.
/// Episode switching re-resolves through [onResolveEpisode] and
/// reloads the embed for the new episode; progress is marked via
/// [onEpisodeChanged] exactly like the mpv player.
///
/// The embed URL is fetched fresh on every resolve (it expires),
/// so this screen never caches one. If the embed fails to load
/// (Cloudflare challenge, no network), the error state shows the
/// reason + Retry — never a blank screen.
class AnipmWebPlayerScreen extends StatefulWidget {
  const AnipmWebPlayerScreen({
    super.key,
    required this.store,
    required this.anime,
    required this.episodes,
    required this.initialEpisode,
    required this.initialEmbedUrl,
    required this.onResolveEpisode,
    this.onEpisodeChanged,
    this.subDub = 'Sub',
    this.webViewBuilder,
  });

  final SettingsStore store;
  final Anime anime;
  final List<Episode> episodes;
  final Episode initialEpisode;

  /// Fresh settlar embed URL for the initial episode (resolved
  /// by Detail just before pushing this screen).
  final String initialEmbedUrl;

  /// Resolve the embed stream for another episode. Must return
  /// a [StreamPlayback.webEmbed] stream (or null on failure).
  final Future<ResolvedStream?> Function(Episode episode)
  onResolveEpisode;

  /// Fired when the user jumps to another episode (Detail marks
  /// progress + list status).
  final ValueChanged<Episode>? onEpisodeChanged;

  final String subDub;

  /// Test seam: build the video area for an embed URL. Production
  /// builds the real [WebViewWidget]; tests pass a placeholder so
  /// no platform WebView is needed.
  final Widget Function(BuildContext context, String embedUrl)?
  webViewBuilder;

  @override
  State<AnipmWebPlayerScreen> createState() => _AnipmWebPlayerScreenState();
}

class _AnipmWebPlayerScreenState extends State<AnipmWebPlayerScreen> {
  late Episode _currentEpisode;
  late String _embedUrl;
  WebViewController? _controller;
  bool _loading = true;
  bool _switching = false;
  String? _error;

  bool get _usesRealWebView => widget.webViewBuilder == null;

  @override
  void initState() {
    super.initState();
    _currentEpisode = widget.initialEpisode;
    _embedUrl = widget.initialEmbedUrl;
    // Landscape + immersive, like the mpv player.
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (_usesRealWebView) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              if (!mounted) return;
              setState(() {
                _loading = true;
                _error = null;
              });
            },
            onPageFinished: (String url) {
              if (!mounted) return;
              setState(() => _loading = false);
            },
            onNavigationRequest: (NavigationRequest request) {
              // The embed is a video player, not a browser: keep
              // top-level navigation inside the embed (and the
              // Cloudflare challenge host it may use). Anything
              // else — an ad or an accidental link — stays out.
              final Uri uri = Uri.parse(request.url);
              final String host = uri.host.toLowerCase();
              final bool allowed =
                  host.endsWith('.settlar.io') ||
                  host == 'settlar.io' ||
                  host == 'challenges.cloudflare.com';
              return allowed
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onWebResourceError: (WebResourceError error) {
              if (!mounted || error.isForMainFrame != true) return;
              setState(() {
                _loading = false;
                _error =
                    'AniPM could not load the player'
                    ' (${error.errorCode}). Check your connection '
                    'and try again.';
              });
            },
          ),
        )
        ..loadRequest(Uri.parse(_embedUrl));
    } else {
      _loading = false;
    }
    // One-time note: this source plays in the site's own player.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      TopNotification.show(
        context,
        'AniPM plays in the site player',
        detail:
            'Subtitles, PiP, Cast and downloads are not available for this source.',
        neutral: true,
      );
    });
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadEmbed(String url) async {
    setState(() {
      _embedUrl = url;
      _loading = true;
      _error = null;
    });
    if (_usesRealWebView) {
      await _controller?.loadRequest(Uri.parse(url));
    } else {
      // Test seam: no real WebView — the placeholder rebuilds
      // with the new URL immediately.
      if (mounted) setState(() => _loading = false);
    }
  }

  Episode? get _nextEpisode {
    final int i = widget.episodes.indexWhere(
      (Episode e) => e.number == _currentEpisode.number,
    );
    if (i < 0 || i + 1 >= widget.episodes.length) return null;
    return widget.episodes[i + 1];
  }

  Episode? get _prevEpisode {
    final int i = widget.episodes.indexWhere(
      (Episode e) => e.number == _currentEpisode.number,
    );
    if (i <= 0) return null;
    return widget.episodes[i - 1];
  }

  /// Switch episodes: re-resolve the embed for [episode] and
  /// reload the WebView. A failed resolve leaves the current
  /// episode playing and shows the reason — never a blank screen.
  Future<void> _selectEpisode(Episode episode) async {
    if (episode.number == _currentEpisode.number || _switching) return;
    setState(() => _switching = true);
    final ResolvedStream? stream = await widget.onResolveEpisode(
      episode,
    );
    if (!mounted) return;
    setState(() => _switching = false);
    if (stream == null || stream.playback != StreamPlayback.webEmbed) {
      TopNotification.show(
        context,
        'Couldn\'t load episode ${episode.number} on AniPM',
        detail: 'Try another episode or another source.',
        neutral: true,
      );
      return;
    }
    setState(() => _currentEpisode = episode);
    widget.onEpisodeChanged?.call(episode);
    await _loadEmbed(stream.url);
  }

  Future<void> _showEpisodeSheet() async {
    final Episode? picked = await showModalBottomSheet<Episode>(
      context: context,
      backgroundColor: const Color(0xFF17171F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Episodes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.6,
                        ),
                    itemCount: widget.episodes.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Episode ep = widget.episodes[index];
                      final bool selected =
                          ep.number == _currentEpisode.number;
                      return InkWell(
                        onTap: () => Navigator.of(context).pop(ep),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary
                                : const Color(0xFF26262F),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${ep.number}',
                            style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : Colors.white70,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) await _selectEpisode(picked);
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child:
                  widget.webViewBuilder?.call(context, _embedUrl) ??
                  WebViewWidget(controller: _controller!),
            ),
            if (_loading || _switching)
              const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              ),
            if (_error != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 48),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF17171F),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        'Couldn\'t load episode',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          TextButton(
                            onPressed: () => _loadEmbed(_embedUrl),
                            child: Text(
                              'Retry',
                              style: TextStyle(color: accent),
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.of(context).pop(),
                            child: const Text(
                              'Close',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            // Top bar: back, title + EP, prev/next, episodes.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Color(0xCC000000),
                        Color(0x00000000),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${widget.anime.title} • EP ${_currentEpisode.number} • AniPM ${widget.subDub}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Previous episode',
                        onPressed: _prevEpisode == null
                            ? null
                            : () => _selectEpisode(_prevEpisode!),
                        icon: const Icon(
                          Icons.skip_previous_rounded,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next episode',
                        onPressed: _nextEpisode == null
                            ? null
                            : () => _selectEpisode(_nextEpisode!),
                        icon: const Icon(
                          Icons.skip_next_rounded,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Episodes',
                        onPressed: _showEpisodeSheet,
                        icon: const Icon(
                          Icons.list_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
