import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _IdlePlayer extends Fake implements AudioPlayer {
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  int? get androidAudioSessionId => null;
  @override
  Duration get position => Duration.zero;
  @override
  bool get playing => false;
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {}
}

const _song = Song(id: '1', hash: 'HASH', title: '歌名', artist: '歌手');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'AVRCP title updates immediately and queue refresh keeps current lyric',
    () async {
      final handler = MusicAudioHandler(player: _IdlePlayer());
      addTearDown(handler.close);
      await handler.setSongQueue(
        queueSongs: [_song],
        queueIndex: 0,
        currentSong: _song,
      );
      handler.updateLyricMetadata(lyricText: '第一句歌词');
      expect(handler.mediaItem.value!.title, '歌名');

      handler.setBluetoothLyricsTitleSync(true);
      expect(handler.mediaItem.value!.title, '第一句歌词');
      const enriched = Song(
        id: '1',
        hash: 'HASH',
        title: '歌名',
        artist: '歌手',
        albumName: '补全的专辑',
        coverUrl: 'https://example.com/cover.jpg',
        duration: Duration(minutes: 3),
      );
      await handler.setSongQueue(
        queueSongs: [enriched],
        queueIndex: 0,
        currentSong: enriched,
      );
      expect(handler.mediaItem.value!.title, '第一句歌词');
      expect(handler.mediaItem.value!.album, '补全的专辑');
      expect(handler.mediaItem.value!.duration, const Duration(minutes: 3));
      expect(handler.mediaItem.value!.artUri, Uri.parse(enriched.coverUrl!));
      handler.updateLyricMetadata(lyricText: '第二句歌词');
      expect(handler.mediaItem.value!.title, '第二句歌词');
      expect(handler.mediaItem.value!.extras!['currentLyric'], '第二句歌词');

      handler.setBluetoothLyricsTitleSync(false);
      expect(handler.mediaItem.value!.title, '歌名');
      handler.setBluetoothLyricsTitleSync(true);
      handler.updateLyricMetadata(lyricText: null);
      expect(handler.mediaItem.value!.title, '歌名');
      handler.updateLyricMetadata(lyricText: '旧歌曲歌词');
      const next = Song(id: '2', hash: 'NEXT', title: '下一首', artist: '歌手');
      await handler.setSongQueue(
        queueSongs: [next],
        queueIndex: 0,
        currentSong: next,
      );
      expect(handler.mediaItem.value!.title, '下一首');
      expect(handler.mediaItem.value!.extras!['currentLyric'], isNull);
    },
  );

  test(
    'car lyrics defaults to AVRCP and master switch restores song title',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.bluetooth_lyrics_enabled': true,
      });
      final handler = MusicAudioHandler(player: _IdlePlayer());
      final controller = PlayerController(MusicApi(ApiClient()), handler);
      await controller.settingsRestored;
      addTearDown(controller.dispose);
      expect(controller.bluetoothLyricsTitleSyncEnabled, isTrue);
      await handler.setSongQueue(
        queueSongs: [_song],
        queueIndex: 0,
        currentSong: _song,
      );
      handler.updateLyricMetadata(lyricText: '实时歌词');
      expect(handler.mediaItem.value!.title, '实时歌词');
      await controller.setBluetoothLyricsEnabled(false);
      expect(handler.mediaItem.value!.title, '歌名');
      await controller.setBluetoothLyricsEnabled(true);
      expect(handler.mediaItem.value!.title, '实时歌词');
      await controller.setBluetoothLyricsTitleSyncEnabled(false);
      expect(handler.mediaItem.value!.title, '歌名');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('settings.bluetooth_lyrics_title_sync_enabled'),
        isFalse,
      );
    },
  );

  test(
    'explicit opt-out survives settings restore and master switch gates title sync',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.bluetooth_lyrics_enabled': true,
        'settings.bluetooth_lyrics_title_sync_enabled': false,
      });
      final handler = MusicAudioHandler(player: _IdlePlayer());
      final controller = PlayerController(MusicApi(ApiClient()), handler);
      await controller.settingsRestored;
      addTearDown(controller.dispose);
      expect(controller.bluetoothLyricsTitleSyncEnabled, isFalse);
      await handler.setSongQueue(
        queueSongs: [_song],
        queueIndex: 0,
        currentSong: _song,
      );
      handler.updateLyricMetadata(lyricText: '实时歌词');
      expect(handler.mediaItem.value!.title, '歌名');
      await controller.setBluetoothLyricsEnabled(false);
      await controller.setBluetoothLyricsTitleSyncEnabled(true);
      expect(handler.mediaItem.value!.title, '歌名');
    },
  );
}
