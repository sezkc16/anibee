import 'dart:convert';

import 'package:anibee/services/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.29 — personal build: the public providers.json is shut down, so
/// the app must NEVER fetch the remote config and NEVER trust the cached
/// copy (it may already hold the killed config). It loads ONLY the
/// bundled `assets/providers.json` (v6: real mirrors + real AniList/MAL
/// OAuth client IDs), so his sources and logins keep working no matter
/// what the public config becomes.
///
/// The killed config this test plants in the cache is exactly what the
/// public shutdown publishes: version 7, empty client IDs, every
/// provider disabled with no mirrors.
void main() {
  test('personal build loads bundled v6 even with a killed cached config',
      () async {
    // rootBundle needs the test binding initialized (plain test()
    // runs without it — "Binding has not yet been initialized").
    TestWidgetsFlutterBinding.ensureInitialized();
    const String killedConfig = '''
{
  "version": 7,
  "updated_at": "2026-11-25T00:00:00Z",
  "anilistClientId": "",
  "malClientId": "",
  "providers": [
    {
      "id": "miruro",
      "name": "Miruro",
      "enabled": false,
      "preferred": true,
      "mirrors": [],
      "endpoints": {}
    },
    {
      "id": "animesama",
      "name": "Anime-Sama",
      "enabled": false,
      "preferred": false,
      "mirrors": [],
      "endpoints": {}
    }
  ]
}
''';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'provider_config_json': killedConfig,
    });

    final ProviderConfigService service = await ProviderConfigService.load();

    // Bundled, not cached: the killed cache must be ignored entirely.
    expect(service.source, ConfigSource.bundled);
    expect(service.version, 6);
    // Real mirrors from the bundled v6, not the killed empty ones.
    expect(service.config.provider('miruro')?.mirrors, isNotEmpty);
    expect(
      service.config.provider('animesama')?.mirrors.first,
      'https://anime-sama.to',
    );
    // Real OAuth client IDs — his AniList/MAL logins must keep working.
    expect(service.config.anilistClientId, '57814');
    expect(service.config.malClientId, isNotEmpty);
  });

  test('the killed config itself parses as disabled with no client IDs',
      () {
    final ProviderConfig killed = ProviderConfig.fromJson(
      jsonDecode('''
{
  "version": 7,
  "anilistClientId": "",
  "malClientId": "",
  "providers": [
    {"id": "miruro", "enabled": false, "mirrors": [], "endpoints": {}}
  ]
}
''') as Map<String, dynamic>,
    );
    expect(killed.version, 7);
    expect(killed.enabledProviders, isEmpty);
    expect(killed.anilistClientId, isEmpty);
    expect(killed.malClientId, isEmpty);
  });
}
