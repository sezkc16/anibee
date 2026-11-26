import 'package:flutter/material.dart';
import 'package:reicon_flutter/reicon_flutter.dart';

import '../models.dart';
import '../settings_store.dart';
import '../theme.dart';
import 'poster.dart';
import 'reicon_icon.dart';

/// One Miruro-style episode card — the Detail screen's card, shared
/// with the in-player episode chooser (0.2.11).
///
/// Thumbnail (104×82, EP badge, completed check) + title (1 line) +
/// 2-line synopsis + date row (CC icon + download button) + thin
/// accent progress bar. The download button is shown only when
/// [onToggleDownload] is given (the player chooser passes none —
/// downloads happen from Detail). [selected] draws an accent border
/// for the currently-playing episode in the player chooser.
class EpisodeCard extends StatelessWidget {
  const EpisodeCard({
    super.key,
    required this.anime,
    required this.episode,
    required this.store,
    required this.onTap,
    this.onToggleDownload,
    this.selected = false,
  });

  final Anime anime;
  final Episode episode;
  final SettingsStore store;
  final VoidCallback onTap;
  final VoidCallback? onToggleDownload;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color card = isDark ? AppTheme.cardDark : AppTheme.cardLight;
    final Color primaryText =
        isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight;
    final Color secondaryText =
        isDark ? AppTheme.textSecondaryDark : AppTheme.textSecondaryLight;
    final Color accent = Theme.of(context).colorScheme.primary;
    final String key = '${anime.id}:${episode.number}';
    final String? status = store.downloadStatus[key];
    final double progress = store.downloadProgress[key] ?? 0;
    // 0.2.5: real watch progress (accent bar) + completed state.
    final double watchProgress = store.episodeProgressFor(anime, episode);
    final bool completed = store.isEpisodeCompleted(anime, episode);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(12),
            border: selected ? Border.all(color: accent, width: 1.5) : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 104,
                      height: 82,
                      child: Stack(
                        children: <Widget>[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 104,
                              height: 82,
                              // 0.2.9: per-episode thumbnail from
                              // AniList streamingEpisodes. The
                              // poster stays underneath — while the
                              // thumbnail loads (or if it fails),
                              // the poster shows, never a blank tile.
                              child: Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  PosterArt(
                                    anime: anime,
                                    showTitle: false,
                                  ),
                                  if (episode.thumbnailUrl != null)
                                    Image.network(
                                      episode.thumbnailUrl!,
                                      fit: BoxFit.cover,
                                      loadingBuilder:
                                          (
                                            BuildContext context,
                                            Widget child,
                                            ImageChunkEvent? progress,
                                          ) {
                                            if (progress == null) {
                                              return child;
                                            }
                                            return const SizedBox.shrink();
                                          },
                                      errorBuilder:
                                          (
                                            BuildContext context,
                                            Object error,
                                            StackTrace? stackTrace,
                                          ) {
                                            return const SizedBox.shrink();
                                          },
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'EP ${episode.number}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          if (completed)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: accent,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              episode.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            // 0.2.31: no fake synopsis — when Kitsu has
                            // none, the slot is hidden, not blank.
                            if (episode.synopsis.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 4),
                              Text(
                                episode.synopsis,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Row(
                              children: <Widget>[
                                Icon(
                                  Icons.closed_caption_rounded,
                                  size: 18,
                                  color: secondaryText,
                                ),
                                const Spacer(),
                                // 0.2.31: no fake air date either.
                                if (episode.airDate.isNotEmpty) ...<Widget>[
                                  Text(
                                    episode.airDate,
                                    style: TextStyle(
                                      color: secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                ],
                                if (onToggleDownload != null)
                                  EpisodeDownloadButton(
                                    status: status,
                                    progress: progress,
                                    accent: accent,
                                    onTap: onToggleDownload!,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // 0.2.5: thin accent progress bar along the card's
                // bottom edge (full when completed). Unwatched = none.
                if (watchProgress > 0)
                  SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      value: watchProgress,
                      backgroundColor: Colors.transparent,
                      color: accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-episode download button: download -> progress -> downloaded.
/// 'paused' (0.2.11, Wi-Fi-only) and 'failed' both show the download
/// icon — tapping resumes / retries.
class EpisodeDownloadButton extends StatelessWidget {
  const EpisodeDownloadButton({
    super.key,
    required this.status,
    required this.progress,
    required this.accent,
    required this.onTap,
  });

  final String? status;
  final double progress;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (status == 'downloaded') {
      // Reicon check (not a generic Material download icon).
      child = ReiconIcon(Reicon.outline.check, size: 22, color: accent);
    } else if (status == 'downloading') {
      child = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          value: progress,
          strokeWidth: 2.5,
          color: accent,
        ),
      );
    } else {
      // Reicon Outline download (reicon.dev) — the app's download mark.
      child = ReiconIcon(
        Reicon.outline.download,
        size: 22,
        color: Theme.of(context).brightness == Brightness.dark
            ? AppTheme.textSecondaryDark
            : AppTheme.textSecondaryLight,
      );
    }
    return IconButton(
      onPressed: onTap,
      icon: child,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
