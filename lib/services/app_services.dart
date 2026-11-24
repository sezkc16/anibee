import '../models.dart';
import '../settings_store.dart';
import 'airing_notifications.dart';
import 'airing_service.dart';
import 'anilist_service.dart';
import 'animekai_resolver.dart';
import 'debrid_service.dart';
import 'download_service.dart';
import 'miruro_resolver.dart';
import 'oauth_service.dart';
import 'provider_config.dart';

/// All M2 services, created once in main() and passed down through
/// AppShell so screens never construct their own clients.
class AppServices {
  AppServices({
    required this.anilist,
    required this.miruro,
    AnimeKaiResolver? animekai,
    required this.debrid,
    required this.oauth,
    required this.downloads,
    required this.airing,
    required this.airingNotifications,
    this.configService,
  })  : animekai = animekai ?? AnimeKaiResolver(anilist: anilist);

  factory AppServices.create({ProviderConfigService? configService}) {
    final AniListService anilist = AniListService();
    return AppServices(
      anilist: anilist,
      miruro: MiruroResolver(anilist: anilist),
      animekai: AnimeKaiResolver(anilist: anilist),
      debrid: DebridService(),
      oauth: OAuthService(),
      downloads: DownloadService(),
      airing: AiringService(anilist: anilist),
      airingNotifications: AiringNotifications(),
      configService: configService,
    );
  }

  final AniListService anilist;
  final MiruroResolver miruro;

  /// AnimeKai (0.2.23): its own selectable resolver — animekai.ro
  /// chain (search -> anime page -> episode list -> server list ->
  /// megavid embed -> signed HLS). Replaces ReAnime (removed —
  /// flixcloud token API 410s) and AniZone (removed).
  final AnimeKaiResolver animekai;
  final DebridService debrid;
  final OAuthService oauth;

  /// Upcoming airing episodes (0.2.10) + their local alerts.
  final AiringService airing;
  final AiringNotifications airingNotifications;

  /// Schedule airing alerts for [entries] — only when AniList is
  /// connected AND the toggle is on. Best-effort, never throws.
  Future<void> scheduleAiringNotifications({
    required SettingsStore store,
    required List<AiringEntry> entries,
  }) async {
    if (!store.anilistConnected || !store.airingNotifications) return;
    await airingNotifications.scheduleAiring(entries);
  }

  /// Real offline downloads (0.2.5): app-lifetime service, never
  /// tied to a screen — leaving Detail can't stall a download.
  final DownloadService downloads;

  /// Remote config (OAuth client IDs live here in 0.2.3).
  final ProviderConfigService? configService;

  /// Resolve a playable stream for an episode.
  /// [debrid] is null (source resolvers) or 'torbox' / 'realdebrid'.
  /// [server] is the chosen source ('Miruro' | 'AniKoto' |
  /// 'AnimeKai') — 0.2.11 actually routes to it now:
  /// Miruro = justanime chain, AniKoto = anikoto.cz chain, AnimeKai
  /// = the animekai.ro chain (0.2.23). Previously every non-debrid
  /// resolve silently went to Miruro and `preferredServer` was
  /// display-only. When the chosen server fails and the user's
  /// fallback setting is on, the other Miruro-family server is
  /// tried once. Returns null when nothing resolved —
  /// [miruro.lastError] / [animekai.lastError] / the debrid path
  /// carries the reason.
  Future<ResolvedStream?> resolveEpisode({
    required Anime anime,
    required int episode,
    required String subDub,
    required SettingsStore store,
    String? debrid,
    String? server,
    void Function(String status)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (debrid == 'torbox' && store.torboxApiKey != null) {
      return this.debrid.resolveEpisode(
        service: 'torbox',
        apiKey: store.torboxApiKey!,
        title: anime.title,
        episode: episode,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    if (debrid == 'realdebrid' && store.realDebridApiKey != null) {
      return this.debrid.resolveEpisode(
        service: 'realdebrid',
        apiKey: store.realDebridApiKey!,
        title: anime.title,
        episode: episode,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    final String chosen = server ?? store.preferredServer;
    if (chosen == 'AnimeKai') {
      return animekai.resolve(
        anime: anime,
        episodeNumber: episode,
        subDub: subDub,
      );
    }
    return miruro.resolve(
      anime: anime,
      episodeNumber: episode,
      subDub: subDub,
      server: chosen == 'AniKoto' ? 'AniKoto' : 'Miruro',
      fallback: store.fallbackProviders,
    );
  }

  /// Push a Collection status to AniList + MAL (best-effort, never
  /// throws). Resolves the MAL id via AniList when the catalogue entry
  /// doesn't carry one. Called when the user changes My List status
  /// or starts/finishes an anime. [progress] (0.2.11) is the episode
  /// number just finished — when given, AniList also gets the
  /// episode progress (e.g. 5/12), not just the status.
  Future<void> pushListStatus({
    required SettingsStore store,
    required Anime anime,
    required String status, // 'watching' | 'finished' | 'plan'
    int? progress,
  }) async {
    if (store.anilistConnected && anime.anilistId != null) {
      final String anilistStatus = switch (status) {
        'finished' => 'COMPLETED',
        'plan' => 'PLANNING',
        _ => 'CURRENT',
      };
      await anilist.saveListEntry(
        store.anilistToken!,
        anime.anilistId!,
        anilistStatus,
        progress: progress,
      );
    }
    if (store.malConnected) {
      int? malId = anime.malId;
      if (malId == null && anime.anilistId != null) {
        try {
          final Anime? detail = await anilist.mediaById(anime.anilistId!);
          malId = detail?.malId;
        } catch (_) {
          malId = null;
        }
      }
      if (malId != null) {
        final String malStatus = switch (status) {
          'finished' => 'completed',
          'plan' => 'plan_to_watch',
          _ => 'watching',
        };
        await _malWithRefresh(store, (String token) async {
          await oauth.malSaveListStatus(token, malId!, malStatus);
        });
      }
    }
  }

  /// Two-way AniList sync, PULL half (0.2.11): fetch the user's
  /// AniList list and merge it into the local Collection.
  ///
  /// AniList wins on first sync after login ([firstSync] — the
  /// local status for every AniList entry is overwritten). On later
  /// pulls, entries present on AniList update the local status and
  /// progress; local-only titles are left alone (never deleted by a
  /// pull). PAUSED / DROPPED are not synced at all. Synced titles
  /// are kept in the store's synced library so Collection can show
  /// titles that are not in the bundled catalogue.
  ///
  /// Returns the number of entries merged. Best-effort, never
  /// throws. When [force] is false, pulls at most once every
  /// 15 minutes (the Collection open/refresh path calls this
  /// repeatedly).
  Future<int> pullAnilistList({
    required SettingsStore store,
    bool force = false,
    bool firstSync = false,
  }) async {
    if (!store.anilistConnected) return 0;
    final String? token = store.anilistToken;
    if (token == null || token.isEmpty) return 0;
    if (!force) {
      final int last = store.lastAnilistSyncAt;
      if (last > 0 &&
          DateTime.now().millisecondsSinceEpoch - last <
              const Duration(minutes: 15).inMilliseconds) {
        return 0;
      }
    }
    final List<AnilistListEntry> entries = await anilist.fetchUserList(
      token,
    );
    if (entries.isEmpty) return 0;
    int merged = 0;
    for (final AnilistListEntry entry in entries) {
      final String localStatus = switch (entry.status) {
        'COMPLETED' => 'finished',
        'PLANNING' => 'plan',
        _ => 'watching',
      };
      // 0.2.18: list status is keyed by the CANONICAL key
      // (SettingsStore.keyFor) — a synced title carries id
      // 'anilist-<id>' from animeFromMedia while the catalogue
      // uses its own id, and both must share one list entry.
      final String? existing = store.explicitStatusOf(entry.anime);
      // First sync after login: AniList wins outright. Later pulls:
      // AniList still wins for entries it has (the user's AniList is
      // the source of truth for those titles), but a local-only
      // title is never touched — it is not in this list at all.
      if (firstSync || existing == null || existing != localStatus) {
        await store.setListStatus(entry.anime, localStatus);
      }
      if (entry.progress > 0) {
        await store.markProgress(entry.anime, entry.progress);
      }
      await store.upsertSyncedAnime(entry.anime);
      merged++;
    }
    await store.setLastAnilistSyncAt(
      DateTime.now().millisecondsSinceEpoch,
    );
    return merged;
  }

  /// Run a MAL call with a fresh token (refresh when expired).
  /// Returns false when no usable token exists.
  Future<bool> _malWithRefresh(
    SettingsStore store,
    Future<void> Function(String token) call,
  ) async {
    String? token = store.malAccessToken;
    if (token == null || token.isEmpty) return false;
    final DateTime? expiry = store.malTokenExpiry;
    if (expiry != null &&
        DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 5)))) {
      final String? refresh = store.malRefreshToken;
      // 0.2.3: the MAL client ID comes from the remote config now
      // (never typed in by the user).
      final String clientId = configService?.config.malClientId ?? '';
      if (refresh == null || clientId.isEmpty) return false;
      try {
        final MalTokens tokens = await oauth.refreshMalToken(
          clientId: clientId,
          refreshToken: refresh,
        );
        if (!tokens.isValid) return false;
        await store.setMalSession(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiry: DateTime.now().add(
            Duration(seconds: tokens.expiresInSeconds),
          ),
          username: store.malUsername,
        );
        token = tokens.accessToken;
      } catch (_) {
        return false;
      }
    }
    try {
      await call(token);
      return true;
    } catch (_) {
      return false;
    }
  }
}
