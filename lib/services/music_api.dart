import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../models/app_version.dart';
import '../models/music_models.dart';

class MusicApi {
  MusicApi(this._client);

  static const _registerHint = '若没有账号请先在酷狗音乐概念版App注册';

  final ApiClient _client;

  /// 暴露 ApiClient 当前持有的后端 session key（由响应 header 自动保存）。
  String? get clientSessionId => _client.sessionId;

  void setSession(LoginSession? session) {
    if (session == null) {
      _client.token = null;
      _client.t1 = null;
      _client.sessionId = null;
      return;
    }
    _client.token = session.token;
    _client.t1 = session.t1;
    // 扫码/手机号登录返回的 session 不携带 sessionId，
    // 此时 _client.sessionId 已由 ApiClient._processResponse 从
    // 登录请求的响应 header (X-Kg-Session-Id) 中保存。
    // 不能用 null 覆盖，否则后续请求无法关联到后端 session，
    // 导致 /user/detail、/user/playlist 等接口拿不到登录态。
    final sid = session.sessionId;
    if (sid != null && sid.isNotEmpty) {
      _client.sessionId = sid;
    }
  }

  Future<void> sendLoginCode(String mobile) async {
    final json = asMap(
      await _client.post('/captcha/sent', query: {'mobile': mobile}),
    );
    if (!_isSuccess(json)) {
      throw ApiException('发送验证码失败，$_registerHint${_failureSuffix(json)}');
    }
  }

  Future<PhoneLoginResult> loginWithPhone({
    required String mobile,
    required String code,
    String? userId,
  }) async {
    final json = asMap(
      await _client.post(
        '/login/cellphone',
        body: {
          'mobile': mobile,
          'code': code,
          if (userId != null && userId.isNotEmpty) 'userId': userId,
        },
      ),
    );
    if (_requiresUserSelection(json)) {
      final accounts = asList(json['accounts'])
          .whereType<Map>()
          .map((item) => MobileLoginAccount.fromJson(asMap(item)))
          .where((item) => item.userId.isNotEmpty)
          .toList();
      return PhoneLoginResult.accountSelection(
        accounts: accounts,
        message:
            asString(json['message']) ?? asString(json['msg']) ?? '请选择需要登录的账号',
        errorCode: asInt(json['errorCode'] ?? json['error_code']),
      );
    }
    if (!_isSuccess(json)) {
      throw ApiException('登录失败，$_registerHint${_failureSuffix(json)}');
    }
    final session = LoginSession.fromJson(json);
    return PhoneLoginResult.success(
      LoginSession(
        userId: session.userId,
        token: session.token,
        t1: session.t1,
        sessionId: _client.sessionId,
      ),
    );
  }

  Future<LoginSession> refreshToken() async {
    final json = asMap(await _client.post('/login/token'));
    final session = LoginSession.fromJson(json);
    return LoginSession(
      userId: session.userId,
      token: session.token,
      t1: session.t1,
      sessionId: _client.sessionId,
    );
  }

  Future<void> logout() async {
    await _client.post('/login/logout');
  }

  Future<QrCodeInfo> getQrCode() async {
    final json = asMap(await _client.get('/login/qr/key'));
    return QrCodeInfo.fromJson(json);
  }

  Future<QrCheckResult> checkQrStatus(String key) async {
    final json = asMap(await _client.get('/login/qr/check', {'key': key}));
    return QrCheckResult.fromJson(json);
  }

  Future<UserProfile> userDetail() async {
    final json = asMap(await _client.get('/user/detail'));
    return UserProfile.fromJson(json);
  }

  Future<List<PlaylistSummary>> userPlaylists({
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/user/playlist', {'page': page, 'pagesize': pageSize}),
    );
    _debugPlaylistLogObject('raw response', json);
    final currentUserId = asString(json['userid']);
    final rawItems = asList(json['info']).whereType<Map<String, dynamic>>();
    _debugPlaylistLogObject(
      'raw item fields',
      rawItems
          .map(
            (item) => {
              'name': item['name'],
              'listid': item['listid'],
              'global_collection_id': item['global_collection_id'],
              'count': item['count'],
              'is_def': item['is_def'],
              'is_default': item['is_default'],
              'type': item['type'],
              'userid': item['userid'],
              'list_create_username': item['list_create_username'],
              'list_create_userid': item['list_create_userid'],
              'list_create_gid': item['list_create_gid'],
              'list_create_listid': item['list_create_listid'],
            },
          )
          .toList(),
    );
    final playlists = rawItems
        .map(
          (item) =>
              PlaylistSummary.fromUser(item, currentUserId: currentUserId),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
    final orderedPlaylists = _orderUserPlaylistsForDisplay(playlists);
    _debugPlaylistLogObject(
      'parsed item fields',
      orderedPlaylists
          .map(
            (item) => {
              'title': item.title,
              'id': item.id,
              'songCount': item.songCount,
              'isDefault': item.isDefault,
              'type': item.type,
              'source': item.source,
              'isLikedPlaylist': item.isLikedPlaylist,
              'isCreatedPlaylist': item.isCreatedPlaylist,
              'creatorName': item.creatorName,
              'creatorUserId': item.creatorUserId,
              'currentUserId': item.currentUserId,
              'sourceGlobalId': item.sourceGlobalId,
              'sourceListId': item.sourceListId,
              'hasCollectionSource': item.hasCollectionSource,
            },
          )
          .toList(),
    );
    return orderedPlaylists;
  }

  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async {
    final json = asMap(
      await _client.get('/top/playlist', {
        'category_id': categoryId,
        'page': page,
      }),
    );
    return asList(json['special_list'])
        .whereType<Map<String, dynamic>>()
        .map(PlaylistSummary.fromRecommend)
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<DailyRecommend> dailyRecommend() async {
    final json = asMap(await _client.get('/recommend/songs'));
    return DailyRecommend.fromJson(json);
  }

  /// 获取红心 Radio + 根据口味的私人 FM 推荐。
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) async {
    final hasPlaybackFeedback =
        hash != null || songId != null || playtime != null;
    final raw = await _client.get('/personal/fm', {
      'mode': 'normal',
      'songPoolId': 0,
      if (hasPlaybackFeedback) ...{
        'hash': hash,
        'songid': songId,
        'playtime': playtime,
        'action': 'play',
        'isOverplay': isOverplay,
        'remainSongCnt': 0,
      },
    });
    final json = asMap(raw);
    final songs = <Song>[];
    final identities = <String>{};
    for (final item in asList(json['song_list']).whereType<Map>()) {
      final song = Song.fromPersonalFm(asMap(item));
      final identity = song.hash.isNotEmpty ? song.hash : song.id;
      if (identity.isEmpty || !identities.add(identity)) {
        continue;
      }
      songs.add(song);
      if (songs.length == 5) {
        break;
      }
    }
    return songs;
  }

  /// 新歌速递。
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async {
    final raw = await _client.get('/top/song', {'type': type, 'page': page});
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(json['data'] ?? json['song_list'] ?? _firstListValue(json));
    return items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromTopSong)
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  /// 新碟上架。
  Future<List<TopAlbumItem>> topAlbums({int page = 1, int pageSize = 30}) async {
    final raw = await _client.get('/top/album', {'page': page, 'pagesize': pageSize});
    final json = asMap(raw);
    final data = asMap(json['data']);
    final items = asList(data['chn'] ?? json['chn']);
    return items
        .whereType<Map<String, dynamic>>()
        .map(TopAlbumItem.fromJson)
        .where((album) => album.id.isNotEmpty)
        .toList();
  }

  /// 探索发现页的 6 组推荐歌曲。
  ///
  /// 每组推荐独立降级，单个请求失败不会阻断其他推荐或首页加载。
  Future<List<RecommendedSongCard>> recommendedSongCards() async {
    const definitions = <(int, String)>[
      (1, '私人专属好歌'),
      (2, '经典怀旧金曲'),
      (3, '热门好歌精选'),
      (4, '小众宝藏佳作'),
      (5, '潮流尝鲜'),
      (6, 'VIP 专属推荐'),
    ];
    final cards = await Future.wait(
      definitions.map((definition) async {
        try {
          final json = asMap(
            await _client.get('/top/card', {'card_id': definition.$1}),
          );
          final card = RecommendedSongCard.fromJson(
            cardId: definition.$1,
            title: definition.$2,
            json: json,
          );
          return card.songs.isEmpty ? null : card;
        } catch (error, stackTrace) {
          debugPrint(
            'Failed to load recommended song card ${definition.$1}: $error\n'
            '$stackTrace',
          );
          return null;
        }
      }),
    );
    return cards.whereType<RecommendedSongCard>().toList();
  }

  Future<List<AlbumShopItem>> albumShop({int page = 1, int pageSize = 30}) async {
    final json = asMap(
      await _client.get('/album/shop', {'page': page, 'pagesize': pageSize}),
    );
    return asList(json['album_list'])
        .whereType<Map<String, dynamic>>()
        .map(AlbumShopItem.fromJson)
        .where((item) => item.mediaId > 0)
        .toList();
  }

  Future<List<FmStation>> fmRecommendedStations() async {
    final raw = await _client.get('/fm/recommend');
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return items
        .whereType<Map>()
        .map((item) => FmStation.fromJson(asMap(item)))
        .where((station) => station.id.isNotEmpty)
        .toList();
  }

  Future<List<FmClassGroup>> fmClassGroups() async {
    final raw = await _client.get('/fm/class');
    final json = asMap(raw);
    return asList(json['class_list'] ?? json['data'])
        .whereType<Map>()
        .map((item) => FmClassGroup.fromJson(asMap(item)))
        .where((group) => group.stations.isNotEmpty)
        .toList();
  }

  Future<List<Song>> fmSongs(
    FmStation station, {
    int offset = -1,
    int size = 20,
  }) async {
    final raw = await _client.get('/fm/songs', {
      'fmid': station.id,
      'type': station.type,
      'offset': offset,
      'size': size,
    });
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    final pages = items
        .whereType<Map>()
        .map((item) => FmSongPage.fromJson(asMap(item)))
        .toList();
    if (pages.isEmpty) {
      return const [];
    }
    return pages.expand((page) => page.songs).toList();
  }

  Future<Map<String, FmImage>> fmImages(List<String> fmids) async {
    final ids = fmids.where((id) => id.isNotEmpty).toSet().join(',');
    if (ids.isEmpty) {
      return const {};
    }
    final raw = await _client.get('/fm/image', {'fmid': ids});
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return {
      for (final image
          in items
              .whereType<Map>()
              .map((item) => FmImage.fromJson(asMap(item)))
              .where((image) => image.fmid.isNotEmpty))
        image.fmid: image,
    };
  }

  /// 获取当前登录用户 VIP 信息。
  Future<UserVipInfo> vipDetail() async {
    final json = asMap(await _client.get('/user/vip/detail'));
    return UserVipInfo.fromJson(json);
  }

  /// 获取服务端继续播放信息。
  Future<LatestListenResult> latestListenSongs({int pageSize = 30}) async {
    final json = asMap(
      await _client.post(
        '/lastest/songs/listen',
        query: {'pagesize': pageSize},
      ),
    );
    return LatestListenResult.fromJson(asMap(json['data']));
  }
  Future<VipReceiveHistory> vipReceiveHistory() async {
    final json = asMap(await _client.get('/youth/month/vip/record'));
    return VipReceiveHistory.fromJson(json);
  }

  Future<OneDayVipResult> dailyVip() async {
    final json = asMap(await _client.get('/youth/day/vip'));
    return OneDayVipResult.fromJson(json);
  }

  Future<UpgradeVipResult> upgradeVipReward() async {
    final json = asMap(await _client.get('/youth/day/vip/upgrade'));
    return UpgradeVipResult.fromJson(json);
  }

  Future<void> addListeningTime() async {
    await _client.post('/listen/timeadd');
  }

  Future<AppVersionInfo> latestAppVersion(AppUpdatePlatform platform) async {
    final json = asMap(
      await _client.get('/mobile/app/versions/latest', {
        'platform': platform.apiValue,
      }),
    );
    return AppVersionInfo.fromJson(json);
  }

  /// 获取歌手专辑列表。
  Future<List<ArtistAlbum>> artistAlbums(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/artist/albums', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
      'sort': 'new',
    });
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['data'] ??
                json['albums'] ??
                json['list'] ??
                _firstListValue(json),
          );
    return items
        .whereType<Map<String, dynamic>>()
        .map(ArtistAlbum.fromJson)
        .where((album) => album.id.isNotEmpty)
        .toList();
  }

  Future<ArtistDetail> artistDetail(String id) async {
    final json = asMap(await _client.get('/artist/detail', {'id': id}));
    return ArtistDetail.fromJson(json, id: id);
  }

  Future<List<Song>> artistAudios(
    String id, {
    int page = 1,
    int pageSize = 30,
    String sort = 'hot',
  }) async {
    final raw = await _client.get('/artist/audios', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
      'sort': sort,
    });
    _debugArtistLogObject('/artist/audios raw', raw);

    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['data'] ??
                json['songs'] ??
                json['song'] ??
                json['list'] ??
                json['info'] ??
                _firstListValue(json),
          );
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => Song.fromArtistAudio(item, artistId: id))
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  Future<List<Song>> albumSongs(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final songPage = await albumSongPage(id, page: page, pageSize: pageSize);
    return songPage.songs;
  }

  Future<SongPage> albumSongPage(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/album/songs', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
    });
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['songs'] ??
                json['data'] ??
                json['info'] ??
                _firstListValue(json),
          );
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromAlbum)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return SongPage(songs: songs, rawItemCount: items.length);
  }

  Object? _firstListValue(Map<String, dynamic> json) {
    for (final value in json.values) {
      if (value is List) {
        return value;
      }
      if (value is Map) {
        final nested = _firstListValue(asMap(value));
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  Future<MusicCommentResponse> musicComments(
    String mixsongid, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/comment/music', {
        'mixsongid': mixsongid,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    return MusicCommentResponse.fromJson(json);
  }

  /// 获取相似歌单。
  Future<List<PlaylistSummary>> similarPlaylists(String id) async {
    final raw = await _client.get('/playlist/similar', {'ids': id});
    final json = asMap(raw);
    final groups = asList(json['data'])
        .whereType<Map<String, dynamic>>()
        .toList();
    final items = groups.isEmpty
        ? const <Map<String, dynamic>>[]
        : asList(groups.first['collection_list'])
            .whereType<Map<String, dynamic>>();
    return items
        .map(PlaylistSummary.fromSimilar)
        .where((playlist) => playlist.id.isNotEmpty)
        .toList();
  }
  Future<PlaylistSummary> playlistInfo(String id) async {
    final json = asMap(await _client.get('/playlist/detail', {'ids': id}));
    return PlaylistSummary.fromDetail(json);
  }

  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
  }) async {
    if (!fetchAll) {
      final songPage = await playlistSongPage(id, page: page, pageSize: pageSize);
      return songPage.songs;
    }

    final allSongs = <Song>[];
    var currentPage = 1;
    const perPage = 200;
    while (true) {
      final songPage = await playlistSongPage(
        id,
        page: currentPage,
        pageSize: perPage,
      );
      final songs = songPage.songs;
      if (songs.isEmpty) break;
      allSongs.addAll(songs);
      if (songPage.rawItemCount < perPage) break;
      currentPage++;
    }
    return allSongs;
  }

  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
  }) async {
    final json = asMap(
      await _client.get('/playlist/track/all', {
        'id': id,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    final items = asList(json['songs']);
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromPlaylist)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return SongPage(songs: songs, rawItemCount: items.length);
  }

  Future<PlaylistDetail> playlistDetail(String id) async {
    final results = await Future.wait([
      playlistInfo(id),
      playlistSongs(id, pageSize: 50),
    ]);
    return PlaylistDetail(
      info: results[0] as PlaylistSummary,
      songs: results[1] as List<Song>,
    );
  }

  /// 获取歌曲高潮片段时间信息，无高潮时返回 null。
  Future<SongClimax?> songClimax(String hash) async {
    final raw = await _client.get('/song/climax', {'hash': hash});
    final json = asMap(raw);
    for (final item in asList(json['data'])) {
      if (item is Map<String, dynamic>) {
        final climax = SongClimax.fromJson(item);
        if (climax.isValid) return climax;
      }
    }
    return null;
  }
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    final json = asMap(
      await _client.get('/song/url', {
        'hash': song.hash,
        'quality': quality.apiValue,
        if (!hashOnly) ...{
          'album_id': song.albumId,
          'album_audio_id': song.albumAudioId,
        },
        'free_part': false,
      }),
    );
    return PlayUrl.fromJson(json);
  }

  /// 获取云盘歌曲列表（分页）。
  Future<CloudDriveResult> cloudDrive({
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/user/cloud', {'page': page, 'pagesize': pageSize}),
    );
    final info = CloudDriveInfo.fromJson(json);
    final songs = asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(CloudDriveSongMeta.fromJson)
        .where((item) => item.song.hash.isNotEmpty)
        .map((item) => item.song)
        .toList();
    return CloudDriveResult(info: info, songs: songs);
  }

  /// 获取云盘歌曲的播放地址。
  Future<PlayUrl> cloudSongUrl(Song song) async {
    final json = asMap(
      await _client.get('/user/cloud/url', {
        'hash': song.hash,
        'album_audio_id': song.albumAudioId,
        'audio_id': song.albumAudioId,
        'name': song.title,
      }),
    );
    final url = asString(json['url']) ?? '';
    final hash = asString(json['hash']) ?? song.hash;
    return PlayUrl(url: url, hash: hash);
  }

  /// 解析网易云 / QQ 音乐歌单分享链接，返回歌单名和歌曲名称列表。
  Future<ExternalPlaylistParseResult> parseExternalPlaylist(
    String sourceText,
  ) async {
    final json = asMap(
      await _client.post(
        '/playlist/external/parse',
        body: {'sourceText': sourceText},
      ),
    );
    return ExternalPlaylistParseResult.fromJson(json);
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    await _client.post(
      '/playlist/create',
      query: {'name': name, 'type': private ? 1 : 0},
    );
  }

  Future<void> collectPlaylist({
    required String name,
    required String globalCollectionId,
  }) async {
    await _client.post(
      '/playlist/add',
      query: {'name': name, 'list_create_gid': globalCollectionId},
    );
  }

  Future<void> deletePlaylist(String listId) async {
    await _client.post('/playlist/del', query: {'listid': listId});
  }

  Future<void> addToPlaylist(String listId, Song song) async {
    await addSongsToPlaylist(listId, [song]);
  }

  Future<void> addSongsToPlaylist(String listId, List<Song> songs) async {
    if (songs.isEmpty) return;
    await _client.post(
      '/playlist/tracks/add',
      body: {'listId': listId, 'songs': songs.map(_songAddPayload).toList()},
    );
  }

  Future<void> removeFromPlaylist(String listId, Song song) async {
    await removeSongsFromPlaylist(listId, [song]);
  }

  Future<void> removeSongsFromPlaylist(String listId, List<Song> songs) async {
    final fileIds = songs
        .map((song) => song.id)
        .where((id) => id.isNotEmpty)
        .join(',');
    if (fileIds.isEmpty) return;
    await _client.post(
      '/playlist/tracks/del',
      query: {'listid': listId, 'fileids': fileIds},
    );
  }

  Map<String, Object?> _songAddPayload(Song song) {
    return {
      'name': song.title,
      'hash': song.hash,
      'albumId': song.albumId,
      'mixSongId': song.albumAudioId ?? song.id,
    };
  }

  bool _isSuccess(Map<String, dynamic> json) {
    return asInt(json['status']) == 1;
  }

  bool _requiresUserSelection(Map<String, dynamic> json) {
    final requiresUserSelection = json['requiresUserSelection'];
    if (requiresUserSelection is bool) {
      return requiresUserSelection;
    }
    final errorCode = asInt(json['errorCode'] ?? json['error_code']);
    final accounts = asList(json['accounts']);
    return errorCode == 34175 && accounts.isNotEmpty;
  }

  String _failureSuffix(Map<String, dynamic> json) {
    final message =
        asString(json['msg']) ??
        asString(json['message']) ??
        asString(json['errmsg']) ??
        asString(json['error']) ??
        asString(json['error_msg']);
    if (message != null) {
      return '：$message';
    }

    final errorCode =
        asString(json['error_code']) ??
        asString(json['errcode']) ??
        asString(json['code']);
    if (errorCode != null) {
      return '（错误码：$errorCode）';
    }

    return '';
  }

  Future<List<SearchHotCategory>> searchHotKeywords() async {
    final json = asMap(await _client.get('/search/hot'));
    return asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(SearchHotCategory.fromJson)
        .toList();
  }

  Future<List<String>> searchSuggest(String keywords) async {
    final json = asMap(
      await _client.get('/search/suggest', {'keywords': keywords}),
    );
    final items = asList(json['music']);
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => asString(item['keyword']) ?? '')
        .where((k) => k.isNotEmpty)
        .toList();
  }

  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'song',
    });
    if (kDebugMode) {
      debugPrint('[KA Music][search] keywords="$keywords"');
      debugPrint('[KA Music][search] raw type: ${raw.runtimeType}');
      if (raw is List) {
        debugPrint('[KA Music][search] list length: ${raw.length}');
      } else if (raw is Map) {
        debugPrint('[KA Music][search] map keys: ${raw.keys.toList()}');
      }
    }
    // API returns either a plain array or { songs: [...] }
    final List songs;
    if (raw is List) {
      songs = raw;
    } else {
      final json = asMap(raw);
      songs = asList(json['songs'] ?? json['song'] ?? json['lists']);
    }
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Song.fromSearch)
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  /// 搜索专辑（酷狗）。
  ///
  /// 与 [searchSongs] 共用 `/search` 接口，`type=album` 返回专辑列表。
  Future<List<ArtistAlbum>> searchAlbums(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'album',
    });
    // API returns either a plain array or { albums: [...] }
    final List albums;
    if (raw is List) {
      albums = raw;
    } else {
      final json = asMap(raw);
      albums = asList(json['albums'] ?? json['album'] ?? json['lists']);
    }
    return albums
        .whereType<Map<String, dynamic>>()
        .map(ArtistAlbum.fromJson)
        .where((album) => album.id.isNotEmpty)
        .toList();
  }

  /// 搜索网易云歌曲。
  ///
  /// 使用独立的网易云 API（`wyy.music.api.hoilai.cn`）：
  /// 1. 调用 `/search?keywords=xxx` 获取歌曲 ID 列表
  /// 2. 调用 `/song/detail?ids=id1,id2,...` 获取歌曲详情（名称、歌手、专辑、封面）
  Future<List<Song>> searchNetEaseSongs(
    String keywords, {
    int limit = 30,
    int offset = 0,
  }) async {
    final baseUri = Uri.parse('https://wyy.music.api.hoilai.cn');

    // 1. 搜索获取歌曲 ID
    final searchUri = baseUri.replace(
      path: '/search',
      queryParameters: {
        'keywords': keywords,
        'limit': '$limit',
        'offset': '$offset',
        'type': '1',
      },
    );
    final searchResponse = await _client.getRaw(searchUri);
    final searchJson = asMap(searchResponse);
    final rawSongs = asList(searchJson['result'] is Map
        ? asMap(searchJson['result'])['songs']
        : searchJson['songs']);
    final ids = rawSongs
        .whereType<Map>()
        .map((item) => asInt(asMap(item)['id']))
        .whereType<int>()
        .where((id) => id > 0)
        .toList();
    if (ids.isEmpty) return const [];

    // 2. 批量获取歌曲详情
    final detailUri = baseUri.replace(
      path: '/song/detail',
      queryParameters: {'ids': ids.join(',')},
    );
    final detailResponse = await _client.getRaw(detailUri);
    final detailJson = asMap(detailResponse);
    final songsList = asList(detailJson['songs']);

    return songsList
        .whereType<Map<String, dynamic>>()
        .map((item) => NetEaseSong.fromJson(item).toSong())
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  Future<List<LyricLine>> lyrics(Song song) async {
    _debugLyricLog(
      'request song="${song.title}" artist="${song.artist}" hash="${song.hash}" albumAudioId="${song.albumAudioId}"',
    );
    final candidate = await _searchLyricCandidate(song);
    _debugLyricLogObject('selected candidate', candidate);
    if (candidate == null) {
      _debugLyricLog('no lyric candidate found');
      return const [];
    }

    final krcLyrics = await _lyricByFormat(candidate, 'krc');
    if (krcLyrics.isNotEmpty) {
      return krcLyrics;
    }

    return _lyricByFormat(candidate, 'lrc');
  }

  Future<Map<String, dynamic>?> _searchLyricCandidate(Song song) async {
    final query = {'hash': song.hash};
    _debugLyricLogObject('search query', query);
    final searchJson = await _client.get('/search/lyric', query);
    _debugLyricLogObject('search response', searchJson);

    final candidate = _findLyricCandidate(searchJson);
    if (candidate != null) {
      _debugLyricLog('search found candidate by hash');
      return candidate;
    }
    return null;
  }

  Future<List<LyricLine>> _lyricByFormat(
    Map<String, dynamic> candidate,
    String format,
  ) async {
    final id =
        asString(candidate['id']) ??
        asString(candidate['lyrics_id']) ??
        asString(candidate['lyric_id']) ??
        asString(candidate['lyricid']);
    final accessKey =
        asString(candidate['accesskey']) ??
        asString(candidate['access_key']) ??
        asString(candidate['accessKey']);
    if (id == null || accessKey == null) {
      return const [];
    }

    final result = asMap(
      await _client.get('/lyric', {
        'id': id,
        'accesskey': accessKey,
        'fmt': format,
        'decode': true,
      }),
    );
    _debugLyricLogObject('$format lyric response keys', result.keys.toList());

    final candidates = [
      asString(result['decodedContent']),
      asString(result['rawContent']),
      asString(result['content']),
    ].whereType<String>().toList();
    _debugLyricLog('$format content candidate count=${candidates.length}');

    candidates.sort(
      (a, b) => _lyricContentScore(b).compareTo(_lyricContentScore(a)),
    );
    for (var index = 0; index < candidates.length; index++) {
      final content = candidates[index];
      _debugLyricContent(
        '$format content[$index] score=${_lyricContentScore(content)} length=${content.length}',
        content,
      );
      final lines = parseLyrics(content);
      _debugLyricLog('$format content[$index] parsed lines=${lines.length}');
      if (lines.isNotEmpty) {
        return lines;
      }
    }
    _debugLyricLog('$format lyric parsed no lines');
    return const [];
  }

  Map<String, dynamic>? _findLyricCandidate(Object? value) {
    final root = asMap(value);
    final direct = _asLyricCandidate(root);
    if (direct != null) {
      return direct;
    }

    final candidates = [
      root['candidates'],
      root['candidate'],
      root['list'],
      root['lyrics'],
      root['items'],
      root['info'],
      root['data'],
    ];

    for (final candidate in candidates) {
      if (candidate is List && candidate.isNotEmpty) {
        for (final item in candidate) {
          final found = _findLyricCandidate(item);
          if (found != null) {
            return found;
          }
        }
      }
      if (candidate is Map) {
        final found = _findLyricCandidate(candidate);
        if (found != null) {
          return found;
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _asLyricCandidate(Map<String, dynamic> value) {
    final hasId =
        asString(value['id']) != null ||
        asString(value['lyrics_id']) != null ||
        asString(value['lyric_id']) != null ||
        asString(value['lyricid']) != null;
    final hasAccessKey =
        asString(value['accesskey']) != null ||
        asString(value['access_key']) != null ||
        asString(value['accessKey']) != null;
    return hasId && hasAccessKey ? value : null;
  }
}

List<PlaylistSummary> _orderUserPlaylistsForDisplay(
  List<PlaylistSummary> playlists,
) {
  if (playlists.length <= 2) {
    return playlists;
  }
  return [...playlists.take(2), ...playlists.skip(2).toList().reversed];
}

List<LyricLine> parseLyrics(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const [];
  }

  final normalized = content
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n');
  final krcLines = _parseKrc(normalized);
  final parsed = krcLines.isNotEmpty
      ? krcLines
      : _mergeSameTimeTranslation(_parseLrc(normalized));
  if (parsed.isEmpty) {
    return const [];
  }

  final variants = _parseLyricVariants(
    originalContent: normalized,
  );
  return _mergeLyricVariants(parsed, variants);
}

/// 合并同一时间戳的相邻歌词行。
///
/// LRC 歌词常见的“原文 + 翻译”写法是两行共用同一个时间戳，
/// 不合并的话翻译会被当成独立的歌词行（有自己独立的卡拉OK进度），
/// 导致原文瞬间被跳过、翻译进度对不上。这里把第二行并入第一行的
/// [LyricLine.translation]，与 KRC language 标签的处理保持一致。
List<LyricLine> _mergeSameTimeTranslation(List<LyricLine> lines) {
  if (lines.length < 2) {
    return lines;
  }
  final merged = <LyricLine>[];
  for (final line in lines) {
    final last = merged.isNotEmpty ? merged.last : null;
    if (last != null &&
        last.translation == null &&
        last.romanization == null &&
        line.time == last.time &&
        !_sameLyricText(last.text, line.text)) {
      merged[merged.length - 1] = last.copyWith(translation: line.text);
      continue;
    }
    merged.add(line);
  }
  return merged;
}

List<LyricLine> _parseKrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final lineExpression = RegExp(r'^\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\](.*)$');
  final wordExpression = RegExp(r'<\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*>');

  for (final rawLine in content.split('\n')) {
    final match = lineExpression.firstMatch(rawLine.trim());
    if (match == null) {
      continue;
    }

    final start = int.tryParse(match.group(1) ?? '');
    final duration = int.tryParse(match.group(2) ?? '');
    if (start == null || duration == null) {
      continue;
    }

    final content = match.group(3) ?? '';
    final words = <LyricWord>[];
    final matches = wordExpression.allMatches(content).toList();
    for (var index = 0; index < matches.length; index++) {
      final wordMatch = matches[index];
      final wordStart = int.tryParse(wordMatch.group(1) ?? '') ?? 0;
      final wordDuration = int.tryParse(wordMatch.group(2) ?? '') ?? 0;
      final wordEnd = index + 1 < matches.length
          ? matches[index + 1].start
          : content.length;
      final wordText = content.substring(wordMatch.end, wordEnd);
      if (wordText.isEmpty) {
        continue;
      }
      words.add(
        LyricWord(
          time: Duration(
            milliseconds: (start + wordStart + offset)
                .clamp(0, 1 << 31)
                .toInt(),
          ),
          duration: Duration(
            milliseconds: wordDuration.clamp(0, 1 << 31).toInt(),
          ),
          text: wordText,
        ),
      );
    }

    final displayWords = _trimLyricWords(words);
    final text = displayWords.isEmpty
        ? content.replaceAll(wordExpression, '').trim()
        : displayWords.map((word) => word.text).join();
    if (text.isEmpty) {
      continue;
    }

    lines.add(
      LyricLine(
        time: Duration(
          milliseconds: (start + offset).clamp(0, 1 << 31).toInt(),
        ),
        duration: Duration(milliseconds: duration.clamp(0, 1 << 31).toInt()),
        text: text,
        words: displayWords,
      ),
    );
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

List<LyricWord> _trimLyricWords(List<LyricWord> words) {
  final result = words
      .map(
        (word) => LyricWord(
          time: word.time,
          duration: word.duration,
          text: word.text,
        ),
      )
      .toList();
  while (result.isNotEmpty && result.first.text.trim().isEmpty) {
    result.removeAt(0);
  }
  while (result.isNotEmpty && result.last.text.trim().isEmpty) {
    result.removeLast();
  }
  if (result.isEmpty) {
    return result;
  }
  result[0] = LyricWord(
    time: result[0].time,
    duration: result[0].duration,
    text: result[0].text.trimLeft(),
  );
  final lastIndex = result.length - 1;
  result[lastIndex] = LyricWord(
    time: result[lastIndex].time,
    duration: result[lastIndex].duration,
    text: result[lastIndex].text.trimRight(),
  );
  return result.where((word) => word.text.isNotEmpty).toList();
}

List<LyricLine> _parseLrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final expression = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final rawLine in content.split('\n')) {
    final matches = expression.allMatches(rawLine).toList();
    if (matches.isEmpty) {
      continue;
    }
    final text = rawLine.replaceAll(expression, '').trim();
    if (text.isEmpty) {
      continue;
    }
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final fraction = match.group(3) ?? '0';
      final milliseconds = fraction.length == 3
          ? int.parse(fraction)
          : int.parse(fraction.padRight(3, '0'));
      lines.add(
        LyricLine(
          time: Duration(
            milliseconds:
                (Duration(
                          minutes: minutes,
                          seconds: seconds,
                          milliseconds: milliseconds,
                        ).inMilliseconds +
                        offset)
                    .clamp(0, 1 << 31)
                    .toInt(),
          ),
          text: text,
        ),
      );
    }
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

int _extractOffset(String content) {
  final match = RegExp(
    r'^\[offset:([+-]?\d+)\]',
    multiLine: true,
  ).firstMatch(content);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

int _lyricContentScore(String content) {
  var score = 0;
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\].*<',
    multiLine: true,
  ).hasMatch(content)) {
    score += 100;
  }
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\]',
    multiLine: true,
  ).hasMatch(content)) {
    score += 60;
  }
  if (RegExp(r'\[\d{1,2}:\d{1,2}').hasMatch(content)) {
    score += 40;
  }
  if (content.contains('[language:')) {
    score += 10;
  }
  return score;
}

_ParsedLyricVariants _parseLyricVariants({
  required String originalContent,
}) {
  // decodedTranslation 是纯文本，没有行号/时间戳信息，无法与主歌词逐行对应。
  // 翻译/音译只从 decodedContent 中的 [language:...] 标签解析，
  // 其 lyricContent 下标与主歌词行序严格一致。
  final krcVariants = _parseKrcLanguageVariants(originalContent);
  return _ParsedLyricVariants(
    translation: krcVariants.translation,
    romanization: krcVariants.romanization,
  );
}

_ParsedLyricVariants _parseKrcLanguageVariants(String content) {
  final match = RegExp(
    r'^\[language:([A-Za-z0-9+/\-_]+=*)\]',
    multiLine: true,
  ).firstMatch(content);
  final encoded = match?.group(1);
  if (encoded == null || encoded.isEmpty) {
    return const _ParsedLyricVariants();
  }

  try {
    // [language:...] 标签中的 Base64 可能使用 URL-safe 变体，需要转换
    var normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');
    final mod4 = normalized.length % 4;
    if (mod4 > 0) {
      normalized += '=' * (4 - mod4);
    }
    final decoded = utf8.decode(base64.decode(normalized));
    _debugLyricContent('language tag decoded', decoded);
    final json = jsonDecode(decoded);
    final translationByTime = <int, String>{};
    final translationByIndex = <String>[];
    final romanizationByTime = <int, String>{};
    final romanizationByIndex = <String>[];
    _collectKrcLanguageRows(
      json,
      translationByTime: translationByTime,
      translationByIndex: translationByIndex,
      romanizationByTime: romanizationByTime,
      romanizationByIndex: romanizationByIndex,
    );
    _debugLyricLog('language: transByIndex=${translationByIndex.length} transByTime=${translationByTime.length} romanByIndex=${romanizationByIndex.length} romanByTime=${romanizationByTime.length}');
    for (var i = 0; i < translationByIndex.length; i++) {
      final t = translationByIndex[i];
      if (t.isNotEmpty) {
        _debugLyricLog('language trans[$i]: "$t"');
      }
    }
    return _ParsedLyricVariants(
      translation: _TimedLyricVariant(
        byTime: translationByTime,
        byIndex: translationByIndex,
      ),
      romanization: _TimedLyricVariant(
        byTime: romanizationByTime,
        byIndex: romanizationByIndex,
      ),
    );
  } catch (_) {
    return const _ParsedLyricVariants();
  }
}

void _collectKrcLanguageRows(
  Object? value, {
  required Map<int, String> translationByTime,
  required List<String> translationByIndex,
  required Map<int, String> romanizationByTime,
  required List<String> romanizationByIndex,
}) {
  if (value is List) {
    for (final item in value) {
      _collectKrcLanguageRows(
        item,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
    return;
  }
  if (value is! Map) {
    return;
  }

  final map = asMap(value);
  final sectionType = asInt(map['type']);
  final lyricContent = map['lyricContent'];
  if (lyricContent is List) {
    for (final row in lyricContent) {
      final parsedRow = _parseKrcLanguageRow(row, sectionType);
      if (parsedRow == null) {
        continue;
      }

      final byTime = sectionType == 0 ? romanizationByTime : translationByTime;
      final byIndex = sectionType == 0
          ? romanizationByIndex
          : translationByIndex;

      if (parsedRow.time != null) {
        byTime[parsedRow.time!] = parsedRow.text;
      } else {
        byIndex.add(parsedRow.text);
      }
    }
  }

  for (final child in map.values) {
    if (child is List || child is Map) {
      _collectKrcLanguageRows(
        child,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
  }
}

({int? time, String text})? _parseKrcLanguageRow(
  Object? row,
  int? sectionType,
) {
  if (row is! List || row.isEmpty) {
    return null;
  }

  final time = row.length > 1 ? asInt(row[0]) : null;
  final values = row.map(asString).whereType<String>().toList();
  if (values.isEmpty) {
    return null;
  }

  final text = time != null && row.length > 1
      ? asString(row[1])
      : (sectionType == 0 ? values.join('') : values.join(' ').trim());
  if (text == null || text.isEmpty) {
    return null;
  }
  return (time: time, text: text);
}

List<LyricLine> _mergeLyricVariants(
  List<LyricLine> lines,
  _ParsedLyricVariants variants,
) {
  if (variants.isEmpty) {
    return lines;
  }

  final indexedTranslations = _indexedLyricVariants(
    lines,
    variants.translation,
  );
  final indexedRomanizations = _indexedLyricVariants(
    lines,
    variants.romanization,
  );
  final merged = <LyricLine>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final byTime = variants.translation.byTime[line.time.inMilliseconds];
    final nearest = _nearestLyricVariant(
      line.time.inMilliseconds,
      variants.translation.byTime,
    );
    final indexed = indexedTranslations[index];
    final trans = byTime ?? nearest ?? indexed;
    merged.add(
      line.copyWith(
        translation: trans,
        romanization:
            variants.romanization.byTime[line.time.inMilliseconds] ??
            _nearestLyricVariant(
              line.time.inMilliseconds,
              variants.romanization.byTime,
            ) ??
            indexedRomanizations[index],
      ),
    );
    if (trans != null && trans.isNotEmpty) {
      _debugLyricLog('merge[$index]: "${line.text}" → "$trans" (byTime=$byTime nearest=$nearest indexed=$indexed)');
    }
  }
  return merged;
}

Map<int, String> _indexedLyricVariants(
  List<LyricLine> lines,
  _TimedLyricVariant variant,
) {
  if (variant.byIndex.isEmpty) {
    return const {};
  }

  final result = <int, String>{};

  // 计算偏移量：
  // 如果翻译数组开头有空条目（对应制作人员信息行），则直接按索引对应。
  // 如果没有空条目（翻译只包含实际歌词），则需要偏移。
  final leadingEmpty = variant.byIndex
      .takeWhile((t) => t.trim().isEmpty)
      .length;
  final offset = leadingEmpty > 0
      ? 0
      : (lines.length - variant.byIndex.length).clamp(0, lines.length);

  _debugLyricLog('indexedVariants: lines=${lines.length} variants=${variant.byIndex.length} leadingEmpty=$leadingEmpty offset=$offset');

  for (var i = 0; i < variant.byIndex.length; i++) {
    final lineIndex = i + offset;
    if (lineIndex >= lines.length) break;

    final text = variant.byIndex[i].trim();
    if (text.isEmpty || _sameLyricText(lines[lineIndex].text, text)) {
      continue;
    }
    result[lineIndex] = text;
    _debugLyricLog('indexedVariants[$i→$lineIndex]: "${lines[lineIndex].text}" → "$text"');
  }

  _debugLyricLog('indexedVariants: assigned=${result.length} entries');
  return result;
}

bool _sameLyricText(String a, String b) {
  return _compactLyricText(a) == _compactLyricText(b);
}

String _compactLyricText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (_isHanRune(rune) ||
        _isKanaRune(rune) ||
        _isHangulRune(rune) ||
        _isLatinRune(rune) ||
        (rune >= 0x30 && rune <= 0x39)) {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isHanRune(int rune) {
  return (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0xf900 && rune <= 0xfaff);
}

bool _isKanaRune(int rune) {
  return (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x31f0 && rune <= 0x31ff);
}

bool _isHangulRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x3130 && rune <= 0x318f) ||
      (rune >= 0xac00 && rune <= 0xd7af);
}

bool _isLatinRune(int rune) {
  return (rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a);
}

String? _nearestLyricVariant(int time, Map<int, String> variants) {
  var bestDistance = 1 << 31;
  String? bestText;
  for (final entry in variants.entries) {
    final distance = (entry.key - time).abs();
    if (distance < bestDistance && distance <= 250) {
      bestDistance = distance;
      bestText = entry.value;
    }
  }
  return bestText;
}

class _ParsedLyricVariants {
  const _ParsedLyricVariants({
    this.translation = const _TimedLyricVariant(),
    this.romanization = const _TimedLyricVariant(),
  });

  final _TimedLyricVariant translation;
  final _TimedLyricVariant romanization;

  bool get isEmpty => translation.isEmpty && romanization.isEmpty;
}

class _TimedLyricVariant {
  const _TimedLyricVariant({this.byTime = const {}, this.byIndex = const []});

  final Map<int, String> byTime;
  final List<String> byIndex;

  bool get isEmpty => byTime.isEmpty && byIndex.isEmpty;
}

void _debugLyricLog(String message) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[KA Music][lyrics] $message');
}

void _debugLyricLogObject(String label, Object? value) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  _debugLyricContent(label, text);
}

void _debugLyricContent(String label, String content) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[KA Music][lyrics] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < content.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, content.length);
    debugPrint(content.substring(start, end));
  }
  debugPrint('[KA Music][lyrics] ==== end $label ====');
}

void _debugPlaylistLogObject(String label, Object? value) {
  if (!kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  debugPrint('[KA Music][playlists] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < text.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, text.length);
    debugPrint(text.substring(start, end));
  }
  debugPrint('[KA Music][playlists] ==== end $label ====');
}

void _debugArtistLogObject(String label, Object? value) {
  if (!kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  debugPrint('[KA Music][artist] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < text.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, text.length);
    debugPrint(text.substring(start, end));
  }
  debugPrint('[KA Music][artist] ==== end $label ====');
}
