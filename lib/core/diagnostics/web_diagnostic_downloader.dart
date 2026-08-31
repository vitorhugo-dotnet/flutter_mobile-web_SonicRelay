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
    String? objectUrl;
    web.HTMLAnchorElement? anchor;
    var anchorAttached = false;

    try {
      final blob = web.Blob(
        [contents.toJS].toJS,
        web.BlobPropertyBag(type: mimeType),
      );
      final url = web.URL.createObjectURL(blob);
      objectUrl = url;
      final downloadAnchor = web.HTMLAnchorElement()
        ..href = url
        ..download = filename
        ..style.display = 'none';
      anchor = downloadAnchor;

      final body = web.document.body;
      if (body == null) {
        throw StateError(
          'Cannot start a browser download without a document body.',
        );
      }
      body.append(downloadAnchor);
      anchorAttached = true;
      downloadAnchor.click();
    } finally {
      if (anchorAttached) anchor!.remove();
      if (objectUrl != null) web.URL.revokeObjectURL(objectUrl);
    }
  }
}
