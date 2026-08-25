import 'diagnostic_log.dart';
import 'in_memory_diagnostic_log.dart';

/// Builds the memory-only log the browser uses. [directory] is accepted so the
/// factory keeps one signature across platforms, and ignored because the
/// browser has no filesystem to point it at.
DiagnosticLog createDiagnosticLog(String directory) => InMemoryDiagnosticLog();
