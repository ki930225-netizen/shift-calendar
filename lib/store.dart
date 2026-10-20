import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'holidays.dart';
import 'ical.dart';
import 'models.dart';
import 'native.dart';

final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

class _Pending {
  final DateTime when;
  final String title;
  final String body;
  final bool alarmType;
  final String tone;
  final bool sound;
  final bool vibrate;
  final String key; // 같은 알람인지 구분하는 값 (알림 번호의 재료)
  final int id; // 알림 번호 (같은 알람은 항상 같은 번호)
  final bool notice; // 알람 전에 알림창에 띄우는 "N분 뒤 알람" 미리 알림
  final int targetMs; // 미리 알림이 가리키는 실제 알람 시각(밀리초)
  final String? payload;
  _Pending(this.when, this.title, this.body, this.alarmType,
      {this.tone = 'bell',
      this.sound = true,
      this.vibrate = true,
      this.key = '',
      this.id = 0,
      this.notice = false,
      this.targetMs = 0,
      this.payload});
}

/// 알람 채널: 소리/진동 조합마다 채널이 따로 필요하다 (안드로이드 규칙)
AndroidNotificationDetails buildAlarmDetails(String tone0, bool sound, bool vibrate) {
  final tone = tone0 == 'custom' ? 'sys' : tone0; // 예비(일반 알림) 방식에서는 내 음악 파일 대신 폰 기본 알람음
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
    actions: <AndroidNotificationAction>[
      AndroidNotificationAction('snooze5', '5분 후 다시 울림',
          showsUserInterface: false, cancelNotification: true),
      AndroidNotificationAction('snooze10', '10분 후 다시 울림',
          showsUserInterface: false, cancelNotification: true),
      AndroidNotificationAction('stop', '알람 종료',
          showsUserInterface: false, cancelNotification: true),
    ],
  );
}


/// 알람 알림에 붙여 두는 정보 (다시 울림 때 같은 소리·제목으로 다시 예약하기 위함)
String alarmPayload(int id, String tone, bool sound, bool vibrate, String title, String body) =>
    jsonEncode({'id': id, 't': tone, 's': sound, 'v': vibrate, 'ti': title, 'b': body});

/// "N분 후 다시 울림": 지금부터 N분 뒤에 같은 알람을 다시 예약한다.
/// 다시 울림 알림 번호는 0x40000000 이상으로 두어 평소 재등록 때 지워지지 않게 한다.
@pragma('vm:entry-point')
Future<void> snoozeFromPayload(String? payload, int minutes) async {
  if (payload == null) return;
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {}
  try {
    final m = jsonDecode(payload);
    if (m is! Map) return;
    final id = (m['id'] as num?)?.toInt() ?? 0;
    final sid = 0x40000000 + (id & 0xFFFFFF);
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Seoul'));
    final details = NotificationDetails(
      android: buildAlarmDetails(
        (m['t'] as String?) ?? 'bell',
        (m['s'] as bool?) ?? true,
        (m['v'] as bool?) ?? true,
      ),
    );
    final when = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    final plugin = FlutterLocalNotificationsPlugin();
    final title = (m['ti'] as String?) ?? '알람';
    final body = '${(m['b'] as String?) ?? ''} (다시 울림)';
    try {
      await plugin.zonedSchedule(sid, title, body, when, details,
          androidScheduleMode: AndroidScheduleMode.alarmClock, payload: payload);
    } catch (_) {
      await plugin.zonedSchedule(sid, title, body, when, details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle, payload: payload);
    }
  } catch (e) {
    debugPrint('다시 울림 실패: $e');
  }
}

/// 알림 버튼(이번 알람 끄기 / 다시 울림) 처리
void handleNotificationAction(NotificationResponse r) {
  final a = r.actionId;
  if (a == 'skip') {
    skipFromPayload(r.payload);
  } else if (a == 'snooze5') {
    snoozeFromPayload(r.payload, 5);
  } else if (a == 'snooze10') {
    snoozeFromPayload(r.payload, 10);
  }
}

/// "이번 알람 끄기" 처리: 그 회차 알람을 취소하고, 다시 등록되지 않도록 기억해 둔다.
/// (앱이 꺼져 있어도 동작해야 해서 화면과 무관한 최상위 함수로 둔다)
@pragma('vm:entry-point')
Future<void> skipFromPayload(String? payload) async {
  if (payload == null) return;
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {}
  try {
    final i = payload.lastIndexOf('#');
    if (i < 0) return;
    final key = payload.substring(0, i);
    final id = int.tryParse(payload.substring(i + 1));
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final l = p.getStringList('skipped') ?? <String>[];
    if (!l.contains(key)) l.add(key);
    await p.setStringList('skipped', l);
    if (id != null) await FlutterLocalNotificationsPlugin().cancel(id);
  } catch (e) {
    debugPrint('이번 알람 끄기 실패: $e');
  }
}

@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse r) {
  handleNotificationAction(r);
}

class AlarmStatus {
  final bool notifOk;
  final bool exactOk;
  final int pending;
  final bool batteryOk;
  final bool fullOk; // 잠금 화면 위 알람 화면(전체 화면 알림) 허용
  final int nativePending; // 앱이 직접 예약한 근무 알람 수 (-1: 모름)
  AlarmStatus(this.notifOk, this.exactOk, this.pending, this.batteryOk,
      {this.fullOk = true, this.nativePending = -1});
}

/// 같은 입력이면 항상 같은 번호가 나오는 해시 (알림 번호용)
int _fnv(String s) {
  int h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x3FFFFFFF;
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
  bool _loaded = false; // 불러오기에 성공해야만 저장한다 (실패한 빈 데이터로 덮어쓰기 방지)

  Map<String, String> monthMemos = {}; // 'yyyy-MM' -> 월별 메모
  Map<int, String> weekPattern = {}; // 요일(1=월..7=일) -> 근무 id
  String? weekBefore; // 쉬는 날 전날에 넣을 근무 id
  bool weekRestSat = true;
  bool weekRestSun = true;
  bool weekRestHol = true;

  int preNoticeMin = 20; // 알람 몇 분 전에 알림창에 미리 알려줄지 (0 = 끔)
  int rampSec = 20; // 알람 소리가 점점 커지는 시간(초). 0 = 처음부터 큰 소리
  String customSoundName = ''; // "내 음악 파일"로 고른 파일 이름
  Map<String, List<int>> shiftTimes = {}; // 근무 id -> [시작분, 종료분] (통계의 근무시간 계산용)
  String schedNote = ''; // 마지막 알람 등록 결과
  int schedVersion = 0;

  // 폰 캘린더
  bool deviceCal = false;
  List<int> deviceCalSel = [];
  List<Ev> deviceEvs = [];
  String deviceMsg = '';

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

  /// "이번만 끄기"로 건너뛸 회차 ('S|알람id|시각ms'). 데이터 파일에 같이 저장된다.
  Set<String> skippedKeys = <String>{};

  static String alarmKey(NextAlarm na) => 'S|${na.alarm.id}|${na.when.millisecondsSinceEpoch}';

  bool isSkipped(NextAlarm na) => skippedKeys.contains(alarmKey(na));

  /// 앞으로 가장 먼저 울릴 근무 알람 (이번만 끄기 한 회차는 제외)
  NextAlarm? nextAlarm() {
    for (final na in planShiftAlarms(DateTime.now(), 60)) {
      if (!isSkipped(na)) return na;
    }
    return null;
  }

  /// 바로 다음 알람 하나만 끄기 / 되돌리기
  Future<void> skipOnce(NextAlarm na) async {
    skippedKeys.add(alarmKey(na));
    await save();
  }

  Future<void> unskip(String key) async {
    skippedKeys.remove(key);
    await save();
  }

  /// 건너뛴 회차 중 아직 안 지난 것 (알람 탭에 "꺼둔 회차"로 표시)
  List<NextAlarm> skippedUpcoming() =>
      planShiftAlarms(DateTime.now(), 60).where(isSkipped).toList();

  /// 알림창에서 누른 "이번 알람 끄기"를 앱에 반영
  Future<void> pullSkipped() async {
    final l = await nativeTakeSkipped();
    if (l.isEmpty) return;
    skippedKeys.addAll(l);
    await save();
  }

  void _rebuildEv() {
    final m = <String, List<Ev>>{};
    for (final e in [...holidayEvs, ...googleEvs, ...deviceEvs]) {
      m.putIfAbsent(e.date, () => []).add(e);
    }
    evByDay = m;
  }

  // ── 불러오기 / 저장 ──

  // 저장 상태 (설정 화면의 "저장 상태 점검"에 표시)
  String loadSource = '';
  String loadNote = '';
  String saveNote = '';
  DateTime? lastSaveAt;
  String? _dir;

  /// 앱 전용 폴더 안의 파일 (설정저장소와 별개로 한 벌 더 저장해 두는 용도)
  Future<File?> _file(String name) async {
    if (kIsWeb) return null;
    try {
      _dir ??= await filesDirPath();
      final d = _dir;
      if (d == null || d.isEmpty) return null;
      return File('$d/$name');
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _state() => {
        'v': 3,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'days': days,
        'attend': attend,
        'attendTypes': attendTypes,
        'pattern': pattern,
        'memos': memos.map((e) => e.toJson()).toList(),
        'alarms': alarms.map((e) => e.toJson()).toList(),
        'nextId': nextId,
        'monthMemos': monthMemos,
        'week': weekPattern.map((k, v) => MapEntry(k.toString(), v)),
        'weekBefore': weekBefore,
        'weekSat': weekRestSat,
        'weekSun': weekRestSun,
        'weekHol': weekRestHol,
        'deviceCal': deviceCal,
        'deviceCalSel': deviceCalSel,
        'holidaySync': holidaySync,
        'icalUrl': icalUrl,
        'preNotice': preNoticeMin,
        'rampSec': rampSec,
        'customSound': customSoundName,
        'shiftTimes': shiftTimes,
        'skipped': skippedKeys.toList(),
      };

  /// 저장된 상태를 통째로 읽어 반영. 하나라도 실패하면 아무것도 바꾸지 않고 false.
  bool _applyState(Map<String, dynamic> m) {
    try {
      final nDays = Map<String, String>.from((m['days'] as Map?) ?? {});
      final nAttend = Map<String, String>.from((m['attend'] as Map?) ?? {});
      final nTypes = List<String>.from((m['attendTypes'] as List?) ?? attendTypes);
      final nPattern = List<String>.from((m['pattern'] as List?) ?? []);
      final nMemos = ((m['memos'] as List?) ?? [])
          .map((e) => Memo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final nAlarms = ((m['alarms'] as List?) ?? [])
          .map((e) => AlarmItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final nMonth = Map<String, String>.from((m['monthMemos'] as Map?) ?? {});
      final nWeek = <int, String>{};
      Map<String, dynamic>.from((m['week'] as Map?) ?? {}).forEach((k, v) {
        final n = int.tryParse(k);
        if (n != null) nWeek[n] = '$v';
      });
      final nSel = <int>[];
      for (final e in ((m['deviceCalSel'] as List?) ?? [])) {
        if (e is num) nSel.add(e.toInt());
      }
      final nSkip = <String>{};
      for (final e in ((m['skipped'] as List?) ?? [])) {
        nSkip.add('$e');
      }
      days = nDays;
      skippedKeys = nSkip;
      attend = nAttend;
      attendTypes = nTypes;
      pattern = nPattern;
      memos = nMemos;
      alarms = nAlarms;
      nextId = (m['nextId'] as num?)?.toInt() ?? 1;
      monthMemos = nMonth;
      weekPattern = nWeek;
      weekBefore = m['weekBefore'] as String?;
      weekRestSat = (m['weekSat'] as bool?) ?? true;
      weekRestSun = (m['weekSun'] as bool?) ?? true;
      weekRestHol = (m['weekHol'] as bool?) ?? true;
      deviceCal = (m['deviceCal'] as bool?) ?? false;
      deviceCalSel = nSel;
      holidaySync = (m['holidaySync'] as bool?) ?? true;
      icalUrl = (m['icalUrl'] as String?) ?? '';
      preNoticeMin = (m['preNotice'] as num?)?.toInt() ?? 20;
      rampSec = (m['rampSec'] as num?)?.toInt() ?? 20;
      customSoundName = (m['customSound'] as String?) ?? '';
      final st = <String, List<int>>{};
      ((m['shiftTimes'] as Map?) ?? {}).forEach((k, v) {
        if (v is List && v.length >= 2) st['$k'] = [(v[0] as num).toInt(), (v[1] as num).toInt()];
      });
      shiftTimes = st;
      return true;
    } catch (e) {
      loadNote = '$loadNote 데이터 해석 실패($e)';
      return false;
    }
  }

  Map<String, dynamic>? _parseJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  int _savedAt(Map<String, dynamic> m) => (m['savedAt'] as num?)?.toInt() ?? 0;

  /// 예전 버전(v2.0~2.2)이 여러 칸으로 나눠 저장해 둔 데이터를 읽는다 (처음 한 번 옮겨 담기용)
  bool _loadLegacy(SharedPreferences p) {
    days = _decodeStrMap(p.getString('v2_days'));
    attend = _decodeStrMap(p.getString('v2_attend'));
    attendTypes = p.getStringList('v2_attendTypes') ?? attendTypes;
    pattern = p.getStringList('v2_pattern') ?? [];
    memos = _decodeList<Memo>(p.getString('v2_memos'), Memo.fromJson);
    alarms = _decodeList<AlarmItem>(p.getString('v2_alarms'), AlarmItem.fromJson);
    nextId = p.getInt('v2_nextId') ?? 1;
    monthMemos = _decodeStrMap(p.getString('v2_monthMemos'));
    final wk = _decodeStrMap(p.getString('v2_week'));
    weekPattern = {};
    wk.forEach((k, v) {
      final n = int.tryParse(k);
      if (n != null) weekPattern[n] = v;
    });
    weekBefore = p.getString('v2_weekBefore');
    weekRestSat = p.getBool('v2_weekSat') ?? true;
    weekRestSun = p.getBool('v2_weekSun') ?? true;
    weekRestHol = p.getBool('v2_weekHol') ?? true;
    deviceCal = p.getBool('deviceCal') ?? false;
    deviceCalSel =
        (p.getStringList('deviceCalSel') ?? <String>[]).map((e) => int.tryParse(e) ?? -1).toList();
    deviceCalSel.removeWhere((e) => e < 0);
    holidaySync = p.getBool('holidaySync') ?? true;
    icalUrl = p.getString('icalUrl') ?? '';
    return days.isNotEmpty || alarms.isNotEmpty || memos.isNotEmpty;
  }

  /// 설정저장소와 파일, 두 곳에서 읽어 더 최근에 저장된 쪽을 쓴다
  Future<void> load() async {
    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (e) {
      loadNote = '설정저장소 열기 실패($e)';
    }
    final cands = <MapEntry<String, Map<String, dynamic>>>[];
    if (p != null) {
      final m = _parseJson(p.getString('v3_state'));
      if (m != null) cands.add(MapEntry('설정저장소', m));
    }
    try {
      final f = await _file('shift_data.json');
      if (f != null && await f.exists()) {
        final m = _parseJson(await f.readAsString());
        if (m != null) cands.add(MapEntry('파일', m));
      }
    } catch (e) {
      loadNote = '$loadNote 파일 읽기 실패($e)';
    }
    cands.sort((a, b) => _savedAt(b.value).compareTo(_savedAt(a.value)));
    bool done = false;
    for (final c in cands) {
      if (_applyState(c.value)) {
        loadSource = c.key;
        done = true;
        break;
      }
    }
    if (!done && p != null) {
      final had = _loadLegacy(p);
      loadSource = had ? '이전 버전 저장소(옮겨 담음)' : '저장된 데이터 없음(처음 실행)';
    }
    if (p != null) {
      lastSync = p.getString('lastSync') ?? '';
      holidayEvs = _decodeList<Ev>(p.getString('ev_holiday'), Ev.fromJson);
      googleEvs = _decodeList<Ev>(p.getString('ev_google'), Ev.fromJson);
    }
    _rebuildEv();
    // 둘 다 열 수 없으면 저장도 못 하므로 기존 데이터를 건드리지 않게 막아 둔다
    _loaded = p != null || (await _file('shift_data.json')) != null;
    notifyListeners();
  }

  bool _saving = false;
  bool _saveAgain = false;

  /// 저장은 한 번에 하나씩 (연달아 눌러도 파일이 꼬이지 않게)
  Future<void> _persist() async {
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    try {
      do {
        _saveAgain = false;
        await _persistOnce();
      } while (_saveAgain);
    } finally {
      _saving = false;
    }
  }

  Future<void> _persistOnce() async {
    final js = jsonEncode(_state());
    bool a = false;
    bool b = false;
    final err = StringBuffer();
    try {
      final p = await SharedPreferences.getInstance();
      a = await p.setString('v3_state', js);
    } catch (e) {
      err.write('설정저장소 $e ');
    }
    try {
      final f = await _file('shift_data.json');
      if (f != null) {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(js, flush: true);
        await tmp.rename(f.path);
        b = true;
      }
    } catch (e) {
      err.write('파일 $e');
    }
    lastSaveAt = DateTime.now();
    saveNote = '설정저장소 ${a ? '성공' : '실패'} · 파일 ${b ? '성공' : '실패'}'
        '${err.isEmpty ? '' : ' ($err)'}';
  }

  Future<void> save({bool resched = true}) async {
    notifyListeners();
    if (!_loaded) return; // 불러오기에 실패한 상태면 기존 저장 데이터를 건드리지 않는다
    await _persist();
    if (resched) await rescheduleAll();
  }

  /// 저장소가 실제로 쓰고 읽히는지 점검 (설정 화면의 "저장 테스트")
  Future<String> storageSelfTest() async {
    final out = <String>[];
    final t = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('selftest', t);
      await p.reload();
      out.add('설정저장소: ${p.getString('selftest') == t ? '정상' : '쓴 값을 못 읽음'}');
    } catch (e) {
      out.add('설정저장소 오류: $e');
    }
    try {
      final f = await _file('selftest.txt');
      if (f == null) {
        out.add('파일: 폴더를 찾지 못함');
      } else {
        await f.writeAsString(t, flush: true);
        out.add('파일: ${(await f.readAsString()) == t ? '정상' : '쓴 값을 못 읽음'}');
      }
    } catch (e) {
      out.add('파일 오류: $e');
    }
    return out.join('\n');
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

  /// 주별 패턴에서 그 날짜에 들어갈 근무 (없으면 null = 건드리지 않음)
  /// 우선순위: 쉬는 날 → '휴' / 쉬는 날 전날 → beforeRest / 그 외 → 요일에 정한 근무
  String? weekShiftFor(DateTime d, Map<int, String> week,
      {bool restSat = false, bool restSun = false, bool restHol = false, String? beforeRest}) {
    final anyRest = restSat || restSun || restHol;
    if (anyRest && isRestDay(d, sat: restSat, sun: restSun, hol: restHol)) return 'OFF';
    final next = DateTime(d.year, d.month, d.day + 1);
    if (anyRest &&
        beforeRest != null &&
        isRestDay(next, sat: restSat, sun: restSun, hol: restHol)) {
      return beforeRest;
    }
    return week[d.weekday];
  }

  /// 주별(요일별) 패턴 적용. 비워 둔 요일은 건드리지 않는다.
  void applyWeekPattern(DateTime start, int count, Map<int, String> week,
      {bool restSat = false, bool restSun = false, bool restHol = false, String? beforeRest}) {
    weekPattern = Map<int, String>.of(week);
    weekBefore = beforeRest;
    weekRestSat = restSat;
    weekRestSun = restSun;
    weekRestHol = restHol;
    for (int i = 0; i < count; i++) {
      final d = DateTime(start.year, start.month, start.day + i);
      final sid = weekShiftFor(d, week,
          restSat: restSat, restSun: restSun, restHol: restHol, beforeRest: beforeRest);
      if (sid != null) days[dayKey(d)] = sid;
    }
    save();
  }

  // ── 월별 메모 ──

  String monthKey(DateTime d) => '${d.year}-${two(d.month)}';

  String monthMemoOf(DateTime d) => monthMemos[monthKey(d)] ?? '';

  void setMonthMemo(DateTime d, String text) {
    final k = monthKey(d);
    final t = text.trim();
    if (t.isEmpty) {
      monthMemos.remove(k);
    } else {
      monthMemos[k] = t;
    }
    save(resched: false);
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
        'monthMemos': monthMemos,
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
      monthMemos = _decodeStrMap(jsonEncode(m['monthMemos'] ?? {}));
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

  // ── 폰 캘린더 직접 연동 ──

  /// 휴일 전용 캘린더(삼성 휴일 등)는 우리 앱이 이미 공휴일을 표시하므로 기본 선택에서 뺀다
  List<int> defaultCalSel(List<Map<String, dynamic>> cals) {
    final out = <int>[];
    for (final c in cals) {
      final n = '${c['name']}'.toLowerCase();
      if (n.contains('holiday') || n.contains('휴일')) continue;
      final id = c['id'];
      if (id is num) out.add(id.toInt());
    }
    return out;
  }

  /// 권한을 요청하고 연동을 켠다. 결과 안내 문구를 돌려준다.
  Future<String> enableDeviceCal() async {
    final ok = await requestCalendarPermission();
    if (!ok) {
      deviceCal = false;
      await save(resched: false);
      return '캘린더 권한이 필요해요. 권한 창에서 "허용"을 눌러주세요';
    }
    deviceCal = true;
    if (deviceCalSel.isEmpty) {
      deviceCalSel = defaultCalSel(await deviceCalendars());
    }
    await save(resched: false);
    await syncDevice();
    return deviceMsg;
  }

  Future<void> disableDeviceCal() async {
    deviceCal = false;
    deviceEvs = [];
    deviceMsg = '';
    _rebuildEv();
    await save(resched: false);
  }

  /// 폰에 들어 있는 캘린더 일정을 읽어온다 (구글/삼성 캘린더에 등록된 일정이 그대로 보인다)
  Future<void> syncDevice() async {
    if (kIsWeb || !deviceCal) return;
    try {
      if (!await hasCalendarPermission()) {
        deviceMsg = '캘린더 권한이 없어요 (설정에서 다시 켜 주세요)';
        notifyListeners();
        return;
      }
      if (deviceCalSel.isEmpty) {
        deviceMsg = '연동할 캘린더를 선택하세요';
        deviceEvs = [];
        _rebuildEv();
        notifyListeners();
        return;
      }
      final now = DateTime.now();
      final from = DateTime(now.year - 1, 1, 1);
      final to = DateTime(now.year + 3, 1, 1);
      final rows = await deviceEvents(from.millisecondsSinceEpoch, to.millisecondsSinceEpoch, deviceCalSel);
      final out = <Ev>[];
      final seen = <String>{};
      void add(Ev e) {
        if (seen.add('${e.date}|${e.title}|${e.time}')) out.add(e);
      }

      for (final r in rows) {
        final raw = '${r['title'] ?? ''}'.trim();
        final title = raw.isEmpty ? '(제목 없음)' : raw;
        final b = (r['begin'] as num).toInt();
        final e = (r['end'] as num).toInt();
        if (r['allDay'] == true) {
          final bs = DateTime.fromMillisecondsSinceEpoch(b, isUtc: true);
          final es = DateTime.fromMillisecondsSinceEpoch(e, isUtc: true);
          final s0 = DateTime(bs.year, bs.month, bs.day);
          final e0 = DateTime(es.year, es.month, es.day);
          int span = e0.difference(s0).inDays;
          if (span < 1) span = 1;
          if (span > 31) span = 31;
          for (int k = 0; k < span; k++) {
            add(Ev(dayKey(DateTime(s0.year, s0.month, s0.day + k)), title));
          }
        } else {
          final l = DateTime.fromMillisecondsSinceEpoch(b);
          add(Ev(dayKey(l), title, time: '${two(l.hour)}:${two(l.minute)}'));
        }
      }
      deviceEvs = out;
      deviceMsg = '폰 일정 ${out.length}건';
      _rebuildEv();
      notifyListeners();
    } catch (e) {
      deviceMsg = '폰 일정 읽기 실패(${_short(e)})';
      notifyListeners();
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

  // ── 근무 통계 ──

  /// 근무 하나의 근무시간(분). 시간이 설정돼 있지 않으면 null. 종료가 시작보다 이르면 다음날로 계산.
  int? shiftMinutes(String id) {
    final t = shiftTimes[id];
    if (t == null) return null;
    var d = t[1] - t[0];
    if (d <= 0) d += 1440;
    return d;
  }

  /// 한 달 통계: 근무별 일수, 총 근무시간(분), 근태 일수
  ({Map<String, int> counts, int workMinutes, int nightDays, Map<String, int> attendCounts, int emptyDays})
      monthStats(DateTime month) {
    final counts = <String, int>{};
    final att = <String, int>{};
    int mins = 0, night = 0, empty = 0;
    final n = DateUtils.getDaysInMonth(month.year, month.month);
    for (int i = 1; i <= n; i++) {
      final d = DateTime(month.year, month.month, i);
      final sid = days[dayKey(d)];
      if (sid == null) {
        empty++;
      } else {
        counts[sid] = (counts[sid] ?? 0) + 1;
        mins += shiftMinutes(sid) ?? 0;
        final t = shiftTimes[sid];
        if (t != null && (t[1] <= t[0] || t[0] >= 20 * 60 || t[0] < 5 * 60)) night++;
      }
      final a = attend[dayKey(d)];
      if (a != null) att[a] = (att[a] ?? 0) + 1;
    }
    return (counts: counts, workMinutes: mins, nightDays: night, attendCounts: att, emptyDays: empty);
  }

  // ── 알람 등록 ──

  String lastSchedError = '';
  DateTime? _lastResched;
  bool _rescheduling = false;
  bool _reschedAgain = false;

  /// 근무별 알람 + 메모 알림을 다시 등록한다. 앱을 열 때와 설정을 바꿀 때마다 자동 실행.
  /// (동시에 두 번 돌지 않도록 한 번에 하나씩만 처리한다)
  DateTime? _reschedStart;
  String reschedError = '';

  Future<void> rescheduleAll() async {
    // 이전 등록이 1분 넘게 끝나지 않으면 멈춘 것으로 보고 새로 시작한다
    if (_rescheduling &&
        _reschedStart != null &&
        DateTime.now().difference(_reschedStart!) > const Duration(seconds: 60)) {
      _rescheduling = false;
    }
    if (_rescheduling) {
      _reschedAgain = true;
      return;
    }
    _rescheduling = true;
    _reschedStart = DateTime.now();
    try {
      do {
        _reschedAgain = false;
        try {
          await _rescheduleImpl().timeout(const Duration(seconds: 45));
          _lastResched = DateTime.now();
          reschedError = '';
        } catch (e) {
          debugPrint('알람 등록 실패: $e');
          final es = e.toString();
          reschedError = '${DateFormat('HH:mm:ss').format(DateTime.now())} '
              '${es.length > 400 ? es.substring(0, 400) : es}';
          schedVersion++;
          notifyListeners();
        }
      } while (_reschedAgain);
    } finally {
      _rescheduling = false;
    }
  }

  /// 근무 알람 계산 결과 요약 (알람 탭에 표시: 왜 0개인지 바로 보이게)
  String planSummary() {
    final enabled = alarms.where((a) => a.enabled).toList();
    final plan = planShiftAlarms(DateTime.now(), 60);
    final shiftDays = days.length;
    final sb = StringBuffer('알람 ${alarms.length}개(켜짐 ${enabled.length}) · 근무 입력된 날 $shiftDays일 · '
        '60일 안에 울릴 근무 알람 ${plan.length}회');
    if (plan.isEmpty && enabled.isNotEmpty) {
      final now = DateTime.now();
      final upcoming = <String>{};
      for (int i = 0; i <= 60; i++) {
        final sid = days[dayKey(DateTime(now.year, now.month, now.day + i))];
        if (sid != null) upcoming.add(sid);
      }
      sb.write(upcoming.isEmpty
          ? '\n→ 오늘부터 60일 안에 입력된 근무가 없어요. 달력에서 근무를 먼저 입력하세요'
          : '\n→ 앞으로 입력된 근무(${upcoming.map((e) => shiftById(e)?.label ?? e).join(",")})와 '
              '알람의 근무(${enabled.map((a) => shiftById(a.shiftId)?.label ?? a.shiftId).toSet().join(",")})가 달라요');
    }
    return sb.toString();
  }

  /// 앱으로 돌아올 때: 10분 안에 이미 등록했다면 건너뛴다
  Future<void> rescheduleIfStale() async {
    final l = _lastResched;
    if (l != null && DateTime.now().difference(l) < const Duration(minutes: 10)) return;
    await rescheduleAll();
  }

  /// 마지막 등록 때 생긴 문제들 (화면에 그대로 보여 준다)
  String schedWarn = '';

  Future<void> _rescheduleImpl() async {
    if (kIsWeb) return; // PC 크롬 미리보기에서는 알람 기능 없음
    final errs = <String>[];
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      errs.add('설정 읽기: $e');
    }
    // 예전 방식(번호 1,2,3...)으로 등록된 알림은 한 번만 전부 지운다
    if (prefs != null && !(prefs.getBool('sched_v3') ?? false)) {
      try {
        await notif.cancelAll();
      } catch (e) {
        errs.add('예전 알림 정리: $e');
      }
      try {
        await prefs.setBool('sched_v3', true);
      } catch (_) {}
    }
    try {
      await prefs?.reload(); // "이번 알람 끄기"가 다른 곳(백그라운드)에서 저장한 값을 읽기 위해
    } catch (_) {}
    final now = DateTime.now();
    final used = <int>{};
    int idFor(String key) {
      var id = _fnv(key);
      while (used.contains(id) || id == 9001 || id == 9002) {
        id = (id + 1) & 0x3FFFFFFF;
      }
      used.add(id);
      return id;
    }

    // "이번 알람 끄기"로 건너뛰기로 한 회차 (지난 것은 정리)
    final skipped = <String>{};
    try {
      skipped.addAll(prefs?.getStringList('skipped') ?? const <String>[]);
    } catch (e) {
      errs.add('건너뛰기 목록: $e');
    }
    skipped.addAll(await nativeTakeSkipped());
    skipped.addAll(skippedKeys);
    skipped.removeWhere((k) {
      final parts = k.split('|');
      final ms = parts.length >= 3 ? int.tryParse(parts[2]) : null;
      return ms == null || ms < now.millisecondsSinceEpoch - 86400000;
    });
    if (skipped.length != skippedKeys.length || !skipped.containsAll(skippedKeys)) {
      skippedKeys = {...skipped};
      try {
        await _persist(); // 다시 등록과 꼬이지 않도록 저장만 (save()는 재등록을 부름)
      } catch (_) {}
    }
    try {
      await prefs?.setStringList('skipped', skipped.toList());
    } catch (e) {
      errs.add('건너뛰기 저장: $e');
    }

    // 1) 근무별 알람: 앞으로 60일 (+ 알람 전 미리 알림)
    final alarmPend = <_Pending>[];
    final noticePend = <_Pending>[];
    final nativeList = <Map<String, dynamic>>[];
    for (final na in planShiftAlarms(now, 60)) {
      final a = na.alarm;
      final shift = shiftById(a.shiftId);
      if (shift == null) continue;
      final key = 'S|${a.id}|${na.when.millisecondsSinceEpoch}';
      if (skipped.contains(key)) continue;
      final String day = a.dayOffset < 0 ? '내일' : (a.dayOffset > 0 ? '어제' : '오늘');
      final body = a.label.isNotEmpty ? a.label : '$day ${shift.label} 근무 · ${fmtHM(a.minutes)}';
      final aid = idFor(key);
      final atitle = '${shift.label} 근무 알람';
      alarmPend.add(_Pending(na.when, atitle, body, true,
          tone: a.tone,
          sound: a.sound,
          vibrate: a.vibrate,
          key: key,
          id: aid,
          payload: alarmPayload(aid, a.tone, a.sound, a.vibrate, atitle, body)));
      int noticeAt = 0;
      final nTitle = '$preNoticeMin분 뒤 알람 · ${shift.label} 근무';
      final nBody = '${fmtHM(a.minutes)}에 알람이 울려요. 이번만 끄려면 아래 버튼을 누르세요';
      if (preNoticeMin > 0) {
        final nw = na.when.subtract(Duration(minutes: preNoticeMin));
        if (nw.isAfter(now)) {
          noticeAt = nw.millisecondsSinceEpoch;
          final nkey = 'P|$key';
          noticePend.add(_Pending(
            nw,
            nTitle,
            nBody,
            false,
            key: nkey,
            id: idFor(nkey),
            notice: true,
            targetMs: na.when.millisecondsSinceEpoch,
            payload: '$key#$aid',
          ));
        }
      }
      nativeList.add({
        'id': aid,
        'at': na.when.millisecondsSinceEpoch,
        'title': atitle,
        'body': body,
        'tone': a.tone,
        'sound': a.sound,
        'vibrate': a.vibrate,
        'key': key,
        'noticeAt': noticeAt,
        'noticeTitle': nTitle,
        'noticeBody': nBody,
        'ramp': rampSec,
      });
    }

    // 근무 알람은 앱이 직접 울리는 "알람 시계" 방식으로 등록 (진동/무음 모드에서도 소리, 잠금 화면에 알람 화면)
    // 안드로이드 예약 한도(앱당 약 500개)를 넘지 않도록 가까운 150회까지
    nativeList.sort((x, y) => (x['at'] as int).compareTo(y['at'] as int));
    bool nativeOk = false;
    String nativeNote = '';
    try {
      final r = await nativeSetAlarms(nativeList.take(150).toList())
          .timeout(const Duration(seconds: 20));
      nativeOk = true;
      nativeNote = '근무 알람 ${r['total'] ?? '?'}개 (알람시계 ${r['clock'] ?? 0} · 부정확 ${r['inexact'] ?? 0} · '
          '실패 ${r['fail'] ?? 0})';
      final le = r['error'];
      if (le is String && le.isNotEmpty) errs.add('알람 예약 경고: $le');
    } catch (e) {
      errs.add('알람 화면 방식 실패 → 일반 알림으로 대신 등록: $e');
    }

    // 2) 메모 알림 (+ 위가 실패했을 때만 근무 알람도 일반 알림으로)
    final pend = <_Pending>[];
    if (!nativeOk) {
      pend.addAll(alarmPend);
      pend.addAll(noticePend);
    }
    final limit = now.add(const Duration(days: 120));
    int nMemo = 0;
    for (final m in memos) {
      if (m.alarmBefore < 0 || m.done) continue;
      final sd = parseKey(m.start);
      final base = m.allDay ? 9 * 60 : m.startMin;
      final when = DateTime(sd.year, sd.month, sd.day, base ~/ 60, base % 60)
          .subtract(Duration(minutes: m.alarmBefore));
      if (when.isBefore(now) || when.isAfter(limit)) continue;
      final key = 'M|${m.id}|${when.millisecondsSinceEpoch}';
      pend.add(_Pending(when, '메모 알림', m.title.isEmpty ? '(제목 없음)' : m.title, false,
          key: key, id: idFor(key)));
      nMemo++;
    }

    pend.sort((a, b) => a.when.compareTo(b.when));
    final take = pend.take(nativeOk ? 150 : 450).toList();
    final keep = <int>{for (final p in take) p.id};

    int nClock = 0, nExact = 0, nInexact = 0, nFail = 0, nAlarm = 0;
    lastSchedError = '';
    for (final p in take) {
      final r = await _scheduleOne(p.id, p);
      if (r == 'clock') nClock++;
      if (r == 'exact') nExact++;
      if (r == 'inexact') nInexact++;
      if (r == 'fail') nFail++;
      if (p.alarmType) nAlarm++;
    }

    // 더 이상 필요 없는(지워졌거나 바뀐) 알림만 취소
    try {
      final pending = await notif.pendingNotificationRequests();
      for (final r in pending) {
        if (r.id == 9001 || r.id == 9002 || r.id >= 0x40000000) continue;
        if (!keep.contains(r.id)) await notif.cancel(r.id);
      }
    } catch (e) {
      errs.add('예약 목록 확인: $e');
    }

    final t = DateFormat('HH:mm:ss').format(DateTime.now());
    if (nativeOk) {
      schedNote = '$nativeNote · 메모 알림 $nMemo개'
          '${nFail > 0 ? ' (메모 실패 $nFail)' : ''} · $t';
    } else {
      schedNote = '[일반 알림 방식] 근무 알람 $nAlarm개 포함 총 ${take.length}개 등록 '
          '(알람시계 $nClock · 정확 $nExact · 부정확 $nInexact · 실패 $nFail) $t';
    }
    schedWarn = errs.join('\n');
    schedVersion++;
    notifyListeners();
  }

  AndroidNotificationDetails _alarmDetails(String tone, bool sound, bool vibrate) =>
      buildAlarmDetails(tone, sound, vibrate);

  NotificationDetails _detailsFor(_Pending p) {
    if (p.alarmType) {
      return NotificationDetails(android: _alarmDetails(p.tone, p.sound, p.vibrate));
    }
    if (p.notice) {
      final lead = p.targetMs - p.when.millisecondsSinceEpoch;
      return NotificationDetails(
        android: AndroidNotificationDetails(
          'alarm_notice',
          '알람 미리 알림',
          channelDescription: '알람이 울리기 전에 알림창에 몇 분 남았는지 표시',
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          category: AndroidNotificationCategory.reminder,
          showWhen: true,
          when: p.targetMs,
          usesChronometer: true,
          chronometerCountDown: true,
          timeoutAfter: lead > 0 ? lead : null,
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction('skip', '이번 알람 끄기',
                showsUserInterface: false, cancelNotification: true),
          ],
        ),
      );
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
    // 근무 알람은 "알람 시계" 방식(절전 모드에서도 가장 잘 울림)으로 먼저 시도한다
    final modes = p.alarmType
        ? <AndroidScheduleMode>[
            AndroidScheduleMode.alarmClock,
            AndroidScheduleMode.exactAllowWhileIdle,
            AndroidScheduleMode.inexactAllowWhileIdle,
          ]
        : <AndroidScheduleMode>[
            AndroidScheduleMode.exactAllowWhileIdle,
            AndroidScheduleMode.inexactAllowWhileIdle,
          ];
    for (final mode in modes) {
      try {
        await notif.zonedSchedule(id, p.title, p.body, when, details,
            androidScheduleMode: mode, payload: p.payload);
        if (mode == AndroidScheduleMode.alarmClock) return 'clock';
        return mode == AndroidScheduleMode.inexactAllowWhileIdle ? 'inexact' : 'exact';
      } catch (e) {
        debugPrint('알람 예약 실패($mode): $e');
        lastSchedError = '$mode: $e';
      }
    }
    return 'fail';
  }

  /// 알람 테스트. now=true 면 바로 울리고, 아니면 10초 뒤에 울린다.
  Future<String> testAlarm({
    required bool now,
    int seconds = 10,
    String tone = 'bell',
    bool sound = true,
    bool vibrate = true,
  }) async {
    if (kIsWeb) return 'PC 미리보기에서는 알람을 테스트할 수 없어요';
    final String whenTxt = seconds >= 60 ? '${seconds ~/ 60}분' : '$seconds초';
    final m = <String, dynamic>{
      'id': 9002,
      'at': DateTime.now().add(Duration(seconds: now ? 0 : seconds)).millisecondsSinceEpoch,
      'title': '테스트 알람',
      'body': '이 알람이 들리면 정상입니다',
      'tone': tone,
      'sound': sound,
      'vibrate': vibrate,
      'key': 'T|9002|0',
      'noticeAt': 0,
      'ramp': rampSec,
    };
    String nativeErr = '';
    try {
      if (now) {
        await nativeRingNow(m);
        return '알람 화면을 띄웠어요. 소리가 작으면 알람 볼륨을 올려 주세요';
      }
      final r = await nativeScheduleOne(m);
      schedVersion++;
      notifyListeners();
      if (r.startsWith('clock')) {
        return '$whenTxt 뒤에 알람 화면이 떠요. 앱을 완전히 끄고 화면도 끈 채로 기다려 보세요';
      }
      if (r.startsWith('inexact')) return '예약은 됐지만 "정확한 알람" 권한이 없어 늦을 수 있어요 ($r)';
      nativeErr = r;
    } catch (e) {
      nativeErr = e.toString();
    }
    // 알람 화면 방식이 안 되면 예전(일반 알림) 방식으로
    try {
      final p = _Pending(
        DateTime.now().add(Duration(seconds: seconds)),
        '테스트 알람',
        '이 알람이 들리면 정상입니다',
        true,
        tone: tone,
        sound: sound,
        vibrate: vibrate,
        payload: alarmPayload(9002, tone, sound, vibrate, '테스트 알람', '이 알람이 들리면 정상입니다'),
      );
      if (now) {
        await notif.show(9001, p.title, p.body, _detailsFor(p), payload: p.payload);
        return '[예비 방식] 알림을 보냈어요 ($nativeErr)';
      }
      final r = await _scheduleOne(9002, p);
      final String when = seconds >= 60 ? '${seconds ~/ 60}분' : '$seconds초';
      if (r == 'clock' || r == 'exact') {
        return '[예비 방식] $when 뒤에 울려요 ($nativeErr)';
      }
      if (r == 'inexact') return '예약은 됐지만 "정확한 알람" 권한이 없어 시간이 늦을 수 있어요';
      return '알람 예약에 실패했어요: $lastSchedError / $nativeErr';
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
    if (kIsWeb) return AlarmStatus(false, false, 0, false);
    try {
      final a =
          notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final n = await a?.areNotificationsEnabled() ?? false;
      final e = await a?.canScheduleExactNotifications() ?? false;
      int p = -1;
      try {
        p = (await notif.pendingNotificationRequests()).length;
      } catch (_) {}
      final bt = await isIgnoringBattery();
      final fs = await canFullScreen();
      final np = await nativeAlarmCount();
      return AlarmStatus(n, e, p, bt, fullOk: fs, nativePending: np);
    } catch (_) {
      return AlarmStatus(false, false, 0, false);
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
    onDidReceiveNotificationResponse: handleNotificationAction,
    onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
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
