// 음력 변환 (1900~2049). 한국 표준시(UTC+9) 기준 합삭일로 보정한 표를 사용합니다.
// 보정: 2020·2023·2026·2027·2028·2029·2031·2034년의 일부 달 (중국 기준 표와 하루 차이)

class Lunar {
  final int year;
  final int month;
  final int day;
  final bool leap;
  const Lunar(this.year, this.month, this.day, this.leap);
}

const List<int> _info = [
  0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
  0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
  0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
  0x06566, 0x0d4a0, 0x0ea50, 0x16a95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
  0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
  0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
  0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
  0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b5a0, 0x195a6,
  0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
  0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x055c0, 0x0ab60, 0x096d5, 0x092e0,
  0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
  0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
  0x0b954, 0x06aa0, 0x0ad50, 0x06b52, 0x04b60, 0x0a6e6, 0x0a570, 0x05270, 0x06a65, 0x0d930,
  0x05aa0, 0x0b6a3, 0x096d0, 0x04afb, 0x04ae0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
  0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
];

int _leapMonth(int y) => _info[y - 1900] & 0xf;

int _leapDays(int y) =>
    _leapMonth(y) == 0 ? 0 : ((_info[y - 1900] & 0x10000) != 0 ? 30 : 29);

int _monthDays(int y, int m) => (_info[y - 1900] & (0x10000 >> m)) != 0 ? 30 : 29;

int _yearDays(int y) {
  int sum = 348;
  for (int i = 0x8000; i > 0x8; i >>= 1) {
    if ((_info[y - 1900] & i) != 0) sum++;
  }
  return sum + _leapDays(y);
}

/// 양력 → 음력. 범위 밖이면 null.
Lunar? solarToLunar(DateTime d) {
  int offset = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1900, 1, 31)).inDays;
  if (offset < 0 || d.year >= 2049) return null;
  int i = 1900;
  int temp = 0;
  for (; i < 2050 && offset > 0; i++) {
    temp = _yearDays(i);
    offset -= temp;
  }
  if (offset < 0) {
    offset += temp;
    i--;
  }
  final year = i;
  final leap = _leapMonth(year);
  bool isLeap = false;
  i = 1;
  for (; i < 13 && offset > 0; i++) {
    if (leap > 0 && i == leap + 1 && !isLeap) {
      i--;
      isLeap = true;
      temp = _leapDays(year);
    } else {
      temp = _monthDays(year, i);
    }
    if (isLeap && i == leap + 1) isLeap = false;
    offset -= temp;
  }
  if (offset == 0 && leap > 0 && i == leap + 1) {
    if (isLeap) {
      isLeap = false;
    } else {
      isLeap = true;
      i--;
    }
  }
  if (offset < 0) {
    offset += temp;
    i--;
  }
  return Lunar(year, i, offset + 1, isLeap);
}

String _k(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final Map<int, Map<String, String>> _lunarHolidayCache = {};

/// 음력 기준 공휴일(설날·추석 연휴, 부처님오신날) — 인터넷 없이도 몇 년 앞까지 계산됨
Map<String, String> lunarHolidays(int year) {
  return _lunarHolidayCache.putIfAbsent(year, () {
    final out = <String, String>{};
    var d = DateTime(year, 1, 1);
    while (d.year == year) {
      final l = solarToLunar(d);
      if (l != null && !l.leap) {
        final prev = DateTime(d.year, d.month, d.day - 1);
        final next = DateTime(d.year, d.month, d.day + 1);
        if (l.month == 1 && l.day == 1) {
          out[_k(prev)] = '설날 연휴';
          out[_k(d)] = '설날';
          out[_k(next)] = '설날 연휴';
        } else if (l.month == 8 && l.day == 15) {
          out[_k(prev)] = '추석 연휴';
          out[_k(d)] = '추석';
          out[_k(next)] = '추석 연휴';
        } else if (l.month == 4 && l.day == 8) {
          out[_k(d)] = '부처님오신날';
        }
      }
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out;
  });
}

/// 달력 칸에 표시할 음력 라벨 (음력 1일·15일만)
String? lunarCellLabel(DateTime d) {
  final l = solarToLunar(d);
  if (l == null) return null;
  if (l.day == 1 || l.day == 15) return '${l.leap ? '윤' : ''}${l.month}.${l.day}';
  return null;
}

/// 날짜 시트 제목용: "음 09.23"
String lunarFull(DateTime d) {
  final l = solarToLunar(d);
  if (l == null) return '';
  return '음 ${l.leap ? '윤' : ''}${l.month.toString().padLeft(2, '0')}.${l.day.toString().padLeft(2, '0')}';
}

/// ISO 주차 (월요일 시작, 목요일이 속한 주 기준)
int isoWeekOf(DateTime d) {
  final day = DateTime.utc(d.year, d.month, d.day);
  final thursday = day.add(Duration(days: 4 - day.weekday));
  final jan1 = DateTime.utc(thursday.year, 1, 1);
  return thursday.difference(jan1).inDays ~/ 7 + 1;
}
