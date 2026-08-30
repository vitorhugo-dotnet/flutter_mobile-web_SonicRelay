import 'diagnostic_event.dart';
import 'diagnostic_log.dart';

/// [DiagnosticLog] for the browser: the shared ring buffer and nothing else.
///
/// The web publisher is deliberately session-scoped — dotnet_SonicRelay#33
/// keeps its device secret in memory and expects everything to disappear when
/// the tab closes — so writing a durable log would contradict the same rule
/// that keeps the credential out of `localStorage`. Diagnostics stay readable
/// on the settings screen for the life of the tab, and go no further.
class InMemoryDiagnosticLog extends DiagnosticLog {
  @override
  Future<void> persistEvent(DiagnosticEvent event) async {}

  @override
  Future<void> deletePersistedEvents() async {}

  @override
  Future<DiagnosticExportResult> exportPersistedEvents() async => throw UnsupportedError(
    'Diagnostics are kept in memory in the browser and cannot be exported to '
    'a file. Read them on the settings screen instead.',
  );
}
