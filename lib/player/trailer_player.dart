import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/miruro_resolver.dart';

/// Dedup key for a subtitle track row (0.2.12): the normalized
/// VISIBLE label — what the user reads. Two tracks with the same
/// visible label are one row, whatever their ids or language codes:
/// mpv reports HLS rendition tracks with ISO 639-2 codes ('eng')
/// under fresh ids on every variant switch, and resolver-fetched
/// tracks carry no language at all. Pure — unit-tested.
String subtitleDedupKey(SubtitleTrack t) {
  final String label = (t.title != null && t.title!.isNotEmpty)
      ? t.title!
      : (t.language != null && t.language!.isNotEmpty)
      ? t.language!
      : 'Subtitle';
  return label.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Dedup a subtitle track list by visible label, keeping the first
/// track per label (mpv's own tracks come first — they are already
/// loaded in the player). Pure — unit-tested.
List<SubtitleTrack> dedupSubtitleTracks(Iterable<SubtitleTrack> tracks) {
  final List<SubtitleTrack> out = <SubtitleTrack>[];
  final Set<String> seen = <String>{};
  for (final SubtitleTrack t in tracks) {
    if (seen.add(subtitleDedupKey(t))) out.add(t);
  }
  return out;
}

/// Pick the subtitle track for the user's preferred language
/// (Settings → Player → Subtitle language): 'auto' | 'en' | 'hi' |
/// 'ar' | 'off'. 'auto' means English. A missing language falls back
/// to English, then the first track. Returns null for 'off' (no
/// subtitles) or an empty list.
SubtitleTrack? pickSubtitleTrack(List<SubtitleTrack> tracks, String language) {
  if (language == 'off' || tracks.isEmpty) return null;
  bool matches(String lang, SubtitleTrack track) {
    final String label = (track.title ?? '').trim().toLowerCase();
    final String code = (track.language ?? '').trim().toLowerCase();
    switch (lang) {
      case 'en':
        return MiruroResolver.isEnglishLabel(track.title) ||
            code == 'en' ||
            code == 'eng';
      case 'hi':
        return label.contains('hindi') ||
            label == 'hi' ||
            label.startsWith('hi ') ||
            code == 'hi' ||
            code == 'hin';
      case 'ar':
        return label.contains('arabic') ||
            label == 'ar' ||
            label.startsWith('ar ') ||
            code == 'ar' ||
            code == 'ara';
      default:
        return false;
    }
  }

  if (language != 'auto') {
    for (final SubtitleTrack track in tracks) {
      if (matches(language, track)) return track;
    }
  }
  // 'auto' = English; also the fallback for a missing language.
  for (final SubtitleTrack track in tracks) {
    if (matches('en', track)) return track;
  }
  return tracks.first;
}

/// Default subtitle track for a freshly loaded stream: prefer English
/// (matching the SUB selection) — sources list tracks in their own
/// order and Arabic can come first, so taking `.first` wrongly showed
/// Arabic subtitles (0.2.1, Chainsaw Man EP 2). Falls back to the
/// first track when no English track exists. [tracks] must be non-empty.
SubtitleTrack pickDefaultSubtitleTrack(List<SubtitleTrack> tracks) {
  return pickSubtitleTrack(tracks, 'auto') ?? tracks.first;
}

/// The ONE libmpv player shared by the Detail screen and the full
/// player screen — same engine, same Player instance, handed between
/// the two Video widgets.
///
/// 0.2.5: the inline trailer preview is GONE (the YouTube embed
/// failed on the phone with Error 153) — the detail banner is a
/// poster image only. This class is now purely the full-player
/// engine: [loadStream] opens a resolved episode stream, the full
/// player owns the surface while it is open, and [backToInline] is
/// a no-op hand-back (the banner shows no video any more).
///
/// 0.2.27: TWO player bugs fixed here (phone-proven 2026-11-25,
/// JJK EP3 via Anime-Sama — the error screen showed while the
/// episode's AUDIO kept playing, and the audio kept playing after
/// going back):
/// (a) media_kit forwards EVERY mpv log line at level `error`
/// (ffmpeg/tcp segment errors, vd/ad/cplayer errors) into
/// `player.stream.error` — including TRANSIENT ones a healthy
/// playback survives (mpv retries the segment and keeps playing
/// audio; the VM probe saw `hls: Failed to open segment 2` while
/// mpv played 300 frames fine). The old code treated the FIRST
/// such event as a fatal load failure, set [_loadError]
/// permanently, and the full player REMOVED the Video widget —
/// so the video could never come back even after mpv recovered.
/// Now an error event only surfaces after a grace window AND only
/// when playback is not advancing (not playing, position 0); an
/// error that arrives while playback is advancing is swallowed,
/// and a surfaced error clears itself if playback recovers.
/// (b) A [loadStream] in flight (slow `open()`) used to call
/// `play()` AFTER the screen had already closed and stopped the
/// player — the stale `play()` restarted audio on the Detail
/// screen. A load-generation counter now invalidates stale loads:
/// [stop]/[backToInline] bump it, and [loadStream] aborts (no
/// play, no error) as soon as it sees a newer generation.
class TrailerPlayer extends ChangeNotifier {
  TrailerPlayer() {
    _player = Player();
    _controller = VideoController(_player);
    _errorSub = _player.stream.error.listen(_onPlayerError);
    // 0.2.27: playback recovery — if the player demonstrably
    // starts advancing after an error was (or was about to be)
    // surfaced, the error was transient: cancel the pending
    // check and clear a surfaced error so the video comes back.
    // A play attempt also starts the grace window for an error
    // that was held while paused.
    _playingSub = _player.stream.playing.listen((bool playing) {
      if (playing) {
        _everPlayed = true;
        _maybeClearLoadError();
        _armErrorTimerIfPlaying();
      }
    });
    _positionSub = _player.stream.position.listen((Duration position) {
      if (position > Duration.zero) _maybeClearLoadError();
    });
  }

  late final Player _player;
  late final VideoController _controller;
  late final StreamSubscription<dynamic> _errorSub;
  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<Duration> _positionSub;

  /// Grace window before a non-fatal mpv error becomes the
  /// visible "Couldn't load episode" state. A stream that is
  /// genuinely dead never starts playing, so it still errors —
  /// just 3 s later. A stream that recovers inside the window
  /// never shows the error at all.
  static const Duration _loadErrorGrace = Duration(seconds: 3);

  /// Monotonic counter: bumped by every [loadStream] start and
  /// every [stop]/[backToInline]. A load whose generation is no
  /// longer current is stale — it must not play or error.
  int _loadGeneration = 0;

  /// Error text waiting out the grace window (or held while the
  /// player is paused — see [_onPlayerError]), if any.
  Timer? _pendingErrorTimer;
  String? _pendingErrorText;

  /// Test-only override for the "playback is advancing" signal.
  /// The VM test env cannot produce it: mpv's time-pos never
  /// advances headless (no audio output, mocked video output —
  /// proven by probe: playing=true, duration=5 s, position stuck
  /// at 0 for 6+ s). The phone is the authority for the real
  /// signal; tests force it through this seam to exercise the
  /// grace/swallow/clear rules. Null = use the real player state.
  bool? _advancingOverrideForTest;

  /// True once this load has ever reported playing. Distinguishes
  /// the two paused states: paused AFTER having played (the
  /// 02:30 repro — pause at ~10 min, background, return: the
  /// error is held) from a load that never started playing (a
  /// genuine load failure: the grace window runs, the error
  /// surfaces). Reset by every new load / stop.
  bool _everPlayed = false;

  /// Test hook for the advancing signal (see above).
  @visibleForTesting
  // ignore: avoid_setters_without_getters
  set advancingOverrideForTest(bool? value) {
    _advancingOverrideForTest = value;
  }

  VideoController get controller => _controller;
  Player get player => _player;

  String? _url;
  bool _inlineActive = true;
  bool _loaded = false;
  String? _loadError;

  /// True when the loaded media is a real episode stream (M2).
  /// Retry re-opens the same stream.
  bool _isStream = false;
  Map<String, String> _streamHeaders = const <String, String>{};
  List<SubtitleTrack> _streamSubtitles = const <SubtitleTrack>[];

  /// Preferred subtitle language for the loaded stream ('auto' |
  /// 'en' | 'hi' | 'ar' | 'off') — kept so retry() re-applies it.
  String _subtitleLanguage = 'auto';

  /// Subtitle tracks of the loaded stream (incl. externally fetched
  /// ones added via [addExternalSubtitle]) — the player sheet merges
  /// these with mpv's own track list.
  List<SubtitleTrack> get streamSubtitles => _streamSubtitles;

  /// Whether the Detail hero should render its inline Video widget.
  /// False while the full player screen owns the video surface.
  bool get inlineActive => _inlineActive;

  bool get loaded => _loaded;

  /// Non-null when the current media failed to load (UI shows the
  /// never-blank fallback state instead of a black screen).
  String? get loadError => _loadError;

  /// 0.2.27: a mpv error-log event is NOT a load failure by
  /// itself — media_kit forwards every `error`-level mpv log line
  /// (a single failed segment fetch, a decoder warning), and mpv
  /// routinely recovers from those while audio keeps playing.
  /// Surface the error only when playback is NOT advancing:
  /// if the player is already advancing, swallow it outright;
  /// if it is PLAYING but not yet advancing, wait out the grace
  /// window and surface it only if playback still has not
  /// started; if the player is PAUSED after having played, HOLD
  /// the error without surfacing it — a paused player has
  /// nothing to fail (the 02:30 phone repro: pause → background
  /// → return showed the error for a stream the user had not
  /// tried to play) — and only start the grace window when a
  /// play is attempted. A load that NEVER started playing is a
  /// genuine load failure: its grace window runs and it surfaces.
  void _onPlayerError(Object? e) {
    if (e == null) return;
    if (_loadError != null) return;
    if (_isAdvancing) return;
    if (_pendingErrorText != null) return;
    _pendingErrorText = e.toString();
    _armErrorTimerIfPlaying();
  }

  /// Start the grace timer for a held error, unless the player is
  /// paused after having played (then the error stays held until
  /// a play is attempted — see [_onPlayerError]).
  void _armErrorTimerIfPlaying() {
    if (_pendingErrorText == null || _pendingErrorTimer != null) return;
    if (!_player.state.playing && _everPlayed) return;
    _pendingErrorTimer = Timer(_loadErrorGrace, () {
      _pendingErrorTimer = null;
      if (_loadError != null) return;
      if (_isAdvancing) return;
      _loadError = _pendingErrorText;
      _pendingErrorText = null;
      notifyListeners();
    });
  }

  /// True when playback is demonstrably advancing: playing AND
  /// past the start. (media_kit sets `playing` optimistically on
  /// `play()`, so position is the real proof — a dead stream can
  /// sit at `playing: true, position: 0` forever.)
  bool get _isAdvancing =>
      _advancingOverrideForTest ??
      (_player.state.playing && _player.state.position > Duration.zero);

  /// 0.2.27: playback started advancing — a pending error check
  /// is moot and a surfaced error was transient: drop both so
  /// the video comes back instead of staying on the error screen.
  void _maybeClearLoadError() {
    if (!_isAdvancing) return;
    _pendingErrorTimer?.cancel();
    _pendingErrorTimer = null;
    _pendingErrorText = null;
    if (_loadError != null) {
      _loadError = null;
      notifyListeners();
    }
  }

  /// Test hook: feed an mpv error event through the same handler
  /// the real `player.stream.error` subscription uses, so the
  /// grace/swallow/clear rules are testable without a failing CDN.
  @visibleForTesting
  void simulatePlayerErrorForTest(String message) {
    _onPlayerError(message);
  }

  /// Test hook: model a position/playing tick showing playback is
  /// advancing — exactly what the real playing/position listeners
  /// do when mpv's time-pos moves. Marks this load as having
  /// played and runs the recovery check (clears a surfaced or
  /// held error when playback is advancing). The VM cannot produce
  /// a real advancing tick (mpv's time-pos never moves headless —
  /// proven by probe), so tests drive the recovery path through
  /// this, with [advancingOverrideForTest] modelling the signal.
  @visibleForTesting
  void simulatePlaybackAdvancedForTest() {
    _everPlayed = true;
    _maybeClearLoadError();
    _armErrorTimerIfPlaying();
  }

  /// The URL currently loaded (the PiP software player re-opens this).
  String? get url => _url;

  /// Apply the Hardware decoding setting (mpv hwdec) to this player.
  /// Best-effort: the public Player has no setProperty — the native
  /// platform player does (Zeus pattern).
  Future<void> applyHwdec(bool enabled) async {
    final PlatformPlayer? platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('hwdec', enabled ? 'auto' : 'no');
      } catch (_) {
        // Playback continues with the default decoder.
      }
    }
  }

  /// Load a real resolved episode stream (M2): the URL + playback
  /// headers (Referer/Origin) + subtitle tracks. Playback STOPS at
  /// the end of the episode (PlaylistMode.none) — 0.2.10: `single`
  /// means "loop the current media forever" in media_kit, which is
  /// what silently restarted EP 2 from 00:00 at EOF on the phone
  /// (2026-11-23 video); the full player owns the end-of-episode
  /// card and the next-episode advance. [muted] is false when the
  /// full player loads the stream (volume 100); the inline hero
  /// never loads streams. [subtitleLanguage] is the user's preferred
  /// subtitle language (Settings → Player).
  Future<void> loadStream(
    ResolvedStream stream, {
    bool muted = false,
    String subtitleLanguage = 'auto',
  }) async {
    // 0.2.27: this load owns its generation — a newer load (or a
    // stop) invalidates it, so a slow open that finishes after the
    // player closed can never play() or error afterwards.
    final int generation = ++_loadGeneration;
    _url = stream.url;
    _isStream = true;
    _streamHeaders = stream.headers;
    _subtitleLanguage = subtitleLanguage;
    // 0.2.12: the resolver can return the same label twice (e.g.
    // English from two subtitle endpoints) — dedup by normalized
    // label here, so the Subtitles panel never lists one language
    // twice for the same stream.
    final Map<String, SubtitleTrack> byLabel = <String, SubtitleTrack>{};
    for (final SubtitleInfo s in stream.subtitles) {
      byLabel.putIfAbsent(
        s.label.toLowerCase().trim(),
        () => SubtitleTrack.uri(s.url, title: s.label),
      );
    }
    _streamSubtitles = byLabel.values.toList();
    _loadError = null;
    _pendingErrorTimer?.cancel();
    _pendingErrorTimer = null;
    _pendingErrorText = null;
    _loaded = false;
    // 0.2.27: a new load has not played yet — the paused-hold
    // rule (see _armErrorTimerIfPlaying) must not inherit the
    // previous episode's playback.
    _everPlayed = false;
    notifyListeners();
    try {
      // 0.2.27: open PAUSED (`play: false`). media_kit's open()
      // plays by default — so a stale load would start audio the
      // moment open() completed, BEFORE the generation check
      // below could stop it (the VM probe caught exactly that:
      // playing=true ~17 s in, from open() itself, with the
      // loadStream checks intact). The only play is the explicit
      // guarded one after the checks.
      await _player.open(
        Media(stream.url, httpHeaders: stream.headers),
        play: false,
      );
      // 0.2.27: the open was slow and the load is stale now (a
      // newer load started, or the player was stopped/closed) —
      // abort without playing. The check sits directly before
      // each command with no await between check and call, so no
      // stop can slip in between.
      if (generation != _loadGeneration) return;
      await _player.setVolume(muted ? 0 : 100);
      if (generation != _loadGeneration) return;
      // 0.2.10: PlaylistMode.none — playback STOPS at EOF. `single`
      // loops the current media forever (the EP 2 restart bug).
      await _player.setPlaylistMode(PlaylistMode.none);
      if (generation != _loadGeneration) return;
      await _player.play();
      _loaded = true;
      _loadError = null;
      if (_streamSubtitles.isNotEmpty) {
        try {
          final SubtitleTrack? picked = pickSubtitleTrack(
            _streamSubtitles,
            subtitleLanguage,
          );
          await _player.setSubtitleTrack(picked ?? SubtitleTrack.no());
        } catch (_) {
          // Subtitles are best-effort; playback continues without them.
        }
      }
    } catch (e) {
      // 0.2.27: a stale load's failure is not this screen's
      // failure — the player was already stopped or superseded,
      // so surfacing it would show an error for a dead screen.
      if (generation != _loadGeneration) return;
      _loadError = e.toString();
      _loaded = false;
    }
    notifyListeners();
  }

  /// Add an externally fetched subtitle (e.g. English fetched when
  /// the stream carried none) and select it. Joins [_streamSubtitles]
  /// so the sheet lists it and retry() keeps it.
  Future<void> addExternalSubtitle(SubtitleInfo info) async {
    final SubtitleTrack track = SubtitleTrack.uri(info.url, title: info.label);
    // 0.2.12: dedup by URL (the id for uri tracks) AND by label —
    // a re-fetched English track can arrive under a new signed URL
    // with the same visible label, and the panel must not grow a
    // second "English" row for it.
    if (_streamSubtitles.any(
      (SubtitleTrack t) =>
          t.id == track.id || subtitleDedupKey(t) == subtitleDedupKey(track),
    )) {
      return;
    }
    _streamSubtitles = <SubtitleTrack>[..._streamSubtitles, track];
    try {
      await _player.setSubtitleTrack(track);
    } catch (_) {
      // Best-effort; playback continues without it.
    }
    notifyListeners();
  }

  /// Hand the surface to the full player screen.
  Future<void> expandToFull() async {
    final int generation = _loadGeneration;
    _inlineActive = false;
    notifyListeners();
    await _player.setVolume(100);
    // 0.2.10: none, not `single` (which loops the media — see
    // loadStream). The full player owns the end-of-episode card.
    await _player.setPlaylistMode(PlaylistMode.none);
    // 0.2.27: a stop (or a newer load) may have landed while this
    // was awaiting — do not restart audio for a closed player.
    if (generation != _loadGeneration) return;
    await _player.play();
  }

  /// Hand the surface back: 0.2.5 the banner is a poster, not a
  /// video — nothing plays here. Stops the stream so no audio keeps
  /// running after the player closes.
  Future<void> backToInline() async {
    // 0.2.27: invalidate any load still in flight (its play()
    // must never run after this stop) and drop any pending or
    // surfaced error — the player is closed.
    ++_loadGeneration;
    _pendingErrorTimer?.cancel();
    _pendingErrorTimer = null;
    _pendingErrorText = null;
    _loadError = null;
    _everPlayed = false;
    _inlineActive = true;
    await _player.stop();
    _loaded = false;
    notifyListeners();
  }

  Future<void> stop() async {
    // 0.2.27: same invalidation as backToInline (see above).
    ++_loadGeneration;
    _pendingErrorTimer?.cancel();
    _pendingErrorTimer = null;
    _pendingErrorText = null;
    _loadError = null;
    _everPlayed = false;
    await _player.stop();
    _loaded = false;
    _url = null;
    _isStream = false;
    _streamHeaders = const <String, String>{};
    _streamSubtitles = const <SubtitleTrack>[];
    notifyListeners();
  }

  /// Force a reload of the current stream (Retry button after a load
  /// error). Streams re-open with their headers/subtitles.
  Future<void> retry() async {
    final String? u = _url;
    if (u == null || !_isStream) return;
    await loadStream(
      ResolvedStream(
        url: u,
        label: 'Retry',
        source: 'Miruro',
        headers: _streamHeaders,
        subtitles: _streamSubtitles
            .map(
              // SubtitleTrack.uri(url) stores the URL in `id`
              // (`uri` is just a bool flag).
              (SubtitleTrack t) =>
                  SubtitleInfo(label: t.title ?? '', url: t.id),
            )
            .where((SubtitleInfo s) => s.url.isNotEmpty)
            .toList(),
      ),
      subtitleLanguage: _subtitleLanguage,
    );
  }

  @override
  void dispose() {
    _pendingErrorTimer?.cancel();
    _errorSub.cancel();
    _playingSub.cancel();
    _positionSub.cancel();
    _player.dispose();
    super.dispose();
  }
}
