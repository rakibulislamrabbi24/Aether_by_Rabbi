import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RDMProApp());
}

class RDMProApp extends StatelessWidget {
  const RDMProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RDM Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        primaryColor: const Color(0xFF00F0FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F0FF),
          secondary: Color(0xFF00FF87),
          surface: Color(0xFF151C2C),
        ),
      ),
      home: const RDMHomeScreen(),
    );
  }
}

class DownloadTask {
  String id, url, fileName, savePath, status, speed;
  int downloadedBytes, totalBytes, threads;
  List<double> partProgress;
  CancelToken? cancelToken;

  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.savePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.status = 'Paused',
    this.speed = '0 KB/s',
    this.threads = 4,
    List<double>? partProgress,
  }) : partProgress = partProgress ?? List<double>.filled(threads, 0.0);

  double get progress => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
    'id': id, 'url': url, 'fileName': fileName, 'savePath': savePath,
    'downloadedBytes': downloadedBytes, 'totalBytes': totalBytes,
    'status': (status == 'Downloading' || status == 'Merging...') ? 'Paused' : status,
    'threads': threads, 'partProgress': partProgress,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    int t = (j['threads'] as num?)?.toInt() ?? 4;
    List<double> pp = j['partProgress'] != null
        ? List<double>.from((j['partProgress'] as List).map((x) => (x as num).toDouble()))
        : List<double>.filled(t, 0.0);
    return DownloadTask(
      id: j['id']?.toString() ?? '', url: j['url']?.toString() ?? '',
      fileName: j['fileName']?.toString() ?? 'file.mp4', savePath: j['savePath']?.toString() ?? '',
      downloadedBytes: (j['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
      status: j['status']?.toString() ?? 'Paused', threads: t, partProgress: pp,
    );
  }
}

class RDMHomeScreen extends StatefulWidget {
  const RDMHomeScreen({super.key});
  @override
  State<RDMHomeScreen> createState() => _RDMHomeScreenState();
}

class _RDMHomeScreenState extends State<RDMHomeScreen> with WidgetsBindingObserver {
  List<DownloadTask> _tasks = [];
  final Dio _dio = Dio();
  final TextEditingController _urlCtrl = TextEditingController();
  int _tab = 0, _threads = 8;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
    [Permission.storage, Permission.manageExternalStorage].request();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveHistory();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.detached) _saveHistory();
  }

  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList('rdm_tasks_v6');
    if (l != null) setState(() => _tasks = l.map((e) => DownloadTask.fromJson(jsonDecode(e))).toList());
  }

  Future<void> _saveHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('rdm_tasks_v6', _tasks.map((t) => jsonEncode(t.toJson())).toList());
  }

  Future<String> _getSavePath(String name) async {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    Directory d = Directory('/storage/emulated/0/Download/RDM_Pro');
    if (!await d.exists()) {
      try { await d.create(recursive: true); } catch (_) {
        d = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      }
    }
    return '${d.path}/$clean';
  }

  bool _isSocial(String u) => RegExp(r'(youtube\.com|youtu\.be|facebook\.com|fb\.watch|instagram\.com|tiktok\.com|twitter\.com|x\.com)').hasMatch(u.toLowerCase());

  void _handleInput(String url, int threads) {
    if (url.isEmpty) return;
    if (_isSocial(url)) {
      _showQualitySheet(url, threads);
    } else {
      String name = url.split('/').last.split('?').first;
      if (name.isEmpty || !name.contains('.')) name = 'RDM_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _addTask(url, name, threads);
    }
  }

  void _showQualitySheet(String pageUrl, int threads) {
    final opts = [
      {'l': 'Full HD Video • 1080p', 'q': '1080', 'e': 'mp4', 'a': false},
      {'l': 'HD Video • 720p', 'q': '720', 'e': 'mp4', 'a': false},
      {'l': 'Standard Video • 480p', 'q': '480', 'e': 'mp4', 'a': false},
      {'l': 'Data Saver • 360p', 'q': '360', 'e': 'mp4', 'a': false},
      {'l': 'Audio Only • MP3 (320kbps)', 'q': 'audio', 'e': 'mp3', 'a': true},
    ];
    showModalBottomSheet(
      context: context, backgroundColor: const Color(0xFF151C2C),
      builder: (ctx) => ListView(
        shrinkWrap: true, padding: const EdgeInsets.all(16),
        children: [
          Text('Select Quality ($threads Threads)', style: const TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(color: Colors.white24),
          ...opts.map((o) => ListTile(
            leading: Icon((o['a'] as bool) ? Icons.audiotrack : Icons.videocam, color: const Color(0xFF00FF87)),
            title: Text(o['l'].toString()),
            onTap: () { Navigator.pop(ctx); _extractSocial(pageUrl, o, threads); },
          )),
        ],
      ),
    );
  }

  Future<void> _extractSocial(String url, Map<String, Object> o, int threads) async {
    String? dlUrl;
    String fName = 'RDM_${o['q']}_${DateTime.now().millisecondsSinceEpoch}.${o['e']}';
    for (final api in ['https://api.cobalt.tools/api/json', 'https://co.wuk.sh/api/json']) {
      try {
        final r = await _dio.post(api, data: {'url': url, 'vQuality': (o['a'] as bool) ? '720' : o['q'], 'isAudioOnly': o['a'], 'aFormat': 'mp3'},
            options: Options(headers: {'Accept': 'application/json', 'Content-Type': 'application/json'}));
        if (r.data is Map && r.data['url'] != null) {
          dlUrl = r.data['url'].toString();
          if (r.data['filename'] != null) fName = r.data['filename'].toString();
          break;
        }
      } catch (_) {}
    }
    if (dlUrl != null) {
      _addTask(dlUrl, fName, threads);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Extractor busy! Paste a direct link.')));
    }
  }

  Future<void> _addTask(String url, String name, int threads) async {
    final path = await _getSavePath(name);
    final t = DownloadTask(id: DateTime.now().millisecondsSinceEpoch.toString(), url: url, fileName: name, savePath: path, threads: threads);
    setState(() => _tasks.insert(0, t));
    await _saveHistory();
    _startTask(t);
  }

  Future<void> _startTask(DownloadTask t) async {
    t.cancelToken = CancelToken();
    WakelockPlus.enable();
    setState(() { t.status = 'Downloading'; t.speed = 'Boosting (${t.threads}x)...'; });
    try {
      int total = t.totalBytes;
      bool ranged = false;
      try {
        final h = await _dio.get<ResponseBody>(t.url, cancelToken: t.cancelToken, options: Options(responseType: ResponseType.stream, headers: {'Range': 'bytes=0-0'}));
        if (h.statusCode == 206) {
          ranged = true;
          final cr = h.headers.value('content-range');
          if (cr != null && cr.contains('/')) total = int.tryParse(cr.split('/').last) ?? total;
        }
        await h.data?.stream.drain();
      } catch (_) {}
      if (total > 0) t.totalBytes = total;
      if (ranged && t.totalBytes > 512 * 1024 && t.threads > 1) {
        await _multiPart(t);
      } else {
        t.threads = 1; t.partProgress = [0.0];
        await _singleStream(t);
      }
    } catch (e) {
      setState(() { t.status = 'Paused'; t.speed = (e is DioException && CancelToken.isCancel(e)) ? 'Paused' : 'Network Drop'; });
      await _saveHistory();
    } finally {
      if (!_tasks.any((x) => x.status == 'Downloading')) WakelockPlus.disable();
    }
  }

  Future<void> _multiPart(DownloadTask t) async {
    final int n = t.threads, chunk = (t.totalBytes / n).ceil();
    final List<int> pBytes = List<int>.filled(n, 0);
    if (t.partProgress.length != n) t.partProgress = List<double>.filled(n, 0.0);
    int lastSum = t.downloadedBytes;
    DateTime lastTime = DateTime.now();

    await Future.wait(List.generate(n, (i) async {
      final int start = i * chunk, end = (i == n - 1) ? t.totalBytes - 1 : (start + chunk - 1), pTotal = end - start + 1;
      final File pf = File('${t.savePath}.part$i');
      int exist = await pf.exists() ? await pf.length() : 0;
      if (exist >= pTotal) { pBytes[i] = pTotal; t.partProgress[i] = 1.0; return; }
      pBytes[i] = exist;
      final res = await _dio.get<ResponseBody>(t.url, cancelToken: t.cancelToken, options: Options(responseType: ResponseType.stream, headers: {'Range': 'bytes=${start + exist}-$end'}));
      final raf = pf.openSync(mode: exist > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final c in res.data!.stream) {
          if (t.cancelToken!.isCancelled) break;
          raf.writeFromSync(c);
          pBytes[i] += c.length;
          t.partProgress[i] = (pBytes[i] / pTotal).clamp(
