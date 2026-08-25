/// Selects the [DiagnosticLog] implementation for the platform being compiled,
/// so the shared code can construct one without importing `dart:io`
/// (dotnet_SonicRelay#33).
///
/// Import this barrel rather than either implementation: the one that is not
/// selected is never compiled.
library;

export 'io_diagnostic_log_factory.dart'
    if (dart.library.js_interop) 'web_diagnostic_log_factory.dart'
    show createDiagnosticLog;
