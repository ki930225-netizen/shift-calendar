import 'ical.dart' show builtinHolidays;
import 'lunar.dart' show lunarHolidays;
import 'models.dart' show two;

/// 인터넷 없이 앱이 직접 계산하는 공휴일 (양력 고정 + 설날·추석·부처님오신날 + 대체공휴일)
final Map<int, Map<String, String>> _allHolCache = {};

String _hk(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

DateTime _pk(String k) {
  final p = k.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

class _Grp {
  final List<DateTime> dates;
  final bool sat; // 토요일과 겹쳐도 대체공휴일 (설날·추석은 일요일만)
  final bool overlap; // 다른 공휴일과 겹침 (어린이날 + 부처님오신날)
  _Grp(this.dates, this.sat, this.overlap);
}

List<DateTime> _datesWhere(Map<String, String> m, bool Function(String) test) {
  final l = <DateTime>[];
  m.forEach((k, v) {
    if (test(v)) l.add(_pk(k));
  });
  l.sort((a, b) => a.compareTo(b));
  return l;
}

Map<String, String> allBuiltinHolidays(int y) {
  return _allHolCache.putIfAbsent(y, () {
    final solar = builtinHolidays(y);
    final lunar = lunarHolidays(y);
    final out = <String, String>{};
    solar.forEach((k, v) => out[k] = v);
    lunar.forEach((k, v) {
      final old = out[k];
      out[k] = old == null ? v : '$old·$v';
    });

    final groups = <_Grp>[];
    if (y >= 2014) {
      final seol = _datesWhere(lunar, (n) => n == '설날' || n == '설날 연휴');
      if (seol.isNotEmpty) groups.add(_Grp(seol, false, false));
      final chu = _datesWhere(lunar, (n) => n == '추석' || n == '추석 연휴');
      if (chu.isNotEmpty) groups.add(_Grp(chu, false, false));
      for (final d in _datesWhere(solar, (n) => n == '어린이날')) {
        groups.add(_Grp([d], true, lunar.containsKey(_hk(d))));
      }
    }
    if (y >= 2021) {
      for (final name in ['삼일절', '광복절', '개천절', '한글날']) {
        for (final d in _datesWhere(solar, (n) => n == name)) {
          groups.add(_Grp([d], true, false));
        }
      }
    }
    if (y >= 2023) {
      for (final d in _datesWhere(solar, (n) => n == '성탄절')) {
        groups.add(_Grp([d], true, false));
      }
      for (final d in _datesWhere(lunar, (n) => n == '부처님오신날')) {
        groups.add(_Grp([d], true, false));
      }
    }
    groups.sort((a, b) => a.dates.first.compareTo(b.dates.first));

    for (final g in groups) {
      var hit = g.overlap;
      for (final d in g.dates) {
        if (d.weekday == DateTime.sunday) hit = true;
        if (g.sat && d.weekday == DateTime.saturday) hit = true;
      }
      if (!hit) continue;
      final last = g.dates.last;
      var n = DateTime(last.year, last.month, last.day + 1);
      while (n.weekday == DateTime.saturday ||
          n.weekday == DateTime.sunday ||
          out.containsKey(_hk(n))) {
        n = DateTime(n.year, n.month, n.day + 1);
      }
      out[_hk(n)] = '대체공휴일';
    }
    return out;
  });
}
