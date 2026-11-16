import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/download_service.dart';
import '../services/download_metadata_writer.dart';
import '../services/music_api.dart';

/// 下载状态枚举。
enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// 批量下载结果统计。
class BatchDownloadResult {
  const BatchDownloadResult({
    required this.enqueued,
    required this.skipped,
    required this.failed,
  });

  /// 成功加入下载队列的歌曲数。
  final int enqueued;

  /// 跳过的歌曲数（已下载或已在下载中）。
  final int skipped;

  /// 加入队列失败（无播放地址/网络错误）的歌曲数。
  final int failed;

  /// 已加入队列（含已下载与失败）的总处理数量。
  int get total => enqueued + skipped + failed;
}

/// 下载条目。
class DownloadEntry {
  const DownloadEntry({
    required this.song,
    required this.quality,
    required this.status,
    this.progress = 0,
    this.filePath,
    this.error,
    this.downloadedAt,
  });

  final Song song;
  final AudioQuality quality;
  final DownloadStatus status;
  final double progress;
  final String? filePath;
  final String? error;
  final DateTime? downloadedAt;

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? error,
    DateTime? downloadedAt,
  }) {
    return DownloadEntry(
      song: song,
      quality: quality,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      error: error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }
}

/// 播放缓存条目。
class PlayCacheEntry {
  const PlayCacheEntry({
    required this.cacheKey,
    required this.song,
    required this.quality,
    required this.filePath,
    required this.size,
    required this.cachedAt,
  });

  final String cacheKey;
  final Song song;
  final AudioQuality quality;
  final String filePath;
  final int size;
  final DateTime cachedAt;
}

/// 下载与播放缓存控制器。
///
/// 管理用户主动下载（持久目录）和播放缓存（临时目录）。
/// 下载状态通过 [DownloadStatus] + [entryFor] 查询，UI 用 AnimatedBuilder 监听。
class DownloadController extends ChangeNotifier {
  DownloadController(this._service, this._api);

  final DownloadService _service;
  final MusicApi _api;

  static const _downloadsIndexKey = 'ka_music_downloads_index';
  static const _playCacheIndexKey = 'ka_music_play_cache_index';
  static const _playCacheLimitKey = 'settings.play_cache_limit';
  static const _saveLyricsFileKey = 'settings.download_save_lyrics_file';
  static const _playbackFileCheckTimeout = Duration(milliseconds: 400);

  final Map<String, DownloadEntry> _downloads = {}; // key = hash
  final Map<String, PlayCacheEntry> _playCache = {}; // key = hash_quality
  final Map<String, Object> _downloadAttempts = {};
  final Map<String, Future<void>> _transferTails = {};
  int _metadataRunning = 0;
  final List<Completer<void>> _metadataWaiters = [];
  Future<void>? _initializationFuture;
  final Completer<void> _downloadIndexReady = Completer<void>();

  int _playCacheLimit = 300 * 1024 * 1024; // 默认 300MB
  int get playCacheLimit => _playCacheLimit;

  bool _saveLyricsFile = false;
  bool get saveLyricsFile => _saveLyricsFile;

  /// Embedding is always attempted; this also keeps a portable UTF-8 LRC copy.
  Future<void> setSaveLyricsFile(bool enabled) async {
    _saveLyricsFile = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_saveLyricsFileKey, enabled);
    notifyListeners();
  }

  Future<void> setPlayCacheLimit(int limitInBytes) async {
    _playCacheLimit = limitInBytes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_playCacheLimitKey, limitInBytes);
    notifyListeners();
    await _prunePlayCache(excludePaths: const {});
  }

  /// 启动时加载索引并校验文件存在性。
  Future<void> initialize() {
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _playCacheLimit = prefs.getInt(_playCacheLimitKey) ?? (300 * 1024 * 1024);
      _saveLyricsFile = prefs.getBool(_saveLyricsFileKey) ?? false;
      await _loadDownloads();
    } catch (error) {
      debugPrint('[KA Music] Failed to restore download index: $error');
    } finally {
      if (!_downloadIndexReady.isCompleted) {
        _downloadIndexReady.complete();
      }
    }

    // 下载索引已经可供播放查询后，再在后台校验磁盘文件。部分旧版本保存的
    // 沙盒路径在覆盖安装后可能变成慢 I/O；它不能继续阻塞点歌或下一曲。
    unawaited(_validateRestoredDownloads());

    // 播放只需等用户主动下载索引恢复；播放缓存索引和 LRU
    // 清理失败都不应该阻断选歌、下一曲或网络播放。
    try {
      await _loadPlayCache();
      await _prunePlayCache(excludePaths: const {});
    } catch (error) {
      debugPrint('[KA Music] Failed to restore play cache: $error');
    }
    notifyListeners();
  }

  Future<void> _loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_downloadsIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        final downloadedAtStr = item['downloadedAt'] as String?;
        _downloads[_downloadKey(song)] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloaded,
          filePath: filePath,
          downloadedAt: downloadedAtStr != null
              ? DateTime.tryParse(downloadedAtStr)
              : null,
        );
      }
    } catch (_) {}
  }

  Future<void> _validateRestoredDownloads() async {
    var changed = false;
    for (final entry in _downloads.entries.toList()) {
      final filePath = entry.value.filePath;
      if (filePath == null) continue;
      final size = await _fileSizeForPlayback(filePath);
      // 超时或文件系统异常时保留索引，下次播放仍可重新校验；只有明确确认
      // 文件不存在时才移除下载标记。
      if (size == 0) {
        _downloads.remove(entry.key);
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _persistDownloads();
  }

  Future<void> _loadPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playCacheIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final cacheKey = item['cacheKey'] as String? ?? '';
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        final size = await _service.fileSize(filePath);
        if (size == 0) continue;
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final cachedAtStr = item['cachedAt'] as String?;
        _playCache[cacheKey] = PlayCacheEntry(
          cacheKey: cacheKey,
          song: song,
          quality: quality,
          filePath: filePath,
          size: size,
          cachedAt: cachedAtStr != null
              ? DateTime.tryParse(cachedAtStr) ?? DateTime.now()
              : DateTime.now(),
        );
      }
    } catch (_) {}
  }

  Future<void> _persistDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _downloads.values
        .where((e) => e.status == DownloadStatus.downloaded)
        .map(
          (e) => {
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'downloadedAt': e.downloadedAt?.toIso8601String(),
          },
        )
        .toList();
    await prefs.setString(_downloadsIndexKey, jsonEncode(list));
  }

  Future<void> _persistPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _playCache.values
        .map(
          (e) => {
            'cacheKey': e.cacheKey,
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'size': e.size,
            'cachedAt': e.cachedAt.toIso8601String(),
          },
        )
        .toList();
    await prefs.setString(_playCacheIndexKey, jsonEncode(list));
  }

  // ===== 查询 =====

  String _downloadKey(Song song) => song.hash.trim().toLowerCase();

  /// 返回可播放的本地文件路径。
  ///
  /// 用户主动下载的文件不受当前音质设置限制，始终优先于网络地址；播放缓存
  /// 仍按当前音质匹配。查询前会等待启动索引恢复，并再次校验文件仍然存在。
  Future<String?> localPathFor(Song song, AudioQuality quality) async {
    unawaited(initialize());
    if (!_downloadIndexReady.isCompleted) {
      try {
        await _downloadIndexReady.future.timeout(_playbackFileCheckTimeout);
      } on TimeoutException {
        debugPrint(
          '[KA Music][playback] download-index timeout; use network source',
        );
        return null;
      }
    }
    final key = _service.cacheKeyFor(song, quality);
    // 手动下载优先：即使当前切换了音质，也直接播放已有的完整本地文件。
    final downloadKey = _downloadKey(song);
    final download = _downloads[downloadKey];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null) {
      final size = await _fileSizeForPlayback(download!.filePath!);
      if (size != null && size > 0) {
        return download.filePath;
      }
      if (size == null) return null;
      _downloads.remove(downloadKey);
      notifyListeners();
      await _persistDownloads();
    }
    // 其次使用与当前音质一致的播放缓存。
    final cache = _playCache[key];
    if (cache != null) {
      final size = await _fileSizeForPlayback(cache.filePath);
      if (size != null && size > 0) {
        return cache.filePath;
      }
      if (size == null) return null;
      _playCache.remove(key);
      notifyListeners();
      await _persistPlayCache();
    }
    return null;
  }

  Future<int?> _fileSizeForPlayback(String path) async {
    try {
      return await _service.fileSize(path).timeout(_playbackFileCheckTimeout);
    } on TimeoutException {
      debugPrint(
        '[KA Music][playback] local-file check timeout; use network source',
      );
      return null;
    } catch (error) {
      debugPrint(
        '[KA Music][playback] local-file check failed; use network source: '
        '$error',
      );
      return null;
    }
  }

  bool isDownloaded(Song song) =>
      _downloads[_downloadKey(song)]?.status == DownloadStatus.downloaded;

  DownloadEntry? entryFor(Song song) => _downloads[_downloadKey(song)];

  List<Song> get downloadedSongs => _downloads.values
      .where((e) => e.status == DownloadStatus.downloaded)
      .map((e) => e.song)
      .toList();

  List<DownloadEntry> get downloadEntries => _downloads.values.toList();

  List<PlayCacheEntry> get playCacheEntries => _playCache.values.toList();

  /// 获取下载目录大小（字节）。
  Future<int> getDownloadDirSize() => _service.getDownloadDirSize();

  /// 获取播放缓存目录大小（字节）。
  Future<int> getPlayCacheDirSize() => _service.getPlayCacheDirSize();

  // ===== 下载操作 =====

  /// 用户主动下载歌曲。
  Future<void> download(Song song, AudioQuality quality) async {
    final key = _downloadKey(song);
    final existing = _downloads[key];
    if (existing?.status == DownloadStatus.downloading) return;
    if (existing?.status == DownloadStatus.downloaded) return;
    final attempt = Object();
    _downloadAttempts[key] = attempt;

    _downloads[key] = DownloadEntry(
      song: song,
      quality: quality,
      status: DownloadStatus.downloading,
      progress: 0,
    );
    notifyListeners();

    try {
      final playUrl = await _api.songUrl(song, quality: quality);
      if (_downloadAttempts[key] != attempt) return;
      if (playUrl.url.isEmpty) {
        throw Exception('这首歌暂时没有可播放地址');
      }
      await _transfer(song, quality, playUrl.url, attempt);
    } catch (error) {
      if (_downloadAttempts[key] != attempt) return;
      _downloads[key] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  /// 批量下载：把一组歌曲一次性加入现有下载队列。
  ///
  /// - 已下载、正在下载的歌曲自动跳过；
  /// - 播放地址解析失败或无地址的歌曲进入失败列表，可单独重试；
  /// - 地址解析采用有限并发（4 路），避免一次性发起大量请求；
  /// - 文件传输复用 [DownloadService] 的并发队列（上限
  ///   [AppConfig.maxConcurrentDownloads]），支持进度与断点续传。
  Future<BatchDownloadResult> enqueueBatch(
    List<Song> songs,
    AudioQuality quality,
  ) async {
    const urlConcurrency = 4;
    var enqueued = 0;
    var skipped = 0;
    var failed = 0;
    var cursor = 0;

    Future<void> worker() async {
      while (cursor < songs.length) {
        final song = songs[cursor++];
        final key = _downloadKey(song);
        final existing = _downloads[key];
        if (existing?.status == DownloadStatus.downloading ||
            existing?.status == DownloadStatus.downloaded) {
          skipped++;
          continue;
        }
        final attempt = Object();
        _downloadAttempts[key] = attempt;

        _downloads[key] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloading,
          progress: 0,
        );
        notifyListeners();

        try {
          final playUrl = await _api.songUrl(song, quality: quality);
          if (_downloadAttempts[key] != attempt) {
            skipped++;
            continue;
          }
          if (playUrl.url.isEmpty) {
            _downloads[key] = DownloadEntry(
              song: song,
              quality: quality,
              status: DownloadStatus.failed,
              error: '这首歌暂时没有可播放地址',
            );
            notifyListeners();
            failed++;
            continue;
          }
          enqueued++;
          unawaited(_transfer(song, quality, playUrl.url, attempt));
        } catch (error) {
          if (_downloadAttempts[key] != attempt) continue;
          _downloads[key] = DownloadEntry(
            song: song,
            quality: quality,
            status: DownloadStatus.failed,
            error: error.toString(),
          );
          notifyListeners();
          failed++;
        }
      }
    }

    final workerCount = songs.length < urlConcurrency
        ? songs.length
        : urlConcurrency;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    return BatchDownloadResult(
      enqueued: enqueued,
      skipped: skipped,
      failed: failed,
    );
  }

  /// 文件传输（播放地址已解析）。成功后写入已下载索引，失败进入失败列表。
  Future<void> _transfer(
    Song song,
    AudioQuality quality,
    String url,
    Object attempt,
  ) async {
    final key = _downloadKey(song);
    // A cancelled finalizer must finish its atomic replacement before a retry
    // can download/tag the same path. Only the current attempt may publish it.
    final previous = _transferTails[key];
    final done = Completer<void>();
    _transferTails[key] = done.future;
    try {
      if (previous != null) await previous;
      if (_downloadAttempts[key] != attempt) return;
      await _runTransfer(song, quality, url, attempt);
    } finally {
      done.complete();
      if (identical(_transferTails[key], done.future)) {
        _transferTails.remove(key);
      }
    }
  }

  Future<void> _runTransfer(
    Song song,
    AudioQuality quality,
    String url,
    Object attempt,
  ) async {
    final key = _downloadKey(song);
    try {
      final path = await _service.download(
        song: song,
        quality: quality,
        url: url,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          final entry = _downloads[key];
          if (_downloadAttempts[key] == attempt &&
              entry?.status == DownloadStatus.downloading) {
            _downloads[key] = entry!.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );
      if (_downloadAttempts[key] != attempt) return;
      // Batch URL resolution queues rapidly. Limit enrichment + cover/tag work
      // independently so it cannot fan out to an entire playlist at once.
      await _acquireMetadataSlot();
      late ({Song song, String lyrics}) metadata;
      try {
        if (_downloadAttempts[key] != attempt) return;
        metadata = await _prepareDownloadMetadata(song);
        if (_downloadAttempts[key] != attempt) return;
        final prefs = await SharedPreferences.getInstance();
        if (_downloadAttempts[key] != attempt) return;
        await _service.writeDownloadMetadata(
          filePath: path,
          song: metadata.song,
          lyricsText: metadata.lyrics,
          saveLyricsFile: prefs.getBool(_saveLyricsFileKey) ?? false,
        );
      } finally {
        _releaseMetadataSlot();
      }
      if (_downloadAttempts[key] != attempt) return;
      _downloads[key] = DownloadEntry(
        song: metadata.song,
        quality: quality,
        status: DownloadStatus.downloaded,
        progress: 1,
        filePath: path,
        downloadedAt: DateTime.now(),
      );
      notifyListeners();
      await _persistDownloads();
    } catch (error) {
      if (_downloadAttempts[key] != attempt) return;
      _downloads[key] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  Future<void> _acquireMetadataSlot() async {
    if (_metadataRunning < 3) {
      _metadataRunning++;
      return;
    }
    final ready = Completer<void>();
    _metadataWaiters.add(ready);
    await ready.future;
  }

  void _releaseMetadataSlot() {
    if (_metadataWaiters.isNotEmpty) {
      _metadataWaiters.removeAt(0).complete();
    } else {
      _metadataRunning--;
    }
  }

  Future<({Song song, String lyrics})> _prepareDownloadMetadata(
    Song song,
  ) async {
    var enriched = song;
    try {
      final detail = await _api
          .songDetail(song)
          .timeout(const Duration(seconds: 6));
      if (detail != null) {
        enriched = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          hash: song.hash,
          albumId: detail.albumId ?? song.albumId,
          albumAudioId: detail.albumAudioId ?? song.albumAudioId,
          albumName: detail.albumName?.isNotEmpty == true
              ? detail.albumName
              : song.albumName,
          coverUrl: detail.coverUrl?.isNotEmpty == true
              ? detail.coverUrl
              : song.coverUrl,
          duration: detail.duration ?? song.duration,
          releaseDate: detail.releaseDate ?? song.releaseDate,
          artists: song.artists,
          source: song.source,
          isCloudDrive: song.isCloudDrive,
        );
      }
    } catch (error) {
      debugPrint('[Download] Could not enrich song metadata: $error');
    }
    var text = '';
    try {
      final lyrics = await _api
          .lyrics(enriched)
          .timeout(const Duration(seconds: 8));
      text = downloadLyricsText(lyrics);
    } catch (error) {
      debugPrint('[Download] Could not fetch download lyrics: $error');
    }
    return (song: enriched, lyrics: text);
  }

  /// 移除一条失败记录（从失败列表清除）。
  void removeFailed(Song song) {
    final key = _downloadKey(song);
    final entry = _downloads[key];
    if (entry?.status != DownloadStatus.failed) return;
    _downloads.remove(key);
    notifyListeners();
  }

  /// 取消下载。
  Future<void> cancelDownload(Song song) async {
    final downloadKey = _downloadKey(song);
    final entry = _downloads[downloadKey];
    if (entry?.status != DownloadStatus.downloading) return;
    final transferKey = _service.cacheKeyFor(song, entry!.quality);
    _downloadAttempts.remove(downloadKey);
    _downloads.remove(downloadKey);
    notifyListeners();
    await _service.cancel(transferKey);
  }

  /// 删除单个已下载歌曲。
  Future<void> deleteDownload(Song song) async {
    final key = _downloadKey(song);
    final entry = _downloads[key];
    if (entry?.filePath != null) {
      await _service.deleteFile(entry!.filePath!);
    }
    _downloads.remove(key);
    notifyListeners();
    await _persistDownloads();
  }

  /// 清空所有已下载歌曲。
  Future<void> clearAllDownloads() async {
    for (final entry in _downloads.values) {
      if (entry.filePath != null) {
        await _service.deleteFile(entry.filePath!);
      }
    }
    _downloads.clear();
    notifyListeners();
    await _persistDownloads();
  }

  // ===== 播放缓存 =====

  String? _activePlayCacheKey;

  /// 取消当前正在进行的后台播放缓存传输（切歌时调用，避免快速切歌浪费流量）。
  Future<void> cancelActivePlayCache() async {
    final activeKey = _activePlayCacheKey;
    if (activeKey == null) return;
    _activePlayCacheKey = null;
    final isManualDownload = _downloads.values.any(
      (entry) =>
          entry.status == DownloadStatus.downloading &&
          _service.cacheKeyFor(entry.song, entry.quality) == activeKey,
    );
    if (!isManualDownload) {
      await _service.cancel(activeKey);
    }
  }

  /// 后台缓存当前播放歌曲（稳定播放后调用）。url 来自 songUrl 结果。
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url,
  ) async {
    if (_playCacheLimit <= 0) return;
    final key = _service.cacheKeyFor(song, quality);
    // 已有缓存或已下载/正在下载则跳过
    if (_playCache[key] != null) return;
    final downloadStatus = _downloads[_downloadKey(song)]?.status;
    if (downloadStatus == DownloadStatus.downloading ||
        downloadStatus == DownloadStatus.downloaded) {
      return;
    }

    if (_activePlayCacheKey != null && _activePlayCacheKey != key) {
      await cancelActivePlayCache();
    }
    _activePlayCacheKey = key;

    try {
      final path = await _service.cacheForPlayback(
        song: song,
        quality: quality,
        url: url,
      );
      final size = await _service.fileSize(path);
      if (size <= 0) return;
      _playCache[key] = PlayCacheEntry(
        cacheKey: key,
        song: song,
        quality: quality,
        filePath: path,
        size: size,
        cachedAt: DateTime.now(),
      );
      notifyListeners();
      await _persistPlayCache();
      // LRU 清理
      await _prunePlayCache(excludePaths: {path});
    } catch (_) {
      // 播放缓存失败静默忽略
    } finally {
      if (_activePlayCacheKey == key) {
        _activePlayCacheKey = null;
      }
    }
  }

  /// 清空所有播放缓存。
  Future<void> clearPlayCache() async {
    await _service.clearPlayCacheDir();
    _playCache.clear();
    notifyListeners();
    await _persistPlayCache();
  }

  /// 删除单首播放缓存。
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final entry = _playCache[key];
    if (entry != null) {
      await _service.deleteFile(entry.filePath);
      _playCache.remove(key);
      notifyListeners();
      await _persistPlayCache();
    }
  }

  Future<void> _prunePlayCache({Set<String> excludePaths = const {}}) async {
    final entries =
        _playCache.values
            .map(
              (e) => (
                cacheKey: e.cacheKey,
                filePath: e.filePath,
                cachedAt: e.cachedAt,
              ),
            )
            .toList()
          ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    await _service.prunePlayCache(
      entries,
      maxBytes: _playCacheLimit,
      excludePaths: excludePaths,
    );

    // 清理后校验索引，移除已删除的条目
    final toRemove = <String>[];
    for (final entry in _playCache.values) {
      final size = await _service.fileSize(entry.filePath);
      if (size == 0 && !excludePaths.contains(entry.filePath)) {
        toRemove.add(entry.cacheKey);
      }
    }
    if (toRemove.isNotEmpty) {
      for (final key in toRemove) {
        _playCache.remove(key);
      }
      notifyListeners();
      await _persistPlayCache();
    }
  }

  /// 获取当前实际生效的下载目录绝对路径。
  Future<String> getDownloadDirPath() async {
    final dir = await _service.downloadDir();
    return dir.path;
  }

  /// 获取用户自定义的下载目录（若未配置返回 null）。
  Future<String?> getCustomDownloadDir() => _service.getCustomDownloadDir();

  /// 设置或清除用户自定义下载目录。
  Future<void> setCustomDownloadDir(String? path) async {
    await _service.setCustomDownloadDir(path);
    notifyListeners();
  }
}
