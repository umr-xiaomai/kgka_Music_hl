import 'dart:async';

import 'package:audio_service/audio_service.dart';
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
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    queue.add(newQueue);
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
  }) {
    final song = _currentSong;
    if (song == null) return;
    final Map<String, dynamic> extras = {
      'hash': song.hash,
      'songId': song.id,
      'lyric': ?lyricText,
      'currentLyric': ?lyricText,
      'translationLyric': ?translationText,
      'romanLyric': ?romanizationText,
    };
    final updated = MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      extras: extras,
    );
    mediaItem.add(updated);
  }

  @override
  Future<void> play() async {
    unawaited(audioPlayer.play());
  }

  @override
  Future<void> pause() async {
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
