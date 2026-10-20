import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, LengthLimitingTextInputFormatter, TextInputType;

import 'models.dart';
import 'native.dart';
import 'store.dart';

const List<String> _kDow = ['', '월', '화', '수', '목', '금', '토', '일']; // 1=월 ... 7=일
const List<int> _kDowOrder = [7, 1, 2, 3, 4, 5, 6]; // 화면 표시 순서: 일 월 화 수 목 금 토

String _daysText(AlarmItem a) {
  final s = a.days.toSet();
  if (s.length == 7) return '매일';
  if (s.length == 5 && !s.contains(6) && !s.contains(7)) return '평일';
  if (s.length == 2 && s.contains(6) && s.contains(7)) return '주말';
  final l = <String>[];
  for (final d in _kDowOrder) {
    if (s.contains(d)) l.add(_kDow[d]);
  }
  return l.isEmpty ? '요일 없음' : l.join('·');
}

String _offsetText(int o) => o < 0 ? '전날' : (o > 0 ? '다음날' : '당일');

/// 폰의 "알람" 볼륨을 직접 조절하는 슬라이더
class AlarmVolumeSlider extends StatefulWidget {
  const AlarmVolumeSlider({super.key});

  @override
  State<AlarmVolumeSlider> createState() => _AlarmVolumeSliderState();
}

class _AlarmVolumeSliderState extends State<AlarmVolumeSlider> {
  int _cur = 0;
  int _max = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await getAlarmVolume();
    if (!mounted) return;
    setState(() {
      if (v != null && v[1] > 0) {
        _cur = v[0];
        _max = v[1];
        _ready = true;
      } else {
        _ready = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Text('알람 볼륨은 폰 설정 > 소리 > 볼륨 > 알람 에서 조절하세요',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(_cur == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.grey),
        Expanded(
          child: Slider(
            value: _cur.toDouble(),
            min: 0,
            max: _max.toDouble(),
            divisions: _max,
            label: '$_cur / $_max',
            onChanged: (v) {
              setState(() => _cur = v.round());
              setAlarmVolume(_cur);
            },
          ),
        ),
        Text('$_cur/$_max', style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ]),
      Text(
        _cur == 0 ? '볼륨이 0이면 알람 소리가 나지 않아요' : '폰 전체의 "알람" 볼륨입니다 (모든 알람에 적용)',
        style: TextStyle(color: _cur == 0 ? Colors.red : Colors.grey, fontSize: 12),
      ),
    ]);
  }
}

/// 근무별 알람 탭: "이 근무인 날, 이 시각(24시간제)에 울려라"
class AlarmPage extends StatefulWidget {
  const AlarmPage({super.key});

  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  Timer? _timer;
  AlarmStatus? _st;
  int _seenVer = -1;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    store.addListener(_r);
    _loadStatus();
    store.pullSkipped();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      store.pullSkipped();
      _loadStatus();
      _r();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    store.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (store.schedVersion != _seenVer) {
      _seenVer = store.schedVersion;
      _loadStatus(); // 알람 등록이 끝날 때마다 상태를 새로 읽는다
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadStatus() async {
    final s = await store.alarmStatus();
    if (mounted) setState(() => _st = s);
  }

  void _refreshStatus() {
    _loadStatus();
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

  void _edit(AlarmItem? a) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AlarmEditPage(alarm: a),
    ));
  }

  Future<void> _test(bool now, int seconds) async {
    final m = await store.testAlarm(now: now, seconds: seconds);
    if (!mounted) return;
    setState(() => _msg = m);
    _refreshStatus();
  }

  Widget _statusRow(String label, bool ok, {String? fixText, VoidCallback? onFix}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(ok ? Icons.check_circle : Icons.error,
            size: 18, color: ok ? Colors.green : Colors.red),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        if (!ok && onFix != null)
          TextButton(
            onPressed: onFix,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30)),
            child: Text(fixText ?? '설정'),
          ),
      ]),
    );
  }

  Widget _checkCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 0,
      color: const Color(0xFFF4F6FA),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Builder(
          builder: (ctx) {
            final s = _st;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('알람 상태 점검', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _refreshStatus,
                ),
              ]),
              if (s == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('확인 중...', style: TextStyle(color: Colors.grey)),
                )
              else ...[
                _statusRow('알림 허용', s.notifOk,
                    fixText: '설정 열기', onFix: () => openNotificationSettings()),
                _statusRow('정확한 알람 허용', s.exactOk,
                    fixText: '허용하기', onFix: () => store.requestExact().then((_) => _refreshStatus())),
                _statusRow('배터리 제한 없음 (절전으로 알람이 꺼지는 것 방지)', s.batteryOk,
                    fixText: '허용하기',
                    onFix: () => requestIgnoreBattery().then((_) => _refreshStatus())),
                _statusRow('잠금 화면에 알람 화면 띄우기 (전체 화면 알림)', s.fullOk,
                    fixText: '허용하기',
                    onFix: () => openFullScreenSettings().then((_) => _refreshStatus())),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    const Icon(Icons.schedule, size: 18, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s.nativePending >= 0
                          ? '예약된 근무 알람 ${s.nativePending}개 · 기타 알림 ${s.pending < 0 ? '?' : s.pending}개'
                          : '예약된 알림 ${s.pending < 0 ? '?' : s.pending}개'),
                    ),
                  ]),
                ),
                if (store.schedNote.isNotEmpty)
                  Text('마지막 등록: ${store.schedNote}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                if (store.lastSchedError.isNotEmpty)
                  SelectableText('등록 오류: ${store.lastSchedError}',
                      style: const TextStyle(fontSize: 11, color: Colors.red)),
                if (store.reschedError.isNotEmpty)
                  SelectableText('자동 등록 실패: ${store.reschedError}',
                      style: const TextStyle(fontSize: 11, color: Colors.red)),
                if (store.schedWarn.isNotEmpty)
                  SelectableText('참고: ${store.schedWarn}',
                      style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                Text(store.planSummary(),
                    style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    icon: const Icon(Icons.sync, size: 18),
                    label: const Text('근무 알람 지금 다시 등록'),
                    onPressed: () async {
                      final m = ScaffoldMessenger.of(context);
                      await store.rescheduleAll();
                      _refreshStatus();
                      m.showSnackBar(SnackBar(
                          content: Text(store.reschedError.isNotEmpty
                              ? '실패: ${store.reschedError}'
                              : store.schedNote)));
                    },
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(children: [
                const Text('알람 전 미리 알림', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                DropdownButton<int>(
                  value: const [0, 10, 20, 30, 60].contains(store.preNoticeMin)
                      ? store.preNoticeMin
                      : 20,
                  items: const [0, 10, 20, 30, 60]
                      .map((e) => DropdownMenuItem<int>(
                          value: e, child: Text(e == 0 ? '끄기' : '$e분 전')))
                      .toList(),
                  onChanged: (v) {
                    store.preNoticeMin = v ?? 20;
                    store.save();
                  },
                ),
              ]),
              const Text('알람 전에 알림창에 "N분 뒤 알람"이 뜨고, 거기서 "이번 알람 끄기"를 누르면 그 회차만 꺼져요',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(children: [
                const Text('소리 점점 커지기', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                DropdownButton<int>(
                  value: const [0, 10, 20, 30, 60].contains(store.rampSec) ? store.rampSec : 20,
                  items: const [0, 10, 20, 30, 60]
                      .map((e) => DropdownMenuItem<int>(
                          value: e, child: Text(e == 0 ? '끄기' : '$e초 동안')))
                      .toList(),
                  onChanged: (v) {
                    store.rampSec = v ?? 20;
                    store.save();
                  },
                ),
              ]),
              const Text('알람이 울리면 작은 소리에서 시작해 설정한 시간 동안 점점 커져요 (볼륨 슬라이더 크기까지)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              const Text('알람 볼륨', style: TextStyle(fontWeight: FontWeight.w600)),
              const AlarmVolumeSlider(),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton.icon(
                  onPressed: () => _test(true, 0),
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text('지금 소리'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _test(false, 10),
                  icon: const Icon(Icons.timer, size: 18),
                  label: const Text('10초 뒤'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _test(false, 120),
                  icon: const Icon(Icons.timer_outlined, size: 18),
                  label: const Text('2분 뒤 (앱 종료 테스트)'),
                ),
              ]),
              if (_msg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_msg, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('알람이 안 울릴 때', style: TextStyle(fontSize: 14)),
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '1. 위 "알림 허용", "정확한 알람 허용"이 모두 초록색인지 확인\n'
                      '2. 근무 알람은 달력에 그 근무(예: N)가 입력된 날에만 울려요\n'
                      '3. 갤럭시: 설정 > 배터리 > 백그라운드 사용 제한 에서 "사용하지 않는 앱 절전"을 끄고, '
                      '"절전 상태 앱"·"깊은 절전 상태 앱" 목록에 이 앱이 있으면 빼 주세요\n'
                      '4. 방해금지 모드에서는 알람 소리가 막힐 수 있어요\n'
                      '5. 알람 볼륨이 0이 아닌지 확인',
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => openBatterySettings(),
                      child: const Text('배터리 최적화 설정 열기'),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => openAppSettings(),
                      child: const Text('이 앱의 설정 열기'),
                    ),
                  ),
                ],
              ),
            ]);
          },
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
            Center(
              child: Text(
                  '${DateFormat('M월 d일 (E) HH:mm', 'ko_KR').format(next.when)} · ${shiftById(next.alarm.shiftId)?.label ?? ''} 근무',
                  style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 8),
            Center(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(220, 44)),
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  await store.skipOnce(next);
                  m.showSnackBar(SnackBar(
                      content: Text('${DateFormat('M/d HH:mm').format(next.when)} 알람을 이번만 껐어요')));
                },
                child: const Text('이번만 끄기', style: TextStyle(fontSize: 16)),
              ),
            ),
          ] else
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('울릴 알람이 없어요',
                    style: TextStyle(fontSize: 22, color: Colors.grey)),
              ),
            ),
          for (final sk in store.skippedUpcoming().take(5))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                const Icon(Icons.alarm_off, size: 18, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      '꺼둔 회차: ${DateFormat('M/d (E) HH:mm', 'ko_KR').format(sk.when)} ${shiftById(sk.alarm.shiftId)?.label ?? ''}',
                      style: const TextStyle(color: Colors.grey)),
                ),
                TextButton(
                  onPressed: () => store.unskip(Store.alarmKey(sk)),
                  child: const Text('다시 켜기'),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          _checkCard(),
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
                          child: Row(children: [
                            ShiftBadge(shiftById(a.shiftId) ?? kShifts.first, size: 24),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '${_daysText(a)} · ${_offsetText(a.dayOffset)}'
                                '${a.sound ? ' · ${kTones[a.tone] ?? '벨'}' : ' · 무음'}'
                                '${a.vibrate ? ' · 진동' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ),
                          ]),
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

// ───────────────────────── 알람 편집 화면 ─────────────────────────

class AlarmEditPage extends StatefulWidget {
  final AlarmItem? alarm;
  const AlarmEditPage({super.key, this.alarm});

  @override
  State<AlarmEditPage> createState() => _AlarmEditPageState();
}

class _AlarmEditPageState extends State<AlarmEditPage> {
  late final int _initMin = widget.alarm?.minutes ?? 7 * 60;
  late final TextEditingController hCtl = TextEditingController(text: two(_initMin ~/ 60));
  late final TextEditingController mCtl = TextEditingController(text: two(_initMin % 60));
  final FocusNode hFocus = FocusNode();
  final FocusNode mFocus = FocusNode();
  late String sid = widget.alarm?.shiftId ?? 'D';
  late Set<int> dows = Set<int>.of(widget.alarm?.days ?? const <int>[1, 2, 3, 4, 5, 6, 7]);
  late int offset = widget.alarm?.dayOffset ?? 0;
  late String tone = widget.alarm?.tone ?? 'bell';

  /// 폰에서 소리 파일 고르기. 성공하면 true
  Future<bool> _pickFile() async {
    try {
      final name = await pickAlarmSound();
      if (name == null || name.isEmpty) return false;
      store.customSoundName = name;
      await store.save();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return false;
    }
  }
  late bool sound = widget.alarm?.sound ?? true;
  late bool vibrate = widget.alarm?.vibrate ?? true;
  late final TextEditingController label = TextEditingController(text: widget.alarm?.label ?? '');

  @override
  void initState() {
    super.initState();
    hFocus.addListener(() => _onFocus(hFocus, hCtl, 23));
    mFocus.addListener(() => _onFocus(mFocus, mCtl, 59));
  }

  @override
  void dispose() {
    label.dispose();
    hCtl.dispose();
    mCtl.dispose();
    hFocus.dispose();
    mFocus.dispose();
    super.dispose();
  }

  /// 칸에 들어가면 숫자 전체 선택(바로 덮어쓰기), 나오면 범위/두 자리로 정리
  void _onFocus(FocusNode f, TextEditingController c, int max) {
    if (f.hasFocus) {
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    } else {
      final n = (int.tryParse(c.text) ?? 0).clamp(0, max).toInt();
      c.text = two(n);
    }
  }

  int get _minutes {
    final h = (int.tryParse(hCtl.text) ?? 0).clamp(0, 23).toInt();
    final m = (int.tryParse(mCtl.text) ?? 0).clamp(0, 59).toInt();
    return h * 60 + m;
  }

  Widget _timeField(TextEditingController c, FocusNode f, int max, bool isHour) {
    return SizedBox(
      width: 96,
      child: TextField(
        controller: c,
        focusNode: f,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        textInputAction: isHour ? TextInputAction.next : TextInputAction.done,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w300),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          counterText: '',
        ),
        onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
        onChanged: (v) {
          if (v.length == 2) {
            final n = int.tryParse(v) ?? 0;
            if (n > max) {
              c.value = TextEditingValue(
                text: two(max),
                selection: const TextSelection.collapsed(offset: 2),
              );
            }
            if (isHour) {
              mFocus.requestFocus(); // 시 두 자리를 치면 바로 분 칸으로
            } else {
              f.unfocus();
            }
          }
        },
        onSubmitted: (_) {
          if (isHour) {
            mFocus.requestFocus();
          }
        },
      ),
    );
  }

  void _save() {
    if (dows.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('요일을 하나 이상 선택하세요')));
      return;
    }
    final a = widget.alarm;
    final sortedDays = dows.toList()..sort();
    store.upsertAlarm(AlarmItem(
      id: a?.id ?? store.newId(),
      minutes: _minutes,
      shiftId: sid,
      enabled: a?.enabled ?? true,
      days: sortedDays,
      dayOffset: offset,
      tone: tone,
      sound: sound,
      vibrate: vibrate,
      label: label.text.trim(),
    ));
    Navigator.pop(context);
  }

  Widget _section(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.blue, fontSize: 13)),
        const SizedBox(height: 10),
        child,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alarm;
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1F3F6),
        title: Text(a == null ? '알람 설정' : '알람 수정', style: const TextStyle(fontSize: 18)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('저장', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration:
                BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _timeField(hCtl, hFocus, 23, true),
                const Text(':', style: TextStyle(fontSize: 52, fontWeight: FontWeight.w300)),
                _timeField(mCtl, mFocus, 59, false),
              ]),
              const Text('숫자를 누르고 바로 입력하세요 (24시간제, 예: 18 : 30)',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
          _section(
            '근무에 반복',
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in kShifts)
                GestureDetector(
                  onTap: () => setState(() => sid = s.id),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: sid == s.id ? Colors.blue : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: ShiftBadge(s, size: 38),
                  ),
                ),
            ]),
          ),
          _section(
            '요일에 반복 (근무가 있는 날의 요일)',
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (final d in _kDowOrder)
                GestureDetector(
                  onTap: () => setState(() {
                    if (dows.contains(d)) {
                      dows.remove(d);
                    } else {
                      dows.add(d);
                    }
                  }),
                  child: Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dows.contains(d) ? Colors.blue : const Color(0xFFE3E6EC),
                    ),
                    child: Text(
                      _kDow[d],
                      style: TextStyle(
                        color: dows.contains(d) ? Colors.white : Colors.black54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          _section(
            '알람일',
            Row(children: [
              for (final o in const [0, -1, 1])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_offsetText(o)),
                    selected: offset == o,
                    onSelected: (_) => setState(() => offset = o),
                  ),
                ),
            ]),
          ),
          _section(
            '소리 · 진동',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('알람음'),
                value: sound,
                onChanged: (v) => setState(() => sound = v),
              ),
              if (sound)
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final e in kTones.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: tone == e.key,
                      onSelected: (_) async {
                        if (e.key == 'custom' && store.customSoundName.isEmpty) {
                          if (!await _pickFile()) return;
                        }
                        setState(() => tone = e.key);
                      },
                    ),
                ]),
              if (sound && tone == 'custom')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    const Icon(Icons.music_note, size: 18, color: Colors.blueGrey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        store.customSoundName.isEmpty ? '고른 파일이 없어요' : store.customSoundName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await _pickFile();
                        if (mounted) setState(() {});
                      },
                      child: const Text('파일 바꾸기'),
                    ),
                  ]),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('진동'),
                value: vibrate,
                onChanged: (v) => setState(() => vibrate = v),
              ),
              const SizedBox(height: 4),
              const Text('알람 볼륨', style: TextStyle(fontWeight: FontWeight.w600)),
              const AlarmVolumeSlider(),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final m = await store.testAlarm(
                      now: true, tone: tone, sound: sound, vibrate: vibrate);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('이 설정으로 지금 울려보기'),
              ),
            ]),
          ),
          _section(
            '알람 메모 (알림에 표시)',
            TextField(
              controller: label,
              maxLength: 30,
              decoration: const InputDecoration(
                hintText: '비워 두면 "오늘 N 근무"처럼 자동 표시',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (a != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextButton.icon(
                onPressed: () {
                  store.deleteAlarm(a.id);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            ),
        ],
      ),
    );
  }
}
