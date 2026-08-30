import 'diagnostic_event.dart';
import 'diagnostic_log.dart';

abstract interface class DiagnosticDownloader {
  void download({
    required String filename,
    required String contents,
    required String mimeType,
  });
}

/// [DiagnosticLog] for the browser: the shared ring buffer and nothing else.
///
/// The web publisher is deliberately session-scoped — dotnet_SonicRelay#33
/// keeps its device secret in memory and expects everything to disappear when
/// the tab closes — so writing a durable log would contradict the same rule
/// that keeps the credential out of `localStorage`. Diagnostics stay readable
/// on the settings screen for the life of the tab, and go no further.
class InMemoryDiagnosticLog extends DiagnosticLog {
  InMemoryDiagnosticLog({required DiagnosticDownloader downloader})
    : _downloader = downloader;

  final DiagnosticDownloader _downloader;

  @override
  Future<void> persistEvent(DiagnosticEvent event) async {}

  @override
  Future<void> deletePersistedEvents() async {}

  @override
  Future<DiagnosticExportResult> exportPersistedEvents() async {
    final contents = recentEventsForExport
        .map((event) => event.encode())
        .join('\n');
    final filename =
        'sonicrelay-diagnostics-${DateTime.now().toUtc().toIso8601String()}.jsonl';
    _downloader.download(
      filename: filename,
      contents: contents.isEmpty ? '' : '$contents\n',
      mimeType: 'application/x-ndjson;charset=utf-8',
    );
    return DiagnosticDownloadExport(filename);
  }
}
