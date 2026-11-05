// ignore_for_file: use_null_aware_elements
import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler() {
    audioPlayer.playbackEventStream
        .map(_playbackStateForEvent)
        .pipe(playbackState);
  }

  final AudioPlayer audioPlayer = AudioPlayer();

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  int _queueIndex = 0;
  Song? _currentSong;
  Song? _sourceSong;
  bool _bluetoothLyricsTitleSync = false;

  /// 当前已经加载到音频引擎上的歌曲。
  ///
  /// 与 [PlayerController.currentSong] 不同：切歌时控制器会先更新自身状态，
  /// 网络解析完成后才真正换音源。保存进度时必须用它判断播放器里的位置
  /// 属于哪首歌，否则网络慢时会把上一首的位置写到新歌 hash 上。
  Song? get loadedSong => _sourceSong;

  void setBluetoothLyricsTitleSync(bool enabled) {
    _bluetoothLyricsTitleSync = enabled;
  }

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
  }

  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _currentSong = song;
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    final currentItem = _mediaItemFor(song);
    final items = queueSongs.map(_mediaItemFor).toList(growable: false);

    if (items.isNotEmpty) {
      queue.add(items);
    }
    mediaItem.add(currentItem);
    if (url.startsWith('http://') || url.startsWith('https://')) {
      await audioPlayer.setUrl(url);
    } else {
      await audioPlayer.setAudioSource(AudioSource.file(url));
    }
    // 音源真正切换成功后才更新「已加载歌曲」：在此之前 audioPlayer.position
    // 仍属于上一首，用它写进度会把旧位置错配到新歌上。
    _sourceSong = song;
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    if (currentSong != null) _currentSong = currentSong;
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    queue.add(queueSongs.map(_mediaItemFor).toList(growable: false));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong));
    }
  }

  /// 更新当前播放歌曲的 MediaSession Metadata，写入歌词字段。
  ///
  /// 大多数车机系统不会直接读 AVRCP 里的歌词，但通过 media_item extras
  /// 写入 `lyric / currentLyric` 字段后，SuperLyric 模块或第三方车载 App 可从
  /// MediaSession 元数据里取出歌词并展示。
  ///
  /// 当 [lyricText] 为 `null` 时表示清空歌词（暂停/切歌前）。
  void updateLyricMetadata({
    String? lyricText,
    String? translationText,
    String? romanizationText,
    String? fullLyricLrc,
  }) {
    final song = _currentSong;
    if (song == null) return;

    // 适配 LyricInfo 标准（ColorOS/OriginOS 锁屏岛与状态栏歌词）
    String? lyricInfoJson;
    if (lyricText != null && lyricText.isNotEmpty) {
      final lyricMap = <String, dynamic>{
        'songName': song.title,
        'artist': song.artist,
        if (song.albumName != null && song.albumName!.isNotEmpty)
          'album': song.albumName,
        'songId': song.id.isNotEmpty ? song.id : song.hash,
        'lyric': fullLyricLrc?.isNotEmpty == true ? fullLyricLrc : lyricText,
        if (translationText != null && translationText.isNotEmpty)
          'translation': translationText,
        if (romanizationText != null && romanizationText.isNotEmpty)
          'roma': romanizationText,
      };
      lyricInfoJson = jsonEncode(lyricMap);
    }

    final Map<String, dynamic> extras = {
      'hash': song.hash,
      'songId': song.id,
      if (lyricText != null) 'lyric': lyricText,
      if (lyricText != null) 'currentLyric': lyricText,
      if (translationText != null) 'translationLyric': translationText,
      if (romanizationText != null) 'romanLyric': romanizationText,
      if (fullLyricLrc != null) 'full_lrc': fullLyricLrc,
      if (fullLyricLrc != null) 'org.akanework.lyricinfo.FULL_LYRICS': fullLyricLrc,
      if (lyricText != null) 'org.akanework.lyricinfo.CURRENT_LYRIC': lyricText,
      if (lyricInfoJson != null) 'lyricInfo': lyricInfoJson,
    };

    final title = (_bluetoothLyricsTitleSync && lyricText != null && lyricText.isNotEmpty)
        ? lyricText
        : song.title;

    final updated = MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: title,
      artist: song.artist,
      duration: song.duration,
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      extras: extras,
    );
    mediaItem.add(updated);
  }

  int _playSessionId = 0;

  @override
  Future<void> play() async {
    final sessionId = ++_playSessionId;
    Object? lastError;

    final isMobileOrMac =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);

    // iOS 首次设置音源后，just_audio 可能短暂发出 playing=true，
    // 随后因音频会话激活还未稳定而回落为 false。只等到第一个 true
    // 会把这种情况误判为自动播放成功，而用户再点一次就能播放。
    // 在这里确认播放状态能短暂保持；若首次回落，重新激活会话并重试。
    for (var attempt = 0; attempt < 3; attempt++) {
      if (sessionId != _playSessionId) return;
      try {
        debugPrint(
          '[KA Music][playback] start-attempt=${attempt + 1} '
          'state=${audioPlayer.processingState.name}',
        );
        if (isMobileOrMac) {
          try {
            final session = await AudioSession.instance;
            await session.setActive(true);
          } catch (e) {
            debugPrint('[KA Music][playback] audio session setActive failed: $e');
          }
        }
        if (sessionId != _playSessionId) return;

        final playback = audioPlayer.play();
        await Future.any<void>([
          audioPlayer.playerStateStream
              .firstWhere((state) => state.playing)
              .then<void>((_) {}),
          playback.then<void>((_) {
            if (!audioPlayer.playing && sessionId == _playSessionId) {
              throw StateError('播放器未保持播放状态');
            }
          }),
        ]).timeout(const Duration(seconds: 3));

        if (sessionId != _playSessionId) return;

        // playing 在 play() 后会立即变为 true，稍后再检查一次，
        // 避免把瞬时变化误当成已经真正启播。
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (sessionId != _playSessionId) return;

        if (audioPlayer.playing) {
          debugPrint(
            '[KA Music][playback] start-attempt=${attempt + 1} stable',
          );
          return;
        }
        lastError = StateError('播放启动后立即停止');
      } catch (error) {
        if (sessionId != _playSessionId) return;
        lastError = error;
        debugPrint(
          '[KA Music][playback] start-attempt=${attempt + 1} failed: $error',
        );
      }

      if (sessionId != _playSessionId) return;
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    if (sessionId == _playSessionId) {
      throw StateError('无法自动开始播放：${lastError ?? '未知错误'}');
    }

  }

  @override
  Future<void> pause() async {
    _playSessionId++;
    await audioPlayer.pause();
  }



  @override
  Future<void> seek(Duration position) async {
    await audioPlayer.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> stop() async {
    _playSessionId++;
    await audioPlayer.stop();
  }

  Future<void> close() async {
    await audioPlayer.dispose();
  }

  MediaItem _mediaItemFor(Song song) {
    return MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      extras: {'hash': song.hash, 'songId': song.id},
    );
  }

  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
