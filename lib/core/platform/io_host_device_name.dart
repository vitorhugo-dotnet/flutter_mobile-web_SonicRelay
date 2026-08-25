import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Resolves this device's human name (model or user-assigned name) so the
/// publisher's paired-viewers list can show "Pixel 8" instead of a GUID or a
/// generic "SonicRelay android viewer" label. Best-effort by design: returning
/// null keeps the generic fallback name.
Future<String?> resolveHostDeviceName() async {
  final plugin = DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final info = await plugin.androidInfo;
    final manufacturer = info.manufacturer.trim();
    final model = info.model.trim();
    if (model.isEmpty) return null;
    if (manufacturer.isEmpty ||
        model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
      return model;
    }
    return '${manufacturer[0].toUpperCase()}${manufacturer.substring(1)} '
        '$model';
  }
  if (Platform.isIOS) {
    final info = await plugin.iosInfo;
    final name = info.name.trim();
    return name.isEmpty ? info.utsname.machine : name;
  }
  if (Platform.isMacOS) return (await plugin.macOsInfo).computerName;
  if (Platform.isWindows) return (await plugin.windowsInfo).computerName;
  if (Platform.isLinux) return (await plugin.linuxInfo).prettyName;
  return null;
}
