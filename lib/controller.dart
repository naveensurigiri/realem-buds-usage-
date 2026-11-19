import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';
import 'rfcomm.dart';

enum LinkState { idle, connecting, connected, retrying }

enum PermState { unknown, granted, denied, retrying }

class ModeStat {
  int count = 0;
  int seconds = 0;
}

class DailyStat {
  int seconds = 0;
  final Map<int, int> modeSeconds = {modeAnc: 0, modeTransparency: 0, modeNormal: 0};
}

class BudsController extends ChangeNotifier {
  final Rfcomm _link = Rfcomm();
  final FrameReader _reader = FrameReader();
  SharedPreferences? _prefs;

  LinkState state = LinkState.idle;
  String message = 'Not connected';
  PermState permission = PermState.unknown;
  List<BondedDevice> bonded = [];
  String? address;
  String notes = '';
  Battery battery = const Battery();
  int? modeCode;
  DateTime? connectedAt;
  final Map<int, ModeStat> stats = {
    modeAnc: ModeStat(),
    modeTransparency: ModeStat(),
    modeNormal: ModeStat(),
  };
  final Map<String, DailyStat> dailyStats = {};

  DateTime? _modeSince;
  Timer? _poll;
  Timer? _retry;
  int _seq = 0;
  int _attempt = 0;
  bool _want = false;

  // Aggressive request throttling — user: "send very less requests per minute, don't over throttle the model"
  static const int minRequestIntervalMs = 30000; // 30 seconds between request batches
  DateTime? _lastRequestTime;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    address = _prefs!.getString('address');
    notes = _prefs!.getString('notes') ?? '';
    final raw = _prefs!.getString('stats');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in m.entries) {
          final s = stats[int.parse(e.key)];
          if (s != null) {
            s.count = (e.value as List)[0] as int;
            s.seconds = (e.value as List)[1] as int;
          }
        }
      } catch (_) {}
    }
    final rawDaily = _prefs!.getString('dailyStats');
    if (rawDaily != null) {
      try {
        final m = jsonDecode(rawDaily) as Map<String, dynamic>;
        for (final e in m.entries) {
          final day = dailyStats.putIfAbsent(e.key, () => DailyStat());
          final d = e.value as Map<String, dynamic>;
          day.seconds = d['seconds'] as int;
          final ms = d['modeSeconds'] as Map<String, dynamic>?;
          if (ms != null) {
            for (final me in ms.entries) {
              day.modeSeconds[int.parse(me.key)] = me.value as int;
            }
          }
        }
      } catch (_) {}
    }
    _link.listen(_onData, _onClosed);
    await loadBonded();
    if (address != null) unawaited(connect());
  }

  Future<void> loadBonded() async {
    try {
      bonded = await _link.bonded();
      permission = PermState.granted;
    } catch (e) {
      if (e is PlatformException && e.code == 'permission') {
        permission = PermState.denied;
        message = 'Bluetooth permission needed';
      } else {
        permission = PermState.denied;
        message = _errorText(e);
      }
    }
    notifyListeners();
  }

  void selectDevice(String? a) {
    address = a;
    if (a != null) _prefs?.setString('address', a);
    notifyListeners();
  }

  void setNotes(String v) {
    notes = v;
    _prefs?.setString('notes', v);
  }

  String get deviceLabel {
    for (final d in bonded) {
      if (d.address == address) return d.name.isEmpty ? d.address : d.name;
    }
    return address ?? 'None selected';
  }

  int get connectedSeconds =>
      connectedAt == null ? 0 : DateTime.now().difference(connectedAt!).inSeconds;

  int secondsIn(int mode) {
    final s = stats[mode];
    if (s == null) return 0;
    var t = s.seconds;
    if (mode == modeCode && _modeSince != null) {
      t += DateTime.now().difference(_modeSince!).inSeconds;
    }
    return t;
  }

  Future<void> connect() async {
    final a = address;
    if (a == null) return;
    _want = true;
    _retry?.cancel();
    state = LinkState.connecting;
    message = 'Connecting...';
    notifyListeners();
    try {
      await _link.connect(a);
      _attempt = 0;
      permission = PermState.granted;
      state = LinkState.connected;
      message = 'Connected';
      connectedAt = DateTime.now();
      _startPolling();
    } catch (e) {
      if (e is PlatformException && (e.code == 'permission' || _isPermError(e))) {
        _want = false;
        permission = PermState.denied;
        state = LinkState.idle;
        message = 'Bluetooth permission needed — grant Nearby devices, then tap Connect';
      } else {
        _scheduleRetry(_errorText(e));
      }
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _want = false;
    _retry?.cancel();
    _stopPolling();
    _endMode();
    try {
      await _link.disconnect();
    } catch (_) {}
    state = LinkState.idle;
    message = 'Disconnected';
    connectedAt = null;
    notifyListeners();
  }

  String _errorText(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

  bool _isPermError(PlatformException e) {
    final m = (e.message ?? '').toLowerCase();
    return m.contains('permission') || m.contains('bluetooth_scan') || m.contains('bluetooth_connect');
  }

  String get permissionLabel {
    switch (permission) {
      case PermState.granted:
        return 'Granted';
      case PermState.denied:
        return 'Denied — tap Connect to request';
      case PermState.retrying:
        return 'Requesting…';
      case PermState.unknown:
        return 'Unknown';
    }
  }

  void _scheduleRetry(String reason) {
    const delays = [2, 4, 8, 16, 30];
    final wait = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    state = LinkState.retrying;
    message = '$reason. Retrying in ${wait}s';
    _retry?.cancel();
    _retry = Timer(Duration(seconds: wait), connect);
  }

  int _next() {
    _seq = (_seq + 1) & 0xFF;
    return _seq;
  }

  void _send(Uint8List b) {
    // Throttle: enforce minimum interval between outgoing requests
    final now = DateTime.now();
    if (_lastRequestTime != null) {
      final elapsed = now.difference(_lastRequestTime!).inMilliseconds;
      if (elapsed < minRequestIntervalMs) {
        // Skip this request — too soon since last batch
        return;
      }
    }
    _lastRequestTime = now;
    unawaited(_link.send(b).catchError((Object _) {}));
  }

  void _startPolling() {
    _stopPolling();
    _send(buildFrame(cmdInfo, _next(), const []));
    _query();
    // Aggressive throttling: poll every 60s; _send() enforces 30s min interval per batch
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _query());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  // Read-only queries, the same two that Realme Link sends.
  void _query() {
    _send(buildFrame(cmdBatteryQuery, _next(), const []));
    _send(buildFrame(cmdModeQuery, _next(), const [1, 1]));
  }

  void _onData(Uint8List data) {
    for (final f in _reader.add(data)) {
      final b = parseBattery(f);
      if (b != null) battery = b;
      final m = parseMode(f);
      if (m != null) _setMode(m);
    }
    notifyListeners();
  }

  void _onClosed() {
    if (state != LinkState.connected) return;
    _stopPolling();
    _endMode();
    connectedAt = null;
    if (_want) {
      _scheduleRetry('Connection lost');
    } else {
      state = LinkState.idle;
      message = 'Disconnected';
    }
    notifyListeners();
  }

  void _closeSegment() {
    final since = _modeSince;
    final cur = modeCode;
    if (since != null && cur != null) {
      stats[cur]?.seconds += DateTime.now().difference(since).inSeconds;
      _recordDaily(cur, DateTime.now().difference(since).inSeconds);
    }
  }

  void _recordDaily(int mode, int seconds) {
    final today = _dateKey(DateTime.now());
    final day = dailyStats.putIfAbsent(today, () => DailyStat());
    day.seconds += seconds;
    day.modeSeconds[mode] = (day.modeSeconds[mode] ?? 0) + seconds;
    _save();
  }

  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _setMode(int code) {
    if (code == modeCode) return;
    _closeSegment();
    // The first mode seen after connecting is a starting point, not a switch.
    if (modeCode != null) stats[code]?.count++;
    modeCode = code;
    _modeSince = DateTime.now();
    _save();
  }

  void _endMode() {
    _closeSegment();
    modeCode = null;
    _modeSince = null;
    _save();
  }

  void _save() {
    _prefs?.setString(
      'stats',
      jsonEncode({
        for (final e in stats.entries) '${e.key}': [e.value.count, e.value.seconds],
      }),
    );
    _prefs?.setString(
      'dailyStats',
      jsonEncode({
        for (final e in dailyStats.entries)
          e.key: {
            'seconds': e.value.seconds,
            'modeSeconds': {
              for (final me in e.value.modeSeconds.entries) '${me.key}': me.value,
            },
          },
      }),
    );
  }

  // ── UI-facing state (not persisted; live session only) ──

  String activeAudioDevice = 'phone';
  bool commuteShield = true;
  String motionEnv = 'indoor';
  int handoffCount = 0;

  void toggleActiveAudioDevice() {
    activeAudioDevice = activeAudioDevice == 'phone' ? 'laptop' : 'phone';
    handoffCount++;
    notifyListeners();
  }

  void toggleCommuteShield() {
    commuteShield = !commuteShield;
    notifyListeners();
  }

  void setMotionContext(String v) {
    motionEnv = v;
    notifyListeners();
  }

  void setNoiseMode(int code) {
    if (modeCode == code) return;
    _setMode(code);
  }

  void runAcousticSealTest() {
    notifyListeners();
  }

  void updateLRBalance(int v) {
    notifyListeners();
  }

  void updateVolumeExposure(int v) {
    notifyListeners();
  }

  void clearAllData() {
    stats[modeAnc]!.count = 0;
    stats[modeAnc]!.seconds = 0;
    stats[modeTransparency]!.count = 0;
    stats[modeTransparency]!.seconds = 0;
    stats[modeNormal]!.count = 0;
    stats[modeNormal]!.seconds = 0;
    dailyStats.clear();
    _save();
    notifyListeners();
  }
}