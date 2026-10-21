import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const svcUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const gold = Color(0xFFE3A92B);
const presetNames = ['Flat', 'Speech', 'Music', 'Party', 'Night', 'Setup', 'User 1', 'User 2', 'User 3'];

class Ctl {
  final String key, label, unit;
  final double min, max, step;
  final List<String>? opts;
  final bool toggle;
  const Ctl.r(this.key, this.label, this.unit, this.min, this.max, this.step)
      : opts = null, toggle = false;
  const Ctl.t(this.key, this.label)
      : unit = '', min = 0, max = 1, step = 1, opts = null, toggle = true;
  const Ctl.s(this.key, this.label, this.opts)
      : unit = '', min = 0, max = 0, step = 1, toggle = false;
}

const groups = <String, List<Ctl>>{
  'Levels': [
    Ctl.r('woofer', 'Woofer trim', 'dB', -24, 6, .5), Ctl.r('tweeter', 'Tweeter trim', 'dB', -24, 6, .5),
    Ctl.t('woofer_inv', 'Woofer polarity inverted'), Ctl.t('tweeter_inv', 'Tweeter polarity inverted'),
  ],
  'Crossover': [
    Ctl.r('xover', 'Crossover frequency', 'Hz', 200, 8000, 10),
    Ctl.s('xover_slope', 'Slope', ['12 dB', '24 dB', '48 dB']),
  ],
  'Inputs': [
    Ctl.r('mic_gain', 'Mic gain', 'dB', -24, 60, 1), Ctl.t('mic_mute', 'Mic mute'),
    Ctl.r('line_gain', 'Line gain', 'dB', -24, 24, 1), Ctl.t('line_mute', 'Line mute'),
    Ctl.r('in_hp', 'Input high-pass (0 = off)', 'Hz', 0, 300, 5),
  ],
  'Delay': [
    Ctl.r('woofer_delay', 'Woofer delay', 'ms', 0, 10, .01), Ctl.r('tweeter_delay', 'Tweeter delay', 'ms', 0, 10, .01),
  ],
  'Protection': [
    Ctl.r('woofer_hp', 'Woofer high-pass', 'Hz', 20, 80, 1), Ctl.r('tweeter_hp', 'Tweeter high-pass', 'Hz', 1500, 8000, 50),
    Ctl.r('woofer_lim', 'Woofer limiter', 'dB', -20, 0, .5), Ctl.r('tweeter_lim', 'Tweeter limiter', 'dB', -20, 0, .5),
    Ctl.r('attack', 'Attack', 'ms', 1, 50, 1), Ctl.r('release', 'Release', 'ms', 20, 500, 10),
  ],
  'Feedback suppression (AFS)': [
    Ctl.s('afs_mode', 'Mode', ['Off', 'Auto', 'Setup']), Ctl.s('afs_sens', 'Sensitivity', ['Low', 'Med', 'High']),
    Ctl.r('afs_depth', 'Notch depth', 'dB', 3, 18, 1),
  ],
};

/// All Bluetooth logic lives here.
class Dsp extends ChangeNotifier {
  BluetoothDevice? dev;
  BluetoothCharacteristic? rx, tx;
  bool connected = false;
  String status = 'Not connected';
  Map<String, dynamic> v = {};
  List<dynamic> eq = [];
  int preset = -1;
  double mIn = -60, mWf = -60, mTw = -60;
  bool lim = false;
  String _buf = '';
  Future<void> _q = Future.value();
  final _timers = <String, Timer>{};
  StreamSubscription? _s1, _s2;

  double d(String k) => (v[k] as num?)?.toDouble() ?? 0;

  Future<void> connect(BluetoothDevice device, String pin) async {
    try {
      status = 'Connecting…';
      notifyListeners();
      await device.connect(timeout: const Duration(seconds: 12));
      try { await device.requestMtu(185); } catch (_) {}
      final svcs = await device.discoverServices();
      final s = svcs.firstWhere((x) => x.uuid == Guid(svcUuid));
      rx = s.characteristics.firstWhere((c) => c.uuid == Guid(rxUuid));
      tx = s.characteristics.firstWhere((c) => c.uuid == Guid(txUuid));
      await tx!.setNotifyValue(true);
      _s1 = tx!.onValueReceived.listen(_onData);
      _s2 = device.connectionState.listen((st) {
        if (st == BluetoothConnectionState.disconnected) _drop('Disconnected');
      });
      dev = device;
      connected = true;
      status = 'Connected';
      notifyListeners();
      send('AUTH $pin\nMETERS 1');
    } catch (e) {
      status = 'Failed: $e';
      connected = false;
      notifyListeners();
    }
  }

  void _drop(String msg) {
    _s1?.cancel(); _s2?.cancel();
    connected = false; v = {}; eq = []; preset = -1; _buf = '';
    status = msg;
    notifyListeners();
  }

  Future<void> disconnect() async { await dev?.disconnect(); _drop('Disconnected'); }

  void send(String line) {
    final c = rx;
    if (c == null) return;
    _q = _q
        .then((_) => c.write(utf8.encode('$line\n'), withoutResponse: false, allowLongWrite: true))
        .catchError((_) {});
  }

  void sendT(String k, String line) {
    _timers[k]?.cancel();
    _timers[k] = Timer(const Duration(milliseconds: 70), () => send(line));
  }

  void setVal(String key, double x) {
    v[key] = x;
    notifyListeners();
    sendT(key, 'SET $key ${x.toStringAsFixed(2)}');
  }

  void setEq(int tab, int band, int i, double x) {
    eq[tab][band][i] = x;
    notifyListeners();
    final b = eq[tab][band];
    sendT('eq', 'EQ $tab $band ${(b[0] as num).toStringAsFixed(0)} ${(b[1] as num).toStringAsFixed(1)} ${(b[2] as num).toStringAsFixed(2)}');
  }

  void _onData(List<int> data) {
    _buf += utf8.decode(data, allowMalformed: true);
    int i;
    while ((i = _buf.indexOf('\n')) >= 0) {
      final l = _buf.substring(0, i).trim();
      _buf = _buf.substring(i + 1);
      if (l.isNotEmpty) _line(l);
    }
  }

  void _line(String l) {
    if (l == 'ERR pin') { status = 'Wrong PIN'; notifyListeners(); return; }
    try {
      final j = jsonDecode(l);
      if (j is! Map) return;
      if (j['t'] == 'state') {
        v = Map<String, dynamic>.from(j['v']);
        eq = j['eq'];
        preset = j['preset'];
      } else if (j['t'] == 'm') {
        mIn = (j['in'] as num).toDouble();
        mWf = (j['wf'] as num).toDouble();
        mTw = (j['tw'] as num).toDouble();
        lim = j['lim'] == 1;
      }
      notifyListeners();
    } catch (_) {}
  }
}

final dsp = Dsp();

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SAADH DSP',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0B0B0C),
          colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: Brightness.dark, primary: gold),
          cardTheme: const CardTheme(color: Color(0xFF16161A)),
        ),
        home: AnimatedBuilder(
          animation: dsp,
          builder: (_, __) => dsp.connected && dsp.v.isNotEmpty ? const ControlPage() : const ScanPage(),
        ),
      );
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final pin = TextEditingController();
  List<ScanResult> results = [];
  bool scanning = false;
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() => pin.text = p.getString('pin') ?? ''));
  }

  @override
  void dispose() { sub?.cancel(); super.dispose(); }

  Future<void> scan() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    sub?.cancel();
    sub = FlutterBluePlus.scanResults.listen((r) => setState(() => results = r));
    setState(() => scanning = true);
    await FlutterBluePlus.startScan(withServices: [Guid(svcUuid)], timeout: const Duration(seconds: 6));
    if (mounted) setState(() => scanning = false);
  }

  Future<void> pick(BluetoothDevice d) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('pin', pin.text.trim());
    await FlutterBluePlus.stopScan();
    dsp.connect(d, pin.text.trim());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SAADH DSP', style: TextStyle(letterSpacing: 2, color: gold))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: scanning ? null : scan, child: Text(scanning ? 'Scanning…' : 'Scan for DSP')),
          const SizedBox(height: 8),
          AnimatedBuilder(animation: dsp, builder: (_, __) => Text(dsp.status, style: const TextStyle(color: Colors.grey))),
          const SizedBox(height: 8),
          for (final r in results)
            Card(
              child: ListTile(
                title: Text(r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.remoteId.str),
                subtitle: Text('Signal ${r.rssi} dBm'),
                trailing: const Icon(Icons.bluetooth),
                onTap: () => pick(r.device),
              ),
            ),
        ]),
      );
}

class ControlPage extends StatelessWidget {
  const ControlPage({super.key});

  Widget slider(String label, String unit, double min, double max, double step, double val, ValueChanged<double> on, {int? div}) {
    final dv = div ?? ((max - min) / step).round().clamp(1, 2000);
    final dec = step < .1 ? 2 : (step < 1 ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text('${val.toStringAsFixed(dec)} $unit', style: const TextStyle(fontSize: 13)),
        ]),
        Slider(value: val.clamp(min, max), min: min, max: max, divisions: dv, onChanged: on),
      ]),
    );
  }

  Widget ctl(Ctl c) {
    if (c.toggle) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero, dense: true, title: Text(c.label),
        value: dsp.d(c.key) > 0.5,
        onChanged: (b) { dsp.v[c.key] = b ? 1.0 : 0.0; dsp.send('SET ${c.key} ${b ? 1 : 0}\nGET'); dsp.notifyListeners(); },
      );
    }
    if (c.opts != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (var i = 0; i < c.opts!.length; i++) ButtonSegment(value: i, label: Text(c.opts![i]))],
            selected: {dsp.d(c.key).round()},
            onSelectionChanged: (s) { dsp.send('SET ${c.key} ${s.first}\nGET'); },
          ),
        ]),
      );
    }
    return slider(c.label, c.unit, c.min, c.max, c.step, dsp.d(c.key), (x) => dsp.setVal(c.key, x));
  }

  Widget meter(String label, double db, {bool red = false}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 3),
          LinearProgressIndicator(value: ((db + 60) / 60).clamp(0.0, 1.0), minHeight: 8, color: red ? Colors.redAccent : gold),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final muted = dsp.d('mute') > 0.5;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SAADH DSP', style: TextStyle(letterSpacing: 2, color: gold)),
        actions: [IconButton(icon: const Icon(Icons.bluetooth_disabled), onPressed: dsp.disconnect)],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
          slider('Master volume', 'dB', -60, 0, 1, dsp.d('master'), (x) => dsp.setVal('master', x)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: muted ? Colors.redAccent : const Color(0xFF26231B), foregroundColor: muted ? Colors.white : null),
              onPressed: () => dsp.send('SET mute ${muted ? 0 : 1}\nGET'),
              child: Text(muted ? 'MUTED – tap to unmute' : 'MUTE'),
            ),
          ),
        ]))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Presets', style: TextStyle(color: Colors.grey)),
          Wrap(spacing: 8, children: [
            for (var i = 0; i < presetNames.length; i++)
              ChoiceChip(label: Text(presetNames[i]), selected: dsp.preset == i, onSelected: (_) => dsp.send('PRESET $i')),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (var i = 6; i < 9; i++)
              OutlinedButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text('Overwrite ${presetNames[i]}?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (ok == true) dsp.send('SAVE $i\nGET');
                },
                child: Text('Save → ${presetNames[i]}'),
              ),
          ]),
        ]))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Meters', style: TextStyle(color: Colors.grey)),
          meter('Input', dsp.mIn), meter('Woofer', dsp.mWf, red: dsp.lim), meter('Tweeter', dsp.mTw, red: dsp.lim),
        ]))),
        for (final e in groups.entries)
          Card(child: ExpansionTile(title: Text(e.key), shape: const Border(), childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              children: [for (final c in e.value) ctl(c)])),
        const Card(child: Padding(padding: EdgeInsets.all(12), child: EqCard())),
      ]),
    );
  }
}

class EqCard extends StatefulWidget {
  const EqCard({super.key});
  @override
  State<EqCard> createState() => _EqCardState();
}

class _EqCardState extends State<EqCard> {
  int tab = 0, band = 0;
  static const counts = [5, 3, 3];
  double f2s(double f) => 1000 * log(f / 20) / log(1000);
  double s2f(double s) => 20 * pow(1000, s / 1000).toDouble();

  @override
  Widget build(BuildContext context) {
    if (dsp.eq.length < 3) return const SizedBox();
    final b = dsp.eq[tab][band];
    final f = (b[0] as num).toDouble(), g = (b[1] as num).toDouble(), q = (b[2] as num).toDouble();
    Widget sl(String label, String val, double v, double min, double max, int? div, ValueChanged<double> on) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)), Text(val, style: const TextStyle(fontSize: 13)),
            ]),
            Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, onChanged: on),
          ],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Equalizer', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [ButtonSegment(value: 0, label: Text('Input')), ButtonSegment(value: 1, label: Text('Woofer')), ButtonSegment(value: 2, label: Text('Tweeter'))],
        selected: {tab},
        onSelectionChanged: (s) => setState(() { tab = s.first; band = 0; }),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (var i = 0; i < counts[tab]; i++) ChoiceChip(label: Text('Band ${i + 1}'), selected: band == i, onSelected: (_) => setState(() => band = i)),
      ]),
      sl('Frequency', '${f.round()} Hz', f2s(f), 0, 1000, null, (x) => dsp.setEq(tab, band, 0, s2f(x).roundToDouble())),
      sl('Gain', '${g.toStringAsFixed(1)} dB', g, -12, 12, 48, (x) => dsp.setEq(tab, band, 1, x)),
      sl('Q', q.toStringAsFixed(2), q, 0.3, 10, 97, (x) => dsp.setEq(tab, band, 2, x)),
    ]);
  }
}
