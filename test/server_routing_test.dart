import 'package:anibee/models.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/animekai_resolver.dart';
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
/// routes to the chosen server. AnimeKai goes to the AnimeKai
/// resolver, AniKoto to the anikoto.cz chain inside MiruroResolver,
/// Miruro to the justanime chain. A MockClient that 404s everything
/// proves which resolver was entered: the entered resolver sets its
/// lastError, the other stays clean. No fake streams, ever.
/// 0.2.23: ReAnime + AniZone are removed — their routing tests go
/// with them.
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
      animekai: AnimeKaiResolver(client: client, anilist: anilist),
      debrid: DebridService(),
      oauth: OAuthService(),
      downloads: DownloadService(),
      airing: AiringService(anilist: anilist),
      airingNotifications: AiringNotifications(),
    );
  }

  test('server=AnimeKai routes to AnimeKai (miruro untouched)', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
      server: 'AnimeKai',
    );
    expect(stream, isNull);
    expect(svc.animekai.lastError, isNotNull);
    expect(svc.miruro.lastError, isNull);
  });

  test('server=AniKoto routes to the anikoto chain (animekai untouched)',
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
    expect(svc.animekai.lastError, isNull);
  });

  test('no server arg honors store.preferredServer', () async {
    final AppServices svc = await services();
    final SettingsStore store = await SettingsStore.load();
    await store.setPreferredServer('AnimeKai');
    final stream = await svc.resolveEpisode(
      anime: jjk,
      episode: 1,
      subDub: 'Sub',
      store: store,
    );
    expect(stream, isNull);
    expect(svc.animekai.lastError, isNotNull);
    expect(svc.miruro.lastError, isNull);
    await store.setPreferredServer('Miruro');
  });

  test('default sources are Miruro, AniKoto, AnimeKai — no ReAnime / AniZone',
      () {
    final List<String> names =
        defaultSources().map((ProviderSource s) => s.name).toList();
    expect(names, <String>['Miruro', 'AniKoto', 'AnimeKai']);
    expect(names, isNot(contains('AllAnime')));
    expect(names, isNot(contains('ReAnime')));
    expect(names, isNot(contains('AniZone')));
  });

  test('default sources include AnimeKai, enabled (0.2.23)', () {
    final List<ProviderSource> sources = defaultSources();
    final ProviderSource animekai = sources.firstWhere(
      (ProviderSource s) => s.name == 'AnimeKai',
    );
    expect(animekai.enabled, isTrue);
    expect(kServerLanguages['AnimeKai'], <String>['English']);
  });
}
