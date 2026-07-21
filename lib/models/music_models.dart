class LoginSession {
  const LoginSession({
    this.userId,
    this.token,
    this.t1,
    this.sessionId,
    this.nickname,
    this.avatarUrl,
  });

  final String? userId;
  final String? token;
  final String? t1;
  final String? sessionId;
  final String? nickname;
  final String? avatarUrl;

  bool get isValid =>
      (token != null && token!.isNotEmpty) ||
      (sessionId != null && sessionId!.isNotEmpty);

  factory LoginSession.fromJson(Map<String, dynamic> json) {
    return LoginSession(
      userId: asString(json['userid']),
      token: asString(json['token']),
      t1: asString(json['t1']),
    );
  }
}

class PhoneLoginResult {
  const PhoneLoginResult._({
    this.session,
    this.accounts = const [],
    this.message,
    this.errorCode,
  });

  const PhoneLoginResult.success(LoginSession session)
    : this._(session: session);

  const PhoneLoginResult.accountSelection({
    required List<MobileLoginAccount> accounts,
    String? message,
    int? errorCode,
  }) : this._(accounts: accounts, message: message, errorCode: errorCode);

  final LoginSession? session;
  final List<MobileLoginAccount> accounts;
  final String? message;
  final int? errorCode;

  bool get requiresUserSelection => accounts.isNotEmpty;
}

class MobileLoginAccount {
  const MobileLoginAccount({
    required this.userId,
    this.nickname,
    this.avatarUrl,
    this.appId,
    this.username,
  });

  final String userId;
  final String? nickname;
  final String? avatarUrl;
  final int? appId;
  final String? username;

  String get displayName => nickname?.trim().isNotEmpty == true
      ? nickname!.trim()
      : username?.trim().isNotEmpty == true
      ? username!.trim()
      : '账号 $userId';

  String? get subtitle {
    final values = [
      username?.trim(),
      if (appId != null) 'AppID $appId',
    ].whereType<String>().where((value) => value.isNotEmpty).toList();
    if (values.isEmpty) {
      return null;
    }
    return values.join(' · ');
  }

  factory MobileLoginAccount.fromJson(Map<String, dynamic> json) {
    return MobileLoginAccount(
      userId: asString(json['userId'] ?? json['userid']) ?? '',
      nickname: asString(json['nickname']),
      avatarUrl: normalizeImageUrl(asString(json['pic'] ?? json['avatar'])),
      appId: asInt(json['appId'] ?? json['appid']),
      username: asString(json['username']),
    );
  }
}

enum AudioQuality {
  standard('128', '标准音质', '128K'),
  high('320', '高品音质', '320K'),
  lossless('flac', '无损音质', 'FLAC');

  const AudioQuality(this.apiValue, this.label, this.badge);

  final String apiValue;
  final String label;
  final String badge;

  static AudioQuality fromApiValue(String? value) {
    for (final quality in AudioQuality.values) {
      if (quality.apiValue == value) {
        return quality;
      }
    }
    return AudioQuality.standard;
  }
}

class UserProfile {
  const UserProfile({required this.nickname, this.avatarUrl});

  final String nickname;
  final String? avatarUrl;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      nickname: asString(json['nickname']) ?? 'KA Music 用户',
      avatarUrl: normalizeImageUrl(asString(json['pic'])),
    );
  }

  Map<String, dynamic> toCache() =>
      {'nickname': nickname, 'avatarUrl': avatarUrl};

  factory UserProfile.fromCache(Map<String, dynamic> json) {
    return UserProfile(
      nickname: asString(json['nickname']) ?? 'KA Music 用户',
      avatarUrl: asString(json['avatarUrl']),
    );
  }
}

class VipReceiveItem {
  const VipReceiveItem({this.day, this.receiveVip, this.vipType});

  final String? day;
  final int? receiveVip;
  final String? vipType;

  factory VipReceiveItem.fromJson(Map<String, dynamic> json) {
    return VipReceiveItem(
      day: asString(json['day']),
      receiveVip: asInt(json['receive_vip']),
      vipType: asString(json['vip_type']),
    );
  }
}

class VipReceiveHistory {
  const VipReceiveHistory({
    this.month,
    this.serverTime,
    this.items = const [],
    this.status,
    this.errorCode,
  });

  final String? month;
  final int? serverTime;
  final List<VipReceiveItem> items;
  final int? status;
  final int? errorCode;

  factory VipReceiveHistory.fromJson(Map<String, dynamic> json) {
    return VipReceiveHistory(
      month: asString(json['month']),
      serverTime: asInt(json['server_time']),
      items: asList(json['list'])
          .whereType<Map>()
          .map((item) => VipReceiveItem.fromJson(asMap(item)))
          .toList(),
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class OneDayVipResult {
  const OneDayVipResult({this.status, this.errorCode});

  final int? status;
  final int? errorCode;

  factory OneDayVipResult.fromJson(Map<String, dynamic> json) {
    return OneDayVipResult(
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class UpgradeVipResult {
  const UpgradeVipResult({this.status, this.errorCode});

  final int? status;
  final int? errorCode;

  factory UpgradeVipResult.fromJson(Map<String, dynamic> json) {
    return UpgradeVipResult(
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.title,
    this.subtitle,
    this.coverUrl,
    this.songCount,
    this.playCount,
    this.isDefault,
    this.creatorName,
    this.creatorUserId,
    this.currentUserId,
    this.sourceGlobalId,
    this.sourceListId,
    this.type,
    this.source,
    this.listId,
    this.musiclibId,
  });

  final String id;
  final String title;
  final String? subtitle;
  final String? coverUrl;
  final int? songCount;
  final int? playCount;
  final int? isDefault;
  final String? creatorName;
  final String? creatorUserId;
  final String? currentUserId;
  final String? sourceGlobalId;
  final String? sourceListId;

  /// API `type` field: 0 = 用户创建, 1 = 收藏的歌单
  final int? type;

  /// API `source` field: 1 = 自建, 2 = 来自音乐库
  final int? source;

  /// Raw numeric playlist ID for track add/remove operations
  final String? listId;

  /// Album id for collected albums from `/user/playlist`
  final String? musiclibId;

  bool get isLikedPlaylist => isDefault == 2 || title.trim() == '我喜欢';

  bool get isCollectedAlbum =>
      !isLikedPlaylist && (sourceGlobalId == null || sourceGlobalId!.isEmpty);

  String? get albumId {
    if (!isCollectedAlbum) {
      return null;
    }
    if (musiclibId?.isNotEmpty == true) {
      return musiclibId;
    }
    if (sourceListId?.isNotEmpty == true) {
      return sourceListId;
    }
    return null;
  }

  bool get isCreatedPlaylist {
    if (isCollectedAlbum) {
      return false;
    }
    if (type == 0) {
      return true;
    }
    if (type == 1) {
      return false;
    }
    if (isDefault == 0 || isDefault == 1) {
      return true;
    }
    return currentUserId != null &&
        creatorUserId != null &&
        currentUserId == creatorUserId;
  }

  bool get hasCollectionSource {
    return (sourceGlobalId != null && sourceGlobalId!.isNotEmpty) ||
        (sourceListId != null && sourceListId!.isNotEmpty);
  }

  factory PlaylistSummary.fromRecommend(Map<String, dynamic> json) {
    final globalCollectionId = asString(json['global_collection_id']);
    final id = globalCollectionId ?? asString(json['specialid']) ?? '';
    return PlaylistSummary(
      id: id,
      title: asString(json['specialname']) ?? '未命名歌单',
      subtitle: asString(json['nickname']) ?? asString(json['intro']),
      coverUrl: normalizeImageUrl(asString(json['flexible_cover'])),
      playCount: asInt(json['play_count']),
      // 标记来源 ID，避免被 isCollectedAlbum 误判为收藏专辑，
      // 否则 PlaylistDetailPage 会走专辑加载分支导致歌曲列表为空。
      sourceGlobalId: globalCollectionId ?? id,
    );
  }

  factory PlaylistSummary.fromUser(
    Map<String, dynamic> json, {
    String? currentUserId,
  }) {
    final creatorName = asString(json['list_create_username']);
    final sourceGlobalId = asString(json['list_create_gid']);
    final sourceListId = asString(json['list_create_listid']);
    return PlaylistSummary(
      id:
          sourceGlobalId ??
          asString(json['global_collection_id']) ??
          asString(json['listid']) ??
          '',
      title: asString(json['name']) ?? '我的歌单',
      subtitle: creatorName,
      coverUrl: normalizeImageUrl(asString(json['pic'])),
      songCount: asInt(json['count']),
      isDefault: asInt(json['is_def']) ?? asInt(json['is_default']),
      creatorName: creatorName,
      creatorUserId: asString(json['list_create_userid']),
      currentUserId: currentUserId,
      sourceGlobalId: sourceGlobalId,
      sourceListId: sourceListId,
      type: asInt(json['type']),
      source: asInt(json['source']),
      listId: asString(json['listid']),
      musiclibId: asString(json['musiclib_id']),
    );
  }

  factory PlaylistSummary.fromDetail(Map<String, dynamic> json) {
    return PlaylistSummary(
      id:
          asString(json['global_collection_id']) ??
          asString(json['listid']) ??
          '',
      title: asString(json['name']) ?? '歌单',
      subtitle:
          asString(json['list_create_username']) ?? asString(json['intro']),
      coverUrl: normalizeImageUrl(asString(json['pic'])),
      songCount: asInt(json['count']),
      playCount: asInt(json['heat']),
      creatorName: asString(json['list_create_username']),
      creatorUserId: asString(json['list_create_userid']),
      sourceGlobalId: asString(json['list_create_gid']),
      sourceListId: asString(json['list_create_listid']),
    );
  }

  factory PlaylistSummary.fromCache(Map<String, dynamic> json) {
    return PlaylistSummary(
      id: asString(json['id']) ?? '',
      title: asString(json['title']) ?? '我的歌单',
      subtitle: asString(json['subtitle']),
      coverUrl: asString(json['coverUrl']),
      songCount: asInt(json['songCount']),
      playCount: asInt(json['playCount']),
      isDefault: asInt(json['isDefault']),
      creatorName: asString(json['creatorName']),
      creatorUserId: asString(json['creatorUserId']),
      currentUserId: asString(json['currentUserId']),
      sourceGlobalId: asString(json['sourceGlobalId']),
      sourceListId: asString(json['sourceListId']),
      type: asInt(json['type']),
      source: asInt(json['source']),
      listId: asString(json['listId']),
      musiclibId: asString(json['musiclibId']),
    );
  }

  Map<String, dynamic> toCache() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'coverUrl': coverUrl,
      'songCount': songCount,
      'playCount': playCount,
      'isDefault': isDefault,
      'creatorName': creatorName,
      'creatorUserId': creatorUserId,
      'currentUserId': currentUserId,
      'sourceGlobalId': sourceGlobalId,
      'sourceListId': sourceListId,
      'type': type,
      'source': source,
      'listId': listId,
      'musiclibId': musiclibId,
    };
  }
}

/// 歌曲来源平台。
enum SongSource {
  /// 酷狗音乐（默认）
  kugou,
  /// 网易云音乐
  netease,
  /// 本地音乐
  local,
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.hash,
    this.albumId,
    this.albumAudioId,
    this.albumName,
    this.coverUrl,
    this.duration,
    this.artists = const [],
    this.isCloudDrive = false,
    this.source = SongSource.kugou,
  });

  final String id;
  final String title;
  final String artist;
  final String hash;
  final String? albumId;
  final String? albumAudioId;
  final String? albumName;
  final String? coverUrl;
  final Duration? duration;
  final List<ArtistRef> artists;

  /// 标记是否为云盘歌曲。云盘歌曲的播放地址需通过 `/user/cloud/url` 获取。
  final bool isCloudDrive;

  /// 歌曲来源平台。
  final SongSource source;

  factory Song.fromSearch(Map<String, dynamic> json) {
    final songId =
        asString(json['MixSongID']) ??
        asString(json['mixsongid']) ??
        asString(json['songid']) ??
        asString(json['audio_id']) ??
        asString(json['fileid']);

    final hash =
        asString(json['FileHash']) ??
        asString(json['hash']) ??
        asString(json['hash_320']) ??
        asString(json['hash_flac']) ??
        '';
    final imageUrl =
        asString(json['Image']) ??
        asString(json['sizable_cover']) ??
        asString(json['img']);
    final artists = parseArtists(
      json,
      fallbackName:
          asString(json['SingerName']) ??
          asString(json['author_name']) ??
          asString(json['singername']) ??
          asString(json['singer_name']),
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');

    return Song(
      id: songId ?? hash,
      title:
          asString(json['FileName']) ??
          asString(json['songname']) ??
          asString(json['name']) ??
          asString(json['audio_name']) ??
          '未知歌曲',
      artist: artistName.isNotEmpty
          ? artistName
          : asString(json['SingerName']) ??
                asString(json['author_name']) ??
                asString(json['singername']) ??
                asString(json['singer_name']) ??
                '未知艺人',
      hash: hash,
      albumId: asString(json['AlbumID']) ?? asString(json['album_id']),
      albumAudioId: songId,
      albumName: asString(json['AlbumName']) ?? asString(json['album_name']),
      coverUrl: normalizeImageUrl(imageUrl),
      artists: artists,
      duration:
          durationFromSeconds(json['Duration']) ??
          durationFromMilliseconds(json['timelen']) ??
          durationFromSeconds(json['time_length']) ??
          durationFromSeconds(json['duration']),
    );
  }

  factory Song.fromDaily(Map<String, dynamic> json) {
    final songId = asString(json['songid']) ?? asString(json['audio_id']);
    final artists = parseArtists(
      json,
      fallbackName: asString(json['author_name']),
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    return Song(
      id: asString(json['mixsongid']) ?? songId ?? asString(json['hash']) ?? '',
      title:
          asString(json['songname']) ?? asString(json['audio_name']) ?? '未知歌曲',
      artist: artistName.isNotEmpty
          ? artistName
          : asString(json['author_name']) ?? '未知艺人',
      hash:
          asString(json['hash']) ??
          asString(json['hash_320']) ??
          asString(json['hash_flac']) ??
          '',
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['mixsongid']) ?? songId,
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(asString(json['sizable_cover'])),
      artists: artists,
      duration: durationFromSeconds(json['time_length']),
    );
  }

  factory Song.fromPlaylist(Map<String, dynamic> json) {
    final artists = parseArtists(json);
    final artist = artists.map((artist) => artist.name).join(' / ');
    final albumInfo = json['albuminfo'];
    final albumMap = albumInfo is Map<String, dynamic> ? albumInfo : null;

    return Song(
      id: asString(json['fileid']) ?? asString(json['hash']) ?? '',
      title: asString(json['name']) ?? asString(json['audio_name']) ?? '未知歌曲',
      artist: artist.isNotEmpty ? artist : '未知艺人',
      hash: asString(json['hash']) ?? '',
      albumId: asString(json['album_id']) ?? asString(albumMap?['album_id']),
      albumAudioId:
          asString(json['mixsongid']) ??
          asString(json['album_audio_id']) ??
          asString(json['audio_id']),
      albumName:
          asString(albumMap?['album_name']) ?? asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(json['cover']) ??
            asString(albumMap?['sizable_cover']) ??
            asString(albumMap?['cover']),
      ),
      artists: artists,
      duration: durationFromMilliseconds(json['timelen']),
    );
  }

  factory Song.fromArtistAudio(Map<String, dynamic> json, {String? artistId}) {
    var artists = parseArtists(
      json,
      fallbackName: asString(json['author_name']),
    );
    final authorName = asString(json['author_name']);
    if (artistId != null &&
        artistId.isNotEmpty &&
        authorName != null &&
        artists.every((artist) => artist.id.isEmpty)) {
      artists = [ArtistRef(id: artistId, name: authorName)];
    }
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final transParam = asMap(json['trans_param']);

    return Song(
      id:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['hash']) ??
          '',
      title: asString(json['audio_name']) ?? asString(json['name']) ?? '未知歌曲',
      artist: artistName.isNotEmpty ? artistName : authorName ?? '未知艺人',
      hash: asString(json['hash']) ?? '',
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['album_audio_id']),
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(transParam['union_cover']) ??
            asString(json['sizable_cover']) ??
            asString(json['cover']),
      ),
      artists: artists,
      duration:
          durationFromMilliseconds(json['timelength']) ??
          durationFromMilliseconds(json['timelen']),
    );
  }

  factory Song.fromFm(Map<String, dynamic> json) {
    final displayName =
        asString(json['audio_name']) ??
        asString(json['songname']) ??
        asString(json['name']);
    final splitName = _splitSongDisplayName(displayName);
    final artists = parseArtists(
      json,
      fallbackName:
          asString(json['author_name']) ??
          asString(json['SingerName']) ??
          splitName.artist,
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final transParam = asMap(json['trans_param']);

    return Song(
      id:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['sid']) ??
          asString(json['hash']) ??
          '',
      title: splitName.title ?? displayName ?? '未知歌曲',
      artist: artistName.isNotEmpty ? artistName : splitName.artist ?? '未知艺人',
      hash:
          asString(json['hash']) ??
          asString(json['FileHash']) ??
          asString(json['320hash']) ??
          asString(json['hash_320']) ??
          asString(json['hash_flac']) ??
          '',
      albumId: asString(json['album_id']),
      albumAudioId:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['sid']),
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(transParam['union_cover']) ??
            asString(json['sizable_cover']) ??
            asString(json['cover']) ??
            asString(json['imgurl']),
      ),
      artists: artists,
      duration:
          durationFromMilliseconds(json['time']) ??
          durationFromMilliseconds(json['320time']) ??
          durationFromMilliseconds(json['timelen']) ??
          durationFromMilliseconds(json['timelength']),
    );
  }

  factory Song.fromAlbum(Map<String, dynamic> json) {
    final base = asMap(json['base']);
    final audioInfo = asMap(json['audio_info']);
    final albumInfo = asMap(json['album_info']);
    final authorsRaw = asList(
      json['authors'],
    ).whereType<Map<String, dynamic>>();
    final artists = authorsRaw
        .map(
          (item) => ArtistRef(
            id: asString(item['author_id']) ?? '',
            name: asString(item['author_name']) ?? '',
          ),
        )
        .where((artist) => artist.name.isNotEmpty)
        .toList();
    final artistName = artists.map((artist) => artist.name).join(' / ');

    return Song(
      id:
          asString(audioInfo['hash']) ??
          asString(base['album_id']) ??
          asString(json['id']) ??
          '',
      title: asString(base['audio_name']) ?? '未知歌曲',
      artist: artistName.isNotEmpty
          ? artistName
          : asString(base['author_name']) ?? '未知艺人',
      hash: asString(audioInfo['hash']) ?? '',
      albumId: asString(base['album_id']),
      albumAudioId: asString(audioInfo['hash']) ?? asString(json['id']),
      albumName: asString(albumInfo['album_name']),
      coverUrl: normalizeImageUrl(asString(albumInfo['cover'])),
      artists: artists,
      duration: durationFromMilliseconds(audioInfo['duration']),
    );
  }

  Map<String, dynamic> toCache() => {
        'id': id,
        'title': title,
        'artist': artist,
        'hash': hash,
        'albumId': albumId,
        'albumAudioId': albumAudioId,
        'albumName': albumName,
        'coverUrl': coverUrl,
        'durationMs': duration?.inMilliseconds,
        'artists': artists
            .map((a) => {
                  'id': a.id,
                  'name': a.name,
                  'avatarUrl': a.avatarUrl,
                })
            .toList(),
        if (isCloudDrive) 'isCloudDrive': true,
      };

  factory Song.fromCache(Map<String, dynamic> json) {
    return Song(
      id: asString(json['id']) ?? '',
      title: asString(json['title']) ?? '未知歌曲',
      artist: asString(json['artist']) ?? '未知艺人',
      hash: asString(json['hash']) ?? '',
      albumId: asString(json['albumId']),
      albumAudioId: asString(json['albumAudioId']),
      albumName: asString(json['albumName']),
      coverUrl: asString(json['coverUrl']),
      duration: durationFromMilliseconds(json['durationMs']),
      artists: asList(json['artists'])
          .whereType<Map<String, dynamic>>()
          .map((a) => ArtistRef(
                id: asString(a['id']) ?? '',
                name: asString(a['name']) ?? '',
                avatarUrl: asString(a['avatarUrl']),
              ))
          .where((artist) => artist.name.isNotEmpty)
          .toList(),
      isCloudDrive: json['isCloudDrive'] == true,
    );
  }
}

class FmStation {
  const FmStation({
    required this.id,
    required this.name,
    required this.type,
    this.classId,
    this.className,
    this.description,
    this.bannerUrl,
    this.imageUrl,
    this.previewSongs = const [],
  });

  final String id;
  final String name;
  final int type;
  final String? classId;
  final String? className;
  final String? description;
  final String? bannerUrl;
  final String? imageUrl;
  final List<Song> previewSongs;

  String get subtitle {
    if (description != null && description!.isNotEmpty) {
      return description!;
    }
    if (className != null && className!.isNotEmpty) {
      return className!;
    }
    if (previewSongs.isNotEmpty) {
      return previewSongs.first.title;
    }
    return '电台';
  }

  String? get artworkUrl =>
      imageUrl ?? bannerUrl ?? previewSongs.firstOrNull?.coverUrl;

  factory FmStation.fromJson(Map<String, dynamic> json, {String? classId}) {
    final songs = asList(json['rcmdlist'] ?? json['songlist'])
        .whereType<Map>()
        .map((item) => Song.fromFm(asMap(item)))
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return FmStation(
      id: asString(json['fmid']) ?? '',
      name: asString(json['fmname']) ?? '未命名电台',
      type: asInt(json['fmtype']) ?? asInt(json['type']) ?? 2,
      classId: asString(json['classid']) ?? classId,
      className: asString(json['classname']),
      description: asString(json['description']),
      bannerUrl: normalizeImageUrl(asString(json['banner'])),
      imageUrl: normalizeImageUrl(asString(json['imgurl'])),
      previewSongs: songs,
    );
  }

  FmStation mergeImage(FmImage image) {
    return FmStation(
      id: id,
      name: name,
      type: type,
      classId: classId,
      className: className,
      description: description,
      bannerUrl: image.bannerUrl ?? bannerUrl,
      imageUrl: image.imageUrl ?? imageUrl,
      previewSongs: previewSongs,
    );
  }
}

class FmClassGroup {
  const FmClassGroup({
    required this.id,
    required this.name,
    required this.stations,
  });

  final String id;
  final String name;
  final List<FmStation> stations;

  factory FmClassGroup.fromJson(Map<String, dynamic> json) {
    final id = asString(json['classid']) ?? '';
    final stations = asList(json['fmlist'])
        .whereType<Map>()
        .map((item) => FmStation.fromJson(asMap(item), classId: id))
        .where((station) => station.id.isNotEmpty)
        .toList();
    final firstClassName = stations
        .map((station) => station.className)
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .firstOrNull;

    return FmClassGroup(
      id: id,
      name: asString(json['classname']) ?? firstClassName ?? '分类 $id',
      stations: stations,
    );
  }
}

class FmSongPage {
  const FmSongPage({
    required this.fmid,
    required this.type,
    required this.offset,
    required this.size,
    required this.songs,
  });

  final String fmid;
  final int type;
  final int offset;
  final int size;
  final List<Song> songs;

  factory FmSongPage.fromJson(Map<String, dynamic> json) {
    return FmSongPage(
      fmid: asString(json['fmid']) ?? '',
      type: asInt(json['fmtype']) ?? 2,
      offset: asInt(json['offset']) ?? -1,
      size: asInt(json['size']) ?? 0,
      songs: asList(json['songs'])
          .whereType<Map>()
          .map((item) => Song.fromFm(asMap(item)))
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }
}

class FmImage {
  const FmImage({
    required this.fmid,
    this.fmtype,
    this.imageUrl,
    this.bannerUrl,
  });

  final String fmid;
  final int? fmtype;
  final String? imageUrl;
  final String? bannerUrl;

  factory FmImage.fromJson(Map<String, dynamic> json) {
    return FmImage(
      fmid: asString(json['fmid']) ?? '',
      fmtype: asInt(json['fmtype']),
      imageUrl: normalizeImageUrl(asString(json['imgurl'])),
      bannerUrl: normalizeImageUrl(asString(json['banner'])),
    );
  }
}

class _SongDisplayName {
  const _SongDisplayName({this.artist, this.title});

  final String? artist;
  final String? title;
}

_SongDisplayName _splitSongDisplayName(String? value) {
  if (value == null) {
    return const _SongDisplayName();
  }

  final separator = RegExp(r'\s[-–—]\s');
  final match = separator.firstMatch(value);
  if (match == null) {
    return _SongDisplayName(title: value);
  }

  final artist = value.substring(0, match.start).trim();
  final title = value.substring(match.end).trim();
  return _SongDisplayName(
    artist: artist.isEmpty ? null : artist,
    title: title.isEmpty ? value : title,
  );
}

class PlaylistDetail {
  const PlaylistDetail({required this.info, required this.songs});

  final PlaylistSummary info;
  final List<Song> songs;
}

class SongPage {
  const SongPage({required this.songs, required this.rawItemCount});

  final List<Song> songs;
  final int rawItemCount;
}

class ArtistRef {
  const ArtistRef({required this.id, required this.name, this.avatarUrl});

  final String id;
  final String name;
  final String? avatarUrl;
}

class ArtistDetail {
  const ArtistDetail({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.birthday,
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final String? birthday;

  factory ArtistDetail.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return ArtistDetail(
      id: id,
      name: asString(json['author_name']) ?? '未知歌手',
      avatarUrl: normalizeImageUrl(
        asString(json['sizable_avatar']) ?? asString(json['avatar']),
      ),
      birthday: asString(json['birthday']),
    );
  }
}

List<ArtistRef> parseArtists(
  Map<String, dynamic> json, {
  String? fallbackName,
}) {
  final artists = <ArtistRef>[];
  void addFromMap(Map<String, dynamic> item) {
    final id =
        asString(item['id']) ??
        asString(item['author_id']) ??
        asString(item['AuthorID']) ??
        asString(item['AuthorId']) ??
        asString(item['singerid']) ??
        asString(item['singer_id']) ??
        asString(item['SingerId']) ??
        asString(item['SingerID']) ??
        asString(item['singer_id_new']) ??
        asString(item['encode_singer_id']) ??
        asString(item['singerId']) ??
        asString(item['authorId']);
    final name =
        asString(item['name']) ??
        asString(item['author_name']) ??
        asString(item['SingerName']) ??
        asString(item['singername']) ??
        asString(item['singer_name']) ??
        asString(item['singerName']) ??
        asString(item['authorName']);
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return;
    }
    if (artists.any((artist) => artist.id == id)) {
      return;
    }
    artists.add(
      ArtistRef(
        id: id,
        name: name,
        avatarUrl: normalizeImageUrl(
          asString(item['sizable_avatar']) ?? asString(item['avatar']),
        ),
      ),
    );
  }

  for (final key in const ['singerinfo', 'authors', 'author', 'singers', 'Singers']) {
    final value = json[key];
    if (value is List) {
      for (final item in value.whereType<Map<String, dynamic>>()) {
        addFromMap(item);
      }
    } else if (value is Map<String, dynamic>) {
      addFromMap(value);
    }
  }

  addFromMap(json);

  if (artists.isEmpty && fallbackName != null && fallbackName.isNotEmpty) {
    final names = fallbackName
        .split(RegExp(r'\s*[/、,，&]\s*'))
        .where((name) => name.trim().isNotEmpty);
    for (final name in names) {
      artists.add(ArtistRef(id: '', name: name.trim()));
    }
  }
  return artists;
}

class DailyRecommend {
  const DailyRecommend({
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.songs,
  });

  final String title;
  final String? subtitle;
  final String? coverUrl;
  final List<Song> songs;

  factory DailyRecommend.fromJson(Map<String, dynamic> json) {
    final date = asString(json['creation_date']);
    return DailyRecommend(
      title: date == null ? '每日推荐' : '每日推荐 $date',
      subtitle: asString(json['sub_title']),
      coverUrl: normalizeImageUrl(asString(json['cover_img_url'])),
      songs: asList(json['song_list'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromDaily)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toCache() => {
        'title': title,
        'subtitle': subtitle,
        'coverUrl': coverUrl,
        'songs': songs.map((s) => s.toCache()).toList(),
      };

  factory DailyRecommend.fromCache(Map<String, dynamic> json) {
    return DailyRecommend(
      title: asString(json['title']) ?? '每日推荐',
      subtitle: asString(json['subtitle']),
      coverUrl: asString(json['coverUrl']),
      songs: asList(json['songs'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }
}

class AlbumShopItem {
  const AlbumShopItem({
    required this.albumName,
    required this.singerName,
    required this.mediaId,
    required this.topicId,
    this.pic,
    this.price,
    this.buyNum,
  });

  final String albumName;
  final String singerName;
  final int mediaId;
  final int topicId;
  final String? pic;
  final int? price; // 分为单位
  final int? buyNum;

  String? get coverUrl => normalizeImageUrl(pic);

  String get priceText {
    if (price == null) return '';
    final yuan = price! / 100;
    return yuan == yuan.roundToDouble()
        ? '¥${yuan.round()}'
        : '¥${yuan.toStringAsFixed(2)}';
  }

  factory AlbumShopItem.fromJson(Map<String, dynamic> json) {
    return AlbumShopItem(
      albumName: asString(json['album_name']) ?? '未知专辑',
      singerName: asString(json['singer_name']) ?? '未知歌手',
      mediaId: asInt(json['media_id']) ?? 0,
      topicId: asInt(json['topic_id']) ?? 0,
      pic: asString(json['pic']),
      price: asInt(json['price']),
      buyNum: asInt(json['buy_num']),
    );
  }

  Map<String, dynamic> toCache() => {
        'albumName': albumName,
        'singerName': singerName,
        'mediaId': mediaId,
        'topicId': topicId,
        'pic': pic,
        'price': price,
        'buyNum': buyNum,
      };

  factory AlbumShopItem.fromCache(Map<String, dynamic> json) {
    return AlbumShopItem(
      albumName: asString(json['albumName']) ?? '未知专辑',
      singerName: asString(json['singerName']) ?? '未知歌手',
      mediaId: asInt(json['mediaId']) ?? 0,
      topicId: asInt(json['topicId']) ?? 0,
      pic: asString(json['pic']),
      price: asInt(json['price']),
      buyNum: asInt(json['buyNum']),
    );
  }
}

class PlayUrl {
  const PlayUrl({required this.url, required this.hash});

  final String url;
  final String hash;

  factory PlayUrl.fromJson(Map<String, dynamic> json) {
    final urls = asList(json['url']).whereType<String>().toList();
    return PlayUrl(
      url: urls.isNotEmpty ? urls.first : '',
      hash: asString(json['hash']) ?? '',
    );
  }
}

class LyricLine {
  const LyricLine({
    required this.time,
    required this.text,
    this.duration,
    this.translation,
    this.romanization,
    this.words = const [],
  });

  final Duration time;
  final String text;
  final Duration? duration;
  final String? translation;
  final String? romanization;
  final List<LyricWord> words;

  LyricLine copyWith({String? translation, String? romanization}) {
    return LyricLine(
      time: time,
      text: text,
      duration: duration,
      translation: translation ?? this.translation,
      romanization: romanization ?? this.romanization,
      words: words,
    );
  }

  int activeWordIndex(Duration position) {
    if (words.isEmpty) {
      return -1;
    }
    var active = -1;
    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      if (position >= word.time) {
        active = index;
      } else {
        break;
      }
    }
    return active;
  }

  Map<String, dynamic> toCache() => {
        'timeMs': time.inMilliseconds,
        'text': text,
        'durationMs': duration?.inMilliseconds,
        'translation': translation,
        'romanization': romanization,
        'words': words.map((w) => w.toCache()).toList(),
      };

  factory LyricLine.fromCache(Map<String, dynamic> json) {
    return LyricLine(
      time: Duration(milliseconds: asInt(json['timeMs']) ?? 0),
      text: asString(json['text']) ?? '',
      duration: durationFromMilliseconds(json['durationMs']),
      translation: asString(json['translation']),
      romanization: asString(json['romanization']),
      words: (json['words'] as List? ?? const [])
          .whereType<Map>()
          .map((w) => LyricWord.fromCache(asMap(w)))
          .toList(),
    );
  }
}

class LyricWord {
  const LyricWord({
    required this.time,
    required this.duration,
    required this.text,
  });

  final Duration time;
  final Duration duration;
  final String text;

  Map<String, dynamic> toCache() => {
        'timeMs': time.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'text': text,
      };

  factory LyricWord.fromCache(Map<String, dynamic> json) {
    return LyricWord(
      time: Duration(milliseconds: asInt(json['timeMs']) ?? 0),
      duration: Duration(milliseconds: asInt(json['durationMs']) ?? 0),
      text: asString(json['text']) ?? '',
    );
  }
}

class CommentLikeInfo {
  const CommentLikeInfo({this.count, this.haslike, this.likenum});

  final int? count;
  final bool? haslike;
  final int? likenum;

  factory CommentLikeInfo.fromJson(Map<String, dynamic> json) {
    return CommentLikeInfo(
      count: asInt(json['count']),
      haslike: json['haslike'] is bool ? json['haslike'] : null,
      likenum: asInt(json['likenum']),
    );
  }
}

class CommentVipInfo {
  const CommentVipInfo({this.vipType, this.mType, this.userType});

  final int? vipType;
  final int? mType;
  final int? userType;

  factory CommentVipInfo.fromJson(Map<String, dynamic> json) {
    return CommentVipInfo(
      vipType: asInt(json['vip_type']),
      mType: asInt(json['m_type']),
      userType: asInt(json['user_type']),
    );
  }
}

class CommentImage {
  const CommentImage({this.url, this.width, this.height});

  final String? url;
  final int? width;
  final int? height;

  factory CommentImage.fromJson(Map<String, dynamic> json) {
    return CommentImage(
      url: normalizeImageUrl(asString(json['url'])),
      width: asInt(json['width']),
      height: asInt(json['height']),
    );
  }
}

class CommentUserDetail {
  const CommentUserDetail({
    this.medalType,
    this.medalRollWord,
    this.wordV3,
    this.pendantName,
    this.pendantUrl,
  });

  final String? medalType;
  final String? medalRollWord;
  final String? wordV3;
  final String? pendantName;
  final String? pendantUrl;

  factory CommentUserDetail.fromJson(Map<String, dynamic> json) {
    return CommentUserDetail(
      medalType: asString(json['medal_type']),
      medalRollWord: asString(json['medal_roll_word']),
      wordV3: asString(json['word_v3']),
      pendantName: asString(json['pendant_name']),
      pendantUrl: normalizeImageUrl(asString(json['pendant_url'])),
    );
  }
}

class CommentTailInfo {
  const CommentTailInfo({this.id, this.name});

  final String? id;
  final String? name;

  factory CommentTailInfo.fromJson(Map<String, dynamic> json) {
    return CommentTailInfo(
      id: asString(json['id']),
      name: asString(json['name']),
    );
  }
}

class CommentHotWord {
  const CommentHotWord({this.content, this.count});

  final String? content;
  final int? count;

  factory CommentHotWord.fromJson(Map<String, dynamic> json) {
    return CommentHotWord(
      content: asString(json['content']),
      count: asInt(json['count']),
    );
  }
}

class CommentClassifyItem {
  const CommentClassifyItem({this.id, this.label, this.icon, this.cnt});

  final int? id;
  final String? label;
  final String? icon;
  final int? cnt;

  factory CommentClassifyItem.fromJson(Map<String, dynamic> json) {
    return CommentClassifyItem(
      id: asInt(json['id']),
      label: asString(json['label']),
      icon: asString(json['icon']),
      cnt: asInt(json['cnt']),
    );
  }
}

class CommentTag {
  const CommentTag({this.name, this.type, this.count});

  final String? name;
  final String? type;
  final int? count;

  factory CommentTag.fromJson(Map<String, dynamic> json) {
    return CommentTag(
      name: asString(json['name']),
      type: asString(json['type']),
      count: asInt(json['count']),
    );
  }
}

class CommentConfig {
  const CommentConfig({this.emptyTip, this.inputHint});

  final String? emptyTip;
  final String? inputHint;

  factory CommentConfig.fromJson(Map<String, dynamic> json) {
    return CommentConfig(
      emptyTip: asString(json['emptyTip']),
      inputHint: asString(json['input_hint']),
    );
  }
}

class CommentSongScore {
  const CommentSongScore({this.scoreUserCount, this.songScore});

  final int? scoreUserCount;
  final double? songScore;

  factory CommentSongScore.fromJson(Map<String, dynamic> json) {
    return CommentSongScore(
      scoreUserCount: asInt(json['score_user_count']),
      songScore: (json['song_score'] is num)
          ? (json['song_score'] as num).toDouble()
          : double.tryParse(asString(json['song_score']) ?? ''),
    );
  }
}

class MusicCommentItem {
  const MusicCommentItem({
    required this.id,
    this.content,
    this.addtime,
    this.replyNum,
    this.userId,
    this.userName,
    this.userPic,
    this.userSex,
    this.like,
    this.images,
    this.location,
    this.hash,
    this.score,
    this.vipinfo,
    this.udetail,
    this.machineTail,
    this.tail,
  });

  final int id;
  final String? content;
  final String? addtime;
  final int? replyNum;
  final int? userId;
  final String? userName;
  final String? userPic;
  final int? userSex;
  final CommentLikeInfo? like;
  final List<CommentImage>? images;
  final String? location;
  final String? hash;
  final int? score;
  final CommentVipInfo? vipinfo;
  final CommentUserDetail? udetail;
  final String? machineTail;
  final CommentTailInfo? tail;

  factory MusicCommentItem.fromJson(Map<String, dynamic> json) {
    return MusicCommentItem(
      id: asInt(json['id']) ?? 0,
      content: asString(json['content']),
      addtime: asString(json['addtime']),
      replyNum: asInt(json['reply_num']),
      userId: asInt(json['user_id']),
      userName: asString(json['user_name']),
      userPic: normalizeImageUrl(asString(json['user_pic'])),
      userSex: asInt(json['user_sex']),
      like: json['like'] is Map
          ? CommentLikeInfo.fromJson(asMap(json['like']))
          : null,
      images: json['images'] is List
          ? asList(json['images'])
                .whereType<Map>()
                .map((e) => CommentImage.fromJson(asMap(e)))
                .toList()
          : null,
      location: asString(json['location']),
      hash: asString(json['hash']),
      score: asInt(json['score']),
      vipinfo: json['vipinfo'] is Map
          ? CommentVipInfo.fromJson(asMap(json['vipinfo']))
          : null,
      udetail: json['udetail'] is Map
          ? CommentUserDetail.fromJson(asMap(json['udetail']))
          : null,
      machineTail: asString(json['machine_tail']),
      tail: json['tail'] is Map
          ? CommentTailInfo.fromJson(asMap(json['tail']))
          : null,
    );
  }
}

class MusicCommentResponse {
  const MusicCommentResponse({
    this.msg,
    this.message,
    this.childrenid,
    this.count,
    this.combineCount,
    this.currentPage,
    this.maxPage,
    this.list,
    this.hotWordList,
    this.classifyList,
    this.tag,
    this.config,
    this.songScore,
    this.status,
    this.errorCode,
  });

  final String? msg;
  final String? message;
  final String? childrenid;
  final int? count;
  final int? combineCount;
  final int? currentPage;
  final int? maxPage;
  final List<MusicCommentItem>? list;
  final List<CommentHotWord>? hotWordList;
  final List<CommentClassifyItem>? classifyList;
  final List<CommentTag>? tag;
  final CommentConfig? config;
  final CommentSongScore? songScore;
  final int? status;
  final int? errorCode;

  factory MusicCommentResponse.fromJson(Map<String, dynamic> json) {
    return MusicCommentResponse(
      msg: asString(json['msg']),
      message: asString(json['message']),
      childrenid: asString(json['childrenid']),
      count: asInt(json['count']),
      combineCount: asInt(json['combine_count']),
      currentPage: asInt(json['current_page']),
      maxPage: asInt(json['maxPage']),
      list: json['list'] is List
          ? asList(json['list'])
                .whereType<Map>()
                .map((e) => MusicCommentItem.fromJson(asMap(e)))
                .toList()
          : null,
      hotWordList: json['hot_word_list'] is List
          ? asList(json['hot_word_list'])
                .whereType<Map>()
                .map((e) => CommentHotWord.fromJson(asMap(e)))
                .toList()
          : null,
      classifyList: json['classify_list'] is List
          ? asList(json['classify_list'])
                .whereType<Map>()
                .map((e) => CommentClassifyItem.fromJson(asMap(e)))
                .toList()
          : null,
      tag: json['tag'] is List
          ? asList(json['tag'])
                .whereType<Map>()
                .map((e) => CommentTag.fromJson(asMap(e)))
                .toList()
          : null,
      config: json['config'] is Map
          ? CommentConfig.fromJson(asMap(json['config']))
          : null,
      songScore: json['song_score'] is Map
          ? CommentSongScore.fromJson(asMap(json['song_score']))
          : null,
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class SearchHotKeyword {
  const SearchHotKeyword({required this.keyword, this.reason});

  final String keyword;
  final String? reason;

  factory SearchHotKeyword.fromJson(Map<String, dynamic> json) {
    return SearchHotKeyword(
      keyword: asString(json['keyword']) ?? '',
      reason: asString(json['reason']),
    );
  }
}

class SearchHotCategory {
  const SearchHotCategory({required this.name, required this.keywords});

  final String name;
  final List<SearchHotKeyword> keywords;

  factory SearchHotCategory.fromJson(Map<String, dynamic> json) {
    return SearchHotCategory(
      name: asString(json['name']) ?? '',
      keywords: asList(json['keywords'])
          .whereType<Map<String, dynamic>>()
          .map(SearchHotKeyword.fromJson)
          .toList(),
    );
  }
}

class QrCodeInfo {
  const QrCodeInfo({required this.key, required this.imageUrl});

  final String key;
  final String imageUrl;

  factory QrCodeInfo.fromJson(Map<String, dynamic> json) {
    return QrCodeInfo(
      key: asString(json['qrcode']) ?? '',
      imageUrl: asString(json['qrcode_img']) ?? '',
    );
  }
}

class QrCheckResult {
  const QrCheckResult({
    required this.status,
    this.token,
    this.userId,
    this.nickname,
    this.avatar,
  });

  final int status;
  final String? token;
  final String? userId;
  final String? nickname;
  final String? avatar;

  // 酷狗概念版二维码状态码（参考 jsososo/kugou-concept、ImUpXuu/KuGouWebPlayer）：
  //   0 = 已过期        1 = 等待扫码        2 = 已扫码待确认        4 = 登录成功
  bool get isWaitingForScan => status == 1;
  bool get isWaitingForConfirm => status == 2;
  bool get isExpired => status == 0;
  bool get isSuccess => status == 4 && token != null && token!.isNotEmpty;

  factory QrCheckResult.fromJson(Map<String, dynamic> json) {
    return QrCheckResult(
      status: asInt(json['status']) ?? 0,
      token: asString(json['token']),
      userId: asString(json['userid']),
      nickname: asString(json['nickname']),
      avatar: asString(json['pic']),
    );
  }
}

String? asString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? asInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

List<dynamic> asList(Object? value) {
  if (value is List) {
    return value;
  }
  return const [];
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

Duration? durationFromSeconds(Object? value) {
  final seconds = asInt(value);
  return seconds == null ? null : Duration(seconds: seconds);
}

Duration? durationFromMilliseconds(Object? value) {
  final milliseconds = asInt(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

String? normalizeImageUrl(String? url, {int size = 480}) {
  if (url == null) {
    return null;
  }
  return url
      .replaceAll('{size}', '$size')
      .replaceAll('{SIZE}', '$size')
      .replaceAll('/{size}/', '/$size/')
      .replaceAll('/{SIZE}/', '/$size/');
}

String formatDuration(Duration? duration) {
  if (duration == null) {
    return '--:--';
  }
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 云盘容量信息。
class CloudDriveInfo {
  const CloudDriveInfo({
    this.totalCount,
    this.usedBytes,
    this.availableBytes,
    this.maxBytes,
  });

  final int? totalCount;
  final int? usedBytes;
  final int? availableBytes;
  final int? maxBytes;

  double get usageRatio {
    final used = usedBytes ?? 0;
    final max = maxBytes ?? 0;
    if (max <= 0) return 0;
    return (used / max).clamp(0.0, 1.0);
  }

  factory CloudDriveInfo.fromJson(Map<String, dynamic> json) {
    return CloudDriveInfo(
      totalCount: asInt(json['list_count']),
      usedBytes: asInt(json['used_size']),
      availableBytes: asInt(json['availble_size'] ?? json['available_size']),
      maxBytes: asInt(json['max_size']),
    );
  }
}

/// 云盘歌曲分页结果。
class CloudDriveResult {
  const CloudDriveResult({required this.info, required this.songs});

  final CloudDriveInfo info;
  final List<Song> songs;
}

/// 云盘歌曲的额外元数据（文件大小、比特率、扩展名等）。
class CloudDriveSongMeta {
  const CloudDriveSongMeta({
    required this.song,
    this.fileSize,
    this.bitrate,
    this.fileExt,
    this.addedAt,
  });

  final Song song;
  final int? fileSize;
  final int? bitrate;
  final String? fileExt;
  final DateTime? addedAt;

  factory CloudDriveSongMeta.fromJson(Map<String, dynamic> json) {
    final albumInfo = asMap(json['album_info']);
    final authorsRaw = asList(json['authors']).whereType<Map<String, dynamic>>();
    final artists = authorsRaw
        .map(
          (item) => ArtistRef(
            id: asString(item['author_id']) ?? '',
            name: asString(item['author_name']) ?? '',
            avatarUrl: normalizeImageUrl(asString(item['sizable_avatar'])),
          ),
        )
        .where((artist) => artist.name.isNotEmpty)
        .toList();
    final authorName = asString(json['author_name']);
    if (artists.isEmpty && authorName != null && authorName.isNotEmpty) {
      final names = authorName
          .split(RegExp(r'\s*[/、,，&]\s*'))
          .where((name) => name.trim().isNotEmpty);
      for (final name in names) {
        artists.add(ArtistRef(id: '', name: name.trim()));
      }
    }
    final artistName = artists.map((artist) => artist.name).join(' / ');

    // 云盘歌曲的 name 字段通常是上传时的文件名（如 "xxx.mp3"），这里移除后缀。
    final ext = asString(json['ext']);
    final rawName = asString(json['name']) ?? asString(json['audio_name']) ?? '';
    final cleanName = _stripCloudFileExtension(rawName, ext);

    final song = Song(
      id: asString(json['audio_id']) ??
          asString(json['album_audio_id']) ??
          asString(json['hash']) ??
          '',
      title: cleanName.isNotEmpty ? cleanName : '未知歌曲',
      artist: artistName.isNotEmpty ? artistName : authorName ?? '未知艺人',
      hash: asString(json['hash']) ?? asString(json['hash_std']) ?? '',
      albumId: asString(albumInfo['album_id']),
      albumAudioId:
          asString(json['album_audio_id']) ?? asString(json['audio_id']),
      albumName: asString(albumInfo['album_name']),
      coverUrl: normalizeImageUrl(asString(albumInfo['sizable_cover'])),
      artists: artists,
      duration: durationFromMilliseconds(json['timelen']),
      isCloudDrive: true,
    );

    final addTime = asInt(json['add_time']);
    return CloudDriveSongMeta(
      song: song,
      fileSize: asInt(json['size']),
      bitrate: asInt(json['bitrate']),
      fileExt: ext,
      addedAt: addTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(addTime * 1000),
    );
  }
}

/// 移除云盘歌曲文件名的后缀。
///
/// 优先按服务端返回的 `ext` 字段移除；若无则按常见音频后缀兜底。
String _stripCloudFileExtension(String name, String? ext) {
  var result = name.trim();
  if (result.isEmpty) return result;

  // 按服务端返回的 ext 移除（ext 可能带或不带点）
  if (ext != null && ext.isNotEmpty) {
    final normalizedExt = ext.startsWith('.') ? ext : '.$ext';
    if (result.toLowerCase().endsWith(normalizedExt.toLowerCase())) {
      result = result.substring(0, result.length - normalizedExt.length);
    }
  }

  // 兜底：移除常见音频文件后缀
  final match = RegExp(r'\.(mp3|flac|ape|wav|aac|m4a|ogg|wma|opus)$', caseSensitive: false)
      .firstMatch(result);
  if (match != null) {
    result = result.substring(0, match.start);
  }

  return result.trim();
}

/// 网易云音乐搜索结果项。
class NetEaseSong {
  const NetEaseSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.duration,
  });

  final int id;
  final String name;
  final List<NetEaseArtist> artists;
  final NetEaseAlbum album;
  final Duration duration;

  /// 转换为 [Song]，标记来源为网易云。
  Song toSong() {
    final artistName = artists.map((a) => a.name).join(' / ');
    return Song(
      id: '$id',
      title: name,
      artist: artistName.isNotEmpty ? artistName : '未知艺人',
      hash: 'ne_$id',
      albumId: '${album.id}',
      albumAudioId: '$id',
      albumName: album.name,
      coverUrl: album.picUrl,
      duration: duration,
      artists: artists
          .map((a) => ArtistRef(id: '${a.id}', name: a.name))
          .where((a) => a.name.isNotEmpty)
          .toList(),
      source: SongSource.netease,
    );
  }

  factory NetEaseSong.fromJson(Map<String, dynamic> json) {
    return NetEaseSong(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '未知歌曲',
      artists: asList(json['ar'])
          .whereType<Map>()
          .map((item) => NetEaseArtist.fromJson(asMap(item)))
          .where((a) => a.name.isNotEmpty)
          .toList(),
      album: NetEaseAlbum.fromJson(asMap(json['al'])),
      duration: durationFromMilliseconds(json['dt']) ?? Duration.zero,
    );
  }
}

class NetEaseArtist {
  const NetEaseArtist({required this.id, required this.name});

  final int id;
  final String name;

  factory NetEaseArtist.fromJson(Map<String, dynamic> json) {
    return NetEaseArtist(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '',
    );
  }
}

class NetEaseAlbum {
  const NetEaseAlbum({required this.id, required this.name, this.picUrl});

  final int id;
  final String name;
  final String? picUrl;

  factory NetEaseAlbum.fromJson(Map<String, dynamic> json) {
    return NetEaseAlbum(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '未知专辑',
      picUrl: asString(json['picUrl']),
    );
  }
}
