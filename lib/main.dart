import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ical.dart';

// ───────────────────────── 데이터 ─────────────────────────

class ShiftType {
  String id;
  String name; // 칸에 표시되는 짧은 이름 (예: 주, 야, 휴)
  int color;
  int? startMin; // 출근 시각(자정 기준 분). null 이면 휴무(알람 없음)
  int alarmBefore; // 출근 몇 분 전에 울릴지. -1 이면 알람 없음

  ShiftType({
    required this.id,
    required this.name,
    required this.color,
    this.startMin,
    this.alarmBefore = 60,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'startMin': startMin,
        'alarmBefore': alarmBefore,
      };

  factory ShiftType.fromJson(Map<String, dynamic> j) => ShiftType(
        id: j['id'],
        name: j['name'],
        color: j['color'],
        startMin: j['startMin'],
        alarmBefore: j['alarmBefore'] ?? 60,
      );
}

/// 배경색이 밝은(파스텔) 색이면 진한 글자, 어두우면 흰 글자
Color textOn(Color bg) => bg.computeLuminance() > 0.45 ? const Color(0xFF37474F) : Colors.white;

String fmtTime(int min) =>
    '${(min ~/ 60).toString().padLeft(2, '0')}:${(min % 60).toString().padLeft(2, '0')}';

final _keyFmt = DateFormat('yyyy-MM-dd');
String dayKey(DateTime d) => _keyFmt.format(d);

// ───────────────────────── 저장소 + 알람 + 동기화 ─────────────────────────

final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

class Store extends ChangeNotifier {
  List<ShiftType> types = [];
  Map<String, String> days = {}; // yyyy-MM-dd -> shiftType.id
  List<String> pattern = []; // 마지막에 쓴 반복 패턴
  Map<String, List<String>> memos = {}; // 날짜별 메모
  Map<String, int> dayAlarms = {}; // 날짜별 알람 시각(분). -1 = 그날 알람 끔

  // 외부 캘린더
  bool holidaySync = true;
  String icalUrl = '';
  String lastSync = '';
  String syncMsg = '';
  bool syncing = false;
  List<Ev> holidayEvs = [];
  List<Ev> googleEvs = [];
  Map<String, List<Ev>> evByDay = {};

  ShiftType? typeById(String? id) {
    for (final t in types) {
      if (t.id == id) return t;
    }
    return null;
  }

  ShiftType? typeFor(DateTime d) => typeById(days[dayKey(d)]);

  String? holidayName(DateTime d) {
    final k = dayKey(d);
    for (final e in evByDay[k] ?? const <Ev>[]) {
      if (e.kind == 0) return e.title;
    }
    return builtinHolidays(d.year)[k];
  }

  /// 그날 실제로 울릴 알람 시각(분). 없으면 null. 음수/1440 이상이면 전날/다음날.
  int? alarmMinFor(DateTime d) {
    final c = dayAlarms[dayKey(d)];
    if (c != null) return c < 0 ? null : c;
    final t = typeFor(d);
    if (t == null || t.startMin == null || t.alarmBefore < 0) return null;
    return t.startMin! - t.alarmBefore;
  }

  void _rebuildEv() {
    final m = <String, List<Ev>>{};
    for (final e in [...holidayEvs, ...googleEvs]) {
      m.putIfAbsent(e.date, () => []).add(e);
    }
    evByDay = m;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('types');
    if (raw == null) {
      types = [
        ShiftType(id: 'day', name: '주', color: 0xFFFDFFB6, startMin: 7 * 60, alarmBefore: 60),
        ShiftType(id: 'night', name: '야', color: 0xFFA0C4FF, startMin: 23 * 60, alarmBefore: 60),
        ShiftType(id: 'off', name: '휴', color: 0xFFCAFFBF, startMin: null, alarmBefore: -1),
        // A(오전)/F(오후)/N(야간) 출근 시각은 임시값입니다. 설정(조절 아이콘)에서 실제 시간으로 바꿔주세요.
        ShiftType(id: 'a', name: 'A', color: 0xFFFFC8DD, startMin: 7 * 60, alarmBefore: 60),
        ShiftType(id: 'f', name: 'F', color: 0xFFFFD6A5, startMin: 15 * 60, alarmBefore: 60),
        ShiftType(id: 'n', name: 'N', color: 0xFFBDB2FF, startMin: 22 * 60, alarmBefore: 60),
        ShiftType(id: 'compoff', name: '대휴', color: 0xFF9BF6FF, startMin: null, alarmBefore: -1),
        ShiftType(id: 'reward', name: '보상', color: 0xFFD7C4B5, startMin: null, alarmBefore: -1),
      ];
    } else {
      types = (jsonDecode(raw) as List)
          .map((e) => ShiftType.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    final d = p.getString('days');
    if (d != null) days = Map<String, String>.from(jsonDecode(d));
    pattern = p.getStringList('pattern') ?? [];

    final m = p.getString('memos');
    if (m != null) {
      final decoded = jsonDecode(m) as Map<String, dynamic>;
      memos = decoded.map((k, v) => MapEntry(k, List<String>.from(v)));
    }
    final a = p.getString('dayAlarms');
    if (a != null) dayAlarms = Map<String, int>.from(jsonDecode(a));

    holidaySync = p.getBool('holidaySync') ?? true;
    icalUrl = p.getString('icalUrl') ?? '';
    lastSync = p.getString('lastSync') ?? '';
    holidayEvs = _loadEvs(p.getString('ev_holiday'));
    googleEvs = _loadEvs(p.getString('ev_google'));
    _rebuildEv();
    notifyListeners();
  }

  List<Ev> _loadEvs(String? s) {
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => Ev.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save({bool resched = true}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('types', jsonEncode(types.map((e) => e.toJson()).toList()));
    await p.setString('days', jsonEncode(days));
    await p.setStringList('pattern', pattern);
    await p.setString('memos', jsonEncode(memos));
    await p.setString('dayAlarms', jsonEncode(dayAlarms));
    await p.setBool('holidaySync', holidaySync);
    await p.setString('icalUrl', icalUrl);
    notifyListeners();
    if (resched) await rescheduleAll();
  }

  void setDay(DateTime d, String? typeId) {
    if (typeId == null) {
      days.remove(dayKey(d));
    } else {
      days[dayKey(d)] = typeId;
    }
    save();
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

  /// 백업: 근무표·메모·알람 설정을 문자열 하나로 만든다.
  String exportJson() => jsonEncode({
        'v': 1,
        'types': types.map((e) => e.toJson()).toList(),
        'days': days,
        'pattern': pattern,
        'memos': memos,
        'dayAlarms': dayAlarms,
      });

  /// 복원: exportJson 으로 만든 문자열을 읽어 현재 데이터를 덮어쓴다.
  Future<bool> importJson(String s) async {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      if (m['types'] == null) return false;
      final newTypes = (m['types'] as List)
          .map((e) => ShiftType.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final newDays = Map<String, String>.from(m['days'] ?? {});
      final newPattern = List<String>.from(m['pattern'] ?? []);
      final newMemos = Map<String, dynamic>.from(m['memos'] ?? {})
          .map((k, v) => MapEntry(k, List<String>.from(v)));
      final newAlarms = Map<String, int>.from(m['dayAlarms'] ?? {});
      types = newTypes;
      days = newDays;
      pattern = newPattern;
      memos = newMemos;
      dayAlarms = newAlarms;
      await save();
      return true;
    } catch (_) {
      return false;
    }
  }

  void addMemo(DateTime d, String text) {
    memos.putIfAbsent(dayKey(d), () => []).add(text);
    save(resched: false);
  }

  void removeMemo(DateTime d, int index) {
    final k = dayKey(d);
    final list = memos[k];
    if (list == null || index >= list.length) return;
    list.removeAt(index);
    if (list.isEmpty) memos.remove(k);
    save(resched: false);
  }

  /// null = 기본값 사용, -1 = 그날 알람 끔, 0~1439 = 직접 지정한 시각
  void setDayAlarm(DateTime d, int? min) {
    if (min == null) {
      dayAlarms.remove(dayKey(d));
    } else {
      dayAlarms[dayKey(d)] = min;
    }
    save();
  }

  /// 구글 공휴일 + 내 구글 캘린더(비공개 iCal 주소)를 가져온다.
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

  /// 앞으로 60일치 알람을 전부 다시 등록한다. (앱을 열 때마다 자동으로 갱신됨)
  Future<void> rescheduleAll() async {
    if (kIsWeb) return; // PC 크롬 미리보기에서는 알람 기능 없음
    await notif.cancelAll();
    final now = tz.TZDateTime.now(tz.local);
    for (int i = 0; i < 60; i++) {
      final d = DateTime(now.year, now.month, now.day + i);
      final m = alarmMinFor(d);
      if (m == null) continue;
      final t = typeFor(d);
      final when = tz.TZDateTime(tz.local, d.year, d.month, d.day).add(Duration(minutes: m));
      if (when.isBefore(now)) continue;

      final custom = dayAlarms[dayKey(d)] != null;
      String title;
      String body;
      if (t != null && t.startMin != null) {
        title = '${t.name} 근무 알림';
        body = '${fmtTime(t.startMin!)} 출근';
        if (!custom && t.alarmBefore > 0) body += ' (${t.alarmBefore}분 전)';
      } else {
        title = '알람';
        body = DateFormat('M월 d일 (E)', 'ko_KR').format(d);
      }
      final memo = memos[dayKey(d)];
      if (memo != null && memo.isNotEmpty) body += ' · ${memo.first}';

      await notif.zonedSchedule(
        int.parse(DateFormat('yyyyMMdd').format(d)),
        title,
        body,
        when,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'shift_alarm',
            '근무 알람',
            channelDescription: '출근 시간 알람',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            fullScreenIntent: true,
            playSound: true,
            enableVibration: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
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
  final a = notif
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await a?.requestNotificationsPermission();
  await a?.requestExactAlarmsPermission();
}

// ───────────────────────── 앱 ─────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR');
  await initNotifications();
  await store.load();
  await store.rescheduleAll();
  runApp(const ShiftApp());
  store.syncAll(); // 앱을 열 때마다 공휴일/내 일정을 자동으로 갱신
}

class ShiftApp extends StatelessWidget {
  const ShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '근무 캘린더',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomePage(),
    );
  }
}

// ───────────────────────── 홈(캘린더) ─────────────────────────

class _Bar {
  final String text;
  final Color color;
  _Bar(this.text, this.color);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  final _memoCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    store.addListener(_refresh);
  }

  @override
  void dispose() {
    store.removeListener(_refresh);
    _memoCtl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  List<_Bar> _bars(DateTime d, String? hol) {
    final k = dayKey(d);
    final items = <_Bar>[];
    if (hol != null) items.add(_Bar(hol, Colors.red));
    for (final e in store.evByDay[k] ?? const <Ev>[]) {
      if (e.kind == 0) continue;
      items.add(_Bar(e.title, e.kind == 1 ? Colors.grey : Colors.blue));
    }
    for (final m in store.memos[k] ?? const <String>[]) {
      items.add(_Bar(m, Colors.orange));
    }
    return items.take(2).toList();
  }

  Widget _cell(DateTime day, {bool outside = false}) {
    final cs = Theme.of(context).colorScheme;
    final t = store.typeFor(day);
    final hol = store.holidayName(day);
    final selected = isSameDay(day, _selected);
    final today = isSameDay(day, DateTime.now());
    Color? numColor;
    if (day.weekday == DateTime.sunday || hol != null) {
      numColor = Colors.red;
    } else if (day.weekday == DateTime.saturday) {
      numColor = Colors.blue;
    }

    return Container(
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: selected ? cs.primary.withAlpha(30) : null,
        border: today ? Border.all(color: cs.primary, width: 1.5) : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Opacity(
        opacity: outside ? 0.35 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Text('${day.day}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: numColor)),
            const SizedBox(height: 2),
            if (t != null)
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Color(t.color), shape: BoxShape.circle),
                child: Text(t.name,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                        color: textOn(Color(t.color)),
                        fontSize: t.name.length > 1 ? 9 : 11,
                        fontWeight: FontWeight.bold)),
              )
            else
              const SizedBox(height: 22),
            for (final b in _bars(day, hol))
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 1),
                padding: const EdgeInsets.symmetric(horizontal: 1),
                color: b.color.withAlpha(40),
                child: Text(
                  b.text,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 9, color: b.color),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _alarmText(DateTime d) {
    final c = store.dayAlarms[dayKey(d)];
    if (c != null) return c < 0 ? '이 날 알람 꺼짐' : '${fmtTime(c)} (직접 지정)';
    final t = store.typeFor(d);
    final m = store.alarmMinFor(d);
    if (t == null || m == null) return '없음';
    final before = t.alarmBefore == 0 ? '출근 정각' : '출근 ${t.alarmBefore}분 전';
    final time = m < 0 ? '전날 ${fmtTime(m + 1440)}' : fmtTime(m);
    return '$time (기본: $before)';
  }

  Future<void> _alarmDialog() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${DateFormat('M월 d일', 'ko_KR').format(_selected)} 알람'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'default'),
              child: const Text('기본값 사용 (근무 종류 설정대로)')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'custom'),
              child: const Text('원하는 시각으로 지정…')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'off'),
              child: const Text('이 날은 알람 끄기')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'default') {
      store.setDayAlarm(_selected, null);
    } else if (choice == 'off') {
      store.setDayAlarm(_selected, -1);
    } else {
      final cur = store.alarmMinFor(_selected);
      final init = (cur != null && cur >= 0 && cur < 1440) ? cur : 18 * 60;
      final p = await showTimePicker(
          context: context, initialTime: TimeOfDay(hour: init ~/ 60, minute: init % 60));
      if (p != null) store.setDayAlarm(_selected, p.hour * 60 + p.minute);
    }
  }

  void _addMemo() {
    final text = _memoCtl.text.trim();
    if (text.isEmpty) return;
    store.addMemo(_selected, text);
    _memoCtl.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 이번 달 근무 집계
    final counts = <String, int>{};
    final last = DateTime(_focused.year, _focused.month + 1, 0).day;
    for (int i = 1; i <= last; i++) {
      final t = store.typeFor(DateTime(_focused.year, _focused.month, i));
      if (t != null) counts[t.id] = (counts[t.id] ?? 0) + 1;
    }

    final sel = store.typeFor(_selected);
    final selKey = dayKey(_selected);
    final hol = store.holidayName(_selected);
    final evs = (store.evByDay[selKey] ?? const <Ev>[]).where((e) => e.kind != 0).toList();
    final memos = store.memos[selKey] ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('근무 캘린더'),
        actions: [
          IconButton(
            tooltip: '오늘',
            icon: const Icon(Icons.today),
            onPressed: () => setState(() {
              _focused = DateTime.now();
              _selected = DateTime.now();
            }),
          ),
          IconButton(
            tooltip: '패턴 일괄 적용',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => showDialog(context: context, builder: (_) => const PatternDialog()),
          ),
          IconButton(
            tooltip: '근무 종류/알람 설정',
            icon: const Icon(Icons.tune),
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const TypesPage())),
          ),
          IconButton(
            tooltip: '공휴일/구글 캘린더 연동',
            icon: Icon(store.syncing ? Icons.sync : Icons.cloud_sync_outlined),
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const SyncPage())),
          ),
        ],
      ),
      body: ListView(
        children: [
          TableCalendar(
            locale: 'ko_KR',
            firstDay: DateTime(2020),
            lastDay: DateTime(2035),
            focusedDay: _focused,
            rowHeight: 82,
            startingDayOfWeek: StartingDayOfWeek.sunday,
            headerStyle: const HeaderStyle(formatButtonVisible: false, titleCentered: true),
            selectedDayPredicate: (d) => isSameDay(d, _selected),
            onDaySelected: (s, f) => setState(() {
              _selected = s;
              _focused = f;
            }),
            onPageChanged: (f) => setState(() => _focused = f),
            calendarBuilders: CalendarBuilders(
              dowBuilder: (ctx, day) {
                final label = DateFormat.E('ko_KR').format(day);
                Color? c;
                if (day.weekday == DateTime.sunday) c = Colors.red;
                if (day.weekday == DateTime.saturday) c = Colors.blue;
                return Center(child: Text(label, style: TextStyle(color: c, fontSize: 12)));
              },
              defaultBuilder: (ctx, day, f) => _cell(day),
              todayBuilder: (ctx, day, f) => _cell(day),
              selectedBuilder: (ctx, day, f) => _cell(day),
              outsideBuilder: (ctx, day, f) => _cell(day, outside: true),
            ),
          ),
          const Divider(height: 1),

          // ── 선택한 날짜 상세 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat('M월 d일 (E)', 'ko_KR').format(_selected),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (hol != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: Colors.red.withAlpha(30), borderRadius: BorderRadius.circular(8)),
                    child: Text(hol, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final t in store.types)
                  ChoiceChip(
                    label: Text(t.name),
                    avatar: CircleAvatar(backgroundColor: Color(t.color), radius: 6),
                    selected: sel?.id == t.id,
                    onSelected: (_) => store.setDay(_selected, t.id),
                  ),
                ActionChip(
                  label: const Text('지우기'),
                  avatar: const Icon(Icons.close, size: 16),
                  onPressed: () => store.setDay(_selected, null),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(
              store.alarmMinFor(_selected) == null ? Icons.alarm_off : Icons.alarm,
            ),
            title: Text('알람  ${_alarmText(_selected)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _alarmDialog,
          ),
          if (evs.isNotEmpty)
            for (final e in evs)
              ListTile(
                dense: true,
                leading: Icon(e.kind == 1 ? Icons.flag_outlined : Icons.event,
                    color: e.kind == 1 ? Colors.grey : Colors.blue),
                title: Text(e.title),
                subtitle: Text(e.time ?? '종일'),
              ),
          for (int i = 0; i < memos.length; i++)
            ListTile(
              dense: true,
              leading: const Icon(Icons.sticky_note_2_outlined, color: Colors.orange),
              title: Text(memos[i]),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => store.removeMemo(_selected, i),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _memoCtl,
                    decoration: const InputDecoration(
                        hintText: '이 날짜에 메모 추가', isDense: true),
                    onSubmitted: (_) => _addMemo(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.add_circle), onPressed: _addMemo),
              ],
            ),
          ),

          // ── 이번 달 합계 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text('${_focused.month}월 합계:',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final t in store.types)
                  if ((counts[t.id] ?? 0) > 0)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      CircleAvatar(backgroundColor: Color(t.color), radius: 5),
                      const SizedBox(width: 4),
                      Text('${t.name} ${counts[t.id]}일'),
                    ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 연동 설정 ─────────────────────────

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final TextEditingController _url = TextEditingController(text: store.icalUrl);

  @override
  void initState() {
    super.initState();
    store.addListener(_r);
  }

  @override
  void dispose() {
    store.removeListener(_r);
    _url.dispose();
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('공휴일 / 구글 캘린더 연동')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('대한민국 공휴일 자동 표시'),
            subtitle: const Text('구글의 "대한민국의 휴일" 캘린더를 가져옵니다.\n설날·추석·대체공휴일 포함, 앞으로 몇 년치 자동 갱신'),
            value: store.holidaySync,
            onChanged: (v) {
              store.holidaySync = v;
              store.save(resched: false);
              store.syncAll();
            },
          ),
          const Divider(height: 32),
          Text('내 구글 캘린더 연결', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('제미나이로 등록한 일정은 구글 캘린더에 들어가므로, '
              '아래에 "비공개 iCal 주소"를 넣으면 이 앱 달력에 자동으로 나타납니다.'),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '비공개 iCal 주소 (https://calendar.google.com/...basic.ics)',
            ),
            onChanged: (v) {
              store.icalUrl = v.trim();
              store.save(resched: false);
            },
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: store.syncing ? null : () => store.syncAll(),
            icon: const Icon(Icons.sync),
            label: Text(store.syncing ? '동기화 중...' : '지금 동기화'),
          ),
          const SizedBox(height: 8),
          if (store.syncMsg.isNotEmpty) Text(store.syncMsg),
          if (store.lastSync.isNotEmpty)
            Text('마지막 동기화: ${store.lastSync}', style: const TextStyle(color: Colors.grey)),
          const Divider(height: 32),
          Text('백업 / 복원', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('근무표·메모·알람 설정을 문자로 복사해 두었다가, 폰을 바꾸거나 앱을 다시 설치했을 때 '
              '붙여넣어 복원합니다. 카톡 "나와의 채팅"에 붙여넣어 보관하세요.'),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('백업 복사'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: store.exportJson()));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('백업이 복사되었습니다. 카톡 나와의 채팅 등에 붙여넣어 보관하세요')));
              },
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.paste),
              label: const Text('복원'),
              onPressed: () async {
                final ctl = TextEditingController();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('백업 붙여넣기'),
                    content: TextField(
                      controller: ctl,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(), hintText: '백업 내용을 붙여넣으세요'),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('복원 (현재 데이터 덮어씀)')),
                    ],
                  ),
                );
                if (ok != true) return;
                final done = await store.importJson(ctl.text.trim());
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(done ? '복원되었습니다' : '백업 형식이 올바르지 않습니다')));
              },
            ),
          ]),
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('iCal 주소 찾는 방법'),
            children: const [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '1. PC(또는 폰 브라우저 "데스크톱 사이트")에서 calendar.google.com 접속\n'
                  '2. 왼쪽 "내 캘린더"에서 연결할 캘린더 옆 ⋮ → 설정 및 공유\n'
                  '3. 아래쪽 "캘린더 통합" → "iCal 형식의 비공개 주소" 복사\n'
                  '4. 위 입력칸에 붙여넣기\n\n'
                  '※ 이 주소는 비밀번호와 같습니다. 남에게 보여주지 마세요. 주소는 이 폰 안에만 저장됩니다.',
                ),
              ),
              SizedBox(height: 8),
            ],
          ),
          const Text(
            '※ 구글 "할 일(Tasks)"은 iCal 주소로 내보내지지 않아 연동되지 않습니다. '
            '제미나이에게 일정을 등록할 때는 "구글 캘린더에 일정으로 추가해줘"라고 하면 연동됩니다.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 패턴 일괄 적용 ─────────────────────────

class PatternDialog extends StatefulWidget {
  const PatternDialog({super.key});

  @override
  State<PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<PatternDialog> {
  DateTime start = DateTime.now();
  int count = 90;
  late List<String> seq = List.of(store.pattern);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('교대 패턴 일괄 적용'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('아래 버튼을 눌러 반복할 순서를 만드세요.\n예) 주 → 주 → 야 → 야 → 휴 → 휴'),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (int i = 0; i < seq.length; i++)
                Chip(
                  label: Text(store.typeById(seq[i])?.name ?? '?'),
                  backgroundColor:
                      Color(store.typeById(seq[i])?.color ?? 0xFF9E9E9E).withAlpha(64),
                  onDeleted: () => setState(() => seq.removeAt(i)),
                ),
              if (seq.isEmpty) const Text('(비어 있음)'),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (final t in store.types)
                ActionChip(
                  label: Text('+ ${t.name}'),
                  onPressed: () => setState(() => seq.add(t.id)),
                ),
            ]),
            const Divider(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('시작일'),
              subtitle: Text(DateFormat('yyyy년 M월 d일 (E)', 'ko_KR').format(start)),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () async {
                final p = await showDatePicker(
                    context: context,
                    initialDate: start,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2035));
                if (p != null) setState(() => start = p);
              },
            ),
            Row(children: [
              const Text('적용 기간'),
              const Spacer(),
              DropdownButton<int>(
                value: count,
                items: [30, 60, 90, 180, 365]
                    .map((e) => DropdownMenuItem(value: e, child: Text('$e일')))
                    .toList(),
                onChanged: (v) => setState(() => count = v!),
              ),
            ]),
            const Text('※ 해당 기간의 기존 근무는 덮어씌워집니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: seq.isEmpty
              ? null
              : () {
                  store.applyPattern(start, count, seq);
                  Navigator.pop(context);
                },
          child: const Text('적용'),
        ),
      ],
    );
  }
}

// ───────────────────────── 근무 종류 / 알람 설정 ─────────────────────────

class TypesPage extends StatefulWidget {
  const TypesPage({super.key});

  @override
  State<TypesPage> createState() => _TypesPageState();
}

class _TypesPageState extends State<TypesPage> {
  @override
  void initState() {
    super.initState();
    store.addListener(_r);
  }

  @override
  void dispose() {
    store.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('근무 종류 / 알람')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('추가'),
        onPressed: () => _edit(
          ShiftType(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: '새',
              color: 0xFFBAE1FF,
              startMin: 9 * 60),
          isNew: true,
        ),
      ),
      body: ListView(
        children: [
          for (final t in store.types)
            ListTile(
              leading: CircleAvatar(
                  backgroundColor: Color(t.color),
                  child: Text(t.name, style: TextStyle(color: textOn(Color(t.color))))),
              title: Text(t.startMin == null
                  ? '${t.name} (휴무)'
                  : '${t.name}  ·  ${fmtTime(t.startMin!)} 출근'),
              subtitle: Text(t.alarmBefore < 0
                  ? '알람 없음'
                  : t.alarmBefore == 0
                      ? '출근 시각 정각에 알람'
                      : '${t.alarmBefore}분 전 알람'),
              onTap: () => _edit(t),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('※ 특정 날짜만 알람 시각을 바꾸려면 메인 화면에서 날짜를 누르고 "알람"을 눌러주세요.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Future<void> _edit(ShiftType t, {bool isNew = false}) async {
    final name = TextEditingController(text: t.name);
    int color = t.color;
    int? startMin = t.startMin;
    int alarm = t.alarmBefore;
    const palette = [
      0xFFFFB3BA, 0xFFFFC8DD, 0xFFFFD6A5, 0xFFFFDFBA,
      0xFFFDFFB6, 0xFFCAFFBF, 0xFFBAFFC9, 0xFF9BF6FF,
      0xFFBAE1FF, 0xFFA0C4FF, 0xFFBDB2FF, 0xFFE0BBE4,
      0xFFFFC6FF, 0xFFD7C4B5, 0xFFCFD8DC, 0xFFF1F1F1,
    ];
    const offsets = <int, String>{
      -1: '없음',
      0: '정각',
      10: '10분 전',
      30: '30분 전',
      60: '1시간 전',
      90: '1시간 30분 전',
      120: '2시간 전',
      180: '3시간 전',
      240: '4시간 전',
      300: '5시간 전',
      360: '6시간 전',
    };
    if (!offsets.containsKey(alarm)) alarm = 60;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isNew ? '근무 종류 추가' : '근무 종류 수정'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                maxLength: 3,
                decoration: const InputDecoration(labelText: '이름 (예: 주, 야, 휴)'),
              ),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in palette)
                  GestureDetector(
                    onTap: () => setS(() => color = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == c ? Colors.black54 : Colors.black12,
                          width: color == c ? 2 : 1,
                        ),
                      ),
                      child: color == c
                          ? const Icon(Icons.check, size: 18, color: Colors.black54)
                          : null,
                    ),
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('휴무 (출근 없음)'),
                value: startMin == null,
                onChanged: (v) => setS(() {
                  startMin = v ? null : 9 * 60;
                  alarm = v ? -1 : 60;
                }),
              ),
              if (startMin != null) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('출근 시각'),
                  trailing: Text(fmtTime(startMin!), style: const TextStyle(fontSize: 18)),
                  onTap: () async {
                    final p = await showTimePicker(
                        context: ctx,
                        initialTime:
                            TimeOfDay(hour: startMin! ~/ 60, minute: startMin! % 60));
                    if (p != null) setS(() => startMin = p.hour * 60 + p.minute);
                  },
                ),
                Row(children: [
                  const Text('알람'),
                  const Spacer(),
                  DropdownButton<int>(
                    value: alarm,
                    items: [
                      for (final e in offsets.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setS(() => alarm = v!),
                  ),
                ]),
              ],
            ]),
          ),
          actions: [
            if (!isNew)
              TextButton(
                onPressed: () {
                  store.types.removeWhere((e) => e.id == t.id);
                  store.days.removeWhere((k, v) => v == t.id);
                  store.save();
                  Navigator.pop(ctx);
                },
                child: const Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
              onPressed: () {
                t.name = name.text.trim().isEmpty ? '?' : name.text.trim();
                t.color = color;
                t.startMin = startMin;
                t.alarmBefore = startMin == null ? -1 : alarm;
                if (isNew) store.types.add(t);
                store.save();
                Navigator.pop(ctx);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}
