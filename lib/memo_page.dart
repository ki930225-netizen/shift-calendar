import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';
import 'store.dart';

/// 메모 작성/수정 화면 (제목, 색, 할 일, 기간, 알림)
class MemoEditPage extends StatefulWidget {
  final Memo? memo;
  final DateTime day;
  const MemoEditPage({super.key, this.memo, required this.day});

  @override
  State<MemoEditPage> createState() => _MemoEditPageState();
}

class _MemoEditPageState extends State<MemoEditPage> {
  final TextEditingController _title = TextEditingController();
  int _id = -1;
  String _start = '';
  String _end = '';
  bool _allDay = false;
  bool _todo = false;
  bool _done = false;
  int _startMin = 8 * 60;
  int _endMin = 9 * 60;
  int _fg = 0xFFFFFFFF;
  int _bg = 0xFF444444;
  int _alarm = -1;

  @override
  void initState() {
    super.initState();
    final m = widget.memo;
    if (m != null) {
      _id = m.id;
      _title.text = m.title;
      _start = m.start;
      _end = m.end;
      _allDay = m.allDay;
      _todo = m.todo;
      _done = m.done;
      _startMin = m.startMin;
      _endMin = m.endMin;
      _fg = m.fg;
      _bg = m.bg;
      _alarm = kMemoAlarmOptions.containsKey(m.alarmBefore) ? m.alarmBefore : -1;
    } else {
      _start = dayKey(widget.day);
      _end = _start;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _fixEnd(bool startChanged) {
    if (_end.compareTo(_start) < 0) {
      if (startChanged) {
        _end = _start;
      } else {
        _start = _end;
      }
    }
    if (_end == _start && !_allDay && _endMin <= _startMin) {
      if (startChanged) {
        _endMin = _startMin + 60 > 1439 ? 1439 : _startMin + 60;
      } else {
        _startMin = _endMin - 60 < 0 ? 0 : _endMin - 60;
      }
    }
  }

  Future<void> _pickDate(bool isStart) async {
    final cur = parseKey(isStart ? _start : _end);
    final p = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (p == null) return;
    setState(() {
      if (isStart) {
        _start = dayKey(p);
      } else {
        _end = dayKey(p);
      }
      _fixEnd(isStart);
    });
  }

  Future<void> _pickTime(bool isStart) async {
    final v = await pickTime24(context, isStart ? _startMin : _endMin);
    if (v == null) return;
    setState(() {
      if (isStart) {
        _startMin = v;
      } else {
        _endMin = v;
      }
      _fixEnd(isStart);
    });
  }

  Future<int?> _pickColor(List<int> options, int current) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in options)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == current ? Colors.blue : Colors.black26,
                      width: c == current ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('메모 내용을 입력하세요')));
      return;
    }
    final m = Memo(
      id: _id < 0 ? store.newId() : _id,
      title: title,
      start: _start,
      end: _end,
      allDay: _allDay,
      startMin: _startMin,
      endMin: _endMin,
      fg: _fg,
      bg: _bg,
      alarmBefore: _alarm,
      todo: _todo,
      done: _todo ? _done : false,
    );
    store.upsertMemo(m);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('메모를 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      store.deleteMemo(_id);
      if (mounted) Navigator.pop(context);
    }
  }

  Widget _swatch(String label, int color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(width: 6),
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Color(color),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black26),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _dtRow(String label, String key, int min, bool isStart) {
    final text = DateFormat('yyyy.MM.dd').format(parseKey(key));
    return ListTile(
      title: Text(label),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => _pickDate(isStart),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(text, style: const TextStyle(fontSize: 16)),
          ),
        ),
        if (!_allDay)
          InkWell(
            onTap: () => _pickTime(isStart),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(fmtHM(min), style: const TextStyle(fontSize: 16)),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메모'),
        centerTitle: true,
        actions: [
          if (widget.memo != null)
            IconButton(
                tooltip: '삭제',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete),
          TextButton(
            onPressed: _save,
            child: const Text('저장', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _title,
              autofocus: widget.memo == null,
              minLines: 1,
              maxLines: 3,
              style: TextStyle(color: Color(_fg), fontSize: 17),
              decoration: InputDecoration(
                filled: true,
                fillColor: Color(_bg),
                hintText: '메모를 입력하세요',
                hintStyle: TextStyle(color: Color(_fg).withAlpha(150)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          ListTile(
            title: const Text('색'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _swatch('글자', _fg, () async {
                final c = await _pickColor(kMemoFg, _fg);
                if (c != null) setState(() => _fg = c);
              }),
              _swatch('배경', _bg, () async {
                final c = await _pickColor(kMemoBg, _bg);
                if (c != null) setState(() => _bg = c);
              }),
            ]),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.check_box_outlined),
            title: const Text('할 일'),
            value: _todo,
            onChanged: (v) => setState(() => _todo = v),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('기간', style: TextStyle(color: Colors.blue, fontSize: 13)),
          ),
          SwitchListTile(
            title: const Text('하루 종일'),
            value: _allDay,
            onChanged: (v) => setState(() {
              _allDay = v;
              _fixEnd(true);
            }),
          ),
          _dtRow('시작일', _start, _startMin, true),
          _dtRow('종료일', _end, _endMin, false),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: const Text('알림'),
            trailing: DropdownButton<int>(
              value: _alarm,
              underline: const SizedBox.shrink(),
              items: [
                for (final e in kMemoAlarmOptions.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _alarm = v ?? -1),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text('※ 하루 종일 메모의 알림은 오전 9시를 기준으로 합니다.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
