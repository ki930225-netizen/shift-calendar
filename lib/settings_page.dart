import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';

import 'models.dart';
import 'store.dart';

// ───────────────────────── 설정 탭 ─────────────────────────

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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
            subtitle: const Text('예) D → D → N → N → 휴 → 휴 반복 입력'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog(context: context, builder: (_) => const PatternDialog()),
          ),
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
          const SizedBox(height: 32),
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
