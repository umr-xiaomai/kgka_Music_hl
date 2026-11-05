import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/services/music_api.dart';

/// 构造一个按 URI 路由返回预设 JSON 的 ApiClient。
ApiClient clientWith(Future<http.Response> Function(http.Request) handler) {
  return ApiClient(client: MockClient(handler));
}

http.Response jsonResponse(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('searchSuggest', () {
    test('读取主分组 RecordDatas 里的 HintInfo', () async {
      final api = MusicApi(
        clientWith((request) async {
          expect(request.url.path, endsWith('/search/suggest'));
          expect(request.url.queryParameters['keywords'], '周杰伦');
          return jsonResponse({
            'status': 1,
            'data': [
              {
                'RecordDatas': [
                  {'HintInfo': '周杰伦'},
                  {'HintInfo': '周杰伦 晴天'},
                  {'HintInfo': '周杰伦 稻香'},
                ],
              },
              {
                'LableName': 'MV',
                'RecordDatas': [
                  {'HintInfo': '周杰伦 - 晴天'},
                ],
              },
            ],
          });
        }),
      );

      final hints = await api.searchSuggest('周杰伦');
      expect(hints, ['周杰伦', '周杰伦 晴天', '周杰伦 稻香']);
      // 次级分组（MV/专辑）不混入联想词
      expect(hints.any((hint) => hint.contains(' - ')), isFalse);
    });

    test('主分组为空时回退到其它分组', () async {
      final api = MusicApi(
        clientWith((request) async {
          return jsonResponse({
            'data': [
              {'RecordDatas': []},
              {
                'RecordDatas': [
                  {'HintInfo': '七里香'},
                ],
              },
            ],
          });
        }),
      );

      expect(await api.searchSuggest('七里'), ['七里香']);
    });

    test('没有 data 分组时兼容旧的平铺结构', () async {
      final api = MusicApi(
        clientWith((request) async {
          return jsonResponse({
            'music': [
              {'keyword': '青花瓷'},
            ],
          });
        }),
      );

      expect(await api.searchSuggest('青花'), ['青花瓷']);
    });

    test('返回空结构时不抛异常', () async {
      final api = MusicApi(
        clientWith((request) async => jsonResponse({})),
      );
      expect(await api.searchSuggest('任意'), isEmpty);
    });
  });

  group('albumSongs 分页上限', () {
    /// 模拟 `/album/songs`：pagesize > 50 时返回空数组（服务端真实行为）。
    /// `/privilege/lite` 返回数字 album_audio_id，用于校验补查逻辑。
    ApiClient albumClient(
      List<String> names,
      List<int> requestedPages, {
      bool privilegeFails = false,
    }) {
      return clientWith((request) async {
        if (request.url.path.endsWith('/privilege/lite')) {
          if (privilegeFails) {
            // 用 404 而不是 5xx：5xx 会触发 ApiClient 的自动重试，拖慢用例
            return http.Response('not found', 404);
          }
          final hashes = request.url.queryParameters['hash']!.split(',');
          return jsonResponse([
            for (final hash in hashes)
              {'hash': hash, 'album_audio_id': '32144417'},
          ]);
        }
        expect(request.url.path, endsWith('/album/songs'));
        final size = int.parse(request.url.queryParameters['pagesize']!);
        final page = int.parse(request.url.queryParameters['page']!);
        requestedPages.add(size);
        if (size > 50) return jsonResponse(<Map<String, dynamic>>[]);
        final start = (page - 1) * size;
        final slice = names.skip(start).take(size).toList();
        return jsonResponse([
          for (final name in slice)
            {
              'base': {'audio_name': name, 'author_name': '测试歌手'},
              'audio_info': {'hash': 'HASH_$name', 'duration': 180000},
              'album_info': {'album_name': '测试专辑'},
            },
        ]);
      });
    }

    test('大页请求自动拆成 50 首一页并聚合', () async {
      final names = [for (var i = 0; i < 120; i++) '歌曲$i'];
      final requested = <int>[];
      final api = MusicApi(albumClient(names, requested));

      final songs = await api.albumSongs('1', pageSize: 5000);

      expect(songs.length, 120);
      expect(songs.first.title, '歌曲0');
      expect(songs.last.title, '歌曲119');
      // 所有请求的 pagesize 都被压到服务端上限以内
      expect(requested.every((size) => size <= 50), isTrue);
    });

    test('单页请求直接透传不额外聚合', () async {
      final requested = <int>[];
      final api = MusicApi(albumClient(['甲', '乙'], requested));

      final songs = await api.albumSongs('1', pageSize: 30);

      expect(songs.map((song) => song.title), ['甲', '乙']);
      expect(requested, [30]);
    });

    test('用 privilege/lite 补上数字 album_audio_id', () async {
      final api = MusicApi(albumClient(['甲'], []));

      final songs = await api.albumSongs('1', pageSize: 30);

      expect(songs.single.albumAudioId, '32144417');
      expect(songs.single.hasNumericAlbumAudioId, isTrue);
    });

    test('补查失败时保持原样，播放侧可退回 hash-only', () async {
      final api = MusicApi(albumClient(['甲'], [], privilegeFails: true));

      final songs = await api.albumSongs('1', pageSize: 30);

      expect(songs.single.albumAudioId, isNull);
      expect(songs.single.hasNumericAlbumAudioId, isFalse);
    });
  });
}
