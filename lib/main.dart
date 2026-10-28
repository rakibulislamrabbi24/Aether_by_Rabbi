import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
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
          primary: Color(0xFF00F0FF), // Neon Cyan
          secondary: Color(0xFF00FF87), // Neon Green
          surface: Color(0xFF151C2C),
        ),
      ),
      home: const RDMHomeScreen(),
    );
  }
}

class DownloadTask {
  String url;
  String fileName;
  double progress;
  String status; // Downloading, Paused, Completed, Failed
  String speed;
  CancelToken cancelToken;

  DownloadTask({
    required this.url,
    required this.fileName,
    this.progress = 0.0,
    this.status = 'Starting...',
    this.speed = '0 KB/s',
  }) : cancelToken = CancelToken();
}

class RDMHomeScreen extends StatefulWidget {
  const RDMHomeScreen({super.key});

  @override
  State<RDMHomeScreen> createState() => _RDMHomeScreenState();
}

class _RDMHomeScreenState extends State<RDMHomeScreen> {
  final List<DownloadTask> _tasks = [];
  final Dio _dio = Dio();
  final TextEditingController _urlController = TextEditingController();
  int _selectedTab = 0;

  Future<void> _startNewDownload(String url) async {
    if (url.isEmpty) return;

    String fileName = url.split('/').last.split('?').first;
    if (fileName.isEmpty || !fileName.contains('.')) {
      fileName = 'RDM_File_${DateTime.now().millisecondsSinceEpoch}.bin';
    }

    final task = DownloadTask(url: url, fileName: fileName);
    setState(() {
      _tasks.insert(0, task);
    });

    try {
      final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/${task.fileName}';

      int lastReceived = 0;
      DateTime lastTime = DateTime.now();

      await _dio.download(
        url,
        savePath,
        cancelToken: task.cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final now = DateTime.now();
            final timeDiff = now.difference(lastTime).inMilliseconds;

            if (timeDiff > 500) {
              final bytesDiff = received - lastReceived;
              final speedBps = (bytesDiff * 1000) / timeDiff;
              String speedText = speedBps > 1024 * 1024
                  ? '${(speedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s'
                  : '${(speedBps / 1024).toStringAsFixed(1)} KB/s';

              setState(() {
                task.progress = received / total;
                task.status = 'Downloading';
                task.speed = speedText;
              });

              lastReceived = received;
              lastTime = now;
            }
          }
        },
      );

      setState(() {
        task.progress = 1.0;
        task.status = 'Completed';
        task.speed = 'Done';
      });
    } catch (e) {
      if (CancelToken.isCancel(e as DioException)) {
        setState(() => task.status = 'Canceled');
      } else {
        setState(() => task.status = 'Failed');
      }
    }
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
              _startNewDownload(url);
            },
            child: const Text('Start Now', style: TextStyle(fontWeight: FontWeight.bold)),
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
        elevation: 0,
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
            const Text('PRO', style: TextStyle(color: Color(0xFF00FF87), fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.public, color: Color(0xFF00F0FF)), onPressed: () {}),
          IconButton(icon: const Icon(Icons.settings, color: Colors.white70), onPressed: () {}),
        ],
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
                  Text('Tap + to add a download link', style: TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _tasks.length,
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return Card(
                  color: const Color(0xFF151C2C),
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                task.fileName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (task.status == 'Downloading')
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
                                onPressed: () => task.cancelToken.cancel(),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: task.progress,
                            minHeight: 8,
                            backgroundColor: const Color(0xFF0A0E17),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00F0FF)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${(task.progress * 100).toStringAsFixed(1)}% • ${task.status}',
                              style: const TextStyle(color: Color(0xFF00FF87), fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              task.speed,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
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
