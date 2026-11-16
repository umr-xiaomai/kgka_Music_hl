import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';

class _RecordingClient extends http.BaseClient {
  Uri? lastUri;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUri = request.url;
    final body = jsonEncode({
      'url': ['https://example.com/song.mp3'],
      'hash': 'HASH_ALBUM',
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  group('MusicApi.songUrl', () {
    test('不把 hash 等非数字 albumAudioId 传给播放接口', () async {
      final httpClient = _RecordingClient();
      final api = MusicApi(ApiClient(client: httpClient));

      await api.songUrl(
        const Song(
          id: 'HASH_ALBUM',
          title: '专辑歌曲',
          artist: '测试歌手',
          hash: 'HASH_ALBUM',
          albumId: '163970508',
          albumAudioId: 'HASH_ALBUM',
        ),
      );

      final query = httpClient.lastUri!.queryParameters;
      expect(query['album_id'], '163970508');
      expect(query.containsKey('album_audio_id'), isFalse);
    });

    test('保留合法的数字 albumAudioId', () async {
      final httpClient = _RecordingClient();
      final api = MusicApi(ApiClient(client: httpClient));

      await api.songUrl(
        const Song(
          id: 'HASH_SEARCH',
          title: '搜索歌曲',
          artist: '测试歌手',
          hash: 'HASH_SEARCH',
          albumId: '12345',
          albumAudioId: '800050863',
        ),
      );

      final query = httpClient.lastUri!.queryParameters;
      expect(query['album_audio_id'], '800050863');
    });
  });
}
