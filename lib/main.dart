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
  }) : partProgress = partProgress ?? List.filled(threads, 0.0);

  double get progress => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'fileName': fileName,
        'savePath': savePath,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'status': (status == 'Downloading' || status == 'Merging...') ? 'Paused' : status,
        'threads': threads,
        'partProgress': partProgress,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    int t = json['threads'] ?? 4;
    List<double> pp = json['partProgress'] != null
        ? List<double>.from(json['partProgress'].map((x) => (x as num).toDouble()))
        : List.filled(t, 0.0);
    return DownloadTask(
      id: json['id'],
      url: json['url'],
      fileName: json['fileName'],
      savePath: json['savePath'],
      downloadedBytes: json['downloadedBytes'] ?? 0,
      totalBytes: json['totalBytes'] ?? 0,
      status: json['status'] ?? 'Paused',
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

class _RDMHomeScreenState extends State<RDMHomeScreen> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
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
        _tasks = list.map((item) => DownloadTask.fromJson(jsonDecode(item))).toList();
      });
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> list = _tasks.map((task) => jsonEncode(task.toJson())).toList();
    await prefs.setStringList('rdm_tasks_v4', list);
  }

  Future<String> _getDownloadFolderPath(String fileName) async {
    final cleanName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    Directory? dir = Directory('/storage/emulated/0/Download/RDM_Pro');
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
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

      for (var s in manifest.muxed) {
        options.add(StreamOption(
          label: 'Video • ${s.qualityLabel} (${s.container.name.toUpperCase()})',
          url: s.url.toString(),
          ext: s.container.name,
          sizeBytes: s.size.totalBytes,
        ));
      }

      for (var s in manifest.videoOnly.where((v) => v.container.name == 'mp4').take(3)) {
        if (!options.any((o) => o.label.contains(s.qualityLabel))) {
          options.add(StreamOption(
            label: 'HD Video • ${s.qualityLabel} (MP4)',
            url: s.url.toString(),
            ext: 'mp4',
            sizeBytes: s.size.totalBytes,
          ));
        }
      }

      final audio = manifest.audioOnly.withHighestBitrate();
      options.add(StreamOption(
        label: 'Audio Only • MP3/M4A (${(audio.bitrate.kiloBitsPerSecond).toStringAsFixed(0)} kbps)',
        url: audio.url.toString(),
        ext: 'm4a',
        sizeBytes: audio.size.totalBytes,
        isAudio: true,
      ));

      if (mounted) Navigator.pop(context);
      _showQualitySelectorSheet(video.title, options, threads);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to extract link: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      yt.close();
    }
  }

  void _showQualitySelectorSheet(String title, List<StreamOption> options, int threads) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151C2C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('Select Format & Quality (Turbo $threads Threads):',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const Divider(color: Colors.white12, height: 20),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, idx) {
                  final opt = options[idx];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      opt.isAudio ? Icons.audiotrack : Icons.videocam,
                      color: opt.isAudio ? const Color(0xFF00FF87) : const Color(0xFF00F0FF),
                    ),
                    title: Text(opt.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0E17),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF00FF87).withOpacity(0.5)),
                      ),
                      child: Text(
                        _formatSize(opt.sizeBytes),
                        style: const TextStyle(color: Color(0xFF00FF87), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
                      final fName = '${safeTitle}_${opt.label.split('•').last.trim().split(' ').first}.${opt.ext}';
                      _createAndStartTask(opt.url, fName, threads, opt.sizeBytes);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createAndStartTask(String url, String fileName, int threads, int knownSize) async {
    final savePath = await _getDownloadFolderPath(fileName);
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      fileName: fileName,
      savePath: savePath,
      threads: threads,
      totalBytes: knownSize,
    );

    setState(() => _tasks.insert(0, task));
    await _saveHistory();
    _startOrResumeTask(task);
  }

  Future<void> _startOrResumeTask(DownloadTask task) async {
    task.cancelToken = CancelToken();
    WakelockPlus.enable();

    setState(() {
      task.status = 'Downloading';
      task.speed = 'Boosting (${task.threads}x)...';
    });
    await _saveHistory();

    try {
      int total = task.totalBytes;
      bool supportsRanges = false;

      // চেক করা হচ্ছে সার্ভার মাল্টি-থ্রেডিং সাপোর্ট করে কি না
      try {
        final headRes = await _dio.get<ResponseBody>(
          task.url,
          cancelToken: task.cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=0-0'},
          ),
        );
        if (headRes.statusCode == 206) {
          supportsRanges = true;
          final contentRange = headRes.headers.value('content-range');
          if (contentRange != null && contentRange.contains('/')) {
            total = int.tryParse(contentRange.split('/').last) ?? total;
          }
        }
        await headRes.data?.stream.drain();
      } catch (_) {}

      if (total > 0) task.totalBytes = total;

      if (supportsRanges && task.totalBytes > 512 * 1024 && task.threads > 1) {
        await _runMultiPartDownload(task);
      } else {
        task.threads = 1;
        task.partProgress = [0.0];
        await _runSingleStreamDownload(task);
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        setState(() {
          task.status = 'Paused';
          task.speed = 'Paused';
        });
      } else {
        setState(() {
          task.status = 'Paused (Tap Resume)';
          task.speed = 'Network Drop';
        });
      }
      await _saveHistory();
    } finally {
      if (!_tasks.any((t) => t.status == 'Downloading')) {
        WakelockPlus.disable();
      }
    }
  }

  // মাল্টি-থ্রেডিং ইঞ্জিন (৪ বা ৮ ভাগে সমান্তরাল ডাউনলোড ও ফাইল মার্জার)
  Future<void> _runMultiPartDownload(DownloadTask task) async {
    final int n = task.threads;
    final int chunkSize = (task.totalBytes / n).ceil();
    List<int> partDownloaded = List.filled(n, 0);
    if (task.partProgress.length != n) {
      task.partProgress = List.filled(n, 0.0);
    }

    int lastTotalBytes = task.downloadedBytes;
    DateTime lastSpeedTime = DateTime.now();

    List<Future<void>> futures = [];

    for (int i = 0; i < n; i++) {
      final int start = i * chunkSize;
      final int end = (i == n - 1) ? task.totalBytes - 1 : (start + chunkSize - 1);
      final int partTotal = end - start + 1;
      final File partFile = File('${task.savePath}.part$i');

      futures.add(() async {
        int existing = 0;
        if (await partFile.exists()) {
          existing = await partFile.length();
        }
        if (existing >= partTotal) {
          partDownloaded[i] = partTotal;
          task.partProgress[i] = 1.0;
          return;
        }

        partDownloaded[i] = existing;
        final reqStart = start + existing;

        final response = await _dio.get<ResponseBody>(
          task.url,
          cancelToken: task.cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=$reqStart-$end'},
          ),
        );

        final raf = partFile.openSync(mode: existing > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in response.data!.stream) {
            if (task.cancelToken!.isCancelled) break;
            raf.writeFromSync(chunk);
            partDownloaded[i] += chunk.length;
            task.partProgress[i] = (partDownloaded[i] / partTotal).clamp(0.0, 1.0);

            final now = DateTime.now();
            final diff = now.difference(lastSpeedTime).inMilliseconds;
            if (diff >= 600) {
              final currentSum = partDownloaded.fold(0, (a, b) => a + b);
              task.downloadedBytes = currentSum;
              final bytesDiff = currentSum - lastTotalBytes;
              final speedBps = (bytesDiff * 1000) / diff;
              String speedText = speedBps > 1024 * 1024
                  ? '${(speedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s'
                  : '${(speedBps / 1024).toStringAsFixed(1)} KB/s';

              if (mounted) {
                setState(() => task.speed = speedText);
              }
              lastTotalBytes = currentSum;
              lastSpeedTime = now;
            }
          }
        } finally {
          await raf.close();
        }
      }());
    }

    await Future.wait(futures);

    if (task.cancelToken!.isCancelled) return;

    // সবগুলো পার্ট ডাউনলোড শেষে একসাথে জোড়া লাগানো হচ্ছে (Merging)
    setState(() {
      task.status = 'Merging...';
      task.speed = 'Joining Parts';
    });

    final outFile = File(task.savePath);
    final outSink = outFile.openWrite(mode: FileMode.write);
    for (int i = 0; i < n; i++) {
      final partFile = File('${task.savePath}.part$i');
      if (await partFile.exists()) {
        await outSink.addStream(partFile.openRead());
        await partFile.delete();
      }
    }
    await outSink.close();

    setState(() {
      task.downloadedBytes = task.totalBytes;
      task.status = 'Completed';
      task.speed = 'Done';
    });
    await _saveHistory();
  }

  Future<void> _runSingleStreamDownload(DownloadTask task) async {
    final file = File(task.savePath);
    int existingLength = await file.exists() ? await file.length() : 0;
    task.downloadedBytes = existingLength;

    final response = await _dio.get<ResponseBody>(
      task.url,
      cancelToken: task.cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: existingLength > 0 ? {'Range': 'bytes=$existingLength-'} : null,
      ),
    );

    final isPartial = response.statusCode == 206;
    if (!isPartial && existingLength > 0) {
      existingLength = 0;
      task.downloadedBytes = 0;
    }

    final contentLength = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '0') ?? 0;
    if (contentLength > 0) task.totalBytes = existingLength + contentLength;

    final raf = file.openSync(mode: isPartial ? FileMode.append : FileMode.write);
    int lastBytes = task.downloadedBytes;
    DateTime lastTime = DateTime.now();

    try {
      await for (final chunk in response.data!.stream) {
        if (task.cancelToken!.isCancelled) break;
        raf.writeFromSync(chunk);
        task.downloadedBytes += chunk.length;
        task.partProgress[0] = task.progress;

        final now = DateTime.now();
        final diff = now.difference(lastTime).inMilliseconds;
        if (diff >= 600) {
          final bytesDiff = task.downloadedBytes - lastBytes;
          final speedBps = (bytesDiff * 1000) / diff;
          String speedText = speedBps > 1024 * 1024
              ? '${(speedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s'
              : '${(speedBps / 1024).toStringAsFixed(1)} KB/s';

          if (mounted) setState(() => task.speed = speedText);
          _saveHistory();
          lastBytes = task.downloadedBytes;
          lastTime = now;
        }
      }
    } finally {
      await raf.close();
    }

    if (!task.cancelToken!.isCancelled) {
      setState(() {
        task.status = 'Completed';
        task.speed = 'Done';
      });
      await _saveHistory();
    }
  }

  void _pauseTask(DownloadTask task) {
    task.cancelToken?.cancel();
    setState(() {
      task.status = 'Paused';
      task.speed = 'Paused';
    });
    _saveHistory();
  }

  void _deleteTask(int index) async {
    final task = _tasks[index];
    task.cancelToken?.cancel();
    for (int i = 0; i < task.threads; i++) {
      final p = File('${task.savePath}.part$i');
      if (await p.exists()) await p.delete();
    }
    setState(() => _tasks.removeAt(index));
    await _saveHistory();
  }

  Future<void> _openDownloadedFile(DownloadTask task) async {
    if (await File(task.savePath).exists()) {
      await OpenFilex.open(task.savePath);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not found in storage!'), backgroundColor: Colors.redAccent),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes > 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  void _showAddLinkDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF151C2C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00F0FF), width: 1),
          ),
          title: const Text('New Turbo Download',
      
