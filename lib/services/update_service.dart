import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// A newer AniBee release is available (0.2.17).
class UpdateAvailable {
  const UpdateAvailable({required this.tag, required this.url});

  /// Release tag as published, e.g. 'v0.2.17'.
  final String tag;

  /// Release page URL (opened in the browser — iOS cannot install
  /// an IPA from inside the app; the user sideloads via eSign).
  final String url;
}

/// Update check (0.2.17): on cold start, GET the latest public
/// release and compare its tag with the installed version.
///
/// No token lives in the app — the check only works while the repo
/// is public. Any failure (offline, private repo, bad JSON,
/// timeout) is SILENT: no dialog, no error, and launch never
/// blocks. Never a force-update: the dialog always has a "Later"
/// that records the skipped version.
class UpdateService {
  static const String latestReleaseUrl =
      'https://api.github.com/repos/sezkc16/anibee/releases/latest';

  /// Pure version compare: 'v0.2.17' vs '0.2.17', '0.2' vs
  /// '0.2.0', build metadata ('+21') and pre-release suffixes
  /// ('-beta') ignored for the numeric compare. Returns > 0 when
  /// [latest] is newer than [installed], 0 when equal, < 0 when
  /// older. Non-numeric segments count as 0; missing parts count
  /// as 0.
  static int compareVersions(String latest, String installed) {
    List<int> parse(String v) {
      String s = v.trim();
      if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
      final String core = s.split('+').first.split('-').first;
      return core.split('.').map((String p) => int.tryParse(p) ?? 0).toList();
    }

    final List<int> a = parse(latest);
    final List<int> b = parse(installed);
    final int n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final int av = i < a.length ? a[i] : 0;
      final int bv = i < b.length ? b[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  /// Returns the latest release when it is NEWER than the
  /// installed build, else null. Never throws — every failure
  /// path returns null.
  ///
  /// [client] and [packageInfo] exist for tests (a fake HTTP
  /// client and a fake installed version); production passes
  /// neither.
  static Future<UpdateAvailable?> checkForUpdate({
    http.Client? client,
    Future<PackageInfo> Function()? packageInfo,
  }) async {
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response res = await httpClient
          .get(
            Uri.parse(latestReleaseUrl),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final Map<String, dynamic> json =
          jsonDecode(res.body) as Map<String, dynamic>;
      final String? tag = json['tag_name'] as String?;
      final String? url = json['html_url'] as String?;
      if (tag == null || tag.isEmpty || url == null || url.isEmpty) {
        return null;
      }
      final PackageInfo info =
          await (packageInfo ?? PackageInfo.fromPlatform)();
      if (compareVersions(tag, info.version) <= 0) return null;
      return UpdateAvailable(tag: tag, url: url);
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
  }
}
