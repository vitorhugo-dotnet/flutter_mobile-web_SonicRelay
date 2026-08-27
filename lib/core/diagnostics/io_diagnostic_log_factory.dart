import 'package:path_provider/path_provider.dart';

import 'diagnostic_log.dart';
import 'file_diagnostic_log.dart';

/// Builds the file-backed log Android and iOS use. [directory] is the
/// already-resolved application support directory (see `main.dart`).
DiagnosticLog createDiagnosticLog(String directory) =>
    FileDiagnosticLog(directory);

/// The application support directory [createDiagnosticLog] writes under,
/// resolved once at startup because path_provider's lookup is async.
Future<String> resolveDiagnosticsDirectory() async =>
    (await getApplicationSupportDirectory()).path;
