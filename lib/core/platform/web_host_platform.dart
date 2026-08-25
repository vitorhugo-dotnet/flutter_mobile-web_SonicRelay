/// The `platform` value a browser client reports at device bootstrap. The
/// backend needs it to tell a `web_publisher` apart from the mobile clients
/// and to apply the ephemeral-identity rules (dotnet_SonicRelay#33).
String get hostPlatformName => 'web';

bool get isAndroidHost => false;

/// False even in a mobile browser: this asks whether the *native* mobile
/// integrations are available, and in a tab they are not, whatever the phone
/// underneath is running.
bool get isMobileHost => false;

bool get isWebHost => true;
