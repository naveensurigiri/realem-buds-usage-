import 'dart:typed_data';

// Frame layout (from a real Realme Link capture):
// AA, len, 00, 00, cmdHi, cmdLo, seq, payloadLen(2, LE), payload...
// len = total bytes - 2.

const int cmdInfo = 0x0001;
const int cmdBatteryQuery = 0x0601;
const int cmdBatteryReply = 0x0681;
const int cmdModeQuery = 0x0C01;
const int cmdModeReply = 0x0C81;
const int cmdNotify = 0x0402;

const int modeNormal = 0x01;
const int modeTransparency = 0x02;
const int modeAnc = 0x08;

String modeName(int? code) {
  switch (code) {
    case modeTransparency:
      return 'Transparency';
    case modeAnc:
      return 'ANC';
    case modeNormal:
      return 'Normal';
    default:
      return 'Unknown';
  }
}

Uint8List buildFrame(int cmd, int seq, List<int> payload) {
  final total = 9 + payload.length;
  return Uint8List.fromList([
    0xAA,
    total - 2,
    0x00,
    0x00,
    (cmd >> 8) & 0xFF,
    cmd & 0xFF,
    seq & 0xFF,
    payload.length & 0xFF,
    (payload.length >> 8) & 0xFF,
    ...payload,
  ]);
}

class Frame {
  final int cmd;
  final int seq;
  final Uint8List payload;
  const Frame(this.cmd, this.seq, this.payload);
}

/// Rebuilds frames from a byte stream that may arrive in pieces.
class FrameReader {
  final List<int> _buf = [];

  List<Frame> add(List<int> data) {
    _buf.addAll(data);
    final frames = <Frame>[];
    while (true) {
      final start = _buf.indexOf(0xAA);
      if (start < 0) {
        _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 9) break;
      if (_buf[2] != 0 || _buf[3] != 0) {
        _buf.removeAt(0);
        continue;
      }
      final total = _buf[1] + 2;
      final plen = _buf[7] | (_buf[8] << 8);
      if (total != 9 + plen) {
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < total) break;
      frames.add(Frame(
        (_buf[4] << 8) | _buf[5],
        _buf[6],
        Uint8List.fromList(_buf.sublist(9, total)),
      ));
      _buf.removeRange(0, total);
    }
    return frames;
  }
}

class Battery {
  final int? left;
  final int? right;
  final int? caseLevel;
  const Battery({this.left, this.right, this.caseLevel});
}

int? _pct(int? v) => (v != null && v >= 1 && v <= 100) ? v : null;

/// Battery reply payload: status, count, then (id, value) pairs.
/// Ids 1, 2 and 3 are read as left, right and case. A value of 0 is treated as unknown.
Battery? parseBattery(Frame f) {
  if (f.cmd != cmdBatteryReply) return null;
  final p = f.payload;
  if (p.length < 2 || p[0] != 0) return null;
  final values = <int, int>{};
  for (var i = 0; i < p[1] && 3 + i * 2 < p.length; i++) {
    values[p[2 + i * 2]] = p[3 + i * 2];
  }
  return Battery(
    left: _pct(values[1]),
    right: _pct(values[2]),
    caseLevel: _pct(values[3]),
  );
}

/// Mode from a query reply (00 01 01 XX) or a change notification (03 01 01 XX).
int? parseMode(Frame f) {
  final p = f.payload;
  if (p.length != 4 || p[1] != 1 || p[2] != 1) return null;
  if (f.cmd == cmdModeReply && p[0] == 0) return p[3];
  if (f.cmd == cmdNotify && p[0] == 3) return p[3];
  return null;
}
