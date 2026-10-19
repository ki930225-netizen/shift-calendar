import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ───────────────────────── 근무 종류 (고정) ─────────────────────────

class ShiftType {
  final String id;
  final String label;
  final Color bg;
  final Color fg;
  final bool outlined; // 흰 원 + 테두리 + 색 글자 (휴/대체/보상)
  const ShiftType(this.id, this.label, this.bg, this.fg, {this.outlined = false});
}

const List<ShiftType> kShifts = [
  ShiftType('D', 'D', Color(0xFFFFD600), Color(0xFF333333)),
  ShiftType('A', 'A', Color(0xFFFF9F43), Colors.white),
  ShiftType('F', 'F', Color(0xFF5B8DEF), Colors.white),
  ShiftType('N', 'N', Color(0xFF444444), Colors.white),
  ShiftType('JU', '주', Color(0xFF4DB6AC), Colors.white),
  ShiftType('YA', '야', Color(0xFF5C6BC0), Colors.white),
  ShiftType('OFF', '휴', Colors.white, Color(0xFFE5495B), outlined: true),
  ShiftType('SUB', '대체', Colors.white, Color(0xFF8E24AA), outlined: true),
  ShiftType('COMP', '보상', Colors.white, Color(0xFFF57C00), outlined: true),
];

ShiftType? shiftById(String? id) {
  if (id == null) return null;
  for (final s in kShifts) {
    if (s.id == id) return s;
  }
  return null;
}

class ShiftBadge extends StatelessWidget {
  final ShiftType shift;
  final double size;
  final bool selected;
  const ShiftBadge(this.shift, {super.key, this.size = 28, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final len = shift.label.length;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: shift.bg,
        shape: BoxShape.circle,
        border: shift.outlined ? Border.all(color: const Color(0xFFE0E0E0), width: 1.2) : null,
      ),
      child: Text(
        shift.label,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          color: shift.fg,
          fontWeight: FontWeight.bold,
          fontSize: len > 1 ? size * 0.38 : size * 0.52,
        ),
      ),
    );
  }
}

// ───────────────────────── 메모 / 알람 모델 ─────────────────────────

String two(int n) => n.toString().padLeft(2, '0');

/// 분(0~1439) → "07:15" (24시간제)
String fmtHM(int min) => '${two(min ~/ 60)}:${two(min % 60)}';

final _keyFmt = DateFormat('yyyy-MM-dd');
String dayKey(DateTime d) => _keyFmt.format(d);

DateTime parseKey(String k) {
  final p = k.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

/// 메모 글자색/배경색 선택지
const List<int> kMemoBg = [
  0xFF444444, 0xFF5B8DEF, 0xFFE5495B, 0xFFFF9F43, 0xFF4DB6AC,
  0xFF8E8EF5, 0xFFFFD600, 0xFFBDBDBD, 0xFFFFC8DD, 0xFFCAFFBF,
];
const List<int> kMemoFg = [0xFFFFFFFF, 0xFF333333, 0xFFE5495B, 0xFF1565C0];

/// 알림 선택지: 시작 시각 기준 몇 분 전 (-1 = 알림 없음)
const Map<int, String> kMemoAlarmOptions = {
  -1: '알림 없음',
  0: '정각',
  10: '10분 전',
  30: '30분 전',
  60: '1시간 전',
  180: '3시간 전',
  1440: '1일 전',
};

class Memo {
  int id;
  String title;
  String start; // yyyy-MM-dd
  String end; // yyyy-MM-dd (여러 날에 걸치면 시작보다 뒤)
  bool allDay;
  int startMin;
  int endMin;
  int fg;
  int bg;
  int alarmBefore;
  bool todo;
  bool done;

  Memo({
    required this.id,
    this.title = '',
    required this.start,
    required this.end,
    this.allDay = false,
    this.startMin = 8 * 60,
    this.endMin = 9 * 60,
    this.fg = 0xFFFFFFFF,
    this.bg = 0xFF444444,
    this.alarmBefore = -1,
    this.todo = false,
    this.done = false,
  });

  bool covers(String k) => k.compareTo(start) >= 0 && k.compareTo(end) <= 0;

  String get timeText => allDay ? '하루 종일' : '${fmtHM(startMin)} - ${fmtHM(endMin)}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start,
        'end': end,
        'allDay': allDay,
        'startMin': startMin,
        'endMin': endMin,
        'fg': fg,
        'bg': bg,
        'alarmBefore': alarmBefore,
        'todo': todo,
        'done': done,
      };

  factory Memo.fromJson(Map<String, dynamic> j) => Memo(
        id: j['id'],
        title: j['title'] ?? '',
        start: j['start'],
        end: j['end'],
        allDay: j['allDay'] ?? false,
        startMin: j['startMin'] ?? 480,
        endMin: j['endMin'] ?? 540,
        fg: j['fg'] ?? 0xFFFFFFFF,
        bg: j['bg'] ?? 0xFF444444,
        alarmBefore: j['alarmBefore'] ?? -1,
        todo: j['todo'] ?? false,
        done: j['done'] ?? false,
      );
}

/// 근무별 알람: shiftId 근무인 날, 그날 minutes(0~1439) 시각에 울림
class AlarmItem {
  int id;
  int minutes;
  String shiftId;
  bool enabled;

  AlarmItem({required this.id, required this.minutes, required this.shiftId, this.enabled = true});

  Map<String, dynamic> toJson() =>
      {'id': id, 'minutes': minutes, 'shiftId': shiftId, 'enabled': enabled};

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
        id: j['id'],
        minutes: j['minutes'],
        shiftId: j['shiftId'],
        enabled: j['enabled'] ?? true,
      );
}

class NextAlarm {
  final DateTime when;
  final AlarmItem alarm;
  NextAlarm(this.when, this.alarm);
}

/// 24시간제 시각 선택 (오전/오후 없이 0~23시)
Future<int?> pickTime24(BuildContext context, int initMin) async {
  final p = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: initMin ~/ 60, minute: initMin % 60),
    builder: (ctx, child) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
      child: child ?? const SizedBox.shrink(),
    ),
  );
  if (p == null) return null;
  return p.hour * 60 + p.minute;
}
