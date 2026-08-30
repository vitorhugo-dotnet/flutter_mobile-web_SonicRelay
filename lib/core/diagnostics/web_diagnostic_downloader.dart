import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'in_memory_diagnostic_log.dart';

/// Starts a browser download without retaining diagnostic data in the browser.
class WebDiagnosticDownloader implements DiagnosticDownloader {
  @override
  void download({
    required String filename,
    required String contents,
    required String mimeType,
  }) {
    final blob = web.Blob(
      [contents.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final objectUrl = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = objectUrl
      ..download = filename
      ..style.display = 'none';

    try {
      web.document.body?.append(anchor);
      anchor.click();
    } finally {
      anchor.remove();
      web.URL.revokeObjectURL(objectUrl);
    }
  }
}
