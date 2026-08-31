# Flutter Web Diagnostics Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the browser's bounded, redacted in-memory diagnostics as a locally downloaded JSONL file without introducing persistence or upload.

**Architecture:** `DiagnosticLog.export()` returns a platform-neutral export result. The Web implementation serializes current events and delegates Blob/object-URL/download behavior to an injectable browser adapter; the IO implementation keeps producing a filesystem path and the settings screen shares only path results.

**Tech Stack:** Flutter/Dart 3.11, `package:web`, existing `share_plus`, Flutter test.

**Spec:** `docs/superpowers/specs/2026-08-27-web-listener-auth-and-log-export-design.md`

## Global Constraints

- Keep diagnostics memory-only on Web and preserve the existing 100-event bound and redaction-before-storage behavior.
- Export JSON Lines oldest-first with UTF-8 and MIME type `application/x-ndjson`.
- Do not upload diagnostics or add browser persistence.
- Revoke temporary object URLs after initiating download.
- Do not add or update dependencies.
- Run only diagnostics/settings tests and targeted analysis.

---

### Task 1: Platform-neutral diagnostic export result

**Files:**
- Modify: `lib/core/diagnostics/diagnostic_log.dart`
- Modify: `lib/core/diagnostics/file_diagnostic_log.dart`
- Modify: `test/core/diagnostics/diagnostic_log_test.dart`

**Interfaces:**
- Produces: sealed `DiagnosticExportResult`; `DiagnosticFileExport(path)` for IO and `DiagnosticDownloadExport(filename)` for Web; `Future<DiagnosticExportResult> export()`.

- [ ] **Step 1: Write failing contract tests**

Assert file-backed export returns `DiagnosticFileExport` with the generated path and retains serialized events in order.

- [ ] **Step 2: Run and confirm RED**

Run: `flutter test test/core/diagnostics/diagnostic_log_test.dart`

Expected: compilation fails because export still returns `String`.

- [ ] **Step 3: Implement the result types and IO adaptation**

```dart
sealed class DiagnosticExportResult { const DiagnosticExportResult(); }
final class DiagnosticFileExport extends DiagnosticExportResult {
  const DiagnosticFileExport(this.path);
  final String path;
}
final class DiagnosticDownloadExport extends DiagnosticExportResult {
  const DiagnosticDownloadExport(this.filename);
  final String filename;
}
```

Change the abstract persistence hook and public export queue to return this type; wrap the existing file path in `DiagnosticFileExport`.

- [ ] **Step 4: Run and confirm GREEN**

Run the Task 1 command. Expected: diagnostics contract tests pass.

- [ ] **Step 5: Commit the export contract**

```text
git add lib/core/diagnostics/diagnostic_log.dart lib/core/diagnostics/file_diagnostic_log.dart test/core/diagnostics/diagnostic_log_test.dart
git commit -m "refactor: model diagnostic export results"
```

### Task 2: Browser download adapter and in-memory export

**Files:**
- Create: `lib/core/diagnostics/web_diagnostic_downloader.dart`
- Modify: `lib/core/diagnostics/in_memory_diagnostic_log.dart`
- Modify: `lib/core/diagnostics/web_diagnostic_log_factory.dart`
- Modify: `test/core/diagnostics/in_memory_diagnostic_log_test.dart`

**Interfaces:**
- Consumes: already-redacted `recentEvents` from `DiagnosticLog`.
- Produces: `abstract interface class DiagnosticDownloader { void download({required String filename, required String contents, required String mimeType}); }`; browser implementation uses Blob and an anchor; `InMemoryDiagnosticLog` accepts this adapter and returns `DiagnosticDownloadExport`.

- [ ] **Step 1: Replace refusal tests with failing download tests**

Inject a recording adapter; write two events including a sensitive property; export; assert one call, timestamped `sonicrelay-diagnostics-*.jsonl`, `application/x-ndjson;charset=utf-8`, one encoded event per line in oldest-first order, and `[REDACTED]` rather than the secret.

```dart
final result = await log.export();
expect(result, isA<DiagnosticDownloadExport>());
expect(downloader.contents.split('\n'), hasLength(2));
expect(downloader.contents, isNot(contains('super-secret')));
```

- [ ] **Step 2: Run and confirm RED**

Run: `flutter test test/core/diagnostics/in_memory_diagnostic_log_test.dart`

Expected: old `UnsupportedError` behavior fails the new expectations.

- [ ] **Step 3: Implement JSONL serialization and browser adapter**

Expose a protected snapshot/serialization hook from `DiagnosticLog` rather than accessing mutable storage directly. Join `event.encode()` values with newline, include a final newline only when non-empty, and delegate the browser operation.

The Web adapter creates a UTF-8 Blob, calls `URL.createObjectURL`, creates a hidden anchor with `download=filename`, clicks it, removes it, and calls `URL.revokeObjectURL` in `finally`. Keep DOM code isolated in this Web-selected file.

- [ ] **Step 4: Run and confirm GREEN**

Run the Task 2 command. Expected: all in-memory export tests pass.

- [ ] **Step 5: Commit Web download**

```text
git add lib/core/diagnostics/web_diagnostic_downloader.dart lib/core/diagnostics/in_memory_diagnostic_log.dart lib/core/diagnostics/web_diagnostic_log_factory.dart test/core/diagnostics/in_memory_diagnostic_log_test.dart
git commit -m "feat(web): download diagnostic logs"
```

### Task 3: Settings UI handles file share and browser download

**Files:**
- Modify: `lib/features/settings/presentation/settings_page.dart`
- Create: `test/features/settings/presentation/settings_diagnostics_test.dart`

**Interfaces:**
- Consumes: `DiagnosticFileExport` or `DiagnosticDownloadExport`.
- Produces: share sheet only for file exports; success message `Downloaded diagnostics log.` for browser downloads and `Exported diagnostics log.` for shared files.

- [ ] **Step 1: Write failing widget tests**

Override `diagnosticLogProvider` with fakes. Tap Export and assert a browser result never invokes the injectable file-share callback and displays `Downloaded diagnostics log.`; assert a file result invokes share once; assert exceptions display the existing failure message and retain events.

- [ ] **Step 2: Run and confirm RED**

Run: `flutter test test/features/settings/presentation/settings_diagnostics_test.dart`

Expected: test cannot observe result-specific behavior because the page assumes `String path`.

- [ ] **Step 3: Implement result dispatch**

Use a switch over the sealed result. Remove the `kIsWeb` path special case. Put file sharing behind an existing/new provider callback so widget tests do not invoke platform channels.

- [ ] **Step 4: Run focused tests and analysis**

Run:

```text
flutter test test/core/diagnostics/diagnostic_log_test.dart test/core/diagnostics/in_memory_diagnostic_log_test.dart test/features/settings/presentation/settings_diagnostics_test.dart
flutter analyze lib/core/diagnostics lib/features/settings/presentation/settings_page.dart
```

Expected: tests and analysis pass.

- [ ] **Step 5: Commit settings integration**

```text
git add lib/features/settings/presentation/settings_page.dart test/features/settings/presentation/settings_diagnostics_test.dart lib/app/di/app_providers.dart
git commit -m "fix(web): export diagnostics from settings"
```

### Task 4: Focused verification

**Files:** No production edits expected.

- [ ] **Step 1: Run Task 3 focused tests and analysis**

Expected: PASS with no platform-channel or DOM failures under Flutter test.

- [ ] **Step 2: Inspect the targeted diff**

Run `git diff --check` and `git diff --stat` for the files listed in Tasks 1-3. Confirm no upload, local storage, dependency, or unrelated settings changes.

- [ ] **Step 3: Record manual browser verification**

Document Chrome/Chromium and Firefox checks: clicking Export downloads a readable `.jsonl`, its lines are chronological valid JSON, secrets remain redacted, Clear empties later exports, and no request uploads the file.

