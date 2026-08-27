import 'dart:async';
import 'dart:io';
import 'diagnostic_event.dart';
import 'diagnostic_redactor.dart';

class DiagnosticLog {
  DiagnosticLog(
    this._directory, {
    Duration retention = const Duration(days: 3),
  }) {
    _deleteExpiredFiles(retention);
  }
  static const _eventLimit = 100;
  final String _directory;
  final List<DiagnosticEvent> _recentEvents = [];
  Future<void> _queue = Future.value();
  String get logPath => '$_directory/viewer-${_todayStamp()}.jsonl';
  List<DiagnosticEvent> get recentEvents => List.unmodifiable(_recentEvents);
  Future<void> write(
    String category,
    String message, [
    Map<String, String>? properties,
  ]) {
    final event = DiagnosticEvent(
      timestamp: DateTime.now().toUtc(),
      category: DiagnosticRedactor.redact(category),
      message: DiagnosticRedactor.redact(message),
      properties: {
        for (final e in (properties ?? const {}).entries)
          DiagnosticRedactor.redact(
            e.key,
          ): DiagnosticRedactor.isSensitiveKey(e.key)
              ? '[REDACTED]'
              : DiagnosticRedactor.redact(e.value),
      },
    );
    return _enqueue(() async {
      _recentEvents.add(event);
      if (_recentEvents.length > _eventLimit)
        _recentEvents.removeRange(0, _recentEvents.length - _eventLimit);
      final d = Directory(_directory);
      if (!await d.exists()) await d.create(recursive: true);
      await File(
        logPath,
      ).writeAsString('${event.encode()}\n', mode: FileMode.append);
    });
  }

  Future<void> clear() => _enqueue(() async {
    for (final f in _logFiles()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    _recentEvents.clear();
  });
  Future<String> export() => _enqueue(() async {
    final d = Directory('$_directory/exports');
    await d.create(recursive: true);
    final p = '${d.path}/sonicrelay-logs-${_stamp()}.jsonl';
    final out = File(p).openWrite();
    try {
      for (final f in (_logFiles()..sort((a, b) => a.path.compareTo(b.path))))
        await out.addStream(f.openRead());
    } finally {
      await out.close();
    }
    return p;
  });
  Future<T> _enqueue<T>(Future<T> Function() a) {
    final r = _queue.then((_) => a());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  List<File> _logFiles() {
    final d = Directory(_directory);
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('viewer-') && f.path.endsWith('.jsonl'))
        .toList();
  }

  void _deleteExpiredFiles(Duration r) {
    try {
      final c = DateTime.now().subtract(r);
      for (final f in _logFiles()) {
        if (f.statSync().modified.isBefore(c)) f.deleteSync();
      }
    } catch (_) {}
  }

  String _todayStamp() {
    final n = DateTime.now().toUtc();
    return '${n.year}${_p(n.month)}${_p(n.day)}';
  }

  String _stamp() {
    final n = DateTime.now().toUtc();
    return '${_todayStamp()}-${_p(n.hour)}${_p(n.minute)}${_p(n.second)}';
  }

  String _p(int n) => n.toString().padLeft(2, '0');
}
