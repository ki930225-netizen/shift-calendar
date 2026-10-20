import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import 'alarm_page.dart';
import 'ical.dart';
import 'lunar.dart';
import 'memo_page.dart';
import 'models.dart';
import 'settings_page.dart';
import 'store.dart';
import 'week_page.dart';

const Color kRed = Color(0xFFE5495B);
const Color kBlue = Color(0xFF3F7DE0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeDateFormatting('ko_KR');
  } catch (_) {}
  try {
    await store.load();
  } catch (e) {
    debugPrint('데이터 불러오기 실패: $e');
  }
  runApp(const ShiftApp()); // 화면을 먼저 띄운다 (알람/동기화 오류가 있어도 앱은 열림)
  _startup();
}

/// 화면이 뜬 뒤에 알람 초기화 → 알람 등록 → 공휴일/일정 동기화를 순서대로, 각각 안전하게 실행
Future<void> _startup() async {
  store.syncDevice(); // 폰 캘린더 일정은 바로 읽어서 먼저 보여준다
  try {
    await initNotifications().timeout(const Duration(seconds: 30));
  } catch (e) {
    debugPrint('알림 초기화 실패: $e');
  }
  await store.rescheduleAll();
  store.syncAll(); // 앱을 열 때마다 공휴일/내 일정을 자동으로 갱신
}

class ShiftApp extends StatelessWidget {
  const ShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '근무 캘린더',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1E6FEB),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}

// ───────────────────────── 하단 탭 ─────────────────────────

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _i = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      store.syncDevice(); // 폰 캘린더에 새로 들어온 일정 반영
      store.rescheduleIfStale(); // 알람이 사라졌을 경우를 대비해 다시 등록
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _i,
        children: const [CalendarPage(), AlarmPage(), SettingsPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '캘린더',
          ),
          NavigationDestination(
            icon: Icon(Icons.alarm),
            selectedIcon: Icon(Icons.alarm_on),
            label: '알람',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '설정',
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 캘린더 ─────────────────────────

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  bool _brushMode = false; // 근무 연속 입력 모드
  String? _brush; // null = 아직 고르지 않음, 'CLEAR' = 지우개, 그 외 = 근무 id

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

  void _onDay(DateTime sel, DateTime foc) {
    setState(() {
      _selected = sel;
      _focused = foc;
    });
    final b = _brushMode ? _brush : null;
    if (b != null) {
      store.setShift(sel, b == 'CLEAR' ? null : b);
    } else {
      showDaySheet(context, sel);
    }
  }

  Future<void> _pickMonth() async {
    final p = await showDatePicker(
      context: context,
      initialDate: _focused,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035, 12, 31),
    );
    if (p != null) {
      setState(() {
        _focused = p;
        _selected = p;
      });
    }
  }

  Future<void> _editMonthMemo() async {
    final ctl = TextEditingController(text: store.monthMemoOf(_focused));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_focused.month}월 메모'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '이 달에 기억할 내용',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('저장')),
        ],
      ),
    );
    if (ok == true) store.setMonthMemo(_focused, ctl.text);
  }

  Widget _monthMemoBar() {
    final t = store.monthMemoOf(_focused);
    return InkWell(
      onTap: _editMonthMemo,
      child: Container(
        width: double.infinity,
        color: const Color(0xFFF5F6F8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.sticky_note_2_outlined, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.isEmpty ? '월별 메모 (눌러서 입력)' : t,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: t.isEmpty ? Colors.grey : Colors.black87),
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _barsFor(DateTime day) {
    final out = <Widget>[];
    for (final m in store.memosOn(day)) {
      out.add(_memoBar(m, day));
    }
    final evs = store.evsOn(day)..sort((a, b) => b.kind.compareTo(a.kind));
    for (final e in evs) {
      out.add(_evBar(e));
    }
    return out;
  }

  Widget _memoBar(Memo m, DateTime day) {
    final k = dayKey(day);
    final isStart = k == m.start;
    final isEnd = k == m.end;
    final showTitle = isStart || day.weekday == DateTime.sunday;
    return Container(
      height: 12,
      margin: EdgeInsets.only(top: 1, left: isStart ? 1 : 0, right: isEnd ? 1 : 0),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Color(m.bg).withAlpha(m.done ? 110 : 255),
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(isStart ? 3 : 0),
          right: Radius.circular(isEnd ? 3 : 0),
        ),
      ),
      child: showTitle
          ? Text(
              m.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 9,
                color: Color(m.fg),
                decoration: m.done ? TextDecoration.lineThrough : null,
              ),
            )
          : null,
    );
  }

  Widget _evBar(Ev e) {
    final observance = e.kind == 1;
    final bg = observance ? const Color(0xFFFBE9DD) : const Color(0xFFE8EAF6);
    final fg = observance ? const Color(0xFFB5651D) : const Color(0xFF3949AB);
    return Container(
      height: 12,
      margin: const EdgeInsets.only(top: 1),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: bg,
        border: Border(left: BorderSide(color: fg, width: 2)),
      ),
      child: Text(
        e.title,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: 9, color: fg),
      ),
    );
  }

  Widget _cell(DateTime day, {bool outside = false}) {
    final cs = Theme.of(context).colorScheme;
    final k = dayKey(day);
    final shift = store.shiftOn(day);
    final hol = store.holidayName(day);
    final att = store.attend[k];
    final selected = isSameDay(day, _selected);
    final today = isSameDay(day, DateTime.now());

    Color? numColor;
    if (day.weekday == DateTime.sunday || hol != null) {
      numColor = kRed;
    } else if (day.weekday == DateTime.saturday) {
      numColor = kBlue;
    }

    String? label;
    Color labelColor = Colors.grey;
    if (hol != null) {
      label = hol;
      labelColor = kRed;
    } else if (day.weekday == DateTime.thursday) {
      label = '${isoWeekOf(day)}주차';
    } else {
      label = lunarCellLabel(day);
    }

    final bars = _barsFor(day);

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      foregroundDecoration: selected
          ? BoxDecoration(border: Border.all(color: cs.primary, width: 1.6))
          : null,
      child: LayoutBuilder(
        builder: (ctx, c) {
          final h = c.maxHeight.isFinite ? c.maxHeight : 90.0;
          final slots = ((h - 46 - (att != null ? 12 : 0)) / 13).floor().clamp(0, 6).toInt();
          return ClipRect(
            child: Opacity(
              opacity: outside ? 0.35 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: hol != null ? const Color(0xFFFFD3D9) : null, // 공휴일: 빨간 띠지
                    padding: const EdgeInsets.fromLTRB(3, 2, 3, 1),
                    child: Row(children: [
                      Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        height: 16,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: today
                            ? BoxDecoration(
                                color: cs.primary, borderRadius: BorderRadius.circular(8))
                            : null,
                        child: Text(
                          '${day.day}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: today ? Colors.white : numColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          label ?? '',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          style: TextStyle(fontSize: 8.5, color: labelColor),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 26,
                    child: shift == null ? null : Center(child: ShiftBadge(shift, size: 26)),
                  ),
                  if (att != null)
                    Center(
                      child: Text(att,
                          style: const TextStyle(
                              fontSize: 9, color: kRed, fontWeight: FontWeight.bold)),
                    ),
                  ...bars.take(slots),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _brushItem(String id, Widget child) {
    final on = _brush == id;
    return GestureDetector(
      onTap: () => setState(() => _brush = on ? null : id),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: on ? Colors.blue : Colors.transparent, width: 2.5),
        ),
        child: child,
      ),
    );
  }

  Widget _brushBar() {
    return Material(
      elevation: 8,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              _brush == null
                  ? '근무를 고른 뒤 날짜를 차례로 누르세요'
                  : (_brush == 'CLEAR' ? '지우개: 누른 날짜의 근무를 지웁니다' : '선택한 근무를 누른 날짜에 입력합니다'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in kShifts) _brushItem(s.id, ShiftBadge(s, size: 34)),
                    _brushItem(
                      'CLEAR',
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: Icon(Icons.backspace_outlined, size: 22),
                      ),
                    ),
                  ]),
                ),
              ),
              IconButton(
                tooltip: '연속 입력 끝내기',
                icon: const Icon(Icons.check_circle, color: Colors.blue),
                onPressed: () => setState(() {
                  _brushMode = false;
                  _brush = null;
                }),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          InkWell(
            onTap: _pickMonth,
            child: Text(
              DateFormat('yyyy. MM').format(_focused),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: () => setState(() {
              _focused = DateTime.now();
              _selected = DateTime.now();
            }),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 28),
              shape: const StadiumBorder(),
            ),
            child: const Text('오늘', style: TextStyle(fontSize: 12)),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: '주별 패턴 (요일별 근무)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.view_week),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const WeekPatternPage())),
          ),
          IconButton(
            tooltip: '쉬는 날(토·일·공휴일) 휴로 입력',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.event_busy),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PatternDialog(
                restOnly: true,
                start: DateTime(_focused.year, _focused.month, 1),
                count: DateUtils.getDaysInMonth(_focused.year, _focused.month),
              ),
            ),
          ),
          IconButton(
            tooltip: '근무 연속 입력',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_calendar, color: _brushMode ? cs.primary : null),
            onPressed: () => setState(() {
              _brushMode = !_brushMode;
              if (!_brushMode) _brush = null;
            }),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TableCalendar(
              locale: 'ko_KR',
              firstDay: DateTime(2020, 1, 1),
              lastDay: DateTime(2035, 12, 31),
              focusedDay: _focused,
              headerVisible: false,
              shouldFillViewport: true,
              daysOfWeekHeight: 26,
              startingDayOfWeek: StartingDayOfWeek.sunday,
              selectedDayPredicate: (d) => isSameDay(d, _selected),
              onDaySelected: _onDay,
              onPageChanged: (f) => setState(() => _focused = f),
              calendarBuilders: CalendarBuilders(
                dowBuilder: (ctx, day) {
                  Color? c;
                  if (day.weekday == DateTime.sunday) c = kRed;
                  if (day.weekday == DateTime.saturday) c = kBlue;
                  return Center(
                    child: Text(
                      DateFormat.E('ko_KR').format(day),
                      style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  );
                },
                defaultBuilder: (ctx, day, f) => _cell(day),
                todayBuilder: (ctx, day, f) => _cell(day),
                selectedBuilder: (ctx, day, f) => _cell(day),
                outsideBuilder: (ctx, day, f) => _cell(day, outside: true),
              ),
            ),
          ),
          _monthMemoBar(),
          if (_brushMode) _brushBar(),
        ],
      ),
    );
  }
}

// ───────────────────────── 날짜 시트 (메모 / 근무) ─────────────────────────

Future<void> showDaySheet(BuildContext context, DateTime day) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.86, child: DaySheet(initial: day)),
  );
}

class DaySheet extends StatefulWidget {
  final DateTime initial;
  const DaySheet({super.key, required this.initial});

  @override
  State<DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends State<DaySheet> {
  late DateTime _d = widget.initial;
  int _tab = 0; // 0 = 메모, 1 = 근무
  String? _flash;

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

  void _move(int delta) => setState(() => _d = DateTime(_d.year, _d.month, _d.day + delta));

  void _toast(String s) {
    setState(() => _flash = s);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _flash == s) setState(() => _flash = null);
    });
  }

  String _rangeText(Memo m) {
    final f = DateFormat('M.d');
    if (m.start == m.end) return m.timeText;
    final s = f.format(parseKey(m.start));
    final e = f.format(parseKey(m.end));
    return m.allDay
        ? '$s ~ $e · 하루 종일'
        : '$s ${fmtHM(m.startMin)} ~ $e ${fmtHM(m.endMin)}';
  }

  void _openMemo(Memo? m) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MemoEditPage(memo: m, day: _d),
    ));
  }

  Widget _tabBtn(String t, int i) {
    final on = _tab == i;
    return InkWell(
      onTap: () => setState(() => _tab = i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            t,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: on ? Colors.black87 : Colors.grey.shade400,
            ),
          ),
          const SizedBox(height: 4),
          Container(height: 3, width: 28, color: on ? Colors.black87 : Colors.transparent),
        ]),
      ),
    );
  }

  Widget _memoTab() {
    final memos = store.memosOn(_d);
    final evs = store.evsOn(_d);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ListTile(
          leading: const Icon(Icons.add_circle, color: Colors.grey),
          title: const Text('새 메모', style: TextStyle(fontSize: 16)),
          onTap: () => _openMemo(null),
        ),
        for (final e in evs)
          ListTile(
            dense: true,
            leading: Icon(e.kind == 1 ? Icons.flag_outlined : Icons.event,
                color: e.kind == 1 ? const Color(0xFFB5651D) : const Color(0xFF3949AB)),
            title: Text(e.title),
            subtitle: Text(e.time ?? '종일'),
          ),
        for (final m in memos)
          ListTile(
            leading: m.todo
                ? Checkbox(value: m.done, onChanged: (_) => store.toggleDone(m.id))
                : Container(
                    width: 10,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Color(m.bg),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
            title: Text(
              m.title,
              style: TextStyle(
                fontSize: 16,
                decoration: m.done ? TextDecoration.lineThrough : null,
                color: m.done ? Colors.grey : null,
              ),
            ),
            subtitle: Text(_rangeText(m)),
            trailing: m.alarmBefore >= 0
                ? const Icon(Icons.notifications_active_outlined, size: 18, color: Colors.grey)
                : null,
            onTap: () => _openMemo(m),
          ),
        if (memos.isEmpty && evs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('이 날짜에 메모가 없어요', style: TextStyle(color: Colors.grey)),
            ),
          ),
      ],
    );
  }

  Widget _choice({required Widget child, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.blue : Colors.transparent, width: 3),
        ),
        child: child,
      ),
    );
  }

  Future<void> _editAttend() async {
    final ctl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('근태 편집'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in store.attendTypes)
                  InputChip(
                    label: Text(a),
                    onDeleted: () {
                      store.attendTypes.remove(a);
                      store.save(resched: false);
                      setS(() {});
                    },
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                maxLength: 6,
                decoration: InputDecoration(
                  hintText: '새 근태 이름 (예: 휴직)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final t = ctl.text.trim();
                      if (t.isNotEmpty && !store.attendTypes.contains(t)) {
                        store.attendTypes.add(t);
                        store.save(resched: false);
                        ctl.clear();
                        setS(() {});
                      }
                    },
                  ),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          ],
        ),
      ),
    );
    ctl.dispose();
  }

  Widget _shiftTab() {
    final cur = store.days[dayKey(_d)];
    final att = store.attend[dayKey(_d)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('선택', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final s in kShifts)
            _choice(
              selected: cur == s.id,
              onTap: () {
                store.setShift(_d, s.id);
                _toast('근무를 변경했어요');
              },
              child: ShiftBadge(s, size: 46),
            ),
          _choice(
            selected: false,
            onTap: () {
              store.setShift(_d, null);
              _toast('근무를 지웠어요');
            },
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Icon(Icons.close, color: Colors.grey),
            ),
          ),
        ]),
        const SizedBox(height: 28),
        Row(children: [
          const Text('근태', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(onPressed: _editAttend, child: const Text('편집 >')),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in store.attendTypes)
            ChoiceChip(
              label: Text(a),
              selected: att == a,
              onSelected: (v) {
                store.setAttend(_d, v ? a : null);
                _toast(v ? '근태를 변경했어요' : '근태를 지웠어요');
              },
            ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shift = store.shiftOn(_d);
    final hol = store.holidayName(_d);
    final att = store.attend[dayKey(_d)];

    return Stack(children: [
      Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(children: [
            Text(
              DateFormat('M월 d일 EEEE', 'ko_KR').format(_d),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Text(lunarFull(_d), style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
        ),
        Row(children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _move(-1)),
          Expanded(
            child: Column(children: [
              if (shift != null)
                ShiftBadge(shift, size: 56)
              else
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Icon(Icons.remove, color: Colors.grey.shade400),
                ),
              if (hol != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(hol,
                      style: const TextStyle(
                          color: kRed, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              if (att != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(att, style: const TextStyle(color: kRed, fontSize: 12)),
                ),
            ]),
          ),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _move(1)),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [_tabBtn('메모', 0), const SizedBox(width: 16), _tabBtn('근무', 1)]),
        ),
        const Divider(height: 1),
        Expanded(child: _tab == 0 ? _memoTab() : _shiftTab()),
      ]),
      if (_flash != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xDD333333),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(_flash!, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ),
    ]);
  }
}
