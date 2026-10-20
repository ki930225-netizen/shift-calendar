import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 안드로이드 기능(알람 볼륨, 설정 화면 열기)을 부르는 통로. PC 미리보기에서는 아무 일도 하지 않는다.
const MethodChannel _ch = MethodChannel('shiftcal/native');

/// [현재 볼륨, 최대 볼륨] (폰의 "알람" 볼륨). 읽을 수 없으면 null
Future<List<int>?> getAlarmVolume() async {
  if (kIsWeb) return null;
  try {
    final r = await _ch.invokeMethod<List<dynamic>>('getAlarmVolume');
    if (r == null || r.length < 2) return null;
    return [r[0] as int, r[1] as int];
  } catch (_) {
    return null;
  }
}

Future<void> setAlarmVolume(int v) async {
  if (kIsWeb) return;
  try {
    await _ch.invokeMethod<dynamic>('setAlarmVolume', {'v': v});
  } catch (_) {}
}

Future<void> openAppSettings() => _call('openAppSettings');
Future<void> openBatterySettings() => _call('openBatterySettings');
Future<void> openNotificationSettings() => _call('openNotificationSettings');

Future<void> _call(String name) async {
  if (kIsWeb) return;
  try {
    await _ch.invokeMethod<dynamic>(name);
  } catch (_) {}
}
