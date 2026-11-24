import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anibee/services/cast_relay.dart';
import 'package:flutter_test/flutter_test.dart';

/// 0.2.21: local on-phone Cast relay — the phone re-serves
/// Referer-gated HLS to the TV. The unit tests prove the pure
/// helpers; the live tests run a REAL relay against a fake upstream
/// HttpServer on 127.0.0.1 (no Cast device, no CDN involved).
void main() {
  group('needsCastRelay', () {
    test('gated CDN hosts relay (subdomains included)', () {
      expect(
        needsCastRelay(
          'https://fetch.nexabloom.top/anime/x/index-f1-v1-a1.m3u8',
        ),
        isTrue,
      );
      expect(
        needsCastRelay(
          'https://n953x.midnightvoyage.site/seg-1-f1-v1-a1.jpg',
        ),
        isTrue,
      );
      expect(needsCastRelay('https://megaplay.buzz/embed/x'), isTrue);
      expect(needsCastRelay('https://core.justanime.to/api/watch'), isTrue);
      expect(
        needsCastRelay('https://sub.fetch.nexabloom.top/x.m3u8'),
        isTrue,
      );
    });

    test('host matching is case-insensitive', () {
      expect(
        needsCastRelay('https://FETCH.NEXABLOOM.TOP/x.m3u8'),
        isTrue,
      );
    });

    test('other hosts cast directly — no relay overhead', () {
      expect(needsCastRelay('https://cdn.example.com/ep1.m3u8'), isFalse);
      expect(needsCastRelay('https://commondatastorage.googleapis.com/x'),
          isFalse);
      // A host that merely CONTAINS a gated suffix is not gated.
      expect(needsCastRelay('https://nexabloom.top.evil.com/x'), isFalse);
      expect(needsCastRelay('https://notnexabloom.top/x'), isFalse);
    });

    test('non-http(s) and unparseable URLs never relay', () {
      expect(needsCastRelay('file:///tmp/ep1.mp4'), isFalse);
      expect(needsCastRelay(''), isFalse);
      expect(needsCastRelay('not a url'), isFalse);
    });
  });

  group('castRelayRefererForUrl', () {
    test('the proven megaplay referer for the whole gated set', () {
      expect(
        castRelayRefererForUrl('https://fetch.nexabloom.top/x.m3u8'),
        'https://megaplay.buzz/',
      );
      expect(
        castRelayRefererForUrl('https://n953x.midnightvoyage.site/x.jpg'),
        'https://megaplay.buzz/',
      );
    });
  });

  group('lanIpScore', () {
    test('private LAN ranges first, link-local last', () {
      expect(lanIpScore('192.168.1.5'), lessThan(lanIpScore('10.0.0.2')));
      expect(lanIpScore('10.0.0.2'), lessThan(lanIpScore('172.16.0.9')));
      expect(lanIpScore('172.16.0.9'), lessThan(lanIpScore('8.8.8.8')));
      expect(lanIpScore('8.8.8.8'), lessThan(lanIpScore('169.254.1.2')));
      expect(lanIpScore('172.31.255.1'), lessThan(lanIpScore('172.32.0.1')));
    });
  });

  group('rewriteHlsPlaylist', () {
    const String prefix = 'http://192.168.1.5:51234/r/tok123/u';

    String decodeTarget(String relayUrl) {
      final String token = relayUrl.substring(prefix.length + 1);
      final String padded = token + ('=' * ((4 - token.length % 4) % 4));
      return utf8.decode(base64Url.decode(padded));
    }

    test('master: relative + absolute variant URIs are rewritten', () {
      const String master = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
          'index-f1-v1-a1.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\n'
          'https://fetch.nexabloom.top/anime/x/index-f1-v1-a1.m3u8?token=abc\n';
      final String out = rewriteHlsPlaylist(
        master,
        Uri.parse('https://fetch.nexabloom.top/anime/x/master.m3u8'),
        prefix,
      );
      expect(out, startsWith('#EXTM3U'));
      expect(out, contains('#EXT-X-STREAM-INF:BANDWIDTH=5000000'));
      // No bare CDN URI may survive.
      expect(out, isNot(contains('nexabloom')));
      expect(out, isNot(contains('index-f1-v1-a1.m3u8\n')));
      final List<String> rewritten = out
          .split('\n')
          .where((String l) => l.startsWith(prefix))
          .toList();
      expect(rewritten, hasLength(2));
      expect(
        decodeTarget(rewritten[0]),
        'https://fetch.nexabloom.top/anime/x/index-f1-v1-a1.m3u8',
      );
      expect(
        decodeTarget(rewritten[1]),
        'https://fetch.nexabloom.top/anime/x/index-f1-v1-a1.m3u8?token=abc',
      );
    });

    test('variant: segments + key + map URIs rewritten, tags untouched',
        () {
      const String variant = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:6.0,\n'
          'seg-1-f1-v1-a1.ts\n'
          '#EXTINF:6.0,\n'
          'https://n953x.midnightvoyage.site/seg-2-f1-v1-a1.jpg?token=zz\n';
      final String out = rewriteHlsPlaylist(
        variant,
        Uri.parse(
          'https://fetch.nexabloom.top/anime/x/index-f1-v1-a1.m3u8',
        ),
        prefix,
      );
      expect(out, contains('#EXT-X-VERSION:3'));
      expect(out, contains('#EXT-X-TARGETDURATION:6'));
      expect(out, contains('#EXTINF:6.0,'));
      expect(out, isNot(contains('midnightvoyage')));
      expect(out, isNot(contains('"key.bin"')));
      expect(out, isNot(contains('"init.mp4"')));
      final List<RegExpMatch> uriAttrs =
          RegExp('URI="([^"]*)"').allMatches(out).toList();
      expect(uriAttrs, hasLength(2));
      expect(
        decodeTarget(uriAttrs[0].group(1)!),
        'https://fetch.nexabloom.top/anime/x/key.bin',
      );
      expect(
        decodeTarget(uriAttrs[1].group(1)!),
        'https://fetch.nexabloom.top/anime/x/init.mp4',
      );
      final List<String> mediaLines = out
          .split('\n')
          .where((String l) => l.startsWith(prefix))
          .toList();
      expect(mediaLines, hasLength(2));
      expect(
        decodeTarget(mediaLines[0]),
        'https://fetch.nexabloom.top/anime/x/seg-1-f1-v1-a1.ts',
      );
      expect(
        decodeTarget(mediaLines[1]),
        'https://n953x.midnightvoyage.site/seg-2-f1-v1-a1.jpg?token=zz',
      );
    });

    test('CRLF playlists rewrite cleanly', () {
      const String playlist = '#EXTM3U\r\nseg-1.ts\r\n';
      final String out = rewriteHlsPlaylist(
        playlist,
        Uri.parse('https://fetch.nexabloom.top/x/master.m3u8'),
        prefix,
      );
      expect(out, isNot(contains('\r')));
      expect(out, contains(prefix));
    });
  });

  group('findLanIp', () {
    test('returns null or a dotted-quad IPv4 address', () async {
      final String? ip = await findLanIp();
      if (ip != null) {
        expect(ip, matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')));
      }
    });
  });

  group('CastRelay live (fake upstream on 127.0.0.1)', () {
    late HttpServer upstream;
    late String upstreamBase;
    final List<String> referersSeen = <String>[];
    final List<String> rangesSeen = <String>[];

    const List<int> segmentOne = <int>[1, 2, 3, 4, 5, 6, 7, 8];
    const List<int> segmentTwo = <int>[9, 10, 11, 12];
    const List<int> keyBytes = <int>[
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ];

    Future<void> serveFake(HttpRequest req) async {
      final HttpResponse res = req.response;
      referersSeen.add(req.headers.value('referer') ?? '<none>');
      final String? range = req.headers.value('range');
      if (range != null) rangesSeen.add(range);
      final String path = req.uri.path;
      List<int> body;
      String contentType;
      if (path == '/master.m3u8') {
        contentType = 'application/vnd.apple.mpegurl';
        body = utf8.encode(
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000\n'
          'v1080.m3u8?token=abc\n',
        );
      } else if (path == '/v1080.m3u8') {
        contentType = 'application/vnd.apple.mpegurl';
        body = utf8.encode(
          '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:6.0,\n'
          'seg-1.ts\n'
          '#EXTINF:6.0,\n'
          'seg-2.ts\n',
        );
      } else if (path == '/seg-1.ts') {
        contentType = 'video/mp2t';
        body = segmentOne;
      } else if (path == '/seg-2.ts') {
        // Disguised extension, like the real CDN's .jpg segments.
        contentType = 'image/jpeg';
        body = segmentTwo;
      } else if (path == '/key.bin') {
        contentType = 'application/octet-stream';
        body = keyBytes;
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      // Minimal Range support (the TV seeks through the relay).
      final String? rangeHeader = req.headers.value('range');
      if (rangeHeader != null && body.length > 1) {
        final RegExpMatch? m =
            RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (m != null) {
          final int start = int.parse(m.group(1)!);
          final int end = m.group(2)!.isEmpty
              ? body.length - 1
              : int.parse(m.group(2)!);
          final List<int> slice = body.sublist(start, end + 1);
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            'Content-Range',
            'bytes $start-$end/${body.length}',
          );
          res.headers.contentType = ContentType.parse(contentType);
          res.contentLength = slice.length;
          res.add(slice);
          await res.close();
          return;
        }
      }
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.parse(contentType);
      res.contentLength = body.length;
      res.add(body);
      await res.close();
    }

    setUp(() async {
      referersSeen.clear();
      rangesSeen.clear();
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBase =
          'http://${upstream.address.address}:${upstream.port}';
      unawaited(
        upstream.forEach((HttpRequest req) async {
          try {
            await serveFake(req);
          } catch (e) {
            try {
              req.response.statusCode = HttpStatus.internalServerError;
              await req.response.close();
            } catch (_) {
              // Response already gone — nothing left to do.
            }
          }
        }),
      );
    });

    tearDown(() async {
      await upstream.close(force: true);
    });

    Future<String> getString(HttpClient client, String url) async {
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      final HttpClientResponse res = await req.close();
      return res.transform(utf8.decoder).join();
    }

    test('master → variant → segment, all through the relay', () async {
      final CastRelay relay = CastRelay(lanIpOverride: '127.0.0.1');
      addTearDown(relay.stop);
      final String? relayUrl = await relay.start(
        sourceUrl: '$upstreamBase/master.m3u8',
      );
      expect(relayUrl, isNotNull);
      expect(relay.isRunning, isTrue);
      expect(relayUrl, startsWith('http://127.0.0.1:'));
      expect(relayUrl, endsWith('/master.m3u8'));

      final HttpClient client = HttpClient();
      addTearDown(client.close);

      // Master: rewritten to relay URIs, CORS header present.
      final HttpClientRequest masterReq =
          await client.getUrl(Uri.parse(relayUrl!));
      final HttpClientResponse masterRes = await masterReq.close();
      expect(masterRes.statusCode, HttpStatus.ok);
      expect(
        masterRes.headers.value('access-control-allow-origin'),
        '*',
      );
      final String masterBody =
          await masterRes.transform(utf8.decoder).join();
      expect(masterBody, contains('#EXT-X-STREAM-INF'));
      expect(masterBody, isNot(contains(upstreamBase)));
      final String variantUrl = masterBody
          .split('\n')
          .firstWhere((String l) => l.contains('/r/'));

      // Variant: rewritten segments + key, CORS present.
      final HttpClientRequest variantReq =
          await client.getUrl(Uri.parse(variantUrl));
      final HttpClientResponse variantRes = await variantReq.close();
      expect(variantRes.statusCode, HttpStatus.ok);
      expect(
        variantRes.headers.value('access-control-allow-origin'),
        '*',
      );
      final String variantBody =
          await variantRes.transform(utf8.decoder).join();
      expect(variantBody, contains('#EXT-X-KEY'));
      expect(variantBody, isNot(contains('key.bin"')));
      expect(variantBody, isNot(contains('seg-1.ts\n')));
      final List<String> relayLines = variantBody
          .split('\n')
          .where((String l) => l.contains('/r/'))
          .toList();
      expect(relayLines, hasLength(3)); // key + 2 segments

      // Segment bytes pass through exactly.
      final HttpClientRequest segReq =
          await client.getUrl(Uri.parse(relayLines[1]));
      final HttpClientResponse segRes = await segReq.close();
      expect(segRes.statusCode, HttpStatus.ok);
      expect(
        segRes.headers.value('access-control-allow-origin'),
        '*',
      );
      final List<int> segBytes = await segRes.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      expect(segBytes, segmentOne);

      // The disguised-.jpg segment keeps its bytes (content type
      // is corrected to video/mp2t by the relay).
      final HttpClientRequest seg2Req =
          await client.getUrl(Uri.parse(relayLines[2]));
      final HttpClientResponse seg2Res = await seg2Req.close();
      expect(seg2Res.statusCode, HttpStatus.ok);
      expect(seg2Res.headers.contentType?.mimeType, 'video/mp2t');
      final List<int> seg2Bytes = await seg2Res.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      expect(seg2Bytes, segmentTwo);

      // Every upstream fetch carried the Referer — master, variant
      // and both segments.
      expect(referersSeen, isNotEmpty);
      expect(
        referersSeen.every((String r) => r == 'https://megaplay.buzz/'),
        isTrue,
      );
    });

    test('Range requests forward and return 206', () async {
      final CastRelay relay = CastRelay(lanIpOverride: '127.0.0.1');
      addTearDown(relay.stop);
      final String? relayUrl = await relay.start(
        sourceUrl: '$upstreamBase/master.m3u8',
      );
      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final String masterBody = await getString(client, relayUrl!);
      final String variantUrl = masterBody
          .split('\n')
          .firstWhere((String l) => l.contains('/r/'));
      final String variantBody = await getString(client, variantUrl);
      final String segUrl = variantBody
          .split('\n')
          .where((String l) => l.contains('/r/'))
          .elementAt(1);
      final HttpClientRequest req = await client.getUrl(Uri.parse(segUrl));
      req.headers.set('range', 'bytes=2-5');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, HttpStatus.partialContent);
      expect(res.headers.value('content-range'), 'bytes 2-5/8');
      final List<int> bytes = await res.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      expect(bytes, <int>[3, 4, 5, 6]);
      expect(rangesSeen, contains('bytes=2-5'));
    });

    test('wrong token → 404, non-GET → 405, unknown path → 404',
        () async {
      final CastRelay relay = CastRelay(lanIpOverride: '127.0.0.1');
      addTearDown(relay.stop);
      final String? relayUrl = await relay.start(
        sourceUrl: '$upstreamBase/master.m3u8',
      );
      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final Uri base = Uri.parse(relayUrl!);

      final HttpClientRequest badTokenReq = await client.getUrl(
        base.replace(path: '/r/wrongtoken/master.m3u8'),
      );
      expect((await badTokenReq.close()).statusCode, HttpStatus.notFound);

      final HttpClientRequest postReq = await client.postUrl(base);
      expect((await postReq.close()).statusCode, HttpStatus.methodNotAllowed);

      final HttpClientRequest unknownReq = await client.getUrl(
        base.replace(path: '/r/${base.pathSegments[1]}/nope.m3u8'),
      );
      expect((await unknownReq.close()).statusCode, HttpStatus.notFound);
    });

    test('same source restarts nothing; new source re-points', () async {
      final CastRelay relay = CastRelay(lanIpOverride: '127.0.0.1');
      addTearDown(relay.stop);
      final String? first = await relay.start(
        sourceUrl: '$upstreamBase/master.m3u8',
      );
      final String? again = await relay.start(
        sourceUrl: '$upstreamBase/master.m3u8',
      );
      expect(again, first);
      final String? other = await relay.start(
        sourceUrl: '$upstreamBase/v1080.m3u8',
      );
      expect(other, isNotNull);
      expect(other, isNot(first));
      expect(relay.isRunning, isTrue);
      await relay.stop();
      expect(relay.isRunning, isFalse);
      expect(relay.relayUrl, isNull);
    });

    test('stop is safe when never started', () async {
      final CastRelay relay = CastRelay(lanIpOverride: '127.0.0.1');
      await relay.stop();
      expect(relay.isRunning, isFalse);
    });
  });
}
