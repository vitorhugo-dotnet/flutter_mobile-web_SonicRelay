import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the decoupling from dotnet_SonicRelay#33: the browser publisher is
/// meant to reuse this app's models, API client, signaling and session code, so
/// no library it reaches may import `dart:io` — and the mobile builds must pay
/// nothing for that, which is why the platform-specific halves sit behind
/// conditional imports instead of runtime branches.
///
/// The `dart2js` build is the real check. This test is the fast one: it fails
/// on the pull request that adds the offending import, naming the chain that
/// reaches it, instead of on a web build nobody runs locally.
const _entrypoint = 'lib/main.dart';

/// Files allowed to import `dart:io` because only the non-web branch of a
/// conditional import reaches them. Each must have a web counterpart, so this
/// list may only grow alongside one.
const _ioOnlyLibraries = {
  'lib/core/diagnostics/file_diagnostic_log.dart',
  'lib/core/platform/io_host_device_name.dart',
  'lib/core/platform/io_host_platform.dart',
  'lib/core/websocket/io_websocket_connector.dart',
};

/// One `import`/`export` directive: its default target plus any conditional
/// targets keyed by the environment constant that selects them.
final _directive = RegExp(
  r"""(?:import|export)\s+'([^']+)'((?:\s+if\s*\(\s*[\w.]+\s*\)\s*'[^']+')*)""",
);
final _conditional = RegExp(r"""if\s*\(\s*([\w.]+)\s*\)\s*'([^']+)'""");

/// The libraries reachable from [_entrypoint] when compiling for the browser,
/// mapped to the chain of imports that first reached each one.
Map<String, List<String>> _webReachableLibraries() {
  final chains = <String, List<String>>{
    _entrypoint: [_entrypoint],
  };
  final pending = <String>[_entrypoint];

  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final source = File(current).readAsStringSync();

    for (final match in _directive.allMatches(source)) {
      var target = match.group(1)!;
      // A conditional import compiles its web branch for `dart2js`, so that is
      // the branch this walk has to follow.
      for (final option in _conditional.allMatches(match.group(2) ?? '')) {
        if (option.group(1) == 'dart.library.js_interop' ||
            option.group(1) == 'dart.library.html') {
          target = option.group(2)!;
        }
      }

      final resolved = _resolve(target, from: current);
      if (resolved == null || chains.containsKey(resolved)) continue;
      chains[resolved] = [...chains[current]!, resolved];
      pending.add(resolved);
    }
  }

  return chains;
}

/// Maps a directive target onto a path under `lib/`, or null when it points
/// outside this package (`dart:`, or another package's `package:` URI).
String? _resolve(String target, {required String from}) {
  if (target.startsWith('dart:')) return null;
  if (target.startsWith('package:sonic_relay/')) {
    return 'lib/${target.substring('package:sonic_relay/'.length)}';
  }
  if (target.contains(':')) return null;
  return File('${File(from).parent.path}/$target').uri.normalizePath().path
      .replaceFirst(RegExp('^${Directory.current.path}/'), '');
}

void main() {
  test('no library the browser build reaches imports dart:io', () {
    final chains = _webReachableLibraries();

    // Without this the test passes vacuously the day the resolver stops
    // resolving anything, which is exactly when it would be needed.
    expect(
      chains,
      hasLength(greaterThan(40)),
      reason: 'The import walk collapsed — it is no longer checking the app.',
    );

    final offenders = <String, List<String>>{};

    for (final entry in chains.entries) {
      if (File(entry.key).readAsStringSync().contains("import 'dart:io'")) {
        offenders[entry.key] = entry.value;
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These libraries import dart:io and the browser build reaches them:\n'
          '${offenders.entries.map((e) => '  ${e.key}\n    via ${e.value.join(' -> ')}').join('\n')}\n'
          'Put the platform half behind a conditional import (see '
          'core/platform/host_platform.dart) rather than branching at runtime.',
    );
  });

  test('every dart:io library is reachable only off the web branch', () {
    final webReachable = _webReachableLibraries().keys.toSet();

    final ioImporters = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => file.readAsStringSync().contains("import 'dart:io'"))
        .map((file) => file.path.replaceAll(r'\', '/'))
        .toSet();

    expect(
      ioImporters.difference(_ioOnlyLibraries),
      isEmpty,
      reason:
          'A new library imports dart:io. Either give it a web counterpart '
          'behind a conditional import, or add it to _ioOnlyLibraries once it '
          'has one.',
    );
    expect(
      _ioOnlyLibraries.intersection(webReachable),
      isEmpty,
      reason: 'An io-only library is reachable from the browser build.',
    );
    // A stale allowlist entry hides the next real regression behind it.
    expect(
      _ioOnlyLibraries.difference(ioImporters),
      isEmpty,
      reason: '_ioOnlyLibraries lists a library that no longer imports dart:io.',
    );
  });
}
