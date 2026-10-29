import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      fileName: json['fileName']?.toString() ?? 'file.mp4',
      savePath: json['savePath']?.toString() ?? '',
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'Paused',
      threads: t,
      partProgress: pp,
    );
  }
}

class SocialFormatOption {
  final String label;
  final String quality;
  final String ext;
  final bool isAudio;

  SocialFormatOption({
    required this.label,
    required this.quality,
    required this.ext,
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
  int _selectedThreads = 8;

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
    final List<String>? list = prefs.getStringList('rdm_tasks_v5');
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
    await prefs.setStringList('rdm_tasks_v5', list);
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

  bool _isSocialOrStreamingUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('instagram.com') ||
        lower.contains('tiktok.com') ||
        lower.contains('twitter.com') ||
        lower.contains('x.com');
  }

  Future<void> _handleUrlInput(String url, int threads) async {
    if (url.isEmpty) return;
    if (_isSocialOrStreamingUrl(url)) {
      _showSocialQualitySelector(url, threads);
    } else {
      String fileName = url.split('/').last.split('?').first;
      if (fileName.isEmpty || !fileName.contains('.')) {
        fileName = 'RDM_${DateTime.now().millisecondsSinceEpoch}.mp4';
      }
      await _createAndStartTask(url, fileName, threads);
    }
  }

  void _showSocialQualitySelector(String pageUrl, int threads) {
    final List<SocialFormatOption> formats = [
      SocialFormatOption(label: 'Full HD Video • 1080p (MP4)', quality: '1080', ext: 'mp4'),
      SocialFormatOption(label: 'HD Video • 720p (MP4)', quality: '720', ext: 'mp4'),
      SocialFormatOption(label: 'Standard Video • 480p (MP4)', quality: '480', ext: 'mp4'),
      SocialFormatOption(label: 'Data Saver Video • 360p (MP4)', quality: '360', ext: 'mp4'),
      SocialFormatOption(
          label: 'High Quality Audio Only • MP3 (320kbps)',
          quality: 'audio',
          ext: 'mp3',
          isAudio: true),
    ];

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
            const Row(
              children: [
                Icon(Icons.Auto_awesome, color: Color(0xFF00F0FF)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Social & Streaming Media Detected',
                    style: TextStyle(
                        color: Color(0xFF00F0FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Select Resolution (Turbo $threads Threads):',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const Divider(color: Colors.white12, height: 20),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: formats.length,
                itemBuilder: (context, idx) {
                  final opt = formats[idx];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      opt.isAudio ? Icons.audiotrack : Icons.videocam,
                      color: opt.isAudio
                          ? const Color(0xFF00FF87)
                          : const Color(0xFF00F0FF),
                    ),
                    title: Text(opt.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0E17),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFF00FF87).withOpacity(0.5)),
                      ),
                      child: Text(
                        opt.ext.toUpperCase(),
                        style: const TextStyle(
                            color: Color(0xFF00FF87),
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _resolveSocialLinkAndDownload(pageUrl, opt, threads);
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

  Future<void> _resolveSocialLinkAndDownload(
      String pageUrl, SocialFormatOption opt, int threads) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF151C2C),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF00F0FF)),
            SizedBox(width: 20),
            Expanded(child: Text('Extracting direct high-speed stream...')),
          ],
        ),
      ),
    );

    String? directUrl;
    String fileName =
        'RDM_${opt.quality}p_${DateTime.now().millisecondsSinceEpoch}.${opt.ext}';

    // মাল্টি-এন্ডপয়েন্ট ক্লাউড এক্সট্রাক্টর (YouTube, FB, Insta, TikTok)
    final List<String> apiEndpoints = [
      'https://api.cobalt.tools/api/json',
      'https://co.wuk.sh/api/json',
    ];

    for (final endpoint in apiEndpoints) {
      try {
        final res = await _dio.post(
          endpoint,
          data: {
            'url': pageUrl,
            'vQuality': opt.isAudio ? '720' : opt.quality,
            'isAudioOnly': opt.isAudio,
            'aFormat': 'mp3',
            'filenamePattern': 'basic',
          },
          options: Options(
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
        );

        if (res.data != null && res.data is Map) {
          final map = res.data as Map;
          if (map['url'] != null) {
            directUrl = map['url'].toString();
            if (map['filename'] != null) {
              fileName = map['filename'].toString();
            }
            break;
          }
        }
      } catch (_) {}
    }

    if (mounted) Navigator.pop(context);

    if (directUrl != null && directUrl.isNotEmpty) {
      await _createAndStartTask(directUrl, fileName, threads);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Cloud extractor busy! Try pasting a direct video link or retry in a moment.'),
            backgroundColor: Colors.orangeAccent,
          ),
        );
      }
    }
  }

  Future<void> _createAndStartTask(
      String url, String fileName, int threads) async {
    final savePath = await _getDownloadFolderPath(fileName);
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      fileName: fileName,
      savePath: savePath,
      threads: threads,
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

  Future<void> _runMultiPartDownload(DownloadTask task) async {
    final int n = task.threads;
    final int chunkSize = (task.totalBytes / n).ceil();
    List<int> partDownloaded = List<int>.filled(n, 0);
    if (task.partProgress.length != n) {
      task.partProgress = List<double>.filled(n, 0.0);
    }

    int lastTotalBytes = task.downloadedBytes;
    DateTime lastSpeedTime = DateTime.now();

    List<Future<void>> futures = [];

    for (int i = 0; i < n; i++) {
      final int start = i * chunkSize;
      final int end =
          (i == n - 1) ? task.totalBytes - 1 : (start + chunkSize - 1);
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

        final raf = partFile.openSync(
            mode: existing > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in response.data!.stream) {
            if (task.cancelToken!.isCancelled) break;
            raf.writeFromSync(chunk);
            partDownloaded[i] += chunk.length;
            task.partProgress[i] =
                (partDownloaded[i] / partTotal).clamp(0.0, 1.0);

            final now = DateTime.now();
            final diff = now.difference(lastSpeedTime).inMilliseconds;
            if (diff >= 600) {
              int currentSum = 0;
              for (int val in partDownloaded) {
                currentSum += val;
              }
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

    final contentLength = int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '0') ??
        0;
    if (contentLength > 0) task.totalBytes = existingLength + contentLength;

    final raf =
        file.openSync(mode: isPartial ? FileMode.append : FileMode.write);
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

  void _pauseTask(
