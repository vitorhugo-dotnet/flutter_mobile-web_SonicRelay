import 'diagnostic_log.dart';
import 'file_diagnostic_log.dart';

/// Builds the file-backed log Android and iOS use. [directory] is the
/// already-resolved application support directory (see `main.dart`).
DiagnosticLog createDiagnosticLog(String directory) =>
    FileDiagnosticLog(directory);
