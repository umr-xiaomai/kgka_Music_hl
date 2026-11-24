import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/playlist_export.dart';

http.Response _response(Map<String, Object> data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'TXT contains every row in source order across playlist pages',
    () async {
      final pages = <int>[];
      final api = MusicApi(
        ApiClient(
          client: MockClient((request) async {
            expect(request.url.path, '/playlist/track/all');
            expect(request.url.queryParameters['id'], 'test-list');
            final page = int.parse(request.url.queryParameters['page']!);
            final pageSize = int.parse(
              request.url.queryParameters['pagesize']!,
            );
            pages.add(page);
            final offset = (page - 1) * pageSize;
            final length = (521 - offset).clamp(0, pageSize);
            return _response({
              'count': 521,
              'status': 1,
              'begin_idx': offset,
              if (page == 1) 'list_info': {'list_ver': 109},
              'songs': [
                for (var index = offset; index < offset + length; index++)
                  {
                    'hash': index == 200 ? '' : 'SAME-HASH',
                    'name': '歌曲 ${521 - index}',
                    'singerinfo': [
                      {'id': 1, 'name': '歌手'},
                    ],
                    'timelen': 145815,
                  },
              ],
            });
          }),
        ),
      );

      final songs = await api.playlistSongsForExport('test-list');
      final rows = const LineSplitter().convert(
        utf8.decode(encodePlaylistExport(songs)),
      );

      expect(pages, [1, 2, 3, 1]);
      expect(rows, hasLength(522));
      expect(rows[1], '1\t歌曲 521\t歌手\t02:25.815');
      expect(rows[201], '201\t歌曲 321\t歌手\t02:25.815');
      expect(rows.last, '521\t歌曲 1\t歌手\t02:25.815');
    },
  );

  test(
    'a same-sized playlist edit prevents exporting mixed versions',
    () async {
      final api = MusicApi(
        ApiClient(
          client: MockClient((request) async {
            final page = int.parse(request.url.queryParameters['page']!);
            final pageSize = int.parse(
              request.url.queryParameters['pagesize']!,
            );
            final count = pageSize == 1 || page == 2 ? 1 : 200;
            return _response({
              'count': 201,
              'begin_idx': (page - 1) * pageSize,
              if (page == 1) 'list_info': {'list_ver': pageSize == 1 ? 2 : 1},
              'songs': [
                for (var index = 0; index < count; index++)
                  {'name': 'Song $index'},
              ],
            });
          }),
        ),
      );

      await expectLater(
        api.playlistSongsForExport('test-list'),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('a single page with a version needs only one request', () async {
    var requests = 0;
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          requests++;
          return _response({
            'count': 1,
            'list_info': {'list_ver': 1},
            'songs': [
              {'name': 'Song'},
            ],
          });
        }),
      ),
    );

    final songs = await api.playlistSongsForExport('test-list');

    expect(songs.single.title, 'Song');
    expect(requests, 1);
  });

  test('an incomplete response does not produce a partial backup', () async {
    final api = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          final first = request.url.queryParameters['page'] == '1';
          return _response({
            'count': 2,
            'begin_idx': first ? 0 : 1,
            'songs': [
              if (first) {'name': '已加载的歌曲'},
            ],
          });
        }),
      ),
    );

    await expectLater(
      api.playlistSongsForExport('test-list'),
      throwsA(isA<ApiException>()),
    );
  });

  test('tabs and line breaks in titles do not split tracks in the TXT', () {
    final text = utf8.decode(
      encodePlaylistExport([
        const Song(
          id: '1',
          hash: 'HASH',
          title: 'A\tB\nC\\D',
          artist: '歌手',
          duration: Duration(hours: 1, milliseconds: 2345),
        ),
        const Song(id: '2', hash: 'NEXT', title: '尾曲', artist: '艺人'),
      ]),
    );

    expect(const LineSplitter().convert(text), [
      '序号\t歌名\t歌手\t时长',
      '1\t${r'A\tB\nC\\D'}\t歌手\t1:00:02.345',
      '2\t尾曲\t艺人\t--:--',
    ]);
  });
}
