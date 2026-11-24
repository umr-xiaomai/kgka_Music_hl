import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/ui/widgets/favorite_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _favoriteHashesKey = 'ka_music_liked_hashes';
const _song = Song(id: '987', title: '测试歌曲', artist: '测试歌手', hash: 'ABCDEF');
const _playlist = PlaylistSummary(
  id: 'liked-global',
  title: '我喜欢',
  listId: '42',
);
const _session = LoginSession(token: 'test-token', userId: '1');

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('收藏提交等待期间立即显示实心红心，禁止重复提交', (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    final client = ApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/playlist/tracks/add');
        requests++;
        return response.future;
      }),
    );
    addTearDown(client.close);
    final auth = AuthController(MusicApi(client), CacheService())
      ..session = _session
      ..playlists = [_playlist];
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteIconButton(auth: auth, song: _song),
        ),
      ),
    );

    await tester.tap(find.byTooltip('收藏'));
    await tester.pump();
    final selectedHeart = tester.widget<Icon>(
      find.byIcon(Icons.favorite_rounded),
    );
    expect(selectedHeart.color, Colors.redAccent);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_favoriteHashesKey), isNull);

    response.complete(_json({'status': 1}));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
    expect(jsonDecode(prefs.getString(_favoriteHashesKey)!), ['abcdef']);
  });

  test('取消收藏复用收藏列表的 fileid，服务端拒绝后恢复收藏状态', () async {
    var trackRequests = 0;
    var removeRequests = 0;
    final deletionStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final client = ApiClient(
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/user/detail':
          case '/user/vip/detail':
            return _json({});
          case '/user/playlist':
            return _json({
              'info': [
                {
                  'name': '我喜欢',
                  'listid': '42',
                  'global_collection_id': 'liked-global',
                },
              ],
            });
          case '/playlist/track/all':
            trackRequests++;
            return _json({
              'songs': [
                {'hash': 'abcdef', 'fileid': '456', 'mixsongid': '987'},
              ],
            });
          case '/playlist/tracks/del':
            removeRequests++;
            expect(request.url.queryParameters, {
              'listid': '42',
              'fileids': '456',
            });
            if (removeRequests == 1) {
              deletionStarted.complete();
              return firstResponse.future;
            }
            return _json({'status': 1});
          default:
            fail('Unexpected API request: ${request.url.path}');
        }
      }),
    );
    addTearDown(client.close);
    final auth = AuthController(MusicApi(client), CacheService())
      ..session = _session;
    addTearDown(auth.dispose);
    await auth.refreshProfile();
    expect(auth.isLiked(_song), isTrue);
    final displayedStates = <bool>[];
    auth.addListener(() {
      final liked = auth.isLiked(_song);
      if (displayedStates.isEmpty || displayedStates.last != liked) {
        displayedStates.add(liked);
      }
    });

    final pendingRemoval = auth.toggleLike(_song);
    final failure = expectLater(pendingRemoval, throwsA(isA<ApiException>()));
    expect(auth.isLiked(_song), isFalse);
    expect(auth.isLikePending(_song), isTrue);
    await deletionStarted.future;
    await auth.toggleLike(_song);
    await auth.removeSongFromPlaylist(
      _playlist,
      const Song(id: '456', title: '测试歌曲', artist: '测试歌手', hash: 'abcdef'),
    );
    expect(auth.errorMessage, contains('收藏状态正在更新'));
    expect(removeRequests, 1);
    firstResponse.complete(_json({'status': 0, 'error_code': 123}));
    await failure;

    expect(displayedStates, [false, true]);
    expect(auth.isLikePending(_song), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(_favoriteHashesKey)!), ['abcdef']);
    expect(trackRequests, 1);

    await auth.toggleLike(_song);
    expect(removeRequests, 2);
    expect(auth.isLiked(_song), isFalse);
    expect(jsonDecode(prefs.getString(_favoriteHashesKey)!), isEmpty);
  });

  test('切换账号后，旧收藏请求和旧列表刷新不能写入新账号', () async {
    final staleList = Completer<http.Response>();
    final staleListStarted = Completer<void>();
    final staleAddition = Completer<http.Response>();
    final newProfile = Completer<http.Response>();
    final newProfileStarted = Completer<void>();
    var additionRequests = 0;
    final client = ApiClient(
      client: MockClient((request) async {
        final oldAccount = request.headers['x-kg-session-id'] == 'test-token';
        switch (request.url.path) {
          case '/user/detail':
            if (oldAccount) return _json({});
            newProfileStarted.complete();
            return newProfile.future;
          case '/user/vip/detail':
            return _json({});
          case '/user/playlist':
            if (oldAccount) {
              staleListStarted.complete();
              return staleList.future;
            }
            return _json({
              'info': [
                {
                  'name': '我喜欢',
                  'listid': '99',
                  'global_collection_id': 'new-liked-global',
                },
              ],
            });
          case '/playlist/track/all':
            expect(request.url.queryParameters['id'], 'new-liked-global');
            return _json({'songs': []});
          case '/playlist/tracks/add':
            expect(oldAccount, isTrue);
            additionRequests++;
            return staleAddition.future;
          default:
            fail('Unexpected API request: ${request.url.path}');
        }
      }),
    );
    addTearDown(client.close);
    final api = MusicApi(client)..setSession(_session);
    final auth = AuthController(api, CacheService())
      ..session = _session
      ..playlists = [_playlist];
    addTearDown(auth.dispose);
    await auth.vipClaim.setAutoEnabled(false);

    final refreshing = auth.refreshProfile();
    await staleListStarted.future;
    final adding = auth.toggleLike(_song);
    expect(auth.isLiked(_song), isTrue);
    final switching = auth.loginWithSession(
      const LoginSession(token: 'new-token', userId: '2', t1: 'new-t1'),
    );
    await newProfileStarted.future;
    expect(auth.likedPlaylist, isNull);
    expect(auth.isLiked(_song), isFalse);
    await auth.toggleLike(_song);

    newProfile.complete(_json({}));
    await switching;
    expect(auth.likedPlaylist?.listId, '99');
    staleList.complete(
      _json({
        'info': [
          {
            'name': '我喜欢',
            'listid': '42',
            'global_collection_id': 'liked-global',
          },
        ],
      }),
    );
    staleAddition.complete(_json({'status': 1}));
    await Future.wait([refreshing, adding]);

    expect(additionRequests, 1);
    expect(auth.likedPlaylist?.listId, '99');
    expect(auth.isLikePending(_song), isFalse);
    expect(auth.isLiked(_song), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(_favoriteHashesKey)!), isEmpty);
  });
}
