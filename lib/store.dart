import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'holidays.dart';
import 'ical.dart';
import 'models.dart';

final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

class _Pending {
  final DateTime when;
  final String title;
  final String body;
  final bool alarmType;
  final String tone;
  final bool sound;
  final bool vibrate;
  _Pending(this.when, this.title, this.body, this.alarmType,
      {this.tone = 'bell', this.sound = true, this.vibrate = true});
}

class AlarmStatus {
  final bool notifOk;
  final bool exactOk;
  final int pending;
  AlarmStatus(this.notifOk, this.exactOk, this.pending);
}

List<T> _decodeList<T>(String? s, T Function(Map<String, dynamic>) f) {
  if (s == null) return [];
  try {
    return (jsonDecode(s) as List).map((e) => f(Map<String, dynamic>.from(e))).toList();
  } catch (_) {
    return [];
  }
}

Map<String, String> _decodeStrMap(String? s) {
  if (s == null) return {};
  try {
    return Map<String, String>.from(jsonDecode(s));
  } catch (_) {
    return {};
  }
}

class Store extends ChangeNotifier {
  Map<String, String> days = {}; // yyyy-MM-dd -> ShiftType.id
  Map<String, String> attend = {}; // yyyy-MM-dd -> 근태 이름(연차 등)
  List<String> attendTypes = ['연차', '반차', '병가', '경조', '교육', '출장'];
  List<String> pattern = [];
  List<Memo> memos = [];
  List<AlarmItem> alarms = [];
  int nextId = 1;

  // 외부 캘린더
  bool holidaySync = true;
  String icalUrl = '';
  String lastSync = '';
  String syncMsg = '';
  bool syncing = false;
  List<Ev> holidayEvs = [];
  List<Ev> googleEvs = [];
  Map<String, List<Ev>> evByDay = {};

  // ── 조회 ──

  ShiftType? shiftOn(DateTime d) => shiftById(days[dayKey(d)]);

  String? holidayName(DateTime d) {
    final k = dayKey(d);
    for (final e in evByDay[k] ?? const <Ev>[]) {
      if (e.kind == 0) return e.title;
    }
    return allBuiltinHolidays(d.year)[k];
  }

  /// 쉬는 날인지 (토요일 / 일요일 / 공휴일 중 고른 것)
  bool isRestDay(DateTime d, {bool sat = true, bool sun = true, bool hol = true}) {
    if (sat && d.weekday == DateTime.saturday) return true;
    if (sun && d.weekday == DateTime.sunday) return true;
    if (hol && holidayName(d) != null) return true;
    return false;
  }

  /// 공휴일이 아닌 외부 일정(기념일 포함)
  List<Ev> evsOn(DateTime d) =>
      (evByDay[dayKey(d)] ?? const <Ev>[]).where((e) => e.kind != 0).toList();

  List<Memo> memosOn(DateTime d) {
    final k = dayKey(d);
    final l = memos.where((m) => m.covers(k)).toList();
    l.sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return l;
  }

  List<AlarmItem> get sortedAlarms {
    final l = List<AlarmItem>.of(alarms);
    l.sort((a, b) => a.minutes.compareTo(b.minutes));
    return l;
  }

  /// 앞으로 horizon 일 안에 울릴 근무 알람을 시각 순서로 계산 (요일 조건·전날/다음날 반영)
  List<NextAlarm> planShiftAlarms(DateTime now, int horizon) {
    final out = <NextAlarm>[];
    final limit = now.add(Duration(days: horizon));
    for (int i = -1; i <= horizon + 1; i++) {
      final d = DateTime(now.year, now.month, now.day + i);
      final sid = days[dayKey(d)];
      if (sid == null) continue;
      for (final a in alarms) {
        if (!a.enabled || a.shiftId != sid) continue;
        if (!a.days.contains(d.weekday)) continue;
        final ad = DateTime(d.year, d.month, d.day + a.dayOffset);
        final w = DateTime(ad.year, ad.month, ad.day, a.minutes ~/ 60, a.minutes % 60);
        if (w.isBefore(now) || w.isAfter(limit)) continue;
        out.add(NextAlarm(w, a));
      }
    }
    out.sort((x, y) => x.when.compareTo(y.when));
    return out;
  }

  /// 앞으로 가장 먼저 울릴 근무 알람
  NextAlarm? nextAlarm() {
    final l = planShiftAlarms(DateTime.now(), 60);
    return l.isEmpty ? null : l.first;
  }

  void _rebuildEv() {
    final m = <String, List<Ev>>{};
    for (final e in [...holidayEvs, ...googleEvs]) {
      m.putIfAbsent(e.date, () => []).add(e);
    }
    evByDay = m;
  }

  // ── 불러오기 / 저장 ──

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    days = _decodeStrMap(p.getString('v2_days'));
    attend = _decodeStrMap(p.getString('v2_attend'));
    attendTypes = p.getStringList('v2_attendTypes') ?? attendTypes;
    pattern = p.getStringList('v2_pattern') ?? [];
    memos = _decodeList<Memo>(p.getString('v2_memos'), Memo.fromJson);
    alarms = _decodeList<AlarmItem>(p.getString('v2_alarms'), AlarmItem.fromJson);
    nextId = p.getInt('v2_nextId') ?? 1;

    holidaySync = p.getBool('holidaySync') ?? true;
    icalUrl = p.getString('icalUrl') ?? '';
    lastSync = p.getString('lastSync') ?? '';
    holidayEvs = _decodeList<Ev>(p.getString('ev_holiday'), Ev.fromJson);
    googleEvs = _decodeList<Ev>(p.getString('ev_google'), Ev.fromJson);
    _rebuildEv();
    notifyListeners();
  }

  Future<void> save({bool resched = true}) async {
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('v2_days', jsonEncode(days));
    await p.setString('v2_attend', jsonEncode(attend));
    await p.setStringList('v2_attendTypes', attendTypes);
    await p.setStringList('v2_pattern', pattern);
    await p.setString('v2_memos', jsonEncode(memos.map((e) => e.toJson()).toList()));
    await p.setString('v2_alarms', jsonEncode(alarms.map((e) => e.toJson()).toList()));
    await p.setInt('v2_nextId', nextId);
    await p.setBool('holidaySync', holidaySync);
    await p.setString('icalUrl', icalUrl);
    if (resched) await rescheduleAll();
  }

  // ── 근무 / 근태 ──

  void setShift(DateTime d, String? id) {
    if (id == null) {
      days.remove(dayKey(d));
    } else {
      days[dayKey(d)] = id;
    }
    save();
  }

  void setAttend(DateTime d, String? name) {
    if (name == null) {
      attend.remove(dayKey(d));
    } else {
      attend[dayKey(d)] = name;
    }
    save(resched: false);
  }

  /// 패턴 일괄 적용.
  /// 쉬는 날(토/일/공휴일 중 고른 것)은 '휴'로 채우고, 패턴 순서는 쉬는 날을 건너뛰어
  /// 나머지 날(평일)에만 이어서 적용된다.
  void applyPattern(DateTime start, int count, List<String> seq,
      {bool restSat = false, bool restSun = false, bool restHol = false}) {
    final useRest = restSat || restSun || restHol;
    if (seq.isNotEmpty) pattern = seq;
    int idx = 0;
    for (int i = 0; i < count; i++) {
      final d = DateTime(start.year, start.month, start.day + i);
      if (useRest && isRestDay(d, sat: restSat, sun: restSun, hol: restHol)) {
        days[dayKey(d)] = 'OFF';
      } else if (seq.isNotEmpty) {
        days[dayKey(d)] = seq[idx % seq.length];
        idx++;
      }
    }
    save();
  }

  // ── 메모 ──

  int newId() => nextId++;

  void upsertMemo(Memo m) {
    final i = memos.indexWhere((e) => e.id == m.id);
    if (i >= 0) {
      memos[i] = m;
    } else {
      memos.add(m);
    }
    save();
  }

  void deleteMemo(int id) {
    memos.removeWhere((e) => e.id == id);
    save();
  }

  void toggleDone(int id) {
    final i = memos.indexWhere((e) => e.id == id);
    if (i < 0) return;
    memos[i].done = !memos[i].done;
    save(resched: false);
  }

  // ── 알람 ──

  void upsertAlarm(AlarmItem a) {
    final i = alarms.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      alarms[i] = a;
    } else {
      alarms.add(a);
    }
    save();
  }

  void deleteAlarm(int id) {
    alarms.removeWhere((e) => e.id == id);
    save();
  }

  void setAlarmEnabled(int id, bool on) {
    final i = alarms.indexWhere((e) => e.id == id);
    if (i < 0) return;
    alarms[i].enabled = on;
    save();
  }

  void setAllAlarms(bool on) {
    for (final a in alarms) {
      a.enabled = on;
    }
    save();
  }

  // ── 백업 / 복원 ──

  String exportJson() => jsonEncode({
        'v': 2,
        'days': days,
        'attend': attend,
        'attendTypes': attendTypes,
        'pattern': pattern,
        'memos': memos.map((e) => e.toJson()).toList(),
        'alarms': alarms.map((e) => e.toJson()).toList(),
        'nextId': nextId,
      });

  Future<bool> importJson(String s) async {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      if (m['v'] != 2) return false;
      final newDays = Map<String, String>.from(m['days'] ?? {});
      final newAttend = Map<String, String>.from(m['attend'] ?? {});
      final newTypes = List<String>.from(m['attendTypes'] ?? attendTypes);
      final newPattern = List<String>.from(m['pattern'] ?? []);
      final newMemos = (m['memos'] as List? ?? [])
          .map((e) => Memo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final newAlarms = (m['alarms'] as List? ?? [])
          .map((e) => AlarmItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      days = newDays;
      attend = newAttend;
      attendTypes = newTypes;
      pattern = newPattern;
      memos = newMemos;
      alarms = newAlarms;
      nextId = (m['nextId'] as int?) ?? nextId;
      await save();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── 구글 공휴일 + 내 구글 캘린더 동기화 ──

  Future<void> syncAll() async {
    if (syncing) return;
    syncing = true;
    syncMsg = '동기화 중...';
    notifyListeners();

    final p = await SharedPreferences.getInstance();
    final msgs = <String>[];
    final now = DateTime.now();
    final from = DateTime(now.year - 1, 1, 1);
    final to = DateTime(now.year + 3, 1, 1); // 올해 + 2년 뒤까지

    if (holidaySync) {
      try {
        holidayEvs = await fetchIcs(kHolidayUrl, from, to, holidayCal: true);
        await p.setString('ev_holiday', jsonEncode(holidayEvs.map((e) => e.toJson()).toList()));
        msgs.add('공휴일 ${holidayEvs.length}건');
      } catch (e) {
        msgs.add('공휴일 실패(${_short(e)})');
      }
    } else {
      holidayEvs = [];
      await p.remove('ev_holiday');
    }

    if (icalUrl.trim().isNotEmpty) {
      try {
        googleEvs = await fetchIcs(icalUrl, from, to);
        await p.setString('ev_google', jsonEncode(googleEvs.map((e) => e.toJson()).toList()));
        msgs.add('내 일정 ${googleEvs.length}건');
      } catch (e) {
        msgs.add('내 일정 실패(${_short(e)})');
      }
    } else {
      googleEvs = [];
      await p.remove('ev_google');
    }

    _rebuildEv();
    lastSync = DateFormat('M/d HH:mm').format(now);
    await p.setString('lastSync', lastSync);
    syncing = false;
    syncMsg = msgs.isEmpty ? '가져올 캘린더가 없습니다' : msgs.join(' · ');
    notifyListeners();
  }

  String _short(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 40 ? '${s.substring(0, 40)}…' : s;
  }

  // ── 알람 등록 ──

  /// 근무별 알람 + 메모 알림을 모두 다시 등록한다. 앱을 열 때마다 자동 실행.
  Future<void> rescheduleAll() async {
    try {
      await _rescheduleImpl();
    } catch (e) {
      debugPrint('알람 등록 실패: $e');
    }
  }

  Future<void> _rescheduleImpl() async {
    if (kIsWeb) return; // PC 크롬 미리보기에서는 알람 기능 없음
    await notif.cancelAll();
    final now = DateTime.now();
    final pend = <_Pending>[];

    // 1) 근무별 알람: 앞으로 60일
    for (final na in planShiftAlarms(now, 60)) {
      final a = na.alarm;
      final shift = shiftById(a.shiftId);
      if (shift == null) continue;
      final String day = a.dayOffset < 0 ? '내일' : (a.dayOffset > 0 ? '어제' : '오늘');
      final body = a.label.isNotEmpty ? a.label : '$day ${shift.label} 근무 · ${fmtHM(a.minutes)}';
      pend.add(_Pending(na.when, '${shift.label} 근무 알람', body, true,
          tone: a.tone, sound: a.sound, vibrate: a.vibrate));
    }

    // 2) 메모 알림: 앞으로 120일
    final limit = now.add(const Duration(days: 120));
    for (final m in memos) {
      if (m.alarmBefore < 0 || m.done) continue;
      final sd = parseKey(m.start);
      final base = m.allDay ? 9 * 60 : m.startMin;
      final when = DateTime(sd.year, sd.month, sd.day, base ~/ 60, base % 60)
          .subtract(Duration(minutes: m.alarmBefore));
      if (when.isBefore(now) || when.isAfter(limit)) continue;
      pend.add(_Pending(when, '메모 알림', m.title.isEmpty ? '(제목 없음)' : m.title, false));
    }

    // 안드로이드 예약 한도(약 500개)를 넘지 않도록 가까운 순서로 450개까지
    pend.sort((a, b) => a.when.compareTo(b.when));
    int id = 1;
    for (final p in pend.take(450)) {
      await _scheduleOne(id++, p);
    }
  }

  /// 알람 채널: 소리/진동 조합마다 채널이 따로 필요하다 (안드로이드 규칙)
  AndroidNotificationDetails _alarmDetails(String tone, bool sound, bool vibrate) {
    final toneName = kTones[tone] ?? '벨';
    AndroidNotificationSound? snd;
    if (sound) {
      snd = tone == 'sys'
          ? const UriAndroidNotificationSound('content://settings/system/alarm_alert')
          : RawResourceAndroidNotificationSound('alarm_$tone');
    }
    final chId = 'alarm2_${sound ? tone : 'mute'}_${vibrate ? 'v' : 'n'}';
    final chName = '근무 알람 · ${sound ? toneName : '무음'}${vibrate ? ' · 진동' : ''}';
    return AndroidNotificationDetails(
      chId,
      chName,
      channelDescription: '근무 시간 알람',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
      playSound: sound,
      sound: snd,
      enableVibration: vibrate,
      vibrationPattern:
          vibrate ? Int64List.fromList(<int>[0, 800, 500, 800, 500, 800, 500, 800]) : null,
      additionalFlags: sound ? Int32List.fromList(<int>[4]) : null, // 4 = 끌 때까지 소리 반복
      timeoutAfter: 180000, // 3분 뒤 자동으로 사라짐
    );
  }

  NotificationDetails _detailsFor(_Pending p) {
    if (p.alarmType) {
      return NotificationDetails(android: _alarmDetails(p.tone, p.sound, p.vibrate));
    }
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'memo_alarm',
        '메모 알림',
        channelDescription: '메모 알림',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
  }

  /// 반환: 'exact' (정확한 시각) / 'inexact' (정확한 알람 권한 없음, 몇 분 늦을 수 있음) / 'fail'
  Future<String> _scheduleOne(int id, _Pending p) async {
    final when = tz.TZDateTime.from(p.when, tz.local);
    final details = _detailsFor(p);
    Future<void> schedule(AndroidScheduleMode mode) =>
        notif.zonedSchedule(id, p.title, p.body, when, details, androidScheduleMode: mode);
    try {
      await schedule(AndroidScheduleMode.exactAllowWhileIdle);
      return 'exact';
    } catch (_) {
      // 정확한 알람 권한이 없으면 덜 정확한 방식으로라도 등록
      try {
        await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
        return 'inexact';
      } catch (e) {
        debugPrint('알람 예약 실패: $e');
        return 'fail';
      }
    }
  }

  /// 알람 테스트. now=true 면 바로 울리고, 아니면 10초 뒤에 울린다.
  Future<String> testAlarm({
    required bool now,
    String tone = 'bell',
    bool sound = true,
    bool vibrate = true,
  }) async {
    if (kIsWeb) return 'PC 미리보기에서는 알람을 테스트할 수 없어요';
    try {
      final p = _Pending(
        DateTime.now().add(const Duration(seconds: 10)),
        '테스트 알람',
        '이 알람이 들리면 정상입니다',
        true,
        tone: tone,
        sound: sound,
        vibrate: vibrate,
      );
      if (now) {
        await notif.show(9001, p.title, p.body, _detailsFor(p));
        return '알림을 보냈어요. 소리가 안 나면 아래 점검 항목을 확인하세요';
      }
      final r = await _scheduleOne(9002, p);
      if (r == 'exact') return '10초 뒤에 울려요. 화면을 꺼 두고 기다려 보세요';
      if (r == 'inexact') return '예약은 됐지만 "정확한 알람" 권한이 없어 시간이 늦을 수 있어요';
      return '알람 예약에 실패했어요. 알림 권한을 확인하세요';
    } catch (e) {
      return '테스트 실패: $e';
    }
  }

  /// 알림 + 정확한 알람 권한 요청 (알람 탭의 "허용하기" 버튼)
  Future<void> requestExact() async {
    if (kIsWeb) return;
    try {
      final a =
          notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
      await a?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  Future<AlarmStatus> alarmStatus() async {
    if (kIsWeb) return AlarmStatus(false, false, 0);
    try {
      final a =
          notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final n = await a?.areNotificationsEnabled() ?? false;
      final e = await a?.canScheduleExactNotifications() ?? false;
      final p = (await notif.pendingNotificationRequests()).length;
      return AlarmStatus(n, e, p);
    } catch (_) {
      return AlarmStatus(false, false, 0);
    }
  }
}

final store = Store();

Future<void> initNotifications() async {
  if (kIsWeb) return; // PC 크롬 미리보기에서는 알람 기능 없음
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Seoul'));
  await notif.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final a =
      notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  try {
    await a?.deleteNotificationChannel('shift_alarm'); // 예전 버전 채널 정리
  } catch (_) {}
  await a?.requestNotificationsPermission();
  // 정확한 알람 권한 설정창은 처음 한 번만 자동으로 띄운다 (이후에는 알람 탭에서 직접)
  try {
    final p = await SharedPreferences.getInstance();
    final ok = await a?.canScheduleExactNotifications() ?? true;
    if (!ok && !(p.getBool('askedExact') ?? false)) {
      await p.setBool('askedExact', true);
      await a?.requestExactAlarmsPermission();
    }
  } catch (_) {}
}
