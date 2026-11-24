import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

/// Google Cast (Chromecast) support for the AniBee player — 0.2.19.
///
/// The player casts through the DEFAULT media receiver
/// (`CC1AD845`) — no custom receiver app, no Cast developer
/// registration. The phone becomes the remote: play/pause, seek and
/// volume keep working from the existing player controls while the
/// TV plays; disconnecting resumes local playback at the TV's last
/// position (Continue Watching / resume keep working across the
/// cast).
///
/// HONEST LIMITS (do not fake or hide — the user was told these):
/// - Subtitles do NOT show on the TV: they are drawn by the app's
///   own Flutter overlay, not carried in the stream. The default
///   receiver gets no subtitle tracks from us.
/// - The TV fetches the stream URL directly, so expiring signed
///   links and referer-gated sources may fail on the TV while
///   playing fine on the phone. The Cast SDK gives the sender no
///   way to attach custom HTTP headers with the default receiver
///   (only a custom receiver could read them from `customData`).
///   A failed TV load is caught here (see [GoogleCastService]
///   — the iOS `loadMedia` channel call is fire-and-forget) and
///   surfaces as one short line, never a raw error.
/// - Local files (downloaded episodes, `file://`) cannot be cast:
///   the TV has no access to the phone's storage.
/// - No real Cast device exists on the VM/CI. The user owns a
///   DishHome 4K Streamer (Chromecast built-in) — real casting is
///   phone-test only. A discovery bug was phone-proven 2026-11-24:
///   the stick is visible to official YouTube on the same iPhone
///   but AniBee 0.2.19 showed nothing (see the picker note in
///   full_player_screen.dart — the 1.2.9 plugin's iOS discovery
///   handler is empty and the plugin stops discovery on
///   backgrounding with no restart path).
///   this through the injectable [CastService] (a mock), the same
///   pattern as the update checker's injectable client.
///
/// The service is split in two: the [CastService] interface the
/// player screen talks to (mockable in tests) and
/// [GoogleCastService], the real implementation over
/// flutter_chrome_cast EXACTLY 1.2.9 (Google Cast SDK, iOS +
/// Android) — the last CocoaPods-only version; 1.5.0/2.0.0 resolve
/// their SPM GoogleCast package to SRGSSR 4.8.6, which needs iOS
/// 16.0, but this app targets 15.6 (see pubspec.yaml — do not bump
/// without raising the deployment target first).
/// The player screen never touches the plugin directly.

/// One discovered Cast device (TV / Chromecast / Cast speaker).
class CastDevice {
  const CastDevice({required this.id, required this.name, this.model});

  /// Stable device id from the Cast SDK.
  final String id;

  /// Human-readable name, e.g. "Living Room TV".
  final String name;

  /// Model string, e.g. "Chromecast" — null when unknown.
  final String? model;

  @override
  bool operator ==(Object other) =>
      other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Playback state of the media on the TV.
class CastMediaState {
  const CastMediaState({
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.ended,
  });

  /// True while the TV is playing (not paused/buffering/idle).
  final bool playing;

  /// Current TV position.
  final Duration position;

  /// TV-reported duration (zero when unknown).
  final Duration duration;

  /// TV volume 0..1.
  final double volume;

  /// True when the TV finished the media (idle + finished).
  final bool ended;

  CastMediaState copyWith({
    bool? playing,
    Duration? position,
    Duration? duration,
    double? volume,
    bool? ended,
  }) {
    return CastMediaState(
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      ended: ended ?? this.ended,
    );
  }
}

/// A Cast failure. [message] is a short safe code, never a raw
/// platform error — the player screen maps it to one plain line; the raw error goes to debugPrint only.
class CastException implements Exception {
  const CastException(this.message);

  final String message;

  @override
  String toString() => 'CastException: $message';
}

/// Whether [url] can be sent to a TV at all: only http(s) — a
/// downloaded episode (`file://`) lives on the phone and the TV
/// cannot fetch it. Pure — unit-tested.
bool isCastableUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

/// MIME type the default receiver needs for [url], from the path
/// extension (query/fragment stripped). Returns null for local
/// files and for URLs with no usable scheme — the caller treats
/// null as "cannot cast". Unknown extensions fall back to
/// `video/mp4` (the receiver tries; a real failure surfaces as a
/// load error, never a crash). Pure — unit-tested.
String? castContentTypeForUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final String path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8')) return 'application/x-mpegURL';
  if (path.endsWith('.mpd')) return 'application/dash+xml';
  if (path.endsWith('.webm')) return 'video/webm';
  if (path.endsWith('.m4v')) return 'video/mp4';
  return 'video/mp4';
}

/// The Cast backend the player screen talks to. Implemented by
/// [GoogleCastService] in production and by a scripted fake in
/// widget tests.
abstract class CastService {
  /// Initialise the Cast SDK (default receiver). Safe to call
  /// repeatedly; throws [CastException] when setup fails.
  Future<void> ensureInitialized();

  /// Discovered devices, live.
  Stream<List<CastDevice>> get devices;

  /// Devices known right now (may be empty until discovery runs).
  List<CastDevice> get currentDevices;

  /// Start device discovery (call while the picker is open).
  /// NOTE (0.2.20): on iOS with flutter_chrome_cast 1.2.9 this is
  /// a no-op — the plugin's native discovery method-channel
  /// handler is empty and never reaches GCKDiscoveryManager.
  /// Discovery actually starts inside [ensureInitialized] (the
  /// native context setup calls startDiscovery) and the plugin
  /// stops it on every app-backgrounding with no restart path, so
  /// the app inits Cast when the player opens and the picker reads
  /// the cached list ([currentDevices] / the replaying stream).
  Future<void> startDiscovery();

  /// Stop device discovery (call when the picker closes).
  Future<void> stopDiscovery();

  /// Start a session with [device]. Returns true once the session
  /// reports connected, false when it could not connect (or the
  /// device vanished). Throws [CastException] only on an
  /// unexpected failure.
  Future<bool> connect(CastDevice device);

  /// End the session and stop casting. Best-effort, never throws.
  Future<void> disconnect();

  /// True while a session is connected.
  bool get isConnected;

  /// Friendly name of the connected device, null when not connected.
  String? get connectedDeviceName;

  /// Emits true on connect, false on disconnect (including when the
  /// TV ends the session).
  Stream<bool> get connectionStream;

  /// Live TV playback state (position ticks + status changes).
  Stream<CastMediaState> get mediaStateStream;

  /// The latest known TV playback state (no stream wait).
  CastMediaState get currentMediaState;

  /// Load [url] on the TV at [position] and start playing. Throws
  /// [CastException] when the TV rejects the load (bad/expired
  /// link, referer-gated source) — the caller shows one short
  /// Hinglish line and stays local.
  Future<void> loadMedia({
    required String url,
    required Duration position,
    required String title,
    required String subtitle,
    String? posterUrl,
  });

  /// Best-effort remote controls — never throw.
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
}

/// Real [CastService] over flutter_chrome_cast 1.2.9 (Google Cast
/// SDK). Default receiver only.
class GoogleCastService implements CastService {
  bool _initialized = false;
  StreamController<CastMediaState>? _stateController;
  StreamSubscription<GoggleCastMediaStatus?>? _statusSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _pollTimer;

  @override
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      final GoogleCastOptions options;
      if (Platform.isIOS) {
        options = IOSGoogleCastOptions(
          GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
            GoogleCastDiscoveryCriteria.kDefaultApplicationId,
          ),
        );
      } else {
        options = GoogleCastOptionsAndroid(
          appId: GoogleCastDiscoveryCriteria.kDefaultApplicationId,
        );
      }
      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
      _initialized = true;
    } catch (e) {
      debugPrint('Anibee Cast init failed: $e');
      throw const CastException('init-failed');
    }
  }

  @override
  Stream<List<CastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream.map(
        (List<GoogleCastDevice> found) => found
            .map(
              (GoogleCastDevice d) => CastDevice(
                id: d.deviceID,
                name: d.friendlyName,
                model: d.modelName,
              ),
            )
            .toList(),
      );

  @override
  List<CastDevice> get currentDevices =>
      GoogleCastDiscoveryManager.instance.devices
          .map(
            (GoogleCastDevice d) => CastDevice(
              id: d.deviceID,
              name: d.friendlyName,
              model: d.modelName,
            ),
          )
          .toList();

  @override
  Future<void> startDiscovery() async {
    try {
      await GoogleCastDiscoveryManager.instance.startDiscovery();
    } catch (e) {
      debugPrint('Anibee Cast discovery start failed: $e');
    }
  }

  @override
  Future<void> stopDiscovery() async {
    try {
      await GoogleCastDiscoveryManager.instance.stopDiscovery();
    } catch (e) {
      debugPrint('Anibee Cast discovery stop failed: $e');
    }
  }

  GoogleCastDevice? _findDevice(String id) {
    for (final GoogleCastDevice d
        in GoogleCastDiscoveryManager.instance.devices) {
      if (d.deviceID == id) return d;
    }
    return null;
  }

  @override
  Future<bool> connect(CastDevice device) async {
    await ensureInitialized();
    final GoogleCastDevice? target = _findDevice(device.id);
    if (target == null) return false;
    final bool started;
    try {
      started =
          await GoogleCastSessionManager.instance.startSessionWithDevice(
            target,
          );
    } catch (e) {
      debugPrint('Anibee Cast start session failed: $e');
      return false;
    }
    if (!started) return false;
    // Starting a session is async — wait until the SDK reports
    // connected (15 s cap), then wire the media streams.
    final DateTime deadline = DateTime.now().add(
      const Duration(seconds: 15),
    );
    while (DateTime.now().isBefore(deadline)) {
      if (GoogleCastSessionManager.instance.hasConnectedSession &&
          GoogleCastSessionManager.instance.connectionState ==
              GoogleCastConnectState.connected) {
        _wireMediaStreams();
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  @override
  Future<void> disconnect() async {
    _unwireMediaStreams();
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (e) {
      debugPrint('Anibee Cast end session failed: $e');
    }
  }

  @override
  bool get isConnected =>
      GoogleCastSessionManager.instance.hasConnectedSession;

  @override
  String? get connectedDeviceName =>
      GoogleCastSessionManager.instance.currentSession?.device?.friendlyName;

  @override
  Stream<bool> get connectionStream => GoogleCastSessionManager
      .instance
      .currentSessionStream
      .map(
        (_) => GoogleCastSessionManager.instance.hasConnectedSession,
      )
      .distinct();

  @override
  Stream<CastMediaState> get mediaStateStream {
    _stateController ??= StreamController<CastMediaState>.broadcast();
    return _stateController!.stream;
  }

  @override
  CastMediaState get currentMediaState {
    final GoggleCastMediaStatus? status =
        GoogleCastRemoteMediaClient.instance.mediaStatus;
    final Duration position =
        GoogleCastRemoteMediaClient.instance.playerPosition;
    final Duration duration =
        status?.mediaInformation?.duration ?? Duration.zero;
    final bool playing =
        status?.playerState == CastMediaPlayerState.playing;
    final bool ended =
        status?.playerState == CastMediaPlayerState.idle &&
        status?.idleReason == GoogleCastMediaIdleReason.finished;
    final double volume = (status?.volume ?? 1).toDouble().clamp(0.0, 1.0);
    return CastMediaState(
      playing: playing,
      position: position,
      duration: duration,
      volume: volume,
      ended: ended,
    );
  }

  void _wireMediaStreams() {
    _unwireMediaStreams();
    _stateController ??= StreamController<CastMediaState>.broadcast();
    // Status changes (play/pause/end) and position ticks both
    // re-emit the merged state; a 1 s poll covers a quiet position
    // stream so the phone's seek bar keeps moving.
    _statusSub = GoogleCastRemoteMediaClient.instance.mediaStatusStream
        .listen((_) => _emitState());
    _positionSub = GoogleCastRemoteMediaClient.instance.playerPositionStream
        .listen((_) => _emitState());
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isConnected) _emitState();
    });
  }

  void _unwireMediaStreams() {
    _statusSub?.cancel();
    _statusSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _emitState() {
    final StreamController<CastMediaState>? controller = _stateController;
    if (controller == null || controller.isClosed) return;
    controller.add(currentMediaState);
  }

  @override
  Future<void> loadMedia({
    required String url,
    required Duration position,
    required String title,
    required String subtitle,
    String? posterUrl,
  }) async {
    final String? contentType = castContentTypeForUrl(url);
    if (contentType == null) throw const CastException('not-castable');
    final GoogleCastMediaInformation info = GoogleCastMediaInformation(
      contentId: url,
      streamType: CastMediaStreamType.buffered,
      contentType: contentType,
      contentUrl: Uri.parse(url),
      metadata: GoogleCastGenericMediaMetadata(
        title: title,
        subtitle: subtitle,
        images: posterUrl == null
            ? null
            : <GoogleCastImage>[GoogleCastImage(url: Uri.parse(posterUrl))],
      ),
    );
    final int? previousSessionId =
        GoogleCastRemoteMediaClient.instance.mediaStatus?.mediaSessionID;
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        info,
        autoPlay: true,
        playPosition: position,
      );
    } catch (e) {
      debugPrint('Anibee Cast loadMedia threw: $e');
      throw const CastException('load-failed');
    }
    // The iOS channel call is fire-and-forget: a bad/expired link
    // never throws — the receiver just never plays it. Wait for the
    // media status to accept (loading/buffering/playing/paused) or
    // reject (idle + error) the load.
    final bool accepted = await _waitForLoadVerdict(previousSessionId);
    if (!accepted) throw const CastException('load-failed');
  }

  /// Verdict for one media status, or null when it says nothing
  /// about the pending load yet. Statuses from the PREVIOUS media
  /// session (same session id as before the load) are ignored —
  /// right after a load the SDK still reports the old media.
  bool? _verdictOf(GoggleCastMediaStatus? status, int? previousSessionId) {
    if (status == null) return null;
    if (previousSessionId != null &&
        status.mediaSessionID == previousSessionId) {
      return null;
    }
    switch (status.playerState) {
      case CastMediaPlayerState.loading:
      case CastMediaPlayerState.buffering:
      case CastMediaPlayerState.playing:
      case CastMediaPlayerState.paused:
        return true;
      case CastMediaPlayerState.idle:
        return status.idleReason == GoogleCastMediaIdleReason.error
            ? false
            : null;
      case CastMediaPlayerState.unknown:
        return null;
    }
  }

  Future<bool> _waitForLoadVerdict(int? previousSessionId) async {
    final bool? now = _verdictOf(
      GoogleCastRemoteMediaClient.instance.mediaStatus,
      previousSessionId,
    );
    if (now != null) return now;
    final Completer<bool> completer = Completer<bool>();
    late StreamSubscription<GoggleCastMediaStatus?> sub;
    sub = GoogleCastRemoteMediaClient.instance.mediaStatusStream.listen(
      (GoggleCastMediaStatus? status) {
        final bool? verdict = _verdictOf(status, previousSessionId);
        if (verdict != null && !completer.isCompleted) {
          completer.complete(verdict);
        }
      },
    );
    try {
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> play() async {
    try {
      await GoogleCastRemoteMediaClient.instance.play();
    } catch (e) {
      debugPrint('Anibee Cast play failed: $e');
    }
  }

  @override
  Future<void> pause() async {
    try {
      await GoogleCastRemoteMediaClient.instance.pause();
    } catch (e) {
      debugPrint('Anibee Cast pause failed: $e');
    }
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(position: position),
      );
    } catch (e) {
      debugPrint('Anibee Cast seek failed: $e');
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    try {
      GoogleCastSessionManager.instance.setDeviceVolume(
        volume.clamp(0.0, 1.0),
      );
    } catch (e) {
      debugPrint('Anibee Cast volume failed: $e');
    }
  }

  @override
  Future<void> setRate(double rate) async {
    try {
      await GoogleCastRemoteMediaClient.instance.setPlaybackRate(rate);
    } catch (e) {
      debugPrint('Anibee Cast rate failed: $e');
    }
  }
}
