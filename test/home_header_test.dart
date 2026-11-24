import 'dart:convert';

import 'package:anibee/app_shell.dart';
import 'package:anibee/screens/home_screen.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/app_services.dart';
import 'package:anibee/services/debrid_service.dart';
import 'package:anibee/services/download_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/services/oauth_service.dart';
import 'package:anibee/services/provider_config.dart';
import 'package:anibee/settings_store.dart';
import 'package:anibee/widgets/glass_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.25: the search button is REMOVED from the Home header
/// (user order 2026-11-25 00:12, screenshot: the top-right
/// magnifier — "upar wala"). The header keeps the AniBee
/// wordmark + the bell; Search stays reachable via the Search
/// nav tab. The tests prove: no search button/icon anywhere on
/// Home, the bell is still there, and the Search tab is present
/// and navigates to the Search screen.
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

  http.Response emptyPage() => http.Response.bytes(
        utf8.encode(jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{
            'Page': <String, dynamic>{'media': <dynamic>[]},
          },
        })),
        200,
      );

  AniListService emptyAnilist() => AniListService(
        client: MockClient((http.Request req) async => emptyPage()),
      );

  group('HomeScreen header', () {
    Future<void> pumpHome(WidgetTester tester) async {
      // Tall viewport so the whole Home list is built without
      // scrolling (same harness as home_movies_test). Explicit
      // pumps only — the hero has a 5 s auto-timer.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final SettingsStore store = await SettingsStore.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(
              store: store,
              anilist: emptyAnilist(),
              onOpenAnime: (_) {},
              onWatchNow: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('no search button, bell stays, wordmark stays',
        (tester) async {
      await pumpHome(tester);
      expect(find.byTooltip('Search'), findsNothing);
      expect(find.byIcon(Icons.search), findsNothing);
      expect(find.byIcon(Icons.search_rounded), findsNothing);
      // Wordmark (a Text.rich — find.text does not match spans)
      // + bell are still there.
      expect(find.textContaining('Ani'), findsOneWidget);
      expect(find.textContaining('Bee'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
    });
  });

  group('AppShell nav', () {
    Future<void> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final SettingsStore store =
          (await tester.runAsync<SettingsStore>(() => SettingsStore.load()))!;
      final ProviderConfigService config = (await tester
              .runAsync<ProviderConfigService>(
                  () => ProviderConfigService.load()))!;
      final AniListService anilist = emptyAnilist();
      final AppServices services = AppServices(
        anilist: anilist,
        miruro: MiruroResolver(anilist: anilist),
        debrid: DebridService(),
        oauth: OAuthService(),
        downloads: DownloadService(),
        airing: AiringService(anilist: anilist),
        airingNotifications: AiringNotifications(),
        configService: config,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AppShell(
            store: store,
            configService: config,
            services: services,
            checkForUpdate: () async => null,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Search tab present and opens the Search screen',
        (tester) async {
      await pumpShell(tester);
      expect(find.byType(GlassNavBar), findsOneWidget);
      // Home header: no search button even in the full shell.
      expect(find.byTooltip('Search'), findsNothing);
      expect(find.byTooltip('Notifications'), findsOneWidget);
      // The Search tab is still there and works.
      expect(find.text('Search'), findsOneWidget);
      await tester.tap(find.text('Search'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
