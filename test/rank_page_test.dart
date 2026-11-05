import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';

http.Response jsonResponse(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

MusicApi apiWith(Future<http.Response> Function(http.Request) handler) {
  return MusicApi(ApiClient(client: MockClient(handler)));
}

void main() {
  group('RankBoard 解析', () {
    test('读取榜单 id、名称、封面与前三首预览', () {
      final board = RankBoard.fromJson({
        'rankid': 8888,
        'rankname': 'TOP500',
        'classify': 1,
        'img_9': 'http://imge.kugou.com/mcommon/9/2024/a.png',
        'songinfo': [
          {'name': '第一首'},
          {'name': '第二首'},
        ],
      });

      expect(board.id, '8888');
      expect(board.name, 'TOP500');
      expect(board.classify, 1);
      expect(board.coverUrl, 'http://imge.kugou.com/mcommon/9/2024/a.png');
      expect(board.previewSongs, ['第一首', '第二首']);
    });

    test('缺少 rankid 时由调用方过滤', () {
      final board = RankBoard.fromJson({'rankname': '坏数据'});
      expect(board.id, isEmpty);
    });
  });

  group('Song.fromRankAudio 解析', () {
    test('从 audio_info 取 hash 与时长，album_info 取封面', () {
      final song = Song.fromRankAudio({
        'audio_id': 670090512,
        'album_audio_id': 981116540,
        'album_id': 213380582,
        'songname': 'The Weeknd - Hong Kong',
        'author_name': 'The Weeknd',
        'authors': [
          {'author_id': 171927, 'author_name': 'The Weeknd'},
        ],
        'audio_info': {
          'hash_128': 'HASH_128',
          'duration_128': 216000,
        },
        'deprecated': {'hash': 'OLD_HASH', 'duration': 216000},
        'album_info': {
          'album_name': 'Hong Kong',
          'sizable_cover': 'http://imge.kugou.com/stdmusic/{size}/a.jpg',
        },
      });

      expect(song.hash, 'HASH_128');
      expect(song.id, '670090512');
      expect(song.albumAudioId, '981116540');
      expect(song.albumName, 'Hong Kong');
      expect(song.duration, const Duration(minutes: 3, seconds: 36));
      expect(song.coverUrl, 'http://imge.kugou.com/stdmusic/480/a.jpg');
      expect(song.artists.single.name, 'The Weeknd');
    });

    test('audio_info 缺失时回落到 deprecated 的 hash', () {
      final song = Song.fromRankAudio({
        'songname': '老结构',
        'author_name': '某歌手',
        'deprecated': {'hash': 'OLD_HASH', 'duration': 100000},
      });

      expect(song.hash, 'OLD_HASH');
      expect(song.duration, const Duration(minutes: 1, seconds: 40));
    });
  });

  group('MusicApi 排行榜接口', () {
    test('rankBoards 解析 info 数组并过滤非法项', () async {
      final api = apiWith((request) async {
        expect(request.url.path, endsWith('/rank/list'));
        return jsonResponse({
          'info': [
            {'rankid': 8888, 'rankname': 'TOP500'},
            {'rankid': 6666, 'rankname': '飙升榜'},
            {'rankname': '缺少 id'},
          ],
        });
      });

      final boards = await api.rankBoards();

      expect(boards.map((b) => b.id), ['8888', '6666']);
    });

    test('rankSongs 解析 songlist 与 total，并过滤无 hash 的项', () async {
      final api = apiWith((request) async {
        expect(request.url.path, endsWith('/rank/audio'));
        expect(request.url.queryParameters['rankid'], '8888');
        expect(request.url.queryParameters['pagesize'], '500');
        return jsonResponse({
          'total': 2,
          'songlist': [
            {
              'songname': '有音源',
              'audio_info': {'hash_128': 'H1', 'duration_128': 180000},
            },
            {'songname': '无音源'},
          ],
        });
      });

      final page = await api.rankSongs('8888', pageSize: 500);

      expect(page.total, 2);
      expect(page.songs.length, 1);
      expect(page.songs.single.hash, 'H1');
      expect(page.rawItemCount, 2);
    });
  });
}
