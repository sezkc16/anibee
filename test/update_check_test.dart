import 'dart:convert';
import 'dart:io';

import 'package:anibee/app_shell.dart';
import 'package:anibee/services/airing_notifications.dart';
import 'package:anibee/services/airing_service.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/services/app_services.dart';
import 'package:anibee/services/debrid_service.dart';
import 'package:anibee/services/download_service.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/services/oauth_service.dart';
import 'package:anibee/services/provider_config.dart';
import 'package:anibee/services/update_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.17 UPDATE CHECKER (user order 2026-11-24 02:46, "0.2.17 pe
/// hi dalo"): on cold start, GET the latest public release and
/// compare its tag with the installed version. Newer → dialog
/// "A new version is available — vX.Y.Z" with Download (release page in
/// the browser) and "Later" (records the skipped version).
/// Never forced; any failure is silent; launch never blocks.
///
/// Harness notes: the shell pump is copied from
/// app_shell_keyboard_test.dart (mocked SharedPreferences +
/// secure-storage channel, mocked AniList client returning empty
/// Pages). No pumpAndSettle — Home's hero has a 5 s auto-timer;
/// explicit pumps only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
  });

  group('compareVersions', () {
    test('newer / equal / older', () {
      expect(UpdateService.compareVersions('v0.2.17', '0.2.16'), greaterThan(0));
      expect(UpdateService.compareVersions('0.2.17', '0.2.17'), 0);
      expect(UpdateService.compareVersions('v0.2.15', '0.2.16'), lessThan(0));
      expect(UpdateService.compareVersions('v0.3.0', '0.2.99'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.0.0', '0.9.9'), greaterThan(0));
    });

    test('v prefix, missing parts, build metadata', () {
      expect(UpdateService.compareVersions('0.2', '0.2.0'), 0);
      expect(UpdateService.compareVersions('v0.2.17+21', '0.2.17'), 0);
      expect(UpdateService.compareVersions('v0.2.17', '0.2.17+20'), 0);
      expect(UpdateService.compareVersions('V0.2.18', '0.2.17'), greaterThan(0));
      expect(UpdateService.compareVersions('v0.2.x', '0.2.0'), 0);
    });
  });

  http.Response releaseJson(String tag, {int status = 200}) =>
      http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'tag_name': tag,
            'html_url': 'https://github.com/sezkc16/anibee/releases/tag/$tag',
          }),
        ),
        status,
      );

  PackageInfo fakeInfo(String version) => PackageInfo(
        appName: 'AniBee',
        packageName: 'com.toji.anibee',
        version: version,
        buildNumber: '1',
      );

  group('checkForUpdate', () {
    test('newer release returns tag + url', () async {
      final UpdateAvailable? update =
          await UpdateService.checkForUpdate(
            client: MockClient((_) async => releaseJson('v0.2.17')),
            packageInfo: () async => fakeInfo('0.2.16'),
          );
      expect(update, isNotNull);
      expect(update!.tag, 'v0.2.17');
      expect(
        update.url,
        'https://github.com/sezkc16/anibee/releases/tag/v0.2.17',
      );
    });

    test('equal or older release returns null', () async {
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient((_) async => releaseJson('v0.2.16')),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient((_) async => releaseJson('v0.2.15')),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
    });

    test('non-200, bad JSON and network failure are silent nulls', () async {
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient((_) async => releaseJson('v0.2.17', status: 404)),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient(
            (_) async => http.Response.bytes(utf8.encode('not json'), 200),
          ),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient(
            (_) async => throw const SocketException('offline'),
          ),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
      // Missing tag in an otherwise-200 body (e.g. repo went
      // private and GitHub answered something else).
      expect(
        await UpdateService.checkForUpdate(
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(jsonEncode(<String, dynamic>{})),
              200,
            ),
          ),
          packageInfo: () async => fakeInfo('0.2.16'),
        ),
        isNull,
      );
    });
  });

  test('skipUpdateVersion persists across loads', () async {
    final SettingsStore store = await SettingsStore.load();
    expect(store.skippedUpdateVersion, isNull);
    await store.skipUpdateVersion('v0.2.17');
    expect(store.skippedUpdateVersion, 'v0.2.17');
    final SettingsStore reloaded = await SettingsStore.load();
    expect(reloaded.skippedUpdateVersion, 'v0.2.17');
  });

  http.Response emptyPage() => http.Response.bytes(
        utf8.encode(jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{
            'Page': <String, dynamic>{'media': <dynamic>[]},
          },
        })),
        200,
      );

  Future<SettingsStore> pumpShell(
    WidgetTester tester, {
    Future<UpdateAvailable?> Function()? checkForUpdate,
    String? skippedVersion,
  }) async {
    // 800 pt wide (not 390): Home's hero Details/Watch Now Row
    // overflows by ~38 px at 390 in the test font — a test-env-only
    // artifact (see app_shell_keyboard_test.dart).
    tester.view.physicalSize = const Size(800, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Fresh prefs per test: the skipped-version write from one
    // test must not leak into the next (the mock backend is
    // shared across tests in this file).
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store =
        (await tester.runAsync<SettingsStore>(() => SettingsStore.load()))!;
    if (skippedVersion != null) {
      await store.skipUpdateVersion(skippedVersion);
    }
    final ProviderConfigService config = (await tester
            .runAsync<ProviderConfigService>(
                () => ProviderConfigService.load()))!;
    final AniListService anilist = AniListService(
      client: MockClient((http.Request req) async => emptyPage()),
    );
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
          checkForUpdate: checkForUpdate,
        ),
      ),
    );
    // Post-frame update check runs, then the dialog renders.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return store;
  }

  const UpdateAvailable fakeUpdate = UpdateAvailable(
    tag: 'v9.9.9',
    url: 'https://example.com/anibee/releases/tag/v9.9.9',
  );

  testWidgets('dialog appears on a newer release only',
      (WidgetTester tester) async {
    await pumpShell(
      tester,
      checkForUpdate: () async => fakeUpdate,
    );
    expect(find.text('A new version is available — v9.9.9'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('no dialog when the check finds nothing newer',
      (WidgetTester tester) async {
    await pumpShell(
      tester,
      checkForUpdate: () async => null,
    );
    expect(find.textContaining('A new version is available'), findsNothing);
  });

  testWidgets('no dialog for a version dismissed with Later',
      (WidgetTester tester) async {
    await pumpShell(
      tester,
      checkForUpdate: () async => fakeUpdate,
      skippedVersion: 'v9.9.9',
    );
    expect(find.textContaining('A new version is available'), findsNothing);
  });

  testWidgets('Later persists the skipped version',
      (WidgetTester tester) async {
    final SettingsStore store = await pumpShell(
      tester,
      checkForUpdate: () async => fakeUpdate,
    );
    expect(find.text('A new version is available — v9.9.9'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pump();
    await tester.pump();
    expect(find.text('A new version is available — v9.9.9'), findsNothing);
    expect(store.skippedUpdateVersion, 'v9.9.9');
    final SettingsStore reloaded = await SettingsStore.load();
    expect(reloaded.skippedUpdateVersion, 'v9.9.9');
  });
}
