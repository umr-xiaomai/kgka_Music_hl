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
}
