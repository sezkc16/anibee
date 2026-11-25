import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// Remote fix system (user-approved 2026-11-23 01:28, "apne hisab se karo").
/// Provider definitions (domains, endpoints, mirrors) live in ONE public
/// JSON — https://raw.githubusercontent.com/sezkc16/anibee-config/main/providers.json
/// The app fetches it on launch and resolves from it. If a site's domain or
/// endpoint changes, updating that one JSON fixes every install (him + the
/// 2-3 people he shares AniBee with) without an app update.
///
/// Load order: remote (5s timeout) -> last-good cached copy -> bundled
/// `assets/providers.json` fallback. Big changes (full redesign, stricter
/// Cloudflare) still need an app update — expected and fine.
///
/// 0.2.29 — PERSONAL BUILD, remote config OFF: the user shut AniBee down
/// for everyone else (2026-11-25 22:50, "bass merepe chale auro k pe
/// nahi"), and the public providers.json is being killed. This build
/// NEVER fetches the remote config and NEVER trusts the cached copy
/// (it may already hold the killed config) — it loads ONLY the bundled
/// `assets/providers.json` (v6: real mirrors + the real AniList/MAL
/// OAuth client IDs), so his sources and logins keep working no matter
/// what the public config becomes. Flip [_remoteConfigEnabled] to true
/// to restore remote-config behaviour. NOTE for the shutdown: the
/// resolvers' domains are hardcoded in Dart (Miruro/AniKoto/AniSuge/
/// AniKage/Anime-Sama) and do NOT read this config — a killed remote
/// config alone cannot stop sources on already-installed apps; it only
/// kills new AniList/MAL logins (empty client IDs) and the Anime-Sama
/// mirror override (which falls back to hardcoded anime-sama.to).
/// Stopping other phones = repo private + releases deleted (no new
/// installs, no update prompts), NOT the config.
class ProviderConfigService extends ChangeNotifier {
  ProviderConfigService._(this._prefs);

  static const String remoteUrl =
      'https://raw.githubusercontent.com/sezkc16/anibee-config/main/providers.json';
  static const String _cacheKey = 'provider_config_json';
  static const String _mirrorIndexKey = 'provider_mirror_index';

  /// 0.2.29: false = personal build, bundled config only (see the
  /// class doc). true restores the remote -> cached -> bundled chain.
  static const bool _remoteConfigEnabled = false;

  final SharedPreferences _prefs;

  ProviderConfig _config = ProviderConfig.empty();
  ConfigSource _source = ConfigSource.bundled;

  ProviderConfig get config => _config;
  ConfigSource get source => _source;
  int get version => _config.version;

  static Future<ProviderConfigService> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderConfigService service = ProviderConfigService._(prefs);
    await service._load();
    return service;
  }

  /// Re-fetch the remote config on demand (0.2.4). The login buttons
  /// call this before reading the OAuth client IDs, so IDs added to
  /// anibee-config land in a running app with NO rebuild and NO
  /// restart — the Accounts status text updates via notifyListeners.
  Future<void> refresh() async {
    await _load();
  }

  Future<void> _load() async {
    // 1. Remote — skipped in the 0.2.29 personal build (see the class
    // doc): the public config is shut down, so never fetch it.
    if (_remoteConfigEnabled) {
      try {
        final String? remote = await _fetchRemote().timeout(
          const Duration(seconds: 5),
        );
        if (remote != null) {
          final ProviderConfig parsed = ProviderConfig.fromJson(
            jsonDecode(remote) as Map<String, dynamic>,
          );
          if (parsed.providers.isNotEmpty) {
            _config = parsed;
            _source = ConfigSource.remote;
            await _prefs.setString(_cacheKey, remote);
            notifyListeners();
            return;
          }
        }
      } catch (_) {
        // Fall through to cache / bundled.
      }
      // 2. Last-good cached copy — also skipped in the personal
      // build: the cache may hold the killed public config.
      final String? cached = _prefs.getString(_cacheKey);
      if (cached != null) {
        try {
          final ProviderConfig parsed = ProviderConfig.fromJson(
            jsonDecode(cached) as Map<String, dynamic>,
          );
          if (parsed.providers.isNotEmpty) {
            _config = parsed;
            _source = ConfigSource.cached;
            notifyListeners();
            return;
          }
        } catch (_) {
          // Fall through to bundled.
        }
      }
    }
    // 3. Bundled fallback — the ONLY source in the personal build.
    try {
      final String bundled = await rootBundle.loadString(
        'assets/providers.json',
      );
      _config = ProviderConfig.fromJson(
        jsonDecode(bundled) as Map<String, dynamic>,
      );
      _source = ConfigSource.bundled;
    } catch (_) {
      _config = ProviderConfig.empty();
      _source = ConfigSource.bundled;
    }
    notifyListeners();
  }

  Future<String?> _fetchRemote() async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(remoteUrl),
      );
      request.headers.set('User-Agent', 'AniBee/0.1.0');
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }

  /// Mirrors for a provider, rotated so the last-good mirror is first.
  List<String> mirrorsFor(String providerId) {
    final ProviderDef? def = _config.provider(providerId);
    if (def == null || def.mirrors.isEmpty) return <String>[];
    final int start = _mirrorIndex(providerId) % def.mirrors.length;
    return <String>[
      ...def.mirrors.sublist(start),
      ...def.mirrors.sublist(0, start),
    ];
  }

  /// Call when a mirror fails: the next mirror becomes first for this
  /// provider (persisted, so the fix sticks across launches).
  Future<void> markMirrorFailed(String providerId, String mirror) async {
    final ProviderDef? def = _config.provider(providerId);
    if (def == null || def.mirrors.isEmpty) return;
    final int current = _mirrorIndex(providerId);
    final int failedAt = def.mirrors.indexOf(mirror);
    final int next = failedAt >= 0 ? failedAt + 1 : current + 1;
    final Map<String, int> indices = _mirrorIndices();
    indices[providerId] = next % def.mirrors.length;
    await _prefs.setString(_mirrorIndexKey, jsonEncode(indices));
    notifyListeners();
  }

  int _mirrorIndex(String providerId) {
    return _mirrorIndices()[providerId] ?? 0;
  }

  Map<String, int> _mirrorIndices() {
    final String? raw = _prefs.getString(_mirrorIndexKey);
    if (raw == null) return <String, int>{};
    try {
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (String k, dynamic v) => MapEntry(k, (v as num).toInt()),
      );
    } catch (_) {
      return <String, int>{};
    }
  }

  /// Enabled providers in fallback order: preferred first, then the rest
  /// in config order. Providers with no mirrors are skipped (their
  /// endpoints are not verified yet).
  List<ProviderDef> fallbackOrder() {
    final List<ProviderDef> usable = _config.enabledProviders
        .where((ProviderDef p) => p.mirrors.isNotEmpty)
        .toList();
    usable.sort((ProviderDef a, ProviderDef b) {
      if (a.preferred != b.preferred) return a.preferred ? -1 : 1;
      return 0;
    });
    return usable;
  }

  /// Build an endpoint URL for a provider, trying mirrors in rotation
  /// order. Returns null when the provider/endpoint is unknown.
  String? endpointUrl(
    String providerId,
    String endpointKey, {
    Map<String, String> params = const <String, String>{},
  }) {
    final ProviderDef? def = _config.provider(providerId);
    if (def == null) return null;
    final String? template = def.endpoints[endpointKey];
    if (template == null) return null;
    final List<String> mirrors = mirrorsFor(providerId);
    if (mirrors.isEmpty) return null;
    String path = template;
    params.forEach((String key, String value) {
      path = path.replaceAll('{$key}', Uri.encodeComponent(value));
    });
    return mirrors.first + path;
  }
}

enum ConfigSource { remote, cached, bundled }

class ProviderConfig {
  const ProviderConfig({
    required this.version,
    required this.updatedAt,
    required this.providers,
    this.anilistClientId = '',
    this.malClientId = '',
  });

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final List<dynamic> raw =
        json['providers'] as List<dynamic>? ?? <dynamic>[];
    return ProviderConfig(
      version: (json['version'] as num?)?.toInt() ?? 0,
      updatedAt: json['updated_at'] as String? ?? '',
      providers: raw
          .map((dynamic e) => ProviderDef.fromJson(e as Map<String, dynamic>))
          .toList(),
      // 0.2.3: OAuth client IDs for the one-tap login sheet. These are
      // the APP's developer clients (created once by the developer,
      // registered with redirect anibee://anilist-auth /
      // anibee://mal-auth) — they are public identifiers, not secrets.
      // Empty until they are put in the config: the Login buttons then
      // show "setup in progress" instead of asking the user for an ID.
      anilistClientId: json['anilistClientId'] as String? ?? '',
      malClientId: json['malClientId'] as String? ?? '',
    );
  }

  factory ProviderConfig.empty() {
    return const ProviderConfig(
      version: 0,
      updatedAt: '',
      providers: <ProviderDef>[],
    );
  }

  final int version;
  final String updatedAt;
  final List<ProviderDef> providers;

  /// AniList OAuth client ID from the remote config ('' = not set up).
  final String anilistClientId;

  /// MyAnimeList OAuth client ID from the remote config ('' = not set).
  final String malClientId;

  ProviderDef? provider(String id) {
    for (final ProviderDef p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<ProviderDef> get enabledProviders {
    return providers.where((ProviderDef p) => p.enabled).toList();
  }
}

class ProviderDef {
  const ProviderDef({
    required this.id,
    required this.name,
    required this.enabled,
    required this.preferred,
    required this.mirrors,
    required this.endpoints,
    this.note = '',
  });

  factory ProviderDef.fromJson(Map<String, dynamic> json) {
    return ProviderDef(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      preferred: json['preferred'] as bool? ?? false,
      mirrors: (json['mirrors'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic e) => e as String)
          .toList(),
      endpoints:
          (json['endpoints'] as Map<String, dynamic>? ?? <String, dynamic>{})
              .map((String k, dynamic v) => MapEntry(k, v as String)),
      note: json['note'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final bool enabled;
  final bool preferred;
  final List<String> mirrors;
  final Map<String, String> endpoints;
  final String note;
}
