import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_metadata_writer.dart';
import 'audio_file_format.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';

/// 下载任务类型。
enum DownloadTaskKind { download, playCache }

/// 内部待执行任务。
class _PendingTask {
  _PendingTask({
    required this.kind,
    required this.song,
    required this.quality,
    required this.url,
    required this.completer,
    this.onProgress,
  });

  final DownloadTaskKind kind;
  final Song song;
  final AudioQuality quality;
  final String url;
  final Completer<String> completer;
  final void Function(int received, int total)? onProgress;
}

/// 歌曲下载服务（IO 层 + dio 下载 + 并发管理）。
///
/// 下载到持久目录（用户主动下载），播放缓存到临时目录（系统可清理）。
/// 两者共享并发上限，用户主动下载优先。
class DownloadService {
  DownloadService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 10),
  ));
  final Map<String, CancelToken> _cancelTokens = {};
  final int _maxConcurrent = AppConfig.maxConcurrentDownloads;
  int _running = 0;
  final List<_PendingTask> _queue = [];

  static const _customDownloadDirKey = 'settings.custom_download_dir';

  /// 获取用户自定义下载目录（若未设置返回 null）。
  Future<String?> getCustomDownloadDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_customDownloadDirKey);
    } catch (_) {
      return null;
    }
  }

  /// 设置自定义下载目录（传 null 或空重置为系统默认）。
  Future<void> setCustomDownloadDir(String? path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (path == null || path.isEmpty) {
        await prefs.remove(_customDownloadDirKey);
      } else {
        await prefs.setString(_customDownloadDirKey, path);
      }
    } catch (_) {}
  }

  /// 持久下载目录。
  ///
  /// Android 优先使用系统公共下载目录（/storage/emulated/0/Download/KA Music），
  /// 需要存储权限；其他平台或获取失败时回退到应用文档目录。
  Future<Directory> downloadDir() async {
    try {
      final customPath = await getCustomDownloadDir();
      if (customPath != null && customPath.trim().isNotEmpty) {
        final customDir = Directory(customPath.trim());
        if (!customDir.existsSync()) {
          await customDir.create(recursive: true);
        }
        return customDir;
      }
    } catch (e) {
      debugPrint('[KA Music] Custom download dir error: $e');
    }

    if (Platform.isAndroid) {
      try {
        // Android 11+ 需要 MANAGE_EXTERNAL_STORAGE 权限才能写入公共目录
        // Android 10 及以下需要 WRITE_EXTERNAL_STORAGE
        final hasPermission = await _requestStoragePermission();
        if (hasPermission) {
          final dir = Directory('/storage/emulated/0/Download/${AppConfig.downloadDirName}');
          if (!dir.existsSync()) {
            await dir.create(recursive: true);
          }
          return dir;
        }
      } catch (e) {
        debugPrint('[KA Music] Failed to access public Download dir: $e');
      }
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/${AppConfig.downloadDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 请求存储写入权限。
  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      // Android 11+ (API 30+): 需要 MANAGE_EXTERNAL_STORAGE
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      // 先尝试请求普通写入权限（Android 10 及以下）
      if (await Permission.storage.isGranted) {
        return true;
      }
      // 请求 manageExternalStorage（Android 11+）
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
      // 回退请求普通存储权限
      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }
    return true;
  }

  /// 临时播放缓存目录。
  Future<Directory> playCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/${AppConfig.playCacheDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 文件命名：{歌手}-{歌曲名}.{ext}
  String fileNameFor(Song song, AudioQuality quality) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final safeArtist = _sanitizeFileName(song.artist);
    final safeTitle = _sanitizeFileName(song.title);
    final name = (safeArtist.isNotEmpty && safeTitle.isNotEmpty)
        ? '$safeArtist-$safeTitle'
        : song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '$name.$ext';
  }

  /// 移除文件名中不合法的字符。
  String _sanitizeFileName(String name) {
    // 替换文件系统不允许的字符：\ / : * ? " < > |
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceFirst(RegExp(r'^_+'), '')
        .replaceFirst(RegExp(r'_+$'), '')
        .trim();
  }

  /// 缓存 key：{hash}_{quality.apiValue}
  String cacheKeyFor(Song song, AudioQuality quality) {
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '${safeHash}_${quality.apiValue}';
  }

  /// 下载到持久目录（用户下载）。支持断点续传。
  ///
  /// [onProgress] 回调 (received, total)。返回最终文件路径。
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.download,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
      onProgress: onProgress,
    );
    _enqueue(task);
    return completer.future;
  }

  /// 下载到临时缓存目录（播放缓存）。无进度上报（静默）。
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.playCache,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
    );
    _enqueue(task);
    return completer.future;
  }

  void _enqueue(_PendingTask task) {
    // 用户下载优先：插入队列头部之后（在其它下载任务之后、播放缓存之前）
    if (task.kind == DownloadTaskKind.download) {
      // 插入到第一个 playCache 任务之前
      final firstPlayCache = _queue
          .indexWhere((t) => t.kind == DownloadTaskKind.playCache);
      if (firstPlayCache >= 0) {
        _queue.insert(firstPlayCache, task);
      } else {
        _queue.add(task);
      }
    } else {
      _queue.add(task);
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_running >= _maxConcurrent) return;
    if (_queue.isEmpty) return;

    final task = _queue.removeAt(0);
    _running++;

    try {
      final path = await _executeTask(task);
      task.completer.complete(path);
    } catch (error) {
      task.completer.completeError(error);
    } finally {
      _running--;
      _processQueue();
    }
  }

  Future<String> _executeTask(_PendingTask task) async {
    final key = cacheKeyFor(task.song, task.quality);
    final fileName = fileNameFor(task.song, task.quality);
    final dir = task.kind == DownloadTaskKind.download
        ? await downloadDir()
        : await playCacheDir();
    final targetPath = '${dir.path}/$fileName';
    final partPath = '$targetPath.part';
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;

    try {
      // 断点续传：检查已有 .part 文件大小
      int startOffset = 0;
      final partFile = File(partPath);
      if (partFile.existsSync()) {
        startOffset = await partFile.length();
      }

      final headers = <String, dynamic>{};
      if (startOffset > 0) {
        headers[HttpHeaders.rangeHeader] = 'bytes=$startOffset-';
      }

      await _dio.download(
        task.url,
        partPath,
        onReceiveProgress: (received, total) {
          final actualTotal = startOffset + total;
          final actualReceived = startOffset + received;
          task.onProgress?.call(actualReceived, actualTotal);
        },
        options: Options(headers: headers),
        cancelToken: cancelToken,
        deleteOnError: false,
      );

      // 下载完成，重命名 .part 为最终文件
      if (partFile.existsSync()) {
        await partFile.rename(targetPath);
      }

      // A server may downgrade the requested quality. Match the extension to
      // the actual codec so other players choose the correct metadata parser.
      final format = await inspectAudioFile(targetPath);
      final extension = switch (format.format) {
        AudioFileFormat.mp3 => '.mp3',
        AudioFileFormat.flac => '.flac',
        AudioFileFormat.unsupported => null,
      };
      if (extension != null && !targetPath.endsWith(extension)) {
        final corrected = targetPath.substring(0, targetPath.lastIndexOf('.')) + extension;
        await File(targetPath).rename(corrected);
        return corrected;
      }
      return targetPath;
    } finally {
      _cancelTokens.remove(key);
    }
  }

  /// User downloads await this step before becoming visible as completed.
  /// Playback cache files remain untouched and do not fetch metadata or lyrics.
  Future<DownloadMetadataResult> writeDownloadMetadata({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
  }) => DownloadMetadataWriter.write(
    filePath: filePath,
    song: song,
    lyricsText: lyricsText,
    saveLyricsFile: saveLyricsFile,
  );

  /// 取消下载/缓存任务。
  Future<void> cancel(String cacheKey) async {
    final token = _cancelTokens[cacheKey];
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  /// 删除文件（若存在）。
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
    final sidecar = File(DownloadMetadataWriter.lyricsFilePath(path));
    if (await sidecar.exists()) await sidecar.delete();
  }

  /// 获取文件大小（字节），不存在返回 0。
  Future<int> fileSize(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      return await file.length();
    }
    return 0;
  }

  /// 获取下载目录的总大小（字节）。
  Future<int> getDownloadDirSize() async {
    try {
      final dir = await downloadDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 获取播放缓存目录的总大小（字节）。
  Future<int> getPlayCacheDirSize() async {
    try {
      final dir = await playCacheDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空整个播放缓存目录。
  Future<void> clearPlayCacheDir() async {
    final dir = await playCacheDir();
    if (dir.existsSync()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    }
  }

  /// LRU 清理播放缓存至 [maxBytes]（默认 [AppConfig.playCacheMaxBytes]）以下。
  ///
  /// [entries] 为当前缓存索引（按 cachedAt 升序排列）。
  /// [excludePaths] 中的文件跳过清理（如正在播放的文件）。
  Future<void> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
  }) async {
    int totalSize = 0;
    final fileSizes = <String, int>{};
    for (final entry in entries) {
      final size = await fileSize(entry.filePath);
      fileSizes[entry.filePath] = size;
      totalSize += size;
    }

    final limit = maxBytes ?? AppConfig.playCacheMaxBytes;
    if (limit < 0) return; // 小于 0 代表无限制
    if (totalSize <= limit) return;

    // 按 cachedAt 升序删除最旧条目
    final sorted = List.of(entries)
      ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    for (final entry in sorted) {
      if (totalSize <= limit) break;
      if (excludePaths.contains(entry.filePath)) continue;
      final size = fileSizes[entry.filePath] ?? 0;
      await deleteFile(entry.filePath);
      totalSize -= size;
    }
  }

  /// 关闭 Dio（应用退出时调用）。
  void dispose() {
    _dio.close();
  }
}
