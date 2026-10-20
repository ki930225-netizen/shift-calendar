import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';

import 'models.dart';
import 'native.dart';
import 'stats_page.dart';
import 'store.dart';
import 'week_page.dart';

// ───────────────────────── 설정 탭 ─────────────────────────

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url = TextEditingController(text: store.icalUrl);
  String _testMsg = '';

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

  Future<void> _pickCalendars() async {
    final cals = await deviceCalendars();
    if (!mounted) return;
    if (cals.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('폰에서 캘린더를 찾지 못했어요 (권한을 확인하세요)')));
      return;
    }
    final sel = <int>{...store.deviceCalSel};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('연동할 캘린더'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in cals)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${c['name']}'),
                    subtitle: Text('${c['account']}', style: const TextStyle(fontSize: 11)),
                    value: sel.contains((c['id'] as num).toInt()),
                    onChanged: (v) => setS(() {
                      final id = (c['id'] as num).toInt();
                      if (v == true) {
                        sel.add(id);
                      } else {
                        sel.remove(id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('확인')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    store.deviceCalSel = sel.toList();
    await store.save(resched: false);
    await store.syncDevice();
  }

  Future<void> _restore() async {
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('복원 (현재 데이터 덮어씀)')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await store.importJson(ctl.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(done ? '복원되었습니다' : '백업 형식이 올바르지 않습니다')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정', style: TextStyle(fontWeight: FontWeight.bold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.auto_fix_high),
            title: const Text('교대 패턴 일괄 적용'),
            subtitle: const Text('예) D → D → N → N → 휴 → 휴 반복 입력\n'
                '토·일·공휴일은 휴로 두고 나머지 날에만 패턴을 이어갈 수도 있어요'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog(context: context, builder: (_) => const PatternDialog()),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_busy),
            title: const Text('쉬는 날(토·일·공휴일) 휴로 일괄 입력'),
            subtitle: const Text('기간을 정하면 토요일·일요일·공휴일을 한 번에 "휴"로 채웁니다'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog(
                context: context, builder: (_) => const PatternDialog(restOnly: true)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.view_week),
            title: const Text('주별 패턴 (요일별 근무)'),
            subtitle: const Text('예) 월~목 N, 금 D, 쉬는 날 전날은 D, 토·일·공휴일은 휴'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const WeekPatternPage())),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bar_chart),
            title: const Text('근무 통계'),
            subtitle: const Text('월별 근무 일수, 총 근무시간, 야간 횟수'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const StatsPage())),
          ),
          const Divider(height: 32),
          Text('폰 캘린더 연동', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('폰에 등록된 캘린더 바로 가져오기'),
            subtitle: const Text('구글·삼성 캘린더에 들어 있는 일정(제미나이로 등록한 일정 포함)이 '
                '주소 입력 없이 달력에 나옵니다.'),
            value: store.deviceCal,
            onChanged: (v) async {
              if (v) {
                final m = await store.enableDeviceCal();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
              } else {
                await store.disableDeviceCal();
              }
            },
          ),
          if (store.deviceCal) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('연동할 캘린더 선택'),
              subtitle: Text(store.deviceMsg.isEmpty ? '선택한 캘린더의 일정만 가져옵니다' : store.deviceMsg),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickCalendars,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => store.syncDevice(),
                icon: const Icon(Icons.sync),
                label: const Text('지금 다시 읽기'),
              ),
            ),
          ],
          const Divider(height: 32),
          Text('공휴일', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('대한민국 공휴일 자동 표시'),
            subtitle: const Text('구글 "대한민국의 휴일" 캘린더를 가져옵니다.\n'
                '인터넷이 안 될 때도 설날·추석·고정 공휴일은 앱이 직접 계산합니다.'),
            value: store.holidaySync,
            onChanged: (v) {
              store.holidaySync = v;
              store.save(resched: false);
              store.syncAll();
            },
          ),
          const Divider(height: 32),
          Text('내 구글 캘린더 연결 (인터넷 주소 방식)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('위의 "폰 캘린더 연동"을 쓰면 이 항목은 필요 없어요. '
              '폰이 아닌 다른 구글 캘린더를 보고 싶을 때만 "비공개 iCal 주소"를 넣으세요.'),
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
              onPressed: _restore,
            ),
          ]),
          const Divider(height: 32),
          Text('저장 상태 점검', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '불러온 곳: ${store.loadSource.isEmpty ? '-' : store.loadSource}\n'
            '현재 데이터: 근무 ${store.days.length}일 · 알람 ${store.alarms.length}개 · 메모 ${store.memos.length}개\n'
            '마지막 저장: ${store.lastSaveAt == null ? '아직 없음' : DateFormat('HH:mm:ss').format(store.lastSaveAt!)}'
            '${store.saveNote.isEmpty ? '' : '\n${store.saveNote}'}'
            '${store.loadNote.isEmpty ? '' : '\n불러오기 메모: ${store.loadNote}'}',
            style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
              onPressed: () async {
                final m = await store.storageSelfTest();
                if (mounted) setState(() => _testMsg = m);
              },
              child: const Text('저장 테스트'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () async {
                await store.save(resched: false);
                if (mounted) setState(() {});
              },
              child: const Text('지금 저장'),
            ),
          ]),
          if (_testMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_testMsg, style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ───────────────────────── 패턴 일괄 적용 ─────────────────────────

class PatternDialog extends StatefulWidget {
  final bool restOnly; // true: 패턴 없이 쉬는 날만 휴로 채우기
  final DateTime? start;
  final int? count;
  const PatternDialog({super.key, this.restOnly = false, this.start, this.count});

  @override
  State<PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<PatternDialog> {
  late DateTime start = widget.start ?? DateTime.now();
  late int count = widget.count ?? 90;
  late List<String> seq = widget.restOnly ? <String>[] : List<String>.of(store.pattern);
  late bool useRest = widget.restOnly;
  bool restSat = true;
  bool restSun = true;
  bool restHol = true;

  bool get _canApply => seq.isNotEmpty || (useRest && (restSat || restSun || restHol));

  @override
  Widget build(BuildContext context) {
    final opts = <int>{30, 60, 90, 180, 365, count}.toList()..sort();
    return AlertDialog(
      title: Text(widget.restOnly ? '쉬는 날 휴로 일괄 입력' : '교대 패턴 일괄 적용'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.restOnly) ...[
              const Text('아래 근무를 눌러 반복할 순서를 만드세요.\n예) D → D → N → N → 휴 → 휴'),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (int i = 0; i < seq.length; i++)
                  GestureDetector(
                    onTap: () => setState(() => seq.removeAt(i)),
                    child: Stack(clipBehavior: Clip.none, children: [
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: ShiftBadge(shiftById(seq[i]) ?? kShifts.first, size: 30),
                      ),
                      const Positioned(
                        right: 0,
                        top: 0,
                        child: Icon(Icons.cancel, size: 14, color: Colors.grey),
                      ),
                    ]),
                  ),
                if (seq.isEmpty) const Text('(비어 있음)', style: TextStyle(color: Colors.grey)),
              ]),
              const SizedBox(height: 8),
              const Text('추가', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in kShifts)
                  GestureDetector(
                    onTap: () => setState(() => seq.add(s.id)),
                    child: ShiftBadge(s, size: 32),
                  ),
              ]),
              const Divider(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('쉬는 날은 "휴"로, 나머지 날에만 패턴 이어가기'),
                subtitle: const Text('패턴 순서는 쉬는 날을 건너뛰고 평일에만 이어집니다'),
                value: useRest,
                onChanged: (v) => setState(() => useRest = v),
              ),
            ],
            if (useRest) ...[
              const Text('쉬는 날로 칠 날', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                FilterChip(
                  label: const Text('토요일'),
                  selected: restSat,
                  onSelected: (v) => setState(() => restSat = v),
                ),
                FilterChip(
                  label: const Text('일요일'),
                  selected: restSun,
                  onSelected: (v) => setState(() => restSun = v),
                ),
                FilterChip(
                  label: const Text('공휴일'),
                  selected: restHol,
                  onSelected: (v) => setState(() => restHol = v),
                ),
              ]),
            ],
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
                items: opts
                    .map((e) => DropdownMenuItem<int>(value: e, child: Text('$e일')))
                    .toList(),
                onChanged: (v) => setState(() => count = v ?? count),
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
          onPressed: !_canApply
              ? null
              : () {
                  store.applyPattern(
                    start,
                    count,
                    seq,
                    restSat: useRest && restSat,
                    restSun: useRest && restSun,
                    restHol: useRest && restHol,
                  );
                  Navigator.pop(context);
                },
          child: const Text('적용'),
        ),
      ],
    );
  }
}
