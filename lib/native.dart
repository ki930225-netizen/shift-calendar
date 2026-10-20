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

// ───────────── 배터리 ─────────────

/// 배터리 최적화에서 제외되어 있는지
Future<bool> isIgnoringBattery() async {
  if (kIsWeb) return true;
  try {
    return (await _ch.invokeMethod<bool>('isIgnoringBattery')) ?? false;
  } catch (_) {
    return false;
  }
}

/// "항상 백그라운드 실행 허용?" 창을 띄운다
Future<void> requestIgnoreBattery() => _call('requestIgnoreBattery');

// ───────────── 폰 캘린더 ─────────────

List<Map<String, dynamic>> _maps(dynamic r) {
  if (r is! List) return <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final e in r) {
    if (e is Map) out.add(Map<String, dynamic>.from(e));
  }
  return out;
}

Future<bool> hasCalendarPermission() async {
  if (kIsWeb) return false;
  try {
    return (await _ch.invokeMethod<bool>('hasCalendarPermission')) ?? false;
  } catch (_) {
    return false;
  }
}

Future<bool> requestCalendarPermission() async {
  if (kIsWeb) return false;
  try {
    return (await _ch.invokeMethod<bool>('requestCalendarPermission')) ?? false;
  } catch (_) {
    return false;
  }
}

/// 폰에 등록된 캘린더 목록: id, name, account, color
Future<List<Map<String, dynamic>>> deviceCalendars() async {
  if (kIsWeb) return <Map<String, dynamic>>[];
  try {
    return _maps(await _ch.invokeMethod<dynamic>('getCalendars'));
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

/// 기간 안의 일정: title, begin, end (밀리초), allDay, calId
Future<List<Map<String, dynamic>>> deviceEvents(int startMs, int endMs, List<int> ids) async {
  if (kIsWeb) return <Map<String, dynamic>>[];
  try {
    return _maps(await _ch
        .invokeMethod<dynamic>('getEvents', {'start': startMs, 'end': endMs, 'ids': ids}));
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

// ───────────── 저장 폴더 ─────────────

/// 앱 전용 파일 폴더 경로 (데이터 파일 저장용)
Future<String?> filesDirPath() async {
  if (kIsWeb) return null;
  try {
    return await _ch.invokeMethod<String>('getFilesDir');
  } catch (_) {
    return null;
  }
}

// ───────────── 근무 알람 (알람 시계 방식, 앱이 직접 울림) ─────────────

/// 근무 알람 목록을 통째로 등록. 실패하면 예외를 던진다(호출하는 쪽에서 예비 방식으로 전환).
/// 각 항목: id, at(밀리초), title, body, tone, sound, vibrate, key, noticeAt, noticeTitle, noticeBody
Future<Map<String, dynamic>> nativeSetAlarms(List<Map<String, dynamic>> alarms) async {
  if (kIsWeb) throw UnsupportedError('web');
  final r = await _ch.invokeMethod<dynamic>('alarmSetAll', {'alarms': alarms});
  if (r is Map) return Map<String, dynamic>.from(r);
  return <String, dynamic>{};
}

/// 테스트 알람 등 하나만 예약. 반환: clock / inexact / fail (+ 오류)
Future<String> nativeScheduleOne(Map<String, dynamic> alarm) async {
  if (kIsWeb) throw UnsupportedError('web');
  return (await _ch.invokeMethod<String>('alarmScheduleOne', alarm)) ?? 'fail';
}

/// 바로 알람 화면 띄우고 울리기 (테스트)
Future<void> nativeRingNow(Map<String, dynamic> alarm) async {
  if (kIsWeb) throw UnsupportedError('web');
  await _ch.invokeMethod<dynamic>('alarmRingNow', alarm);
}

/// 알림창의 "이번 알람 끄기"로 꺼진 회차 (가져오면 비워짐)
Future<List<String>> nativeTakeSkipped() async {
  if (kIsWeb) return <String>[];
  try {
    final r = await _ch.invokeMethod<List<dynamic>>('alarmTakeSkipped');
    return (r ?? const []).map((e) => e.toString()).toList();
  } catch (_) {
    return <String>[];
  }
}

/// 앱이 직접 예약해 둔 알람 수. 알 수 없으면 -1
Future<int> nativeAlarmCount() async {
  if (kIsWeb) return -1;
  try {
    final r = await _ch.invokeMethod<dynamic>('alarmInfo');
    if (r is Map) return (r['count'] as num?)?.toInt() ?? -1;
    return -1;
  } catch (_) {
    return -1;
  }
}

/// 잠금 화면 위에 알람 화면을 띄울 수 있는지 (안드로이드 14+ "전체 화면 알림" 권한)
Future<bool> canFullScreen() async {
  if (kIsWeb) return true;
  try {
    return (await _ch.invokeMethod<bool>('canFullScreen')) ?? true;
  } catch (_) {
    return true;
  }
}

Future<void> openFullScreenSettings() => _call('openFullScreenSettings');
