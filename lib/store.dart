import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ical.dart';
import 'lunar.dart';
import 'models.dart';

final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

class _Pending {
  final DateTime when;
  final String title;
  final String body;
  final bool alarmType;
  _Pending(this.when, this.title, this.body, this.alarmType);
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
    return builtinHolidays(d.year)[k] ?? lunarHolidays(d.year)[k];
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

  /// 앞으로 가장 먼저 울릴 근무 알람
  NextAlarm? nextAlarm() {
    final now = DateTime.now();
    NextAlarm? best;
    for (int i = 0; i < 60; i++) {
      final d = DateTime(now.year, now.month, now.day + i);
      final sid = days[dayKey(d)];
      if (sid == null) continue;
      for (final a in alarms) {
        if (!a.enabled || a.shiftId != sid) continue;
        final w = DateTime(d.year, d.month, d.day, a.minutes ~/ 60, a.minutes % 60);
        if (w.isBefore(now)) continue;
        if (best == null || w.isBefore(best.when)) best = NextAlarm(w, a);
      }
    }
    return best;
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

  void applyPattern(DateTime start, int count, List<String> seq) {
    if (seq.isEmpty) return;
    pattern = seq;
    for (int i = 0; i < count; i++) {
      final d = DateTime(start.year, start.month, start.day + i);
      days[dayKey(d)] = seq[i % seq.length];
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
    for (int i = 0; i < 60; i++) {
      final d = DateTime(now.year, now.month, now.day + i);
      final sid = days[dayKey(d)];
      final shift = shiftById(sid);
      if (shift == null) continue;
      for (final a in alarms) {
        if (!a.enabled || a.shiftId != sid) continue;
        final when = DateTime(d.year, d.month, d.day, a.minutes ~/ 60, a.minutes % 60);
        if (when.isBefore(now)) continue;
        pend.add(_Pending(when, '${shift.label} 근무 알람', '${fmtHM(a.minutes)} 알람', true));
      }
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

  Future<void> _scheduleOne(int id, _Pending p) async {
    final when = tz.TZDateTime.from(p.when, tz.local);
    final details = NotificationDetails(
      android: p.alarmType
          ? const AndroidNotificationDetails(
              'shift_alarm',
              '근무 알람',
              channelDescription: '근무 시간 알람',
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.alarm,
              audioAttributesUsage: AudioAttributesUsage.alarm,
              fullScreenIntent: true,
              playSound: true,
              enableVibration: true,
            )
          : const AndroidNotificationDetails(
              'memo_alarm',
              '메모 알림',
              channelDescription: '메모 알림',
              importance: Importance.high,
              priority: Priority.high,
            ),
    );
    Future<void> schedule(AndroidScheduleMode mode) =>
        notif.zonedSchedule(id, p.title, p.body, when, details, androidScheduleMode: mode);
    try {
      await schedule(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // 정확한 알람 권한이 없으면 덜 정확한 방식으로라도 등록
      try {
        await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
      } catch (_) {}
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
  await a?.requestNotificationsPermission();
  await a?.requestExactAlarmsPermission();
}
