import 'package:anibee/models.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anikage_resolver.dart';
import 'package:anibee/services/animesama_resolver.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/anisuge_resolver.dart';
import 'package:anibee/services/app_services.dart';
import 'package:anibee/services/debrid_service.dart';
import 'package:anibee/services/download_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/services/oauth_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:anibee/widgets/server_sheet.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.11: the server picker is HONEST — resolveEpisode actually
/// routes to the chosen server. AniKoto to the anikoto.cz chain
/// inside MiruroResolver, Miruro to the justanime chain. A
/// MockClient that 404s everything proves which resolver was
/// entered: the entered resolver sets its lastError, the other
/// stays clean. No fake streams, ever.
/// 0.2.23: ReAnime + AniZone are removed — their routing tests go
/// with them.
/// 0.2.24: AniSuge + AniKage join — same routing proof (dead client
/// proves which resolver was entered).
/// 0.2.25: AnimeKai is removed — its routing test goes with it.
/// 0.2.26: AniPM is removed (user order) — its routing test goes
/// with it; a stale 'AniPM' choice must fall through to the Miruro
/// chain, never to a dead resolver.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async => null,
    );
  });

  const Anime jjk = Anime(
    id: 'anilist-113415',
    title: 'Jujutsu Kaisen',
    rating: 4.5,
    year: 2020,
    episodeCount: 24,
    genres: <String>['Action'],
    synopsis: 'Test anime.',
    gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    anilistId: 113415,
  );

  MockClient deadClient() => MockClient((http.Request _) async {
    return http.Response('not found', 404);
  });

  Future<AppServices> services() async {
    final MockClient client = deadClient();
    final AniListService anilist = AniListService(client: client);
    return AppServices(
      anilist: anilist,
      miruro: MiruroResolver(client: client, anilist: anilist),
      anisuge: AnisugeResolver(client: client, anilist: anilist),
      anikage: AnikageResolver(client: client, anilist: anilist),
      animesama: AnimeSamaResolver(client: client, anilist: anilist),
      debrid: DebridService(),
      oauth: OAuthService(),
      downloads: DownloadService(),
      airing: AiringService(anilist: anilist),
      airingNotifications: AiringNotifications(),
    );
  }

  test('server=AniPM (removed) falls through to Miruro (0.2.26)', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'AniPM',
    );
    expect(stream, isNull);
    // No AniPM resolver exists any more — the stale name must not
    // route to any other source; the Miruro chain is entered.
    expect(svc.miruro.lastError, isNotNull);
    expect(svc.anisuge.lastError, isNull);
    expect(svc.anikage.lastError, isNull);
    expect(svc.animesama.lastError, isNull);
  });

  test('server=Anime-Sama routes to Anime-Sama (others untouched)',
      () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'Anime-Sama',
    );
    expect(stream, isNull);
    expect(svc.animesama.lastError, isNotNull);
    expect(svc.anisuge.lastError, isNull);
    expect(svc.anikage.lastError, isNull);
    expect(svc.miruro.lastError, isNull);
  });

  test('server=AniKoto routes to the anikoto chain (others untouched)',
      () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'AniKoto',
    );
    expect(stream, isNull);
    expect(svc.miruro.lastError, isNotNull);
  });

  test('no server arg honors store.preferredServer', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    await store.setPreferredServer('Anime-Sama');
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
    );
    expect(stream, isNull);
    expect(svc.animesama.lastError, isNotNull);
    expect(svc.miruro.lastError, isNull);
    await store.setPreferredServer('Miruro');
  });

  test('server=AniSuge routes to AniSuge (others untouched)', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'AniSuge',
    );
    expect(stream, isNull);
    expect(svc.anisuge.lastError, isNotNull);
    expect(svc.anikage.lastError, isNull);
    expect(svc.miruro.lastError, isNull);
  });

  test('server=AniKage routes to AniKage (others untouched)', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'AniKage',
    );
    expect(stream, isNull);
    expect(svc.anikage.lastError, isNotNull);
    expect(svc.anisuge.lastError, isNull);
    expect(svc.miruro.lastError, isNull);
  });

  test(
      'default sources are Miruro, AniKoto, AniSuge, AniKage, Anime-Sama — no AnimeKai / ReAnime / AniZone / AniPM',
      () {
    final List<String> names =
        defaultSources().map((ProviderSource s) => s.name).toList();
    expect(names, <String>[
      'Miruro',
      'AniKoto',
      'AniSuge',
      'AniKage',
      'Anime-Sama',
    ]);
    expect(names, isNot(contains('AllAnime')));
    expect(names, isNot(contains('ReAnime')));
    expect(names, isNot(contains('AniZone')));
    expect(names, isNot(contains('AnimeKai')));
    expect(names, isNot(contains('AniPM')));
  });

  test('default sources include Anime-Sama, enabled, French (0.2.25)', () {
    final List<ProviderSource> sources = defaultSources();
    final ProviderSource animesama = sources.firstWhere(
      (ProviderSource s) => s.name == 'Anime-Sama',
    );
    expect(animesama.enabled, isTrue);
    expect(animesama.tagline, contains('French'));
    expect(kServerLanguages['Anime-Sama'], <String>['French']);
  });

  test('AniPM is gone everywhere (0.2.26)', () {
    final List<ProviderSource> sources = defaultSources();
    expect(
      sources.any((ProviderSource s) => s.name == 'AniPM'),
      isFalse,
    );
    expect(kServerLanguages.containsKey('AniPM'), isFalse);
    expect(kServerLanguages.containsKey('AnimeKai'), isFalse);
  });

  test('default sources include AniSuge + AniKage, enabled (0.2.24)', () {
    final List<ProviderSource> sources = defaultSources();
    for (final String name in <String>['AniSuge', 'AniKage']) {
      final ProviderSource source = sources.firstWhere(
        (ProviderSource s) => s.name == name,
      );
      expect(source.enabled, isTrue);
      expect(kServerLanguages[name], <String>['English']);
    }
  });
}
