/// Selects the signaling-grant implementation for the compiled platform.
library;

export 'io_signaling_grant_preparer.dart'
    if (dart.library.js_interop) 'web_signaling_grant_preparer.dart'
    show createPlatformSignalingGrantPreparer;
