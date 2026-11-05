import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';

void main() {
  group('Song 缓存往返', () {
    test('音源类型会随缓存一起持久化', () {
      const netease = Song(
        id: '123',
        title: '网易云歌曲',
        artist: '某歌手',
        hash: 'ne_123',
        source: SongSource.netease,
      );
      final restored = Song.fromCache(netease.toCache());
      expect(restored.source, SongSource.netease);

      const local = Song(
        id: '/storage/music/a.mp3',
        title: '本地歌曲',
        artist: '本地歌手',
        hash: '/storage/music/a.mp3',
        source: SongSource.local,
      );
      expect(Song.fromCache(local.toCache()).source, SongSource.local);
    });

    test('旧缓存没有 source 字段时回落到酷狗', () {
      final legacy = <String, dynamic>{
        'id': '1',
        'title': '老缓存',
        'artist': '老歌手',
        'hash': 'HASH',
      };
      expect(Song.fromCache(legacy).source, SongSource.kugou);
    });

    test('发行日期与专辑信息在缓存后仍可用', () {
      final song = Song(
        id: '1',
        title: '七里香',
        artist: '周杰伦',
        hash: 'HASH',
        albumId: '971783',
        albumName: '七里香',
        duration: const Duration(minutes: 4, seconds: 59),
        releaseDate: DateTime(2004, 8, 3),
      );
      final restored = Song.fromCache(song.toCache());
      expect(restored.albumName, '七里香');
      expect(restored.releaseDate, DateTime(2004, 8, 3));
      expect(restored.duration, const Duration(minutes: 4, seconds: 59));
    });
  });

  group('专辑歌曲的 album_audio_id', () {
    test('不用 hash 冒充数字 album_audio_id', () {
      final song = Song.fromAlbum({
        'base': {'audio_name': '七里香', 'author_name': '周杰伦'},
        'audio_info': {'hash': '9218D816', 'duration': 299232},
        'album_info': {'album_name': '七里香'},
      });

      // /album/songs 不给数字 ID，必须留空，否则 /song/url 解析不到地址
      expect(song.albumAudioId, isNull);
      expect(song.hasNumericAlbumAudioId, isFalse);
    });

    test('接口给了数字 album_audio_id 时正常使用', () {
      final song = Song.fromAlbum({
        'base': {'audio_name': '七里香'},
        'audio_info': {'hash': '9218D816'},
        'album_audio_id': 32144418,
      });

      expect(song.albumAudioId, '32144418');
      expect(song.hasNumericAlbumAudioId, isTrue);
    });

    test('旧缓存里的 hash 会被判定为非数字 ID', () {
      final legacy = Song.fromCache({
        'id': '1',
        'title': '老缓存',
        'artist': '老歌手',
        'hash': 'HASH_A',
        'albumAudioId': 'HASH_A',
      });

      expect(legacy.hasNumericAlbumAudioId, isFalse);
    });
  });

  group('QueueOrigin', () {
    test('序列化后再解析保持歌单来源', () {
      const origin = QueueOrigin.playlist(id: '243816', title: '测试歌单');
      final restored = QueueOrigin.fromJson(origin.toJson());
      expect(restored, isNotNull);
      expect(restored!.kind, 'playlist');
      expect(restored.id, '243816');
      expect(restored.title, '测试歌单');
      expect(restored.isAlbum, isFalse);
    });

    test('专辑来源可识别，非法数据返回 null', () {
      const album = QueueOrigin.album(id: '971783');
      final restored = QueueOrigin.fromJson(album.toJson());
      expect(restored!.isAlbum, isTrue);
      expect(restored.title, isNull);

      expect(QueueOrigin.fromJson(null), isNull);
      expect(QueueOrigin.fromJson({'kind': 'playlist'}), isNull);
      expect(QueueOrigin.fromJson({'id': '1'}), isNull);
    });
  });

  group('播放进度持久化', () {
    test('解析带 hash 的进度记录', () {
      final raw = '{"hash":"HASH_A","ms":96500}';
      expect(
        parseSavedPosition(raw, 'HASH_A'),
        const Duration(seconds: 96, milliseconds: 500),
      );
    });

    test('歌曲不匹配时丢弃，避免位置串到别的歌上', () {
      final raw = '{"hash":"HASH_A","ms":96500}';
      expect(parseSavedPosition(raw, 'HASH_B'), isNull);
    });

    test('兼容旧版本纯毫秒值', () {
      expect(parseSavedPosition(42000, 'HASH_A'), const Duration(seconds: 42));
      expect(parseSavedPosition(0, 'HASH_A'), isNull);
      expect(parseSavedPosition(-1, 'HASH_A'), isNull);
    });

    test('非法或缺失数据返回 null', () {
      expect(parseSavedPosition(null, 'HASH_A'), isNull);
      expect(parseSavedPosition('', 'HASH_A'), isNull);
      expect(parseSavedPosition('not json', 'HASH_A'), isNull);
      expect(parseSavedPosition('{"hash":"HASH_A"}', 'HASH_A'), isNull);
      expect(parseSavedPosition('{"hash":"HASH_A","ms":0}', 'HASH_A'), isNull);
    });
  });

  group('恢复播放时的进度落盘', () {
    test('音源已加载时用实际加载歌曲与实时位置', () {
      final raw = resolvePositionRecord(
        currentSongHash: 'HASH_NEW',
        loadedSongHash: 'HASH_LOADED',
        playerPosition: const Duration(seconds: 42),
        pendingResume: const Duration(seconds: 120),
      );
      expect(raw, isNotNull);
      expect(parseSavedPosition(raw, 'HASH_LOADED'), const Duration(seconds: 42));
    });

    test('音源未加载但有待恢复进度时，写回恢复进度而不是 0', () {
      final raw = resolvePositionRecord(
        currentSongHash: 'HASH_A',
        loadedSongHash: null,
        playerPosition: Duration.zero,
        pendingResume: const Duration(seconds: 120),
      );
      expect(raw, isNotNull);
      // 退到后台立即落盘不能把磁盘上的 120 秒抹成 0
      expect(parseSavedPosition(raw, 'HASH_A'), const Duration(seconds: 120));
    });

    test('音源未加载且无恢复进度时，保持磁盘原值不改写', () {
      final raw = resolvePositionRecord(
        currentSongHash: 'HASH_A',
        loadedSongHash: null,
        playerPosition: Duration.zero,
        pendingResume: null,
      );
      expect(raw, isNull);
    });

    test('没有当前歌曲时不改写，也不误删磁盘记录', () {
      expect(
        resolvePositionRecord(
          currentSongHash: null,
          loadedSongHash: null,
          playerPosition: Duration.zero,
          pendingResume: null,
        ),
        isNull,
      );
    });
  });

  group('重建队列时保留手动插入的歌曲', () {
    Song song(String hash) => Song(
      id: hash,
      title: hash,
      artist: '测试歌手',
      hash: hash,
    );

    test('用来源歌单补全后，用户插入的歌曲不会丢', () {
      final a = song('A');
      final b = song('B');
      final c = song('C');
      final inserted = song('X');
      // 恢复时只有当前歌曲 A，重建期间用户「下一首播放」插入了 X
      final originalQueue = <Song>[a];
      final currentQueue = <Song>[a, inserted];
      final rebuilt = <Song>[a, b, c];

      final merged = mergeRebuiltQueue(
        originalQueue: originalQueue,
        currentQueue: currentQueue,
        rebuilt: rebuilt,
        currentSong: a,
      );

      expect(merged.map((s) => s.hash), ['A', 'X', 'B', 'C']);
    });

    test('已在重建歌单里的歌曲不重复插入', () {
      final a = song('A');
      final b = song('B');
      final merged = mergeRebuiltQueue(
        originalQueue: <Song>[a],
        currentQueue: <Song>[a, b],
        rebuilt: <Song>[a, b],
        currentSong: a,
      );
      expect(merged.map((s) => s.hash), ['A', 'B']);
    });

    test('没有插入歌曲时直接返回补全结果', () {
      final a = song('A');
      final b = song('B');
      final merged = mergeRebuiltQueue(
        originalQueue: <Song>[a],
        currentQueue: <Song>[a],
        rebuilt: <Song>[a, b],
        currentSong: a,
      );
      expect(merged.map((s) => s.hash), ['A', 'B']);
    });
  });
}
