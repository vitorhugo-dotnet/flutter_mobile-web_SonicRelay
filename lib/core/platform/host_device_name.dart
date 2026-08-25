/// Selects the device-name lookup for the platform being compiled, keeping
/// `device_info_plus` and `dart:io` out of the browser build
/// (dotnet_SonicRelay#33).
///
/// Import this barrel rather than either implementation: the one that is not
/// selected is never compiled.
library;

export 'io_host_device_name.dart'
    if (dart.library.js_interop) 'web_host_device_name.dart'
    show resolveHostDeviceName;
