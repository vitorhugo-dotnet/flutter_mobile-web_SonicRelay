/// The operating system this build is actually running on, resolved without
/// `dart:io` so the shared code compiles for the browser too
/// (dotnet_SonicRelay#33).
///
/// Deliberately not `defaultTargetPlatform`. That is Flutter's *rendering*
/// notion of the platform: an app can override it to get Cupertino widgets on
/// Android, and `flutter test` forces it to `TargetPlatform.android` on every
/// host. The decisions behind this façade — start an Android foreground
/// service, watch connectivity through a plugin that only Android and iOS
/// implement, report a `platform` at device bootstrap — all need the real OS,
/// and would misfire on an overridden or forced value.
///
/// Import this barrel rather than either implementation: the one that is not
/// selected is never compiled.
library;

export 'io_host_platform.dart'
    if (dart.library.js_interop) 'web_host_platform.dart'
    show hostPlatformName, isAndroidHost, isMobileHost, isWebHost;
