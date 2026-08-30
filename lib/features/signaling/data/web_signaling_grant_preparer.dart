import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

import '../../device_identity/data/device_identity_session.dart';
import 'signaling_grant_preparer.dart';

SignalingGrantPreparer createPlatformSignalingGrantPreparer({
  required Uri apiBaseUrl,
  required DeviceIdentitySession deviceIdentitySession,
}) {
  final browserAdapter = BrowserHttpClientAdapter();
  browserAdapter.withCredentials = true;
  final dio = Dio()..httpClientAdapter = browserAdapter;
  return WebSignalingGrantPreparer(
    apiBaseUrl: apiBaseUrl,
    deviceIdentitySession: deviceIdentitySession,
    postAdapter: _DioSignalingGrantPostAdapter(dio, browserAdapter),
  );
}

class _DioSignalingGrantPostAdapter implements SignalingGrantPostAdapter {
  _DioSignalingGrantPostAdapter(this._dio, this._browserAdapter);

  final Dio _dio;
  final BrowserHttpClientAdapter _browserAdapter;

  @override
  set withCredentials(bool value) => _browserAdapter.withCredentials = value;

  @override
  Future<void> post(
    Uri uri, {
    required String bearer,
    required Map<String, Object?> data,
  }) async {
    await _dio.post<void>(
      uri.toString(),
      data: data,
      options: Options(
        headers: <String, String>{'Authorization': 'Bearer $bearer'},
      ),
    );
  }
}
