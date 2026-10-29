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
    this.threads = 8,
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
    int t = (j['threads'] as num?)?.toInt() ?? 8;
    List<double> pp = j['partProgress'] != null
        ? List<double>.from((j['partProgress'] as List).map((x) => (x as num).toDouble()))
        : List<double>.filled(t, 0.0);
    return DownloadTask(
      id: j['id']?.toString() ?? '', url: j['url']?.toString() ?? '',
      fileName: j['fileName']?.toString() ?? 'video.mp4', savePath: j['savePath']?.toString() ?? '',
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
    final l = p.getStringList('rdm_tasks_v7');
    if (l != null) setState(() => _tasks = l.map((e) => DownloadTask.fromJson(jsonDecode(e))).toList());
  }

  Future<void> _saveHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('rdm_tasks_v7', _tasks.map((t) => jsonEncode(t.toJson())).toList());
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

  bool _isSocial(String u) => RegExp(r'(youtube\.com|youtu\.be|facebook\.com|fb\.watch|fb\.com|instagram\.com|tiktok\.com)').hasMatch(u.toLowerCase());

  void _handleInput(String url, int threads) {
    if (url.isEmpty) return;
    if (_isSocial(url)) {
      _extractMediaStreams(url, threads);
    } else {
      String name = url.split('/').last.split('?').first;
      if (name.isEmpty || !name.contains('.')) name = 'RDM_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _addTask(url, name, threads);
    }
  }

  String _cleanEscapedUrl(String raw) {
    return raw
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0025', '%')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u003C', '<')
        .replaceAll(r'\u003E', '>')
        .replaceAll(r'\u003D', '=')
        .replaceAll('&amp;', '&');
  }

  Future<void> _extractMediaStreams(String pageUrl, int threads) async {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF151C2C),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF00F0FF)),
            SizedBox(width: 16),
            Expanded(child: Text('Scanning page for direct video streams...')),
          ],
        ),
      ),
    );

    List> foundStreams = [];
    final lower = pageUrl.toLowerCase();

    try {
      // ১. নিজস্ব লোকাল স্ক্র্যাপার (Facebook, Reels, Instagram, TikTok)
      if (lower.contains('facebook.com') || lower.contains('fb.watch') || lower.contains('fb.com') || lower.contains('instagram.com')) {
        foundStreams = await _scrapeFacebookOrInsta(pageUrl);
      } else if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
        foundStreams = await _scrapeYouTube(pageUrl);
      } else if (lower.contains('tiktok.com')) {
        foundStreams = await _scrapeTikTok(pageUrl);
      }
    } catch (_) {}

    if (mounted) Navigator.pop(context);

    if (foundStreams.isNotEmpty) {
      _showStreamPicker(foundStreams, threads);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not extract private/encrypted link! Make sure the video is Public.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ফেসবুক ও ইন্সটাগ্রাম নেটিভ ডিরেক্ট গ্র্যাবার (No Third-Party Server Needed!)
  Future<List>> _scrapeFacebookOrInsta(String url) async {
    List> list = [];
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Sec-Fetch-Mode': 'navigate',
    };

    final res = await _dio.get<String>(url, options: Options(headers: headers, followRedirects: true, validateStatus: (s) => true));
    String html = res.data ?? '';

    // মোবাইল বা রিলস লিংক হলে ডেস্কটপ/এমবেড ভার্সনও চেক করা হবে
    if (!html.contains('.mp4')) {
      final mbUrl = url.replaceFirst('www.facebook.com', 'm.facebook.com');
      final res2 = await _dio.get<String>(mbUrl, options: Options(headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-S908B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      }, followRedirects: true, validateStatus: (s) => true));
      html += '\n${res2.data ?? ''}';
    }

    final Map<String, RegExp> patterns = {
      'Full HD Video (MP4)': RegExp(r'"(?:playable_url_quality_hd|hd_src|hd_src_no_ratelimit|browser_native_hd_url)"\s*:\s*"([^"]+)"'),
      'Standard SD Video (MP4)': RegExp(r'"(?:playable_url|sd_src|sd_src_no_ratelimit|browser_native_sd_url|video_url)"\s*:\s*"([^"]+)"'),
      'Direct Meta Video (MP4)': RegExp(r'property="og:video(?::url|:secure_url)?"\s+content="([^"]+)"'),
    };

    patterns.forEach((label, reg) {
      final match = reg.firstMatch(html);
      if (match != null && match.group(1) != null) {
        final link = _cleanEscapedUrl(match.group(1)!);
        if (link.startsWith('http') && !list.any((e) => e['url'] == link)) {
          list.add({'label': label, 'url': link, 'ext': 'mp4'});
        }
      }
    });

    // যদি উপরের কী-ওয়ার্ড ছাড়া সরাসরি mp4 স্ট্রিম থাকে
    if (list.isEmpty) {
      final rawMp4 = RegExp(r'"(https?:\\?/\\?/[^"]*?\.mp4[^"]*?)"').allMatches(html);
      int count = 1;
      for (final m in rawMp4.take(3)) {
        final link = _cleanEscapedUrl(m.group(1)!);
        if (!list.any((e) => e['url'] == link)) {
          list.add({'label': 'Video Stream #$count (MP4)', 'url': link, 'ext': 'mp4'});
          count++;
        }
      }
    }
    return list;
  }

  // টিকটক ডিরেক্ট গ্র্যাবার (TikWM Public API)
  Future<List>> _scrapeTikTok(String url) async {
    List> list = [];
    try {
      final r = await _dio.post('https://www.tikwm.com/api/', data: {'url': url, 'hd': 1});
      if (r.data is Map && r.data['data'] != null) {
        final d = r.data['data'];
        if (d['hdplay'] != null) list.add({'label': 'No-Watermark HD (MP4)', 'url': d['hdplay'].toString(), 'ext': 'mp4'});
        if (d['play'] != null) list.add({'label': 'No-Watermark SD (MP4)', 'url': d['play'].toString(), 'ext': 'mp4'});
        if (d['music'] != null) list.add({'label': 'Original Audio (MP3)', 'url': d['music'].toString(), 'ext': 'mp3'});
      }
    } catch (_) {}
    return list;
  }

  // ইউটিউব মাল্টি-নোড এক্সট্রাক্টর (Piped Open Nodes)
  Future<List>> _scrapeYouTube(String url) async {
    List> list = [];
    String? vid;
    final reg = RegExp(r'(?:v=|youtu\.be\/|shorts\/)([a-zA-Z0-9_-]{11})');
    final m = reg.firstMatch(url);
    if (m != null) vid = m.group(1);
    if (vid == null) return list;

    final nodes = [
      'https://pipedapi.kavin.rocks',
      'https://pipedapi.tokhmi.xyz',
      'https://pipedapi.moomoo.me',
      'https://api.piped.projectsegfau.lt',
    ];

    for (final node in nodes) {
      try {
        final r = await _dio.get('$node/streams/$vid', options: Options(receiveTimeout: const Duration(seconds: 8)));
        if (r.data is Map) {
          final vStreams = (r.data['videoStreams'] as List?) ?? [];
          for (final vs in vStreams) {
            if (vs['videoOnly'] == false && vs['url'] != null) {
              list.add({
                'label': 'Video • ${vs['quality']} (${vs['format']})',
                'url': vs['url'].toString(),
                'ext': 'mp4',
              });
            }
          }
          final aStreams = (r.data['audioStreams'] as List?) ?? [];
          if (aStreams.isNotEmpty && aStreams.first['url'] != null) {
            list.add({
              'label': 'Audio Only • High Bitrate (M4A/MP3)',
              'url': aStreams.first['url'].toString(),
              'ext': 'm4a',
            });
          }
          if (list.isNotEmpty) break;
        }
      } catch (_) {}
    }
    return list;
  }

  void _showStreamPicker(List> streams, int threads) {
    showModalBottomSheet(
      context: context, backgroundColor: const Color(0xFF151C2C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ListView(
        shrinkWrap: true, padding: const EdgeInsets.all(16),
        children: [
          Text('Streams Found (Turbo ${threads}x Ready)', style: const TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(color: Colors.white24),
          ...streams.map((s) => ListTile(
            leading: Icon(s['ext'] == 'mp3' || s['ext'] == 'm4a' ? Icons.audiotrack : Icons.videocam, color: const Color(0xFF00FF87)),
            title: Text(s['label']!, style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: const Icon(Icons.download_for_offline, color: Color(0xFF00F0FF)),
            onTap: () {
              Navigator.pop(ctx);
              final name = 'RDM_${DateTime.now().millisecondsSinceEpoch}.${s['ext']}';
              _addTask(s['url']!, name, threads);
            },
          )),
        ],
      ),
    );
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
        final h = await _dio.get<ResponseBody>(t.url, cancelToken: t.cancelToken, options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0', 'User-Agent': 'Mozilla/5.0'},
        ));
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
      final res = await _dio.get<ResponseBody>(t.url, cancelToken: t.cancelToken, options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=${start + exist}-$end', 'User-Agent': 'Mozilla/5.0'},
      ));
      final raf = pf.openSync(mode: exist > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final c in res.data!.stream) {
          if (t.cancelToken!.isCancelled) break;
          raf.writeFromSync(c);
          pBytes[i] += c.length;
          t.partProgress[i] = (pBytes[i] / pTotal).clamp(0.0, 1.0);
          final now = DateTime.now(), diff = now.difference(lastTime).inMilliseconds;
          if (diff >= 600) {
            int sum = 0; for (final v in pBytes) { sum += v; }
            t.downloadedBytes = sum;
            final bps = ((sum - lastSum) * 1000) / diff;
            if (mounted) setState(() => t.speed = bps > 1048576 ? '${(bps / 1048576).toStringAsFixed(2)} MB/s' : '${(bps / 1024).toStringAsFixed(1)} KB/s');
            lastSum = sum; lastTime = now;
          }
        }
      } finally { await raf.close(); }
    }));

    if (t.cancelToken!.isCancelled) return;
    setState(() { t.status = 'Merging...'; t.speed = 'Joining'; });
    final sink = File(t.savePath).openWrite(mode: FileMode.write);
    for (int i = 0; i < n; i++) {
      final pf = File('${t.savePath}.part$i');
      if (await pf.exists()) { await sink.addStream(pf.openRead()); await pf.delete(); }
    }
    await sink.close();
    setState(() { t.downloadedBytes = t.totalBytes; t.status = 'Completed'; t.speed = 'Done'; });
    await _saveHistory();
  }

  Future<void> _singleStream(DownloadTask t) async {
    final f = File(t.savePath);
    int exist = await f.exists() ? await f.length() : 0;
    t.downloadedBytes = exist;
    final res = await _dio.get<ResponseBody>(t.url, cancelToken: t.cancelToken, options: Options(
      responseType: ResponseType.stream,
      headers: {if (exist > 0) 'Range': 'bytes=$exist-', 'User-Agent': 'Mozilla/5.0'},
    ));
    final part = res.statusCode == 206;
    if (!part && exist > 0) { exist = 0; t.downloadedBytes = 0; }
    final len = int.tryParse(res.headers.value(Headers.contentLengthHeader) ?? '0') ?? 0;
    if (len > 0) t.totalBytes = exist + len;
    final raf = f.openSync(mode: part ? FileMode.append : FileMode.write);
    int lastB = t.downloadedBytes; DateTime lastT = DateTime.now();
    try {
      await for (final c in res.data!.stream) {
        if (t.cancelToken!.isCancelled) break;
        raf.writeFromSync(c); t.downloadedBytes += c.length; t.partProgress[0] = t.progress;
        final now = DateTime.now(), diff = now.difference(lastT).inMilliseconds;
        if (diff >= 600) {
          final bps = ((t.downloadedBytes - lastB) * 1000) / diff;
          if (mounted) setState(() => t.speed = bps > 1048576 ? '${(bps / 1048576).toStringAsFixed(2)} MB/s' : '${(bps / 1024).toStringAsFixed(1)} KB/s');
          _saveHistory(); lastB = t.downloadedBytes; lastT = now;
        }
      }
    } finally { await raf.close(); }
    if (!t.cancelToken!.isCancelled) { setState(() { t.status = 'Completed'; t.speed = 'Done'; }); await _saveHistory(); }
  }

  String _fmt(int b) => b <= 0 ? '0 B' : (b > 1048576 ? '${(b / 1048576).toStringAsFixed(2)} MB' : '${(b / 1024).toStringAsFixed(1)} KB');

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF151C2C),
          title: const Text('New Turbo Download', style: TextStyle(color: Color(0xFF00F0FF))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _urlCtrl, decoration: const InputDecoration(hintText: 'Paste FB, Reels, TikTok, YT or Direct link...')),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [1, 4, 8].map((n) => ChoiceChip(
                  label: Text('${n}x'), selected: _threads == n,
                  selectedColor: const Color(0xFF00F0FF),
                  labelStyle: TextStyle(color: _threads == n ? Colors.black : Colors.white),
                  onSelected: (_) => setS(() => _threads = n),
                )).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00F0FF), foregroundColor: Colors.black),
              onPressed: () { final u = _urlCtrl.text.trim(); _urlCtrl.clear(); Navigator.pop(ctx); _handleInput(u, _threads); },
              child: const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }

 @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF151C2C),
        title: const Text('RDM PRO v1.4', style: TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.w900)),
      ),
      body: _tasks.isEmpty
          ? const Center(child: Text('Native FB/Social Scraper & 8x Engine Ready\nTap Turbo Link to start', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF00FF87))))
          : ListView.builder(
              padding: const EdgeInsets.all(12), itemCount: _tasks.length,
              itemBuilder: (ctx, i) {
                final t = _tasks[i], active = t.status == 'Downloading', done = t.status == 'Completed';
                return Card(
                  color: const Color(0xFF151C2C), margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('[${t.threads}x] ', style: const TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold)),
                            Expanded(child: Text(t.fileName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold))),
                            if (!done) IconButton(
                              icon: Icon(active ? Icons.pause_circle : Icons.play_circle, color: const Color(0xFF00FF87)),
                              onPressed: () { if (active) { t.cancelToken?.cancel(); setState(() => t.status = 'Paused'); } else { _startTask(t); } },
                            ),
                            IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () { t.cancelToken?.cancel(); setState(() => _tasks.removeAt(i)); _saveHistory(); }),
                          ],
                        ),
                        LinearProgressIndicator(value: t.progress, minHeight: 6, backgroundColor: const Color(0xFF0A0E17), valueColor: const AlwaysStoppedAnimation(Color(0xFF00F0FF))),
                        if (t.threads > 1 && !done) Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: List.generate(t.threads, (pi) => Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1),
                                child: LinearProgressIndicator(value: pi < t.partProgress.length ? t.partProgress[pi] : 0.0, minHeight: 3, valueColor: const AlwaysStoppedAnimation(Color(0xFF00FF87))),
                              ),
                            )),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('${_fmt(t.downloadedBytes)} / ${_fmt(t.totalBytes)} (${(t.progress * 100).toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                            Text('${t.status} • ${t.speed}', style: const TextStyle(fontSize: 12, color: Color(0xFF00FF87), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        if (done) Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Saved: ${t.savePath}', style: const TextStyle(fontSize: 11, color: Color(0xFF00F0FF))),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00F0FF), foregroundColor: Colors.black,
        onPressed: _showAddDialog, icon: const Icon(Icons.bolt), label: const Text('Turbo Link', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF151C2C), selectedItemColor: const Color(0xFF00F0FF),
        currentIndex: _tab, onTap: (v) => setState(() => _tab = v),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.download), label: 'Downloads'),
          BottomNavigationBarItem(icon: Icon(Icons.language), label: 'Browser'),
          BottomNavigationBarItem(icon: Icon(Icons.hub), label: 'Torrents'),
        ],
      ),
    );
  }
}
// END OF RDM PRO v1.4
