import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xenterm_app/screens/settings/settings_links.dart';

void main() {
  test('every documented link is a fixed HTTPS GitHub destination', () {
    final links = [...projectLinks, ...creditLinks];
    expect(links.map((link) => link.url).toSet().length, links.length);
    for (final link in links) {
      final uri = Uri.parse(link.url);
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.userInfo, isEmpty);
    }
  });

  for (final os in ['linux', 'macos', 'windows']) {
    test('$os opens a verified URL as one argument without a shell', () async {
      final calls = <(String, List<String>)>[];
      final url = projectLinks.first.url;
      final result = await openSettingsLink(url, operatingSystem: os,
        run: (command, arguments) async {
          calls.add((command, arguments));
          return ProcessResult(1, 0, '', '');
        });
      expect(result, isTrue);
      expect(calls.single.$2.last, url);
      expect(calls.single.$1, isNot(anyOf('sh', 'cmd', 'powershell')));
    });
  }

  test('unlisted, non-HTTPS and injected destinations never launch', () async {
    var calls = 0;
    for (final url in [
      'file:///tmp/test', 'javascript:alert(1)',
      'https://github.com.evil.invalid/ixbaicn',
      'https://github.com/ixbaicn/XenTerm;touch /tmp/unwanted',
      'https://unverified.invalid',
    ]) {
      expect(await openSettingsLink(url, run: (_, _) async {
        calls++;
        return ProcessResult(1, 0, '', '');
      }), isFalse);
    }
    expect(calls, 0);
  });

  test('missing browser handler reports failure instead of claiming success', () async {
    expect(await openSettingsLink(projectLinks.first.url,
      operatingSystem: 'linux', run: (_, _) async => ProcessResult(1, 1, '', 'no handler')), isFalse);
    expect(await openSettingsLink(projectLinks.first.url,
      operatingSystem: 'linux', run: (_, _) async => throw const ProcessException('xdg-open', [], 'missing')), isFalse);
  });
}
