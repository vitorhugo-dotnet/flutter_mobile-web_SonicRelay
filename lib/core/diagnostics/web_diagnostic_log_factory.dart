import 'diagnostic_log.dart';
import 'in_memory_diagnostic_log.dart';

/// Builds the memory-only log the browser uses. [directory] is accepted so the
/// factory keeps one signature across platforms, and ignored because the
/// browser has no filesystem to point it at.
DiagnosticLog createDiagnosticLog(String directory) => InMemoryDiagnosticLog();

/// Empty, because the log above never touches it. path_provider ships no web
/// implementation, so calling it from a browser throws before `runApp` and
/// leaves the tab blank — resolving the directory through this façade is what
/// keeps that call out of the web build entirely.
Future<String> resolveDiagnosticsDirectory() async => '';
