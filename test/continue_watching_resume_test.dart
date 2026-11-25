import 'package:anibee/models.dart';
import 'package:anibee/screens/full_player_screen.dart';
import 'package:anibee/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 0.2.28: Continue Watching resumed ~1 min behind where the user
// left off (user, 2026-11-25 17:48). Diagnosis (code + live probe):
// no deliberate rewind and no unit mixup anywhere — the loss was
// two staleness sources stacking: the periodic save ran only every
// 30 s (a killed/backgrounded app lost up to ~30 s), and the HLS
// seek lands up to one segment early (live probe on Tokyo Ghoul
// EP1: max segment 10.4 s). On top of that, the first position tick
// after reopening saved the PRE-SEEK position (~0) because
// _lastProgressSave starts at the epoch — clobbering the good
// resume value. The fix: save every 10 s, never save before the
// resume seek is applied, stamp the save clock when the seek is
// issued, and re-seek once if the seek didn't stick
// (seekNeedsRetry). These tests pin the REAL save-then-resume
// path: the exact store calls _saveInProgress makes, read back
// through the same code the Home CW card and the player use.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Anime anime({required String id, int? anilistId}) {
    return Anime(
      id: id,
      title: 'TOKYO GHOUL',
      rating: 4.1,
      year: 2014,
      episodeCount: 12,
      genres: const <String>['Action'],
      synopsis: '',
      gradient: const <Color>[Colors.black],
      anilistId: anilistId,
    );
  }

  late SettingsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = await SettingsStore.load();
  });

  /// The exact three writes _saveInProgress performs mid-episode.
  Future<void> saveProgress(
    Anime a,
    int episode,
    double position,
    double duration,
  ) async {
    final String key = store.resumeKeyFor(a, episode);
    await store.setResumeSeconds(key, position);
    await store.setResumeDuration(key, duration);
    await store.recordWatch(
      anime: a,
      episode: episode,
      positionSeconds: position,
      durationSeconds: duration,
    );
  }

  test('save at 645s -> back/exit -> resume reads back within seconds',
      () async {
    final Anime tg = anime(id: 'tokyo-ghoul', anilistId: 20605);
    await saveProgress(tg, 1, 645, 1564);

    // The player's resume read.
    final double? resumed = store.resumePositionFor(tg, 1);
    expect(resumed, isNotNull);
    expect((resumed! - 645).abs(), lessThanOrEqualTo(3));

    // The Home Continue Watching card's read: same entry, same
    // position the card shows as "Resume · X left".
    expect(store.watchHistory, hasLength(1));
    final WatchEntry entry = store.watchHistory.first;
    expect((entry.positionSeconds - 645).abs(), lessThanOrEqualTo(3));

    // The CW card -> Detail -> player round-trip: toAnime() must
    // preserve the canonical key, or the player would look the
    // resume up under a different key and find nothing.
    final double? viaCard =
        store.resumePositionFor(entry.toAnime(), entry.episode);
    expect(viaCard, isNotNull);
    expect((viaCard! - 645).abs(), lessThanOrEqualTo(3));
  });

  test('a newer save wins — a stale value never overwrites it',
      () async {
    final Anime tg = anime(id: 'tokyo-ghoul', anilistId: 20605);
    await saveProgress(tg, 1, 600, 1564);
    await saveProgress(tg, 1, 645, 1564);
    expect(store.resumePositionFor(tg, 1), 645);
    expect(store.watchHistory.first.positionSeconds, 645);
  });

  test('the same episode watched later resumes at the later position',
      () async {
    final Anime tg = anime(id: 'tokyo-ghoul', anilistId: 20605);
    await saveProgress(tg, 1, 645, 1564);
    await saveProgress(tg, 1, 700, 1564);
    final double? resumed = store.resumePositionFor(tg, 1);
    expect(resumed, 700);
  });

  group('seekNeedsRetry (resume-seek verification, 0.2.28)', () {
    test('seek to 645s that left the player near 0 needs a retry', () {
      expect(
        seekNeedsRetry(
          target: const Duration(seconds: 645),
          position: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });

    test('seek to 645s that landed at 640s stuck — no retry', () {
      expect(
        seekNeedsRetry(
          target: const Duration(seconds: 645),
          position: const Duration(seconds: 640),
        ),
        isFalse,
      );
    });
  });
}
