import 'dart:convert';

import 'package:anibee/screens/search_screen.dart';
import 'package:anibee/services/anilist_service.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.2.25: recent searches on the Search screen. Only searches
/// the user actually SUBMITTED count — not keystrokes. The store
/// unit tests cover add / dedupe / cap / persist / remove /
/// clear; the widget tests cover the section showing saved terms
/// and tapping one to re-run it.
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

  group('store', () {
    test('add puts the term first, most recent first', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('Naruto');
      await store.addRecentSearch('Bleach');
      expect(store.recentSearches, <String>['Bleach', 'Naruto']);
    });

    test('re-searching moves the term to the top (case-insensitive)',
        () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('Naruto');
      await store.addRecentSearch('Bleach');
      await store.addRecentSearch('naruto');
      expect(store.recentSearches, <String>['naruto', 'Bleach']);
    });

    test('trims and ignores terms under 2 characters', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('  Naruto  ');
      await store.addRecentSearch('x');
      await store.addRecentSearch('  ');
      expect(store.recentSearches, <String>['Naruto']);
    });

    test('caps at 10, dropping the oldest', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      for (int i = 1; i <= 12; i++) {
        await store.addRecentSearch('Title $i');
      }
      expect(store.recentSearches.length, 10);
      expect(store.recentSearches.first, 'Title 12');
      expect(store.recentSearches.last, 'Title 3');
      expect(store.recentSearches, isNot(contains('Title 1')));
      expect(store.recentSearches, isNot(contains('Title 2')));
    });

    test('remove drops one term, clear empties the list', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('Naruto');
      await store.addRecentSearch('Bleach');
      await store.removeRecentSearch('Naruto');
      expect(store.recentSearches, <String>['Bleach']);
      await store.clearRecentSearches();
      expect(store.recentSearches, isEmpty);
    });

    test('persists across restarts', () async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('Naruto');
      await store.addRecentSearch('Bleach');
      final SettingsStore reopened = await SettingsStore.load();
      expect(reopened.recentSearches, <String>['Bleach', 'Naruto']);
      await reopened.clearRecentSearches();
    });
  });

  group('Search screen section', () {
    MockClient emptyAnilist() {
      return MockClient((http.Request req) async {
        if (req.url.host == 'kitsu.io') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, dynamic>{
              'data': <dynamic>[],
              'included': <dynamic>[],
            })),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{
              'Page': <String, dynamic>{'media': <dynamic>[]},
            },
          })),
          200,
        );
      });
    }

    Future<SettingsStore> seededStore() async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await store.addRecentSearch('Naruto');
      await store.addRecentSearch('Bleach');
      return store;
    }

    Future<void> pumpSearchWith(
      WidgetTester tester,
      SettingsStore store,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchScreen(
              onOpenAnime: (_) {},
              anilist: AniListService(client: emptyAnilist()),
              store: store,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('section shows saved terms, most recent first',
        (tester) async {
      final SettingsStore store = await seededStore();
      await pumpSearchWith(tester, store);
      expect(find.text('Recent searches'), findsOneWidget);
      expect(find.text('Bleach'), findsOneWidget);
      expect(find.text('Naruto'), findsOneWidget);
      // Most recent first: Bleach above Naruto.
      final Offset bleach =
          tester.getCenter(find.text('Bleach'));
      final Offset naruto =
          tester.getCenter(find.text('Naruto'));
      expect(bleach.dy, lessThan(naruto.dy));
      expect(find.text('Clear all'), findsOneWidget);
    });

    testWidgets('no section when there is no history', (tester) async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await pumpSearchWith(tester, store);
      expect(find.text('Recent searches'), findsNothing);
    });

    testWidgets('tapping a term fills the field and searches',
        (tester) async {
      final SettingsStore store = await seededStore();
      await pumpSearchWith(tester, store);
      await tester.tap(find.text('Naruto'));
      // Debounce (400 ms) + mock call settle, like the search
      // tests. The section hides once the query is non-empty.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('Recent searches'), findsNothing);
      final TextField field =
          tester.widget(find.byType(TextField));
      expect(field.controller?.text, 'Naruto');
      // Local catalogue match for the re-run search.
      expect(find.text('Naruto'), findsWidgets);
    });

    testWidgets('per-item X removes that term', (tester) async {
      final SettingsStore store = await seededStore();
      await pumpSearchWith(tester, store);
      // Two per-item X icons (one per row) while the query is
      // empty — the first row is Bleach.
      expect(find.byIcon(Icons.close_rounded), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();
      expect(find.text('Bleach'), findsNothing);
      expect(find.text('Naruto'), findsOneWidget);
      expect(store.recentSearches, <String>['Naruto']);
    });

    testWidgets('Clear all empties the section', (tester) async {
      final SettingsStore store = await seededStore();
      await pumpSearchWith(tester, store);
      await tester.tap(find.text('Clear all'));
      await tester.pump();
      expect(find.text('Recent searches'), findsNothing);
      expect(store.recentSearches, isEmpty);
    });

    testWidgets('submitting a search records it', (tester) async {
      final SettingsStore store = await SettingsStore.load();
      await store.clearRecentSearches();
      await pumpSearchWith(tester, store);
      // Keyboard Search key = submit (not a keystroke).
      await tester.enterText(find.byType(TextField), 'Naruto');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(store.recentSearches, contains('Naruto'));
    });
  });
}
