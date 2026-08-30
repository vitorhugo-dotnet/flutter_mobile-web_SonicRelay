import 'dart:async';

import 'diagnostic_event.dart';
import 'diagnostic_redactor.dart';

sealed class DiagnosticExportResult {
  const DiagnosticExportResult();
}

final class DiagnosticFileExport extends DiagnosticExportResult {
  const DiagnosticFileExport(this.path);

  final String path;
}

final class DiagnosticDownloadExport extends DiagnosticExportResult {
  const DiagnosticDownloadExport(this.filename);

  final String filename;
}

/// Redacted, bounded diagnostic log for the viewer. Mirrors
/// windows_SonicRelay's DiagnosticLog: a 100-event in-memory ring buffer plus
/// whatever durable form the platform can offer.
///
/// Redaction, the ring buffer and the write queue live here because they are
/// the parts that must behave identically everywhere. Persistence is the only
/// part that differs, so it is left to the subclass: `FileDiagnosticLog` writes
/// a JSONL file per day on Android and iOS, `InMemoryDiagnosticLog` keeps only
/// the ring buffer in the browser, where there is no filesystem to write to and
/// dotnet_SonicRelay#33 forbids persisting session data anyway.
abstract class DiagnosticLog {
  static const _eventLimit = 100;

  final List<DiagnosticEvent> _recentEvents = [];

  // Serializes every write/clear/export as one queue, so recentEvents and the
  // persisted form always move together — the same class of race a Codex review
  // caught in the paired Windows PR (RecentEvents updated before the write
  // lock was held) cannot happen here because both mutations run inside the
  // same queued closure.
  Future<void> _queue = Future<void>.value();

  List<DiagnosticEvent> get recentEvents => List.unmodifiable(_recentEvents);

  /// A stable oldest-first view for subclasses that serialize retained events.
  /// Events are already redacted before entering this bounded buffer.
  List<DiagnosticEvent> get recentEventsForExport =>
      List.unmodifiable(_recentEvents);

  Future<void> write(
    String category,
    String message, [
    Map<String, String>? properties,
  ]) {
    final safeProperties = <String, String>{
      for (final entry in (properties ?? const {}).entries)
        DiagnosticRedactor.redact(entry.key): DiagnosticRedactor.isSensitiveKey(entry.key)
            ? '[REDACTED]'
            : DiagnosticRedactor.redact(entry.value),
    };
    final event = DiagnosticEvent(
      timestamp: DateTime.now().toUtc(),
      category: DiagnosticRedactor.redact(category),
      message: DiagnosticRedactor.redact(message),
      properties: safeProperties,
    );

    return _enqueue(() async {
      _recentEvents.add(event);
      if (_recentEvents.length > _eventLimit) {
        _recentEvents.removeRange(0, _recentEvents.length - _eventLimit);
      }
      await persistEvent(event);
    });
  }

  /// Deletes every retained event and empties the in-memory buffer.
  Future<void> clear() => _enqueue(() async {
    await deletePersistedEvents();
    _recentEvents.clear();
  });

  /// Concatenates every retained event (oldest first) into one exported file
  /// and returns a platform-neutral export result. Events are already redacted
  /// at write time.
  Future<DiagnosticExportResult> export() => _enqueue(exportPersistedEvents);

  /// Writes one already-redacted event to the platform's durable store.
  Future<void> persistEvent(DiagnosticEvent event);

  /// Drops everything [persistEvent] has written so far.
  Future<void> deletePersistedEvents();

  /// Collects the durable store into one platform-appropriate export result.
  Future<DiagnosticExportResult> exportPersistedEvents();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // Keep the queue alive even if this step failed, otherwise every later
    // write/clear/export would be skipped once one link in the chain rejects.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }
}
