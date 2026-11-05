import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';

/// 播放统计数据。
///
/// 包含累计播放次数、累计听歌时长、最常听歌手/歌曲 Top 10、首次播放时间。
/// 通过 [toJson]/[fromJson] 持久化到 SharedPreferences。
class PlaybackStats {
  const PlaybackStats({
    this.totalPlays = 0,
    this.totalListenTime = Duration.zero,
    this.artistPlayCount = const {},
    this.songPlayCount = const {},
    this.firstPlayDate,
  });

  /// 累计播放次数（每次调用 recordPlay +1）。
  final int totalPlays;

  /// 累计听歌时长。
  final Duration totalListenTime;

  /// 歌手名 -> 播放次数。
  final Map<String, int> artistPlayCount;

  /// 歌曲标题 -> 播放次数。
  final Map<String, int> songPlayCount;

  /// 首次播放时间（本地统计）。
  final DateTime? firstPlayDate;

  factory PlaybackStats.fromJson(Map<String, dynamic> json) {
    return PlaybackStats(
      totalPlays: json['totalPlays'] as int? ?? 0,
      totalListenTime: Duration(
        milliseconds: json['totalListenMs'] as int? ?? 0,
      ),
      artistPlayCount: Map<String, int>.from(
        json['artistPlayCount'] as Map? ?? const {},
      ),
      songPlayCount: Map<String, int>.from(
        json['songPlayCount'] as Map? ?? const {},
      ),
      firstPlayDate: json['firstPlayDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['firstPlayDate'] as int)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'totalPlays': totalPlays,
    'totalListenMs': totalListenTime.inMilliseconds,
    'artistPlayCount': artistPlayCount,
    'songPlayCount': songPlayCount,
    'firstPlayDate': firstPlayDate?.millisecondsSinceEpoch,
  };

  /// 格式化听歌时长为 "x小时y分钟"、"y分钟" 或 "z秒"。
  ///
  /// 不足 1 分钟时显示秒数：只显示「不足1分钟」会让用户以为统计没有增长。
  String get formattedListenTime {
    final h = totalListenTime.inHours;
    final m = totalListenTime.inMinutes.remainder(60);
    if (h > 0) return '$h小时$m分钟';
    if (m > 0) return '$m分钟';
    final seconds = totalListenTime.inSeconds;
    if (seconds > 0) return '$seconds秒';
    return '0秒';
  }

  /// 最常听歌手 Top 10。
  List<MapEntry<String, int>> get topArtists {
    final entries = artistPlayCount.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries.take(10).toList();
  }

  /// 最常听歌曲 Top 10。
  List<MapEntry<String, int>> get topSongs {
    final entries = songPlayCount.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries.take(10).toList();
  }
}

/// 播放统计服务。
///
/// 提供本地播放统计的记录与查询：每次播放记 +1，每上报一次听歌时长同步累加。
///
/// 读取—修改—写回必须是串行的：切歌的 [recordPlay]、15 秒一次的时长落盘、
/// 暂停结算可能同时触发，并发执行会互相覆盖、把更新丢掉。
class PlaybackStatsService {
  static const _key = 'playback_stats';

  /// 串行化所有写操作。
  static Future<void> _writeChain = Future<void>.value();

  /// 读取当前统计；无数据时返回空的 [PlaybackStats]。
  Future<PlaybackStats> getStats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const PlaybackStats();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return PlaybackStats.fromJson(json);
      }
    } catch (_) {}
    return const PlaybackStats();
  }

  /// 记录一次播放：累加播放次数，统计歌手/歌曲计数。
  Future<void> recordPlay(Song song) {
    final artistKey = song.artist.trim().isEmpty ? '未知艺人' : song.artist;
    final songKey = song.title.trim().isEmpty ? '未知歌曲' : song.title;
    return _serialize(() async {
      final stats = await getStats();
      final artistCount = Map<String, int>.of(stats.artistPlayCount);
      final songCount = Map<String, int>.of(stats.songPlayCount);
      artistCount[artistKey] = (artistCount[artistKey] ?? 0) + 1;
      songCount[songKey] = (songCount[songKey] ?? 0) + 1;

      await _save(
        PlaybackStats(
          totalPlays: stats.totalPlays + 1,
          totalListenTime: stats.totalListenTime,
          artistPlayCount: artistCount,
          songPlayCount: songCount,
          firstPlayDate: stats.firstPlayDate ?? DateTime.now(),
        ),
      );
    });
  }

  /// 累加听歌时长。
  Future<void> addListenTime(Duration duration) {
    if (duration <= Duration.zero) return Future<void>.value();
    return _serialize(() async {
      final stats = await getStats();
      await _save(
        PlaybackStats(
          totalPlays: stats.totalPlays,
          totalListenTime: stats.totalListenTime + duration,
          artistPlayCount: stats.artistPlayCount,
          songPlayCount: stats.songPlayCount,
          firstPlayDate: stats.firstPlayDate,
        ),
      );
    });
  }

  /// 清空统计。
  Future<void> clear() {
    return _serialize(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    });
  }

  /// 把操作排到写队列末尾，保证读取—修改—写回不交错。
  static Future<void> _serialize(Future<void> Function() operation) {
    final completer = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        await operation();
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _save(PlaybackStats stats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(stats.toJson()));
  }
}
