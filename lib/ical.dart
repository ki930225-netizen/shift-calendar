import 'dart:convert';

import 'package:http/http.dart' as http;

/// 구글 캘린더 "대한민국의 휴일" 공개 캘린더 (구글이 몇 년 앞까지 관리함)
const String kHolidayUrl =
    'https://calendar.google.com/calendar/ical/ko.south_korea%23holiday%40group.v.calendar.google.com/public/basic.ics';

/// kind: 0 = 공휴일, 1 = 기념일(쉬는 날 아님), 2 = 내 일정
class Ev {
  final String date; // yyyy-MM-dd
  final String title;
  final String? time; // HH:mm, 종일이면 null
  final int kind;

  Ev(this.date, this.title, {this.time, this.kind = 2});

  Map<String, dynamic> toJson() => {'d': date, 't': title, 'tm': time, 'k': kind};

  factory Ev.fromJson(Map<String, dynamic> j) =>
      Ev(j['d'], j['t'], time: j['tm'], kind: j['k'] ?? 2);
}

String _two(int n) => n.toString().padLeft(2, '0');
String _dk(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

final Map<int, Map<String, String>> _builtinCache = {};

/// 인터넷 없이도 계산되는 양력 고정 공휴일 (설날/추석/부처님오신날/대체공휴일은 구글 동기화로 채워짐)
Map<String, String> builtinHolidays(int y) {
  return _builtinCache.putIfAbsent(y, () {
    String k(int m, int d) => '$y-${_two(m)}-${_two(d)}';
    return {
      k(1, 1): '신정',
      k(3, 1): '삼일절',
      k(5, 5): '어린이날',
      k(6, 6): '현충일',
      k(8, 15): '광복절',
      k(10, 3): '개천절',
      k(10, 9): '한글날',
      k(12, 25): '성탄절',
    };
  });
}

Future<List<Ev>> fetchIcs(String url, DateTime from, DateTime to,
    {bool holidayCal = false}) async {
  var u = url.trim();
  if (u.startsWith('webcal://')) u = 'https://${u.substring(9)}';
  final res = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 25));
  if (res.statusCode != 200) {
    throw Exception('HTTP ${res.statusCode}');
  }
  final body = utf8.decode(res.bodyBytes, allowMalformed: true);
  if (!body.contains('BEGIN:VCALENDAR')) {
    throw Exception('캘린더 형식이 아닙니다 (주소를 확인하세요)');
  }
  return parseIcs(body, from, to, holidayCal: holidayCal);
}

List<Ev> parseIcs(String raw, DateTime from, DateTime to, {bool holidayCal = false}) {
  final text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '');
  final out = <Ev>[];
  Map<String, String>? cur;
  List<String> ex = [];
  bool allDay = false;

  for (final line in text.split('\n')) {
    if (line == 'BEGIN:VEVENT') {
      cur = {};
      ex = [];
      allDay = false;
      continue;
    }
    if (line == 'END:VEVENT') {
      final done = cur;
      if (done != null) out.addAll(_handle(done, ex, allDay, from, to, holidayCal));
      cur = null;
      continue;
    }
    final p = cur;
    if (p == null) continue;
    final i = line.indexOf(':');
    if (i < 0) continue;
    final left = line.substring(0, i);
    final val = line.substring(i + 1);
    final name = left.split(';').first.toUpperCase();
    if (name == 'DTSTART') {
      p['DTSTART'] = val;
      allDay = val.length == 8 || left.toUpperCase().contains('VALUE=DATE') &&
          !left.toUpperCase().contains('DATE-TIME');
    } else if (name == 'EXDATE') {
      ex.addAll(val.split(','));
    } else {
      p[name] = val;
    }
  }

  // 날짜 → 종일 먼저, 그다음 시간순
  out.sort((a, b) {
    final c = a.date.compareTo(b.date);
    if (c != 0) return c;
    return (a.time ?? '').compareTo(b.time ?? '');
  });
  return out;
}

DateTime? _parseDt(String v) {
  try {
    final s = v.trim();
    final y = int.parse(s.substring(0, 4));
    final m = int.parse(s.substring(4, 6));
    final d = int.parse(s.substring(6, 8));
    if (s.length < 15) return DateTime(y, m, d);
    final hh = int.parse(s.substring(9, 11));
    final mm = int.parse(s.substring(11, 13));
    final ss = int.parse(s.substring(13, 15));
    if (s.endsWith('Z')) return DateTime.utc(y, m, d, hh, mm, ss).toLocal();
    return DateTime(y, m, d, hh, mm, ss);
  } catch (_) {
    return null;
  }
}

String _unesc(String s) => s
    .replaceAll('\\n', ' ')
    .replaceAll('\\N', ' ')
    .replaceAll('\\,', ',')
    .replaceAll('\\;', ';')
    .replaceAll('\\\\', '\\');

List<Ev> _handle(Map<String, String> p, List<String> ex, bool allDay, DateTime from,
    DateTime to, bool holidayCal) {
  final ds = p['DTSTART'];
  if (ds == null) return [];
  if ((p['STATUS'] ?? '').toUpperCase() == 'CANCELLED') return [];
  final start = _parseDt(ds);
  if (start == null) return [];

  final title = _unesc(p['SUMMARY'] ?? '(제목 없음)');
  final desc = p['DESCRIPTION'] ?? '';
  int kind = 2;
  if (holidayCal) {
    kind = (desc.contains('기념일') || desc.toLowerCase().contains('observance')) ? 1 : 0;
  }

  final endRaw = p['DTEND'];
  final end = endRaw != null ? _parseDt(endRaw) : null;
  int span = 1;
  if (allDay && end != null) {
    final s0 = DateTime(start.year, start.month, start.day);
    final e0 = DateTime(end.year, end.month, end.day);
    span = e0.difference(s0).inDays.clamp(1, 31);
  }

  final exSet = <String>{};
  for (final e in ex) {
    final d = _parseDt(e);
    if (d != null) exSet.add(_dk(d));
  }

  final rr = p['RRULE'];
  final Iterable<DateTime> occ = rr == null ? [start] : _occurrences(start, _rule(rr));
  final res = <Ev>[];
  for (final o in occ) {
    if (o.isAfter(to)) break;
    if (exSet.contains(_dk(o))) continue;
    for (int k = 0; k < span; k++) {
      final d = DateTime(o.year, o.month, o.day + k);
      if (d.isBefore(from) || d.isAfter(to)) continue;
      res.add(Ev(_dk(d), title, time: allDay ? null : _hm(o), kind: kind));
    }
  }
  return res;
}

Map<String, String> _rule(String r) {
  final m = <String, String>{};
  for (final part in r.split(';')) {
    final i = part.indexOf('=');
    if (i > 0) m[part.substring(0, i).toUpperCase()] = part.substring(i + 1);
  }
  return m;
}

const Map<String, int> _wd = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// 반복 일정 펼치기 (DAILY / WEEKLY(+BYDAY) / MONTHLY(같은 날짜) / YEARLY 만 지원)
Iterable<DateTime> _occurrences(DateTime start, Map<String, String> r) sync* {
  final freq = r['FREQ'];
  final interval = int.tryParse(r['INTERVAL'] ?? '') ?? 1;
  final count = int.tryParse(r['COUNT'] ?? '');
  final untilRaw = r['UNTIL'];
  final until = untilRaw != null ? _parseDt(untilRaw) : null;
  final byday = (r['BYDAY'] ?? '')
      .split(',')
      .where((e) => e.length >= 2)
      .map((e) => _wd[e.substring(e.length - 2)])
      .whereType<int>()
      .toSet();
  final h = start.hour, mi = start.minute;

  if (freq == null || !const ['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].contains(freq)) {
    yield start;
    return;
  }

  int n = 0;
  for (int i = 0; i < 4000; i++) {
    DateTime c;
    if (freq == 'DAILY') {
      c = DateTime(start.year, start.month, start.day + i * interval, h, mi);
    } else if (freq == 'WEEKLY') {
      if (byday.isEmpty) {
        c = DateTime(start.year, start.month, start.day + i * 7 * interval, h, mi);
      } else {
        c = DateTime(start.year, start.month, start.day + i, h, mi);
        final base = DateTime(start.year, start.month, start.day - (start.weekday - 1));
        final weekNo = DateTime(c.year, c.month, c.day).difference(base).inDays ~/ 7;
        if (weekNo % interval != 0 || !byday.contains(c.weekday)) continue;
      }
    } else if (freq == 'MONTHLY') {
      c = DateTime(start.year, start.month + i * interval, start.day, h, mi);
      if (c.day != start.day) continue; // 31일 등 없는 달은 건너뜀
    } else {
      c = DateTime(start.year + i * interval, start.month, start.day, h, mi);
      if (c.month != start.month) continue; // 2/29 등
    }
    if (until != null && c.isAfter(until)) return;
    n++;
    if (count != null && n > count) return;
    yield c;
  }
}
