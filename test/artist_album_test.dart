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

void main() {
  group('ArtistAlbum.fromJson 封面', () {
    test('cover 只有文件名时改用 sizable_cover', () {
      final album = ArtistAlbum.fromJson({
        'album_id': 179652761,
        'album_name': '太阳之子',
        'cover': '20260319101420611881.jpg',
        'sizable_cover':
            'http://imge.kugou.com/stdmusic/{size}/20260319/20260319101420611881.jpg',
      });

      expect(
        album.coverUrl,
        'http://imge.kugou.com/stdmusic/480/20260319/20260319101420611881.jpg',
      );
    });

    test('搜索结果只有完整 img 时直接使用', () {
      final album = ArtistAlbum.fromJson({
        'albumid': 960399,
        'albumname': '魔杰座',
        'img': 'http://imge.kugou.com/stdmusic/240/20241118/20241118160622508429.jpg',
      });

      expect(
        album.coverUrl,
        'http://imge.kugou.com/stdmusic/240/20241118/20241118160622508429.jpg',
      );
    });

    test('所有候选都只是文件名时不给地址，避免渲染必然失败的图片', () {
      final album = ArtistAlbum.fromJson({
        'albumid': 1,
        'albumname': '无封面',
        'cover': 'abc.jpg',
      });

      expect(album.coverUrl, isNull);
    });
  });

  group('AlbumDetail 解析', () {
    test('cover 为文件名时使用 sizable_cover 并保留介绍', () {
      final detail = AlbumDetail.fromJson({
        'album_id': 179652761,
        'album_name': '太阳之子',
        'author_name': '周杰伦',
        'publish_date': '2026-03-25',
        'cover': '20260319101420611881.jpg',
        'sizable_cover':
            'http://imge.kugou.com/stdmusic/{size}/20260319/20260319101420611881.jpg',
        'intro': '专辑介绍正文',
      });

      expect(detail.name, '太阳之子');
      expect(detail.publishDate, '2026-03-25');
      expect(detail.intro, '专辑介绍正文');
      expect(
        detail.coverUrl,
        'http://imge.kugou.com/stdmusic/480/20260319/20260319101420611881.jpg',
      );
    });
  });

  group('ArtistDetail 介绍', () {
    test('拼接短简介与 long_intro 分段，跳过重复的「简介」分段', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '周杰伦',
        'intro': '短简介',
        'long_intro': [
          {'title': '简介', 'content': '长简介'},
          {'title': '演艺经历', 'content': '经历正文'},
          {'title': '荣誉记录', 'content': ''},
        ],
      }, id: '3520');

      expect(detail.introText, '短简介\n\n演艺经历\n经历正文');
    });

    test('没有短简介时使用全部 long_intro 分段', () {
      final detail = ArtistDetail.fromJson({
        'author_name': '某歌手',
        'long_intro': [
          {'title': '简介', 'content': '长简介'},
        ],
      }, id: '1');

      expect(detail.introText, '简介\n长简介');
    });

    test('完全没有介绍时返回 null', () {
      final detail = ArtistDetail.fromJson({'author_name': '某歌手'}, id: '1');

      expect(detail.introText, isNull);
    });
  });

  group('MusicApi.albumDetail', () {
    test('解析已解包的数组响应', () async {
      final api = MusicApi(
        ApiClient(
          client: MockClient((request) async {
            expect(request.url.path, endsWith('/album/detail'));
            expect(request.url.queryParameters['id'], '179652761');
            return jsonResponse([
              {
                'album_id': 179652761,
                'album_name': '太阳之子',
                'sizable_cover':
                    'http://imge.kugou.com/stdmusic/{size}/20260319/a.jpg',
                'intro': '介绍',
              },
            ]);
          }),
        ),
      );

      final detail = await api.albumDetail('179652761');

      expect(detail.id, '179652761');
      expect(detail.intro, '介绍');
      expect(
        detail.coverUrl,
        'http://imge.kugou.com/stdmusic/480/20260319/a.jpg',
      );
    });

    test('空数组时返回占位数据而不抛异常', () async {
      final api = MusicApi(
        ApiClient(client: MockClient((request) async => jsonResponse([]))),
      );

      final detail = await api.albumDetail('1');

      expect(detail.name, '未知专辑');
      expect(detail.coverUrl, isNull);
    });
  });
}
