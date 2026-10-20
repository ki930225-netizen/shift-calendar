import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';
import 'store.dart';

const List<String> _dowName = ['', '월', '화', '수', '목', '금', '토', '일']; // 1=월 ... 7=일
const Color _red = Color(0xFFE5495B);
const Color _blue = Color(0xFF3F7DE0);

/// 주별 패턴: 요일마다 근무를 정하고, 쉬는 날 / 쉬는 날 전날 규칙을 붙여서 기간에 일괄 적용
class WeekPatternPage extends StatefulWidget {
  const WeekPatternPage({super.key});

  @override
  State<WeekPatternPage> createState() => _WeekPatternPageState();
}

class _WeekPatternPageState extends State<WeekPatternPage> {
  late Map<int, String> week = Map<int, String>.of(store.weekPattern);
  late String? before = store.weekBefore;
  late bool sat = store.weekRestSat;
  late bool sun = store.weekRestSun;
  late bool hol = store.weekRestHol;
  DateTime start = DateTime.now();
  int weeks = 8;

  Widget _pick({required bool selected, required VoidCallback onTap, required Widget child}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.blue : Colors.transparent, width: 2.5),
        ),
        child: child,
      ),
    );
  }

  Widget _none(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Icon(Icons.remove, size: size * 0.5, color: Colors.grey.shade400),
    );
  }

  Widget _dayRow(int wd) {
    final cur = week[wd];
    Color? c;
    if (wd == 7) c = _red;
    if (wd == 6) c = _blue;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 34,
          child: Text(_dowName[wd],
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: c)),
        ),
        Expanded(
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            for (final s in kShifts)
              _pick(
                selected: cur == s.id,
                onTap: () => setState(() => week[wd] = s.id),
                child: ShiftBadge(s, size: 30),
              ),
            _pick(
              selected: cur == null,
              onTap: () => setState(() => week.remove(wd)),
              child: _none(30),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _card(String title, Widget child, {String? hint}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.blue, fontSize: 13)),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(hint, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }

  void _example() {
    setState(() {
      week = {1: 'N', 2: 'N', 3: 'N', 4: 'N', 5: 'D'};
      sat = true;
      sun = true;
      hol = true;
      before = null;
    });
  }

  String? _shiftFor(DateTime d) => store.weekShiftFor(d, week,
      restSat: sat, restSun: sun, restHol: hol, beforeRest: before);

  Widget _preview() {
    final cells = <Widget>[];
    for (int i = 0; i < 14; i++) {
      final d = DateTime(start.year, start.month, start.day + i);
      final sid = _shiftFor(d);
      final shift = shiftById(sid);
      final holName = store.holidayName(d);
      Color? c;
      if (d.weekday == DateTime.sunday || holName != null) c = _red;
      if (d.weekday == DateTime.saturday && holName == null) c = _blue;
      cells.add(Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${d.month}/${d.day}', style: TextStyle(fontSize: 10, color: c ?? Colors.black54)),
        Text(_dowName[d.weekday], style: TextStyle(fontSize: 10, color: c ?? Colors.black54)),
        const SizedBox(height: 2),
        SizedBox(
          height: 26,
          child: shift == null ? null : ShiftBadge(shift, size: 24),
        ),
      ]));
    }
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: cells.sublist(0, 7)),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: cells.sublist(7, 14)),
    ]);
  }

  void _apply() {
    final anyDay = week.isNotEmpty || sat || sun || hol;
    if (!anyDay) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('요일별 근무를 하나 이상 정해 주세요')));
      return;
    }
    final m = ScaffoldMessenger.of(context);
    store.applyWeekPattern(
      start,
      weeks * 7,
      week,
      restSat: sat,
      restSun: sun,
      restHol: hol,
      beforeRest: before,
    );
    Navigator.pop(context);
    m.showSnackBar(SnackBar(content: Text('$weeks주 동안 근무를 입력했어요')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1F3F6),
        title: const Text('주별 패턴', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _apply,
            child: const Text('적용', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _card(
            '요일별 근무',
            Column(children: [
              for (final wd in const [1, 2, 3, 4, 5, 6, 7]) _dayRow(wd),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _example,
                  child: const Text('예시 채우기 (월~목 N, 금 D, 쉬는 날 휴)'),
                ),
              ),
            ]),
            hint: '"–" 로 두면 그 요일은 건드리지 않아요',
          ),
          _card(
            '쉬는 날은 "휴"로',
            Wrap(spacing: 8, children: [
              FilterChip(
                label: const Text('토요일'),
                selected: sat,
                onSelected: (v) => setState(() => sat = v),
              ),
              FilterChip(
                label: const Text('일요일'),
                selected: sun,
                onSelected: (v) => setState(() => sun = v),
              ),
              FilterChip(
                label: const Text('공휴일'),
                selected: hol,
                onSelected: (v) => setState(() => hol = v),
              ),
            ]),
            hint: '고른 날은 자동으로 휴가 입력됩니다',
          ),
          _card(
            '쉬는 날 전날 근무',
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final s in kShifts)
                _pick(
                  selected: before == s.id,
                  onTap: () => setState(() => before = s.id),
                  child: ShiftBadge(s, size: 30),
                ),
              _pick(
                selected: before == null,
                onTap: () => setState(() => before = null),
                child: _none(30),
              ),
            ]),
            hint: '위에서 고른 쉬는 날의 전날(예: 금요일, 공휴일 전날)은 요일 근무 대신 이 근무가 들어가요. '
                '"–" 이면 쓰지 않습니다.',
          ),
          _card(
            '적용 기간',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                    lastDate: DateTime(2035),
                  );
                  if (p != null) setState(() => start = p);
                },
              ),
              Row(children: [
                const Text('기간'),
                const Spacer(),
                DropdownButton<int>(
                  value: weeks,
                  items: const [2, 4, 8, 12, 26, 52]
                      .map((e) => DropdownMenuItem<int>(value: e, child: Text('$e주')))
                      .toList(),
                  onChanged: (v) => setState(() => weeks = v ?? weeks),
                ),
              ]),
              const Text('※ 해당 기간의 기존 근무가 바뀝니다.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
          _card('미리보기 (시작일부터 2주)', _preview()),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: FilledButton(
              onPressed: _apply,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: const Text('이대로 적용', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
