import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'diagnostic_event.dart';
import 'diagnostic_redactor.dart';

class DiagnosticLog {
  DiagnosticLog(
    this._directory, {
    Duration retention = const Duration(days: 3),
  });
  final String _directory;
  final List<DiagnosticEvent> _events = [];
  Future<void> _queue = Future.value();
  String get logPath => 'web://sonicrelay-logs.jsonl';
  List<DiagnosticEvent> get recentEvents => List.unmodifiable(_events);
  Future<void> write(String c, String m, [Map<String, String>? p]) {
    final e = DiagnosticEvent(
      timestamp: DateTime.now().toUtc(),
      category: DiagnosticRedactor.redact(c),
      message: DiagnosticRedactor.redact(m),
      properties: {
        for (final x in (p ?? const {}).entries)
          DiagnosticRedactor.redact(
            x.key,
          ): DiagnosticRedactor.isSensitiveKey(x.key)
              ? '[REDACTED]'
              : DiagnosticRedactor.redact(x.value),
      },
    );
    return _enqueue(() async {
      _events.add(e);
      if (_events.length > 100) _events.removeAt(0);
    });
  }

  Future<void> clear() => _enqueue(() async => _events.clear());
  Future<String> export() => _enqueue(() async {
    final data = _events.map((e) => e.encode()).join('\n');
    final blob = html.Blob([utf8.encode(data)], 'application/jsonl');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)
      ..download = 'sonicrelay-logs.jsonl'
      ..click();
    html.Url.revokeObjectUrl(url);
    return 'web://sonicrelay-logs.jsonl';
  });
  Future<T> _enqueue<T>(Future<T> Function() a) {
    final r = _queue.then((_) => a());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }
}
