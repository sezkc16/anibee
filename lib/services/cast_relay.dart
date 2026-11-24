import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Local on-phone Cast relay (0.2.21).
///
/// WHY IT EXISTS — phone-proven 2026-11-24, curl-verified on the real
/// Solo Leveling EP2 AniKoto URL: the megaplay CDN (nexabloom.top
/// master + midnightvoyage.site segments) requires
/// `Referer: https://megaplay.buzz/` on EVERY fetch — plain fetch
/// → HTTP 403 Cloudflare, Referer → 200. The TV's default receiver
/// (CC1AD845) fetches the stream URL directly and CANNOT send a
/// Referer, so Miruro/AniKoto could never play on the TV (fast-fail
/// for AniKoto, stuck-loading for Miruro). The phone plays the same
/// links fine because it sends the Referer.
///
/// WHAT IT DOES: while casting, the phone runs a tiny HTTP server on
/// its Wi-Fi LAN IP. It fetches the HLS from the CDN WITH the
/// Referer and re-serves playlists + segments to the TV, with the
/// URIs inside every playlist rewritten to point back at the relay.
/// The TV is told to load the relay URL instead of the CDN URL, so
/// the TV never talks to the CDN directly and never 403s.
///
/// HONEST LIMITS (the user was told these — do not hide them):
/// - The phone must stay on the same Wi-Fi with the app in the
///   FOREGROUND while relaying. iOS may suspend the server when the
///   app backgrounds — the TV will stall (not crash) until the app
///   returns; the existing load-verdict / idle-error handling ends
///   the cast cleanly if the stall persists.
/// - Subtitles still do NOT show on the TV (app-drawn overlay).
/// - This does not fix a source whose CDN blocks the PHONE too —
///   the relay can only forward what the phone itself can fetch.
/// - The relay binds an ephemeral port on the LAN and serves only
///   while a cast is active; it stops on cast end / dispose. The
///   path carries a random token so another device on the network
///   cannot trivially grab the stream; the token is per-cast and
///   never logged.
///
/// Only HLS from known Referer-gated hosts is relayed (see
/// [needsCastRelay]) — everything else casts directly as before, so
/// a relay failure can never break a source that used to work.

/// The Referer the megaplay CDN gates on (curl-proven 2026-11-24:
/// this exact header turns the 403 into a 200 on the master,
/// variant and segment fetches).
const String kCastRelayReferer = 'https://megaplay.buzz/';

/// Host suffixes whose HLS must go through the relay — the hosts
/// the Miruro/AniKoto chain serves from, plus the chain's own
/// domains. Proven from the resolver code (`miruro_resolver.dart`:
/// justanime core API → megaplay embed → nexabloom CDN) and the
/// 0.2.20 curl evidence (master on fetch.nexabloom.top, segments
/// on n953x.midnightvoyage.site). A host matches when it equals a
/// suffix or is a subdomain of one.
const List<String> kCastRelayGatedHostSuffixes = <String>[
  'nexabloom.top',
  'midnightvoyage.site',
  'megaplay.buzz',
  'justanime.to',
];

/// Whether [url]'s host is Referer-gated and must be relayed to
/// the TV. Only http(s) counts; anything else is not relayed.
/// Pure — unit-tested.
bool needsCastRelay(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  for (final String suffix in kCastRelayGatedHostSuffixes) {
    if (host == suffix || host.endsWith('.$suffix')) return true;
  }
  return false;
}

/// The Referer to send upstream for [url]. Today the whole gated
/// set shares the one proven megaplay referer — the CDN checks it
/// on every host in the chain. Pure — unit-tested.
String castRelayRefererForUrl(String url) => kCastRelayReferer;

/// Score for picking the phone's LAN address: the TV is on the
/// same Wi-Fi, so prefer private LAN ranges (192.168/16, then
/// 10/8, then 172.16/12); anything else usable, link-local last.
/// Pure — unit-tested.
int lanIpScore(String ip) {
  if (ip.startsWith('192.168.')) return 0;
  if (ip.startsWith('10.')) return 1;
  final List<String> parts = ip.split('.');
  if (parts.length == 4) {
    final int? second = int.tryParse(parts[1]);
    if (parts[0] == '172' && second != null && second >= 16 && second <= 31) {
      return 2;
    }
  }
  if (ip.startsWith('169.254.')) return 4;
  return 3;
}

/// The phone's best LAN IPv4 address (the one the TV can reach),
/// or null when there is none (cellular-only, no Wi-Fi). Uses
/// `dart:io` only — no extra dependency for one call.
Future<String?> findLanIp() async {
  try {
    final List<NetworkInterface> interfaces =
        await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final List<String> candidates = <String>[];
    for (final NetworkInterface interface in interfaces) {
      for (final InternetAddress address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4) {
          candidates.add(address.address);
        }
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (String a, String b) => lanIpScore(a).compareTo(lanIpScore(b)),
    );
    return candidates.first;
  } catch (e) {
    debugPrint('Anibee Cast relay: LAN IP lookup failed: $e');
    return null;
  }
}

/// Rewrite every URI inside an HLS playlist so the TV fetches it
/// from the relay instead of the CDN. [playlistBase] is the
/// absolute URL the playlist was fetched from (relative URIs
/// resolve against it). [relayPrefix] is the relay's per-target
/// prefix, e.g. `http://192.168.1.5:51234/r/<token>/u` — each URI
/// becomes `$relayPrefix/<base64url of the absolute target URL>`.
/// Media URIs (bare lines), `#EXT-X-KEY` / `#EXT-X-MAP` /
/// `#EXT-X-MEDIA` URI attributes are all rewritten; everything
/// else (tags, durations, comments) passes through unchanged.
/// Query params and tokens survive — they are inside the encoded
/// target URL. Pure — unit-tested.
String rewriteHlsPlaylist(
  String playlist,
  Uri playlistBase,
  String relayPrefix,
) {
  final StringBuffer out = StringBuffer();
  final List<String> lines = playlist.split('\n');
  for (int i = 0; i < lines.length; i++) {
    String line = lines[i];
    final bool last = i == lines.length - 1;
    // Playlists are CRLF in the wild — strip the CR, keep the LF.
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.startsWith('#')) {
      out.write(_rewriteUriAttributes(line, playlistBase, relayPrefix));
    } else if (line.trim().isNotEmpty) {
      final Uri resolved = playlistBase.resolve(line.trim());
      out.write('$relayPrefix/${_encodeTarget(resolved.toString())}');
    } else {
      out.write(line);
    }
    if (!last) out.write('\n');
  }
  return out.toString();
}

/// Rewrite `URI="..."` attributes inside one playlist tag line.
String _rewriteUriAttributes(
  String line,
  Uri playlistBase,
  String relayPrefix,
) {
  return line.replaceAllMapped(
    RegExp('URI="([^"]*)"'),
    (Match m) {
      final Uri resolved = playlistBase.resolve(m.group(1)!);
      return 'URI="$relayPrefix/${_encodeTarget(resolved.toString())}"';
    },
  );
}

/// base64url (no padding — the token stays URL-path-safe: no `/`,
/// `+` or `=`) of an absolute target URL.
String _encodeTarget(String url) =>
    base64Url.encode(utf8.encode(url)).replaceAll('=', '');

/// Inverse of [_encodeTarget]; null when the token is not valid
/// base64url (a forged/typo'd relay path).
String? _decodeTarget(String token) {
  try {
    final String padded = token + ('=' * ((4 - token.length % 4) % 4));
    return utf8.decode(base64Url.decode(padded));
  } catch (_) {
    return null;
  }
}

/// One relay session: an [HttpServer] bound to an ephemeral port on
/// the LAN, serving one source HLS (master + variants + segments +
/// keys) with the Referer the CDN gates on.
///
/// Lifecycle: [start] (returns the relay master URL the TV should
/// load, or null when the relay cannot start — no LAN IP, bind
/// failure); [stop] (closes the server, never throws). A running
/// relay started for the same source URL returns its existing URL;
/// a different source stops the old session first.
class CastRelay {
  /// [lanIpOverride] is a test seam only (127.0.0.1 in tests) — the
  /// player passes nothing and the real LAN IP is detected.
  CastRelay({this.lanIpOverride});

  final String? lanIpOverride;

  HttpServer? _server;
  HttpClient? _client;
  String? _sourceUrl;
  String _referer = kCastRelayReferer;
  String _token = '';

  /// True while the server is up.
  bool get isRunning => _server != null;

  /// The relay master-playlist URL to hand to the TV, or null when
  /// the relay is not running.
  String? get relayUrl {
    final HttpServer? server = _server;
    if (server == null) return null;
    return '${_relayBase(server)}/master.m3u8';
  }

  String _relayBase(HttpServer server) {
    final int port = server.port;
    final String host = lanIpOverride ?? _lanIp ?? '127.0.0.1';
    return 'http://$host:$port/r/$_token';
  }

  String? _lanIp;

  /// Start serving [sourceUrl] (the CDN master playlist URL). The
  /// TV loads the returned URL. Returns null when the relay cannot
  /// start — no LAN IP, bind failure — and the caller falls back to
  /// the direct URL (the existing load-verdict path reports the
  /// failure; never a crash).
  Future<String?> start({
    required String sourceUrl,
    String referer = kCastRelayReferer,
  }) async {
    if (_server != null && _sourceUrl == sourceUrl) return relayUrl;
    await stop();
    final String? lanIp = lanIpOverride ?? await findLanIp();
    if (lanIp == null) {
      debugPrint('Anibee Cast relay: no LAN IP — cannot start');
      return null;
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      debugPrint('Anibee Cast relay: bind failed: $e');
      client.close(force: true);
      return null;
    }
    _lanIp = lanIp;
    _client = client;
    _server = server;
    _sourceUrl = sourceUrl;
    _referer = referer;
    _token = _newToken();
    unawaited(
      server.forEach(_handle).catchError((Object e) {
        debugPrint('Anibee Cast relay: server loop ended: $e');
      }),
    );
    return relayUrl;
  }

  /// Stop serving. Safe to call when not running; never throws.
  Future<void> stop() async {
    final HttpServer? server = _server;
    final HttpClient? client = _client;
    _server = null;
    _client = null;
    _sourceUrl = null;
    _lanIp = null;
    _token = '';
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (e) {
        debugPrint('Anibee Cast relay: close failed: $e');
      }
    }
    client?.close(force: true);
  }

  String _newToken() {
    final Random random = Random.secure();
    final List<int> bytes =
        List<int>.generate(12, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    // CORS on EVERY relay response — the TV's player fetches
    // playlists/segments cross-origin.
    response.headers.set('Access-Control-Allow-Origin', '*');
    try {
      if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final List<String> segments = request.uri.pathSegments;
      // /r/<token>/master.m3u8  or  /r/<token>/u/<b64-target>
      if (segments.length < 3 ||
          segments[0] != 'r' ||
          segments[1] != _token) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (segments.length == 3 && segments[2] == 'master.m3u8') {
        await _servePlaylist(
          request,
          Uri.parse(_sourceUrl!),
          playlistBase: Uri.parse(_sourceUrl!),
        );
        return;
      }
      if (segments.length == 3 && segments[2] == 'u') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (segments.length == 4 && segments[2] == 'u') {
        final String? target = _decodeTarget(segments[3]);
        if (target == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        await _serveTarget(request, Uri.parse(target));
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (e) {
      // A handler failure must never leave the request hanging —
      // the TV treats a stalled fetch as a dead stream.
      debugPrint('Anibee Cast relay: request failed: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // Response already gone — nothing left to do.
      }
    }
  }

  /// Fetch the playlist at [target] upstream (with the Referer),
  /// rewrite its URIs to the relay, and serve it as HLS.
  Future<void> _servePlaylist(
    HttpRequest request,
    Uri target, {
    required Uri playlistBase,
  }) async {
    final HttpResponse response = request.response;
    final HttpClientResponse upstream = await _fetchUpstream(target);
    if (upstream.statusCode != HttpStatus.ok) {
      // Forward the CDN's answer (403 included) — the TV's verdict
      // handling reports it; the relay never invents a playlist.
      response.statusCode = upstream.statusCode;
      await upstream.drain<void>();
      await response.close();
      return;
    }
    final String body = await upstream.transform(utf8.decoder).join();
    final HttpServer? server = _server;
    if (server == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    final String rewritten = rewriteHlsPlaylist(
      body,
      playlistBase,
      '${_relayBase(server)}/u',
    );
    final List<int> bytes = utf8.encode(rewritten);
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    response.headers.set('Cache-Control', 'no-store');
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  /// Fetch [target] upstream (with the Referer, Range forwarded)
  /// and stream it back. A playlist response is rewritten and
  /// served as HLS; anything else (segments, keys, init maps) is
  /// passed through byte-for-byte.
  Future<void> _serveTarget(HttpRequest request, Uri target) async {
    final HttpResponse response = request.response;
    final String? range = request.headers.value('range');
    final HttpClientResponse upstream =
        await _fetchUpstream(target, range: range);
    final String upstreamType =
        upstream.headers.contentType?.mimeType ?? '';
    final bool isPlaylist =
        upstreamType.contains('mpegurl') ||
        target.path.toLowerCase().endsWith('.m3u8');
    if (isPlaylist && upstream.statusCode == HttpStatus.ok) {
      final String body = await upstream.transform(utf8.decoder).join();
      final HttpServer? server = _server;
      if (server == null) {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      final String rewritten = rewriteHlsPlaylist(
        body,
        target,
        '${_relayBase(server)}/u',
      );
      final List<int> bytes = utf8.encode(rewritten);
      response.statusCode = HttpStatus.ok;
      response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      response.headers.set('Cache-Control', 'no-store');
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
      return;
    }
    // Segment / key / init bytes — stream them through untouched.
    response.statusCode = upstream.statusCode;
    _copyResponseHeaders(upstream, response);
    // Segments hide on a second host with a disguised extension
    // (.jpg) and an image/* content type — the bytes are MPEG-TS.
    // The TV's HLS player keys off the playlist, not the header,
    // but serve the honest type anyway.
    if ((response.headers.contentType?.mimeType ?? '')
        .startsWith('image/')) {
      response.headers.contentType = ContentType('video', 'mp2t');
    }
    await response.addStream(upstream);
    await response.close();
  }

  /// Copy upstream headers to the relay response, minus hop-by-hop
  /// ones (the relay terminates the connection itself) and minus
  /// content-length (set by the streaming path / playlist path).
  void _copyResponseHeaders(
    HttpClientResponse upstream,
    HttpResponse response,
  ) {
    const Set<String> hopByHop = <String>{
      'connection',
      'keep-alive',
      'transfer-encoding',
      'trailer',
      'upgrade',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
    };
    upstream.headers.forEach((String name, List<String> values) {
      final String lower = name.toLowerCase();
      if (hopByHop.contains(lower)) return;
      if (lower == 'content-length') {
        final int? length = int.tryParse(values.first);
        if (length != null) response.contentLength = length;
        return;
      }
      for (final String value in values) {
        response.headers.add(name, value);
      }
    });
  }

  /// One upstream GET with the Referer the CDN gates on. Range is
  /// forwarded when the TV asks for one (seeks / resumes).
  Future<HttpClientResponse> _fetchUpstream(
    Uri target, {
    String? range,
  }) async {
    final HttpClient client = _client!;
    final HttpClientRequest req = await client.getUrl(target);
    req.headers.set('Referer', _referer);
    if (range != null) req.headers.set('range', range);
    return req.close();
  }
}
