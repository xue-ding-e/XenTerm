import 'dart:io';

/// Destinations verified against XenTerm's README/THIRD_PARTY_NOTICES and the
/// dependencies' official repository metadata. Keep this list explicit: user
/// text, terminal output and imported profiles must never launch a process.
class SettingsLink {
  final String label;
  final String url;
  const SettingsLink(this.label, this.url);
}

const projectLinks = <SettingsLink>[
  SettingsLink('Source code', 'https://github.com/ixbaicn/XenTerm'),
  SettingsLink('Issue tracker', 'https://github.com/ixbaicn/XenTerm/issues'),
  SettingsLink('Releases', 'https://github.com/ixbaicn/XenTerm/releases'),
  SettingsLink('License', 'https://github.com/ixbaicn/XenTerm/blob/main/LICENSE'),
];

const creditLinks = <SettingsLink>[
  SettingsLink('小白 (ixbaicn)', 'https://github.com/ixbaicn'),
  SettingsLink('xue-ding-e', 'https://github.com/xue-ding-e'),
  // Canonical author.html_url from XenTerm commit 5636933c614d1047f4bffda699f8d3fc0a7c98b9.
  SettingsLink('noerror6', 'https://github.com/noerror6'),
  SettingsLink('XenTerm contributors', 'https://github.com/ixbaicn/XenTerm/graphs/contributors'),
  SettingsLink('Flutter', 'https://github.com/flutter/flutter'),
  SettingsLink('shadcn_flutter', 'https://github.com/sunarya-thito/shadcn_flutter'),
  SettingsLink('Rust', 'https://github.com/rust-lang/rust'),
  SettingsLink('russh', 'https://github.com/Eugeny/russh'),
  SettingsLink('rio-vt', 'https://github.com/raphamorim/rio/tree/main/rio-vt'),
  SettingsLink('Lucide', 'https://github.com/lucide-icons/lucide'),
  SettingsLink('Simple Icons', 'https://github.com/simple-icons/simple-icons'),
  SettingsLink('Twemoji', 'https://github.com/jdecked/twemoji'),
  SettingsLink('Third-party notices', 'https://github.com/ixbaicn/XenTerm/blob/main/THIRD_PARTY_NOTICES.md'),
];

typedef LinkProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Open only our fixed HTTPS destinations, without invoking a command shell.
/// Desktop launchers are already provided by the supported platforms, so this
/// feature does not add a plugin or silently change the dependency lockfile.
/// Tests inject [run] and never open a real browser.
Future<bool> openSettingsLink(
  String url, {
  LinkProcessRunner? run,
  String? operatingSystem,
}) async {
  if (![...projectLinks, ...creditLinks].any((link) => link.url == url)) {
    return false;
  }
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty || uri.hasPort) {
    return false;
  }
  final (executable, arguments) = switch (operatingSystem ?? Platform.operatingSystem) {
    'linux' => ('xdg-open', [url]),
    'macos' => ('/usr/bin/open', [url]),
    'windows' => ('rundll32.exe', ['url.dll,FileProtocolHandler', url]),
    _ => ('', <String>[]),
  };
  if (executable.isEmpty) return false;
  try {
    final result = await (run ?? _run)(executable, arguments);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<ProcessResult> _run(String executable, List<String> arguments) =>
    Process.run(executable, arguments, runInShell: false);
