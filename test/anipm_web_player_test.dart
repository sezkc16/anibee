import 'package:anibee/models.dart';
import 'package:anibee/screens/anipm_web_player_screen.dart';
import 'package:anibee/services/miruro_resolver.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.25: AniPM WebView player. The screen loads the settlar
/// embed in a WebView — in tests the [webViewBuilder] seam swaps
/// the platform WebView for a placeholder that shows the embed
/// URL, so no platform WebView is needed. The tests prove: the
/// screen shows the title + episode, the placeholder carries the
/// initial embed URL, episode switching re-resolves and shows the
/// new embed URL (and marks progress), and Back pops the screen.
/// What is NOT tested here (and not claimed): that the settlar
/// embed actually plays — the embed is Cloudflare-403 from the
/// VM, so only the phone can prove playback.
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

  List<Episode> episodes(int count) => List<Episode>.generate(
        count,
        (int i) => Episode(
          number: i + 1,
          title: 'Episode ${i + 1}',
          duration: '24 min',
          synopsis: 'Test.',
          airDate: 'Oct 4, 2020',
          hasDub: true,
        ),
      );

  const String embed1 =
      'https://embed.settlar.io/embed/v1?t=ep1-token';
  const String embed2 =
      'https://embed.settlar.io/embed/v1?t=ep2-token';
  const String embed3 =
      'https://embed.settlar.io/embed/v1?t=ep3-token';

  Future<SettingsStore> loadStore() => SettingsStore.load();

  /// The screen shows a one-time TopNotification in initState
  /// (and another on a failed episode switch) — its 3s dismiss
  /// timer must be pumped past before teardown, or the test
  /// fails with "a Timer is still pending".
  Future<void> settleNotifications(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  Future<void> pumpScreen(
    WidgetTester tester, {
    required SettingsStore store,
    int initialEpisode = 1,
    Future<ResolvedStream?> Function(Episode episode)? onResolve,
    ValueChanged<Episode>? onEpisodeChanged,
  }) async {
    final List<Episode> eps = episodes(3);
    await tester.pumpWidget(
      MaterialApp(
        home: AnipmWebPlayerScreen(
          store: store,
          anime: jjk,
          episodes: eps,
          initialEpisode: eps[initialEpisode - 1],
          initialEmbedUrl: embed1,
          onResolveEpisode: onResolve ??
              (Episode ep) async => ResolvedStream(
                    url: ep.number == 2
                        ? embed2
                        : ep.number == 3
                            ? embed3
                            : embed1,
                    label: 'AniPM Sub',
                    source: 'AniPM',
                    playback: StreamPlayback.webEmbed,
                  ),
          onEpisodeChanged: onEpisodeChanged,
          // Test seam: show the embed URL instead of a platform
          // WebView.
          webViewBuilder: (BuildContext context, String url) =>
              Center(child: Text(url, key: const Key('embed-url'))),
        ),
      ),
    );
    await tester.pump();
    // The initState TopNotification overlays the top bar and
    // would eat taps on Back / Next / Episodes — let its 3s
    // dismiss timer run out before the test interacts.
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('shows title, EP and the initial embed URL', (tester) async {
    final SettingsStore store = await loadStore();
    await pumpScreen(tester, store: store);
    expect(find.textContaining('Jujutsu Kaisen'), findsOneWidget);
    expect(find.textContaining('EP 1'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byKey(const Key('embed-url')), findsOneWidget);
    expect(find.text(embed1), findsOneWidget);
    // Player chrome for the embed source: prev/next + episodes.
    expect(find.byTooltip('Next episode'), findsOneWidget);
    expect(find.byTooltip('Episodes'), findsOneWidget);
    await settleNotifications(tester);
  });

  testWidgets('next episode re-resolves and shows the new embed URL',
      (tester) async {
    final SettingsStore store = await loadStore();
    final List<int> changed = <int>[];
    await pumpScreen(
      tester,
      store: store,
      onEpisodeChanged: (Episode ep) => changed.add(ep.number),
    );
    await tester.tap(find.byTooltip('Next episode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('EP 2'), findsOneWidget);
    expect(find.text(embed2), findsOneWidget);
    expect(find.text(embed1), findsNothing);
    expect(changed, <int>[2]);
    await settleNotifications(tester);
  });

  testWidgets('episode sheet switches to the picked episode',
      (tester) async {
    final SettingsStore store = await loadStore();
    await pumpScreen(tester, store: store);
    await tester.tap(find.byTooltip('Episodes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Episodes'), findsWidgets);
    await tester.tap(find.text('3').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('EP 3'), findsOneWidget);
    expect(find.text(embed3), findsOneWidget);
    await settleNotifications(tester);
  });

  testWidgets('a failed resolve keeps the current episode playing',
      (tester) async {
    final SettingsStore store = await loadStore();
    await pumpScreen(
      tester,
      store: store,
      onResolve: (Episode ep) async => null,
    );
    await tester.tap(find.byTooltip('Next episode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('EP 1'), findsOneWidget);
    expect(find.text(embed1), findsOneWidget);
    await settleNotifications(tester);
  });

  testWidgets('back button pops the screen', (tester) async {
    final SettingsStore store = await loadStore();
    final List<Episode> eps = episodes(3);
    // Push the screen onto a Navigator — the root route itself
    // cannot pop, so the screen must not be the home widget.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          AnipmWebPlayerScreen(
                        store: store,
                        anime: jjk,
                        episodes: eps,
                        initialEpisode: eps[0],
                        initialEmbedUrl: embed1,
                        onResolveEpisode: (Episode ep) async =>
                            ResolvedStream(
                          url: embed1,
                          label: 'AniPM Sub',
                          source: 'AniPM',
                          playback: StreamPlayback.webEmbed,
                        ),
                        webViewBuilder:
                            (BuildContext context, String url) => Center(
                          child: Text(
                            url,
                            key: const Key('embed-url'),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('open player'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open player'));
    await tester.pump();
    // Let the initState notification dismiss before tapping.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(AnipmWebPlayerScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    // The pop animates out over ~300ms — settle it before
    // asserting the screen is gone.
    await tester.pumpAndSettle();
    expect(find.byType(AnipmWebPlayerScreen), findsNothing);
    expect(find.text('open player'), findsOneWidget);
  });
}
