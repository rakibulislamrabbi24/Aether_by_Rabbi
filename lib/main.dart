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
  String id;
  String url;
  String fileName;
  String savePath;
  int downloadedBytes;
  int totalBytes;
  String status;
  String speed;
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
  });

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'fileName': fileName,
        'savePath': savePath,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'status': status == 'Downloading' ? 'Paused' : status,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        id: json['id'],
        url: json['url'],
        fileName: json['fileName'],
        savePath: json['savePath'],
        downloadedBytes: json['downloadedBytes'] ?? 0,
        totalBytes: json['totalBytes'] ?? 0,
        status: json['status'] ?? 'Paused',
      );
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
    final List<String>? list = prefs.getStringList('rdm_tasks_v3');
    if (list != null) {
      setState(() {
        _tasks = list.map((item) => DownloadTask.fromJson(jsonDecode(item))).toList();
      });
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> list = _tasks.map((task) => jsonEncode(task.toJson())).toList();
    await prefs.setStringList('rdm_tasks_v3', list);
  }

  Future<String> _getDownloadFolderPath(String fileName) async {
    Directory? dir = Directory('/storage/emulated/0/Download/RDM_Pro');
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      }
    }
    return '${dir.path}/$fileName';
  }

  Future<void> _addNewDownload(String url) async {
    if (url.isEmpty) return;

    String fileName = url.split('/').last.split('?').first;
    if (fileName.isEmpty || !fileName.contains('.')) {
      fileName = 'RDM_${DateTime.now().millisecondsSinceEpoch}.mp4';
    }

    final savePath = await _getDownloadFolderPath(fileName);
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      fileName: fileName,
      savePath: savePath,
    );

    setState(() => _tasks.insert(0, task));
    await _saveHistory();
    _startOrResumeTask(task);
  }

  Future<void> _startOrResumeTask(DownloadTask task) async {
    task.cancelToken = CancelToken();
    WakelockPlus.enable();

    final file = File(task.savePath);
    int existingLength = 0;
    if (await file.exists()) {
      existingLength = await file.length();
    }
    task.downloadedBytes = existingLength;

    setState(() {
      task.status = 'Downloading';
      task.speed = 'Connecting...';
    });
    await _saveHistory();

    try {
      final response = await _dio.get<ResponseBody>(
        task.url,
        cancelToken: task.cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: existingLength > 0 ? {'Range': 'bytes=$existingLength-'} : null,
        ),
      );

      final isPartial = response.statusCode == 206;
      if (!isPartial && existingLength > 0) {
        existingLength = 0;
        task.downloadedBytes = 0;
      }

      final contentLength = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '0') ?? 0;
      if (contentLength > 0) {
        task.totalBytes = existingLength + contentLength;
      }

      final raf = file.openSync(mode: isPartial ? FileMode.append : FileMode.write);
      int lastBytes = task.downloadedBytes;
      DateTime lastTime = DateTime.now();

      await for (final chunk in response.data!.stream) {
        if (task.cancelToken!.isCancelled) break;
        raf.writeFromSync(chunk);
        task.downloadedBytes += chunk.length;

        final now = DateTime.now();
        final diff = now.difference(lastTime).inMilliseconds;
        if (diff >= 800) {
          final bytesDiff = task.downloadedBytes - lastBytes;
          final speedBps = (bytesDiff * 1000) / diff;
          String speedText = speedBps > 1024 * 1024
              ? '${(speedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s'
              : '${(speedBps / 1024).toStringAsFixed(1)} KB/s';

          setState(() => task.speed = speedText);
          _saveHistory();
          lastBytes = task.downloadedBytes;
          lastTime = now;
        }
      }
      await raf.close();

      if (!task.cancelToken!.isCancelled) {
        setState(() {
          task.status = 'Completed';
          task.speed = 'Done';
        });
        await _saveHistory();
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
    setState(() => _tasks.removeAt(index));
    await _saveHistory();
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes > 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  void _showAddLinkDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151C2C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF00F0FF), width: 1),
        ),
        title: const Text('New Download', style: TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold)),
        content: TextField(
          controller: _urlController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Paste direct file or video link...',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF0A0E17),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00F0FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              final url = _urlController.text.trim();
              _urlController.clear();
              Navigator.pop(context);
              _addNewDownload(url);
            },
            child: const Text('Download', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF151C2C),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF00F0FF).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF00F0FF)),
              ),
              child: const Text('RDM', style: TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 8),
            const Text('PRO v1.2.1', style: TextStyle(color: Color(0xFF00FF87), fontWeight: FontWeight.bold, fontSize: 15)),
          ],
        ),
      ),
      body: _tasks.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bolt, size: 72, color: Color(0xFF00F0FF)),
                  SizedBox(height: 12),
                  Text('RDM Pro Engine Ready', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 6),
                  Text('Direct Release & Resume Active', style: TextStyle(color: Color(0xFF00FF87), fontSize: 13)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _tasks.length,
              itemBuilder: (context, index) {
                final task = _tasks[index];
                final isDownloading = task.status == 'Downloading';
                final isCompleted = task.status == 'Completed';

                return Card(
                  color: const Color(0xFF151C2C),
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: const Color(0xFF00F0FF).withOpacity(0.2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                task.fileName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (!isCompleted)
                              IconButton(
                                icon: Icon(
                                  isDownloading ? Icons.pause_circle_filled : Icons.play_circle_fill,
                                  color: isDownloading ? Colors.amberAccent : const Color(0xFF00FF87),
                                  size: 28,
                                ),
                                onPressed: () => isDownloading ? _pauseTask(task) : _startOrResumeTask(task),
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                              onPressed: () => _deleteTask(index),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: task.progress,
                            minHeight: 8,
                            backgroundColor: const Color(0xFF0A0E17),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isCompleted ? const Color(0xFF00FF87) : const Color(0xFF00F0FF),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${_formatSize(task.downloadedBytes)} / ${_formatSize(task.totalBytes)} (${(task.progress * 100).toStringAsFixed(1)}%)',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              '${task.status} • ${task.speed}',
                              style: const TextStyle(color: Color(0xFF00FF87), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00F0FF),
        foregroundColor: Colors.black,
        onPressed: _showAddLinkDialog,
        icon: const Icon(Icons.add),
        label: const Text('Add Link', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF151C2C),
        selectedItemColor: const Color(0xFF00F0FF),
        unselectedItemColor: Colors.white54,
        currentIndex: _selectedTab,
        onTap: (idx) => setState(() => _selectedTab = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.download_rounded), label: 'Downloads'),
          BottomNavigationBarItem(icon: Icon(Icons.language), label: 'Browser'),
          BottomNavigationBarItem(icon: Icon(Icons.hub), label: 'Torrents'),
        ],
      ),
    );
  }
}
