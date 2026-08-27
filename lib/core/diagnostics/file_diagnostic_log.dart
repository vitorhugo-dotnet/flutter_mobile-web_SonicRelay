import 'dart:io';

import 'diagnostic_event.dart';
import 'diagnostic_log.dart';

/// [DiagnosticLog] backed by one JSONL file per day under a directory, with
/// retention cleanup and single-file export. The Android and iOS behaviour.
class FileDiagnosticLog extends DiagnosticLog {
  FileDiagnosticLog(
    this._directory, {
    Duration retention = const Duration(days: 3),
  }) {
    _deleteExpiredFiles(retention);
  }

  final String _directory;

  String get logPath => '$_directory/viewer-${_todayStamp()}.jsonl';

  @override
  Future<void> persistEvent(DiagnosticEvent event) async {
    final dir = Directory(_directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(logPath).writeAsString(
      '${event.encode()}\n',
      mode: FileMode.append,
    );
  }

  @override
  Future<void> deletePersistedEvents() async {
    for (final file in _logFiles()) {
      await _tryDelete(file);
    }
  }

  @override
  Future<String> exportPersistedEvents() async {
    final exportDir = Directory('$_directory/exports');
    await exportDir.create(recursive: true);
    final exportPath = '${exportDir.path}/sonicrelay-logs-${_timestampStamp()}.jsonl';
    final output = File(exportPath).openWrite();
    try {
      final files = _logFiles()..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        await output.addStream(file.openRead());
      }
    } finally {
      await output.close();
    }
    return exportPath;
  }

  void _deleteExpiredFiles(Duration retention) {
    try {
      final cutoff = DateTime.now().subtract(retention);
      for (final file in _logFiles()) {
        if (file.statSync().modified.isBefore(cutoff)) {
          file.deleteSync();
        }
      }
    } catch (_) {
      // Retention cleanup must never stop the app from starting.
    }
  }

  List<File> _logFiles() {
    final dir = Directory(_directory);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.startsWith('viewer-') &&
            file.path.endsWith('.jsonl'))
        .toList();
  }

  Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Best-effort, matching the constructor's retention cleanup.
    }
  }

  String _todayStamp() {
    final now = DateTime.now().toUtc();
    return '${now.year}${_pad2(now.month)}${_pad2(now.day)}';
  }

  String _timestampStamp() {
    final now = DateTime.now().toUtc();
    return '${now.year}${_pad2(now.month)}${_pad2(now.day)}-'
        '${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}';
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');
}
