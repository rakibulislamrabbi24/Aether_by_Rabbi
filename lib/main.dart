import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:open_filex/open_filex.dart';

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
  String id;
  String url;
  String fileName;
  String savePath;
  int downloadedBytes;
  int totalBytes;
  String status;
  String speed;
  int threads;
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

  double get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'fileName': fileName,
        'savePath': savePath,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'status': (status == 'Downloading' || status == 'Merging...')
            ? 'Paused'
            : status,
        'threads': threads,
        'partProgress': partProgress,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    int t = (json['threads'] as num?)?.toInt() ?? 4;
    List<double> pp = json['partProgress'] != null
        ? List<double>.from(
            (json['partProgress'] as List).map((x) => (x as num).toDouble()))
        : List<double>.filled(t, 0.0);
    return DownloadTask(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? 'file.bin',
      savePath: json['savePath']?.toString() ?? '',
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'Paused',
      threads: t,
      partProgress: pp,
    );
  }
}

class StreamOption {
  final String label;
  final String url;
  final String ext;
  final int sizeBytes;
  final bool isAudio;

  StreamOption({
    required this.label,
    required this.url,
    required this.ext,
    required this.sizeBytes,
    this.isAudio = false,
  });
}

class RDMHomeScreen extends StatefulWidget {
  const RDMHomeScreen({super.key});

  @override
  State<RDMHomeScreen> createState() => _RDMHomeScreenState();
}

class _RDMHomeScreenState extends State<RDMHomeScreen>
    with WidgetsBindingObserver {
  List<DownloadTask> _tasks = [];
  final Dio _dio = Dio();
  final TextEditingController _urlController = TextEditingController();
  int _selectedTab = 0;
  int _selectedThreads = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
    _requestPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveHistory();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveHistory();
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? list = prefs.getStringList('rdm_tasks_v4');
    if (list != null) {
      setState(() {
        _tasks =
            list.map((item) => DownloadTask.fromJson(jsonDecode(item))).toList();
      });
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> list =
        _tasks.map((task) => jsonEncode(task.toJson())).toList();
    await prefs.setStringList('rdm_tasks_v4', list);
  }

  Future<String> _getDownloadFolderPath(String fileName) async {
    final cleanName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    Directory? dir = Directory('/storage/emulated/0/Download/RDM_Pro');
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        dir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      }
    }
    return '${dir.path}/$cleanName';
  }

  bool _isYouTubeUrl(String url) {
    return url.contains('youtube.com/') || url.contains('youtu.be/');
  }

  Future<void> _handleUrlInput(String url, int threads) async {
    if (url.isEmpty) return;
    if (_isYouTubeUrl(url)) {
      await _analyzeYouTubeVideo(url, threads);
    } else {
      String fileName = url.split('/').last.split('?').first;
      if (fileName.isEmpty || !fileName.contains('.')) {
        fileName = 'RDM_${DateTime.now().millisecondsSinceEpoch}.mp4';
      }
      await _createAndStartTask(url, fileName, threads, 0);
    }
  }

  Future<void> _analyzeYouTubeVideo(String url, int threads) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF151C2C),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF00F0FF)),
            SizedBox(width: 20),
            Expanded(child: Text('Extracting video streams & qualities...')),
          ],
        ),
      ),
    );

    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(url);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      List<StreamOption> options = [];

      for (final s in manifest.muxed) {
        options.add(StreamOption(
          label: 'Video • ${s.qualityLabel} (${s.container.name.toUpperCase()})',
          url: s.url.toString(),
          ext: s.container.name,
          sizeBytes: s.size.totalBytes.toInt(),
        ));
      }

      for (final s in manifest.videoOnly
          .where((v) => v.container.name == 'mp4')
          .take(3)) {
        if (!options.any((o) => o.label.contains(s.qualityLabel))) {
          options.add(StreamOption(
            label: 'HD Video • ${s.qualityLabel} (MP4)',
            url: s.url.toString(),
            ext: 'mp4',
            sizeBytes: s.size.totalBytes.toInt(),
          ));
        }
      }

      final audio = manifest.audioOnly.withHighestBitrate();
      options.add(StreamOption(
        label:
            'Audio Only • MP3/M4A (${audio.bitrate.
        
