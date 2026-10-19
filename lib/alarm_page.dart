import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

/// 근무별 알람 탭: "이 근무인 날, 이 시각(24시간제)에 울려라"
class AlarmPage extends StatefulWidget {
  const AlarmPage({super.key});

  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    store.addListener(_r);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _r());
  }

  @override
  void dispose() {
    _timer?.cancel();
    store.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  String _remain(DateTime when) {
    final diff = when.difference(DateTime.now());
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    final mins = diff.inMinutes % 60;
    if (days > 0) return '$days일 $hours시간 후에 울려요';
    if (diff.inHours > 0) return '${diff.inHours}시간 $mins분 후에 울려요';
    if (diff.inMinutes > 0) return '${diff.inMinutes}분 후에 울려요';
    return '곧 울려요';
  }

  Future<void> _edit(AlarmItem? a) async {
    int minutes = a?.minutes ?? 7 * 60;
    String sid = a?.shiftId ?? 'D';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(a == null ? '알람 추가' : '알람 수정'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('아래 근무인 날에 울립니다', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in kShifts)
                    GestureDetector(
                      onTap: () => setS(() => sid = s.id),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: sid == s.id ? Colors.blue : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                        child: ShiftBadge(s, size: 34),
                      ),
                    ),
                ]),
                const SizedBox(height: 20),
                Center(
                  child: InkWell(
                    onTap: () async {
                      final v = await pickTime24(ctx, minutes);
                      if (v != null) setS(() => minutes = v);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text(fmtHM(minutes),
                          style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w300)),
                    ),
                  ),
                ),
                const Center(
                  child: Text('시각을 눌러 변경 (24시간제)',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ],
            ),
          ),
          actions: [
            if (a != null)
              TextButton(
                onPressed: () {
                  store.deleteAlarm(a.id);
                  Navigator.pop(ctx);
                },
                child: const Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
              onPressed: () {
                store.upsertAlarm(AlarmItem(
                  id: a?.id ?? store.newId(),
                  minutes: minutes,
                  shiftId: sid,
                  enabled: a?.enabled ?? true,
                ));
                Navigator.pop(ctx);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final next = store.nextAlarm();
    final list = List<AlarmItem>.of(store.alarms)
      ..sort((a, b) {
        final ia = kShifts.indexWhere((s) => s.id == a.shiftId);
        final ib = kShifts.indexWhere((s) => s.id == b.shiftId);
        final c = ia.compareTo(ib);
        return c != 0 ? c : a.minutes.compareTo(b.minutes);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('알람', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton.filled(
            tooltip: '알람 추가',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(null),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          if (next != null) ...[
            Center(child: ShiftBadge(shiftById(next.alarm.shiftId) ?? kShifts.first, size: 40)),
            const SizedBox(height: 10),
            Center(
              child: Text(_remain(next.when),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
            ),
          ] else
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('울릴 알람이 없어요',
                    style: TextStyle(fontSize: 22, color: Colors.grey)),
              ),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.sort, size: 18, color: Colors.grey),
              const SizedBox(width: 6),
              const Text('근무 타입 순', style: TextStyle(color: Colors.grey)),
              const Spacer(),
              TextButton(
                onPressed: list.isEmpty ? null : () => store.setAllAlarms(false),
                child: const Text('전체 끄기'),
              ),
            ]),
          ),
          const Divider(height: 1),
          if (list.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                '오른쪽 위 + 버튼으로 알람을 추가하세요.\n'
                '예) N 근무인 날 18:30에 알람\n'
                '지정한 근무가 달력에 입력된 날에만 울립니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, height: 1.6),
              ),
            ),
          for (final a in list)
            InkWell(
              onTap: () => _edit(a),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fmtHM(a.minutes),
                          style: TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w300,
                            color: a.enabled ? null : Colors.grey.shade400,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Opacity(
                          opacity: a.enabled ? 1 : 0.4,
                          child: ShiftBadge(shiftById(a.shiftId) ?? kShifts.first, size: 24),
                        ),
                      ],
                    ),
                  ),
                  Switch(value: a.enabled, onChanged: (v) => store.setAlarmEnabled(a.id, v)),
                ]),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
