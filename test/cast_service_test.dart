import 'dart:async';

import 'package:anibee/services/cast_service.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';

/// 0.2.19: Chromecast — the pure helpers the player screen relies
/// on, plus the [FakeCastService] contract the player widget tests
/// drive. No real Cast device exists on the VM (and the user owns
/// none — confirmed 2026-11-24), so the fake IS the proof for the
/// session logic; real casting is phone-test only, once he has a
/// device.
void main() {
  group('isCastableUrl', () {
    test('http and https streams are castable', () {
      expect(isCastableUrl('https://cdn.example.com/ep1.m3u8'), isTrue);
      expect(isCastableUrl('http://cdn.example.com/ep1.mp4'), isTrue);
    });

    test('local downloads are NOT castable — the TV cannot reach them',
        () {
      expect(isCastableUrl('file:///var/mobile/ep1.mp4'), isFalse);
    });

    test('empty and unparseable URLs are not castable', () {
      expect(isCastableUrl(''), isFalse);
      expect(isCastableUrl('not a url at all :::'), isFalse);
    });
  });

  group('castContentTypeForUrl', () {
    test('HLS / DASH / mp4 / webm by extension', () {
      expect(
        castContentTypeForUrl('https://x/ep1.m3u8'),
        'application/x-mpegURL',
      );
      expect(
        castContentTypeForUrl('https://x/manifest.mpd'),
        'application/dash+xml',
      );
      expect(castContentTypeForUrl('https://x/ep1.mp4'), 'video/mp4');
      expect(castContentTypeForUrl('https://x/ep1.m4v'), 'video/mp4');
      expect(castContentTypeForUrl('https://x/ep1.webm'), 'video/webm');
    });

    test('query strings and fragments do not hide the extension', () {
      expect(
        castContentTypeForUrl(
          'https://x/ep1.m3u8?token=abc123&exp=999#frag',
        ),
        'application/x-mpegURL',
      );
    });

    test('unknown extension falls back to mp4 — the receiver tries',
        () {
      expect(castContentTypeForUrl('https://x/stream'), 'video/mp4');
      expect(castContentTypeForUrl('https://x/ep1.mkv'), 'video/mp4');
    });

    test('local files return null — cannot cast', () {
      expect(castContentTypeForUrl('file:///tmp/ep1.mp4'), isNull);
      expect(castContentTypeForUrl(''), isNull);
    });
  });

  group('CastMediaState.copyWith', () {
    test('only the named fields change', () {
      const CastMediaState state = CastMediaState(
        playing: false,
        position: Duration.zero,
        duration: Duration(minutes: 24),
        volume: 1,
        ended: false,
      );
      final CastMediaState moved = state.copyWith(
        playing: true,
        position: Duration(seconds: 90),
      );
      expect(moved.playing, isTrue);
      expect(moved.position, const Duration(seconds: 90));
      expect(moved.duration, const Duration(minutes: 24));
      expect(moved.volume, 1);
      expect(moved.ended, isFalse);
    });
  });

  group('FakeCastService contract', () {
    test('connect → load → seek → disconnect, in order', () async {
      final FakeCastService fake = FakeCastService();
      fake.devicesValue = <CastDevice>[
        const CastDevice(id: 'tv-1', name: 'Living Room TV'),
      ];
      await fake.ensureInitialized();
      await fake.startDiscovery();
      expect(fake.discoveryStarted, isTrue);
      expect(fake.currentDevices, hasLength(1));

      final bool connected = await fake.connect(fake.currentDevices.first);
      expect(connected, isTrue);
      expect(fake.isConnected, isTrue);
      expect(fake.connectedDeviceName, 'Living Room TV');

      await fake.loadMedia(
        url: 'https://127.0.0.1:9/ep1.m3u8',
        position: const Duration(seconds: 42),
        title: 'Test Anime',
        subtitle: 'Episode 1',
      );
      expect(fake.loadCalls, hasLength(1));
      expect(fake.loadCalls.first.url, 'https://127.0.0.1:9/ep1.m3u8');
      expect(fake.loadCalls.first.position, const Duration(seconds: 42));

      await fake.seek(const Duration(seconds: 100));
      expect(fake.seekCalls, <Duration>[const Duration(seconds: 100)]);
      await fake.setVolume(0.5);
      expect(fake.volumeCalls, <double>[0.5]);

      await fake.disconnect();
      expect(fake.isConnected, isFalse);
      expect(fake.disconnectCalls, 1);
      await fake.stopDiscovery();
      expect(fake.discoveryStarted, isFalse);
    });

    test('connect failure returns false, never throws', () async {
      final FakeCastService fake = FakeCastService()..connectResult = false;
      expect(
        await fake.connect(
          const CastDevice(id: 'gone', name: 'Gone TV'),
        ),
        isFalse,
      );
      expect(fake.isConnected, isFalse);
    });

    test('load failure throws CastException for the screen to map',
        () async {
      final FakeCastService fake = FakeCastService()
        ..loadShouldThrow = true;
      await fake.connect(
        const CastDevice(id: 'tv-1', name: 'Living Room TV'),
      );
      expect(
        () => fake.loadMedia(
          url: 'https://127.0.0.1:9/ep1.m3u8',
          position: Duration.zero,
          title: 'T',
          subtitle: 'Episode 1',
        ),
        throwsA(isA<CastException>()),
      );
    });

    test('control calls never throw, even disconnected', () async {
      final FakeCastService fake = FakeCastService();
      await fake.play();
      await fake.pause();
      await fake.seek(const Duration(seconds: 5));
      await fake.setVolume(0.2);
      await fake.setRate(1.5);
      await fake.disconnect();
    });
  });

  group('castLoadVerdict (0.2.20)', () {
    GoggleCastMediaStatus status(
      CastMediaPlayerState state, {
      GoogleCastMediaIdleReason? reason,
      int sessionId = 7,
    }) {
      return GoggleCastMediaStatus(
        mediaSessionID: sessionId,
        playerState: state,
        idleReason: reason,
        playbackRate: 1,
        volume: 1,
        isMuted: false,
        repeatMode: GoogleCastMediaRepeatMode.off,
      );
    }

    test('loading and buffering are NOT a verdict — keep waiting', () {
      expect(
        castLoadVerdict(status(CastMediaPlayerState.loading), null),
        isNull,
      );
      expect(
        castLoadVerdict(status(CastMediaPlayerState.buffering), null),
        isNull,
      );
    });

    test('playing and paused prove the TV started', () {
      expect(
        castLoadVerdict(status(CastMediaPlayerState.playing), null),
        isTrue,
      );
      expect(
        castLoadVerdict(status(CastMediaPlayerState.paused), null),
        isTrue,
      );
    });

    test('idle + error fails the load; other idle reasons say nothing',
        () {
      expect(
        castLoadVerdict(
          status(
            CastMediaPlayerState.idle,
            reason: GoogleCastMediaIdleReason.error,
          ),
          null,
        ),
        isFalse,
      );
      expect(
        castLoadVerdict(
          status(
            CastMediaPlayerState.idle,
            reason: GoogleCastMediaIdleReason.finished,
          ),
          null,
        ),
        isNull,
      );
      expect(
        castLoadVerdict(
          status(
            CastMediaPlayerState.idle,
            reason: GoogleCastMediaIdleReason.none,
          ),
          null,
        ),
        isNull,
      );
    });

    test('unknown and null statuses say nothing', () {
      expect(
        castLoadVerdict(status(CastMediaPlayerState.unknown), null),
        isNull,
      );
      expect(castLoadVerdict(null, null), isNull);
    });

    test('a status from the previous session is ignored', () {
      expect(
        castLoadVerdict(
          status(CastMediaPlayerState.playing, sessionId: 7),
          7,
        ),
        isNull,
      );
      expect(
        castLoadVerdict(
          status(CastMediaPlayerState.playing, sessionId: 8),
          7,
        ),
        isTrue,
      );
    });
  });
}

/// Scripted [CastService] for the player widget tests. Records
/// every call; the media state is scripted by the test through
/// [emitMediaState] / [emitDisconnected].
class FakeCastService implements CastService {
  final StreamController<List<CastDevice>> _devicesController =
      StreamController<List<CastDevice>>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<CastMediaState> _mediaController =
      StreamController<CastMediaState>.broadcast();

  List<CastDevice> devicesValue = <CastDevice>[];
  bool connectResult = true;
  bool loadShouldThrow = false;
  bool loadStuckInLoading = false;
  bool discoveryStarted = false;
  bool _connected = false;
  CastMediaState _state = const CastMediaState(
    playing: false,
    position: Duration.zero,
    duration: Duration.zero,
    volume: 1,
    ended: false,
  );

  int disconnectCalls = 0;
  final List<({String url, Duration position})> loadCalls =
      <({String url, Duration position})>[];
  final List<Duration> seekCalls = <Duration>[];
  final List<double> volumeCalls = <double>[];
  final List<double> rateCalls = <double>[];
  int playCalls = 0;
  int pauseCalls = 0;

  /// Push a TV state into the media stream (and remember it as the
  /// current state) — the screen's listener mirrors it into
  /// `_castState`.
  void emitMediaState(CastMediaState state) {
    _state = state;
    _mediaController.add(state);
  }

  /// Push a remote disconnect (TV app closed / network drop).
  void emitDisconnected() {
    _connected = false;
    _connectionController.add(false);
  }

  @override
  Future<void> ensureInitialized() async {}

  @override
  Stream<List<CastDevice>> get devices => _devicesController.stream;

  @override
  List<CastDevice> get currentDevices => List<CastDevice>.of(devicesValue);

  @override
  Future<void> startDiscovery() async {
    discoveryStarted = true;
    _devicesController.add(List<CastDevice>.of(devicesValue));
  }

  /// Push a device list into the discovery stream (late arrival —
  /// a device found after the picker is already open). 0.2.20.
  void emitDevices(List<CastDevice> devices) {
    devicesValue = List<CastDevice>.of(devices);
    _devicesController.add(List<CastDevice>.of(devices));
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStarted = false;
  }

  @override
  Future<bool> connect(CastDevice device) async {
    if (!connectResult) return false;
    _connected = true;
    _connectionController.add(true);
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
    _connectionController.add(false);
  }

  @override
  bool get isConnected => _connected;

  @override
  String? get connectedDeviceName =>
      _connected ? 'Living Room TV' : null;

  @override
  Stream<bool> get connectionStream => _connectionController.stream;

  @override
  Stream<CastMediaState> get mediaStateStream => _mediaController.stream;

  @override
  CastMediaState get currentMediaState => _state;

  @override
  Future<void> loadMedia({
    required String url,
    required Duration position,
    required String title,
    required String subtitle,
    String? posterUrl,
  }) async {
    if (loadShouldThrow) throw const CastException('load-failed');
    loadCalls.add((url: url, position: position));
    if (loadStuckInLoading) {
      // Mirror the real service's verdict wait (0.2.20): the
      // receiver reports loading but never starts — after the 10 s
      // window the load fails instead of flipping into remote mode.
      _state = const CastMediaState(
        playing: false,
        position: Duration.zero,
        duration: Duration.zero,
        volume: 1,
        ended: false,
      );
      _mediaController.add(_state);
      await Future<void>.delayed(const Duration(seconds: 10));
      throw const CastException('load-failed');
    }
    _state = CastMediaState(
      playing: true,
      position: position,
      duration: const Duration(minutes: 24),
      volume: 1,
      ended: false,
    );
    _mediaController.add(_state);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _state = _state.copyWith(playing: true);
    _mediaController.add(_state);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _state = _state.copyWith(playing: false);
    _mediaController.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    _state = _state.copyWith(position: position);
    _mediaController.add(_state);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    rateCalls.add(rate);
  }
}
