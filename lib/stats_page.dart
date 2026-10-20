import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';
import 'store.dart';

/// 근무 통계: 월별 근무 종류별 일수, 총 근무시간, 근태. 근무별 시작/종료 시간도 여기서 정한다.
class StatsPage extends StatefulWidget {
  final DateTime? month;
  const StatsPage({super.key, this.month});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late DateTime month = DateTime(
      (widget.month ?? DateTime.now()).year, (widget.month ?? DateTime.now()).month, 1);

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

  String _hm(int min) {
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }

  Future<void> _editTime(ShiftType s) async {
    final cur = store.shiftTimes[s.id];
    final a = await pickTime24(context, cur?[0] ?? 8 * 60);
    if (a == null || !mounted) return;
    final b = await pickTime24(context, cur?[1] ?? (a + 8 * 60) % 1440);
    if (b == null) return;
    store.shiftTimes[s.id] = [a, b];
    await store.save(resched: false);
  }

  Widget _card(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.blue, fontSize: 13)),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = store.monthStats(month);
    final total = st.counts.values.fold<int>(0, (a, b) => a + b);
    final maxV = st.counts.values.fold<int>(1, (a, b) => a > b ? a : b);
    final hasTimes = store.shiftTimes.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1F3F6),
        title: const Text('근무 통계', style: TextStyle(fontSize: 18)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() => month = DateTime(month.year, month.month - 1, 1)),
            ),
            Text(DateFormat('yyyy년 M월').format(month),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(() => month = DateTime(month.year, month.month + 1, 1)),
            ),
          ]),
          _card(
            '근무 일수 (입력된 날 $total일 · 비어 있는 날 ${st.emptyDays}일)',
            total == 0
                ? const Text('이 달에는 입력된 근무가 없어요', style: TextStyle(color: Colors.grey))
                : Column(children: [
                    for (final s in kShifts)
                      if ((st.counts[s.id] ?? 0) > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            ShiftBadge(s, size: 26),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: (st.counts[s.id] ?? 0) / maxV,
                                  minHeight: 12,
                                  backgroundColor: const Color(0xFFEDEFF3),
                                  color: s.outlined ? Colors.blueGrey.shade300 : s.bg,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 48,
                              child: Text('${st.counts[s.id]}일',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ]),
                        ),
                  ]),
          ),
          _card(
            '근무 시간',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (hasTimes) ...[
                Text('총 ${_hm(st.workMinutes)}',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                Text('야간 근무 ${st.nightDays}일 (저녁 8시 이후 시작 또는 새벽 근무)',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
              ] else
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('아래에서 근무별 시작·종료 시간을 정하면 총 근무시간이 계산돼요',
                      style: TextStyle(color: Colors.grey)),
                ),
              for (final s in kShifts)
                if (s.id != 'OFF' && s.id != 'SUB' && s.id != 'COMP')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: ShiftBadge(s, size: 26),
                    title: Text(store.shiftTimes[s.id] == null
                        ? '시간 미설정'
                        : '${fmtHM(store.shiftTimes[s.id]![0])} ~ ${fmtHM(store.shiftTimes[s.id]![1])}'
                            '  (${_hm(store.shiftMinutes(s.id) ?? 0)})'),
                    trailing: store.shiftTimes[s.id] == null
                        ? const Icon(Icons.edit, size: 18)
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              store.shiftTimes.remove(s.id);
                              store.save(resched: false);
                            },
                          ),
                    onTap: () => _editTime(s),
                  ),
              const Text('※ 끝 시간이 시작보다 이르면 다음 날로 계산해요 (예: 22:00 ~ 07:00 = 9시간)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
          if (st.attendCounts.isNotEmpty)
            _card(
              '근태',
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final e in st.attendCounts.entries)
                  Chip(label: Text('${e.key} ${e.value}일')),
              ]),
            ),
        ],
      ),
    );
  }
}
