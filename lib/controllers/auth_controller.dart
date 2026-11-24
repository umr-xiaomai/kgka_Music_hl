import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../models/music_models.dart';
import '../services/cache_service.dart';
import '../services/music_api.dart';
import '../services/vip_background_task.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._api, this._cacheService) {
    _vipBackgroundTask.onClaimSuccess = () {
      refreshVipInfo();
    };
  }

  static const _tokenKey = 'ka_music_token';
  static const _t1Key = 'ka_music_t1';
  static const _sessionIdKey = 'ka_music_session_id';
  static const _userIdKey = 'ka_music_user_id';
  static const _playlistCachePrefix = 'ka_music_cached_playlists';
  static const _playlistEmptyCountPrefix = 'ka_music_playlist_empty_count';
  static const _likedHashesKey = 'ka_music_liked_hashes';
  final MusicApi _api;
  final CacheService _cacheService;
  late final VipBackgroundTask _vipBackgroundTask = VipBackgroundTask(_api);

  VipBackgroundTask get vipClaim => _vipBackgroundTask;

  bool isRestoring = true;
  bool isLoading = false;
  String? errorMessage;
  LoginSession? session;
  UserProfile? profile;
  UserVipInfo? vipInfo;
  List<PlaylistSummary> playlists = const [];

  final Set<String> _likedHashes = {};
  final Map<String, bool> _pendingLikes = {};
  final Map<String, Song> _likedPlaylistTracks = {};
  int _likeSessionGeneration = 0;
  int _likedStateRevision = 0;

  bool get isLoggedIn => session?.isValid == true;

  String _likedHash(Song song) => song.hash.trim().toLowerCase();

  bool isLiked(Song song) {
    if (song.source != SongSource.kugou) return false;
    final hash = _likedHash(song);
    return _pendingLikes[hash] ?? _likedHashes.contains(hash);
  }

  bool isLikePending(Song song) =>
      song.source == SongSource.kugou &&
      _pendingLikes.containsKey(_likedHash(song));

  int get likedCount {
    final playlist = likedPlaylist;
    if (playlist != null && playlist.songCount != null) {
      return playlist.songCount!;
    }
    return _likedHashes.length;
  }

  Future<void> toggleLike(Song song) async {
    final playlist = likedPlaylist;
    final hash = _likedHash(song);
    if (!isLoggedIn ||
        playlist == null ||
        song.source != SongSource.kugou ||
        hash.isEmpty ||
        _pendingLikes.containsKey(hash)) {
      return;
    }

    await _setLiked(playlist, song, liked: !_likedHashes.contains(hash));
  }

  Future<void> _setLiked(
    PlaylistSummary playlist,
    Song song, {
    required bool liked,
    Song? playlistTrack,
  }) async {
    final targetListId = _playlistListId(playlist);
    final currentPlaylist = likedPlaylist;
    if (!isLoggedIn ||
        targetListId == null ||
        currentPlaylist == null ||
        _playlistListId(currentPlaylist) != targetListId) {
      throw StateError('收藏列表已更改，请刷新后重试');
    }
    final hash = _likedHash(song);
    if (_pendingLikes.containsKey(hash)) {
      throw StateError('这首歌的收藏状态正在更新，请稍后重试');
    }
    final generation = _likeSessionGeneration;
    _pendingLikes[hash] = liked;
    notifyListeners();
    try {
      if (generation != _likeSessionGeneration) return;
      if (!liked) {
        // 删除接口需要收藏歌单内的 fileid，播放器里的 song.id 可能是 mixsongid。
        final playlistSong =
            playlistTrack ??
            _likedPlaylistTracks[hash] ??
            await _resolveLikedSongForRemoval(playlist, targetListId, hash);
        if (generation != _likeSessionGeneration) return;
        await _api.removeFromPlaylist(targetListId, playlistSong);
      } else {
        await _api.addToPlaylist(targetListId, song);
      }
      if (generation != _likeSessionGeneration) return;

      _likedStateRevision++;
      if (liked) {
        if (hash.isNotEmpty) _likedHashes.add(hash);
      } else {
        _likedHashes.remove(hash);
        _likedPlaylistTracks.remove(hash);
      }
      try {
        await Future.wait([
          _invalidatePlaylistDetailCache(playlist),
          _persistLikedHashes(generation),
        ]);
      } catch (error) {
        // 服务端已经更新成功，本地缓存失败时保留正确的收藏状态。
        debugPrint('收藏缓存写入失败：$error');
      }
    } catch (_) {
      if (generation == _likeSessionGeneration) {
        if (!liked) _likedPlaylistTracks.remove(hash);
        rethrow;
      }
    } finally {
      if (generation == _likeSessionGeneration) {
        _pendingLikes.remove(hash);
        notifyListeners();
      }
    }
  }

  Future<Song> _resolveLikedSongForRemoval(
    PlaylistSummary playlist,
    String targetListId,
    String hash,
  ) async {
    final ids = <String>{playlist.id, targetListId}
      ..removeWhere((id) => id.isEmpty);

    for (final id in ids) {
      try {
        final songs = await _api.playlistSongs(id, fetchAll: true);
        for (final song in songs) {
          if (_likedHash(song) == hash && _hasPlaylistFileId(song)) {
            return song;
          }
        }
      } catch (_) {
        // 尝试另一个 playlist id；全部失败后再向上抛出明确错误。
      }
    }

    throw StateError('未找到收藏歌单中的歌曲，请刷新收藏列表后重试');
  }

  bool _hasPlaylistFileId(Song song) =>
      song.id.isNotEmpty && song.id.toLowerCase() != _likedHash(song);

  Future<void> _invalidatePlaylistDetailCache(PlaylistSummary playlist) async {
    final ids = <String>{playlist.id, playlist.listId ?? ''}
      ..removeWhere((id) => id.isEmpty);
    for (final id in ids) {
      await _cacheService.remove('cache_playlist_$id');
      await _cacheService.remove('cache_playlist_${id}_full');
    }
  }

  PlaylistSummary? get likedPlaylist {
    for (final playlist in playlists) {
      if (playlist.isLikedPlaylist) {
        return playlist;
      }
    }
    return null;
  }

  List<PlaylistSummary> get createdPlaylists {
    return playlists
        .where(
          (playlist) =>
              !playlist.isCollectedAlbum && playlist.isCreatedPlaylist,
        )
        .toList();
  }

  List<PlaylistSummary> get collectedPlaylists {
    return playlists
        .where(
          (playlist) =>
              !playlist.isLikedPlaylist &&
              !playlist.isCollectedAlbum &&
              !playlist.isCreatedPlaylist,
        )
        .toList();
  }

  List<PlaylistSummary> get collectedAlbums {
    return playlists.where((playlist) => playlist.isCollectedAlbum).toList();
  }

  PlaylistSummary? findUserPlaylist(PlaylistSummary playlist) {
    for (final item in playlists) {
      if (item.id == playlist.id ||
          (playlist.listId != null && item.listId == playlist.listId) ||
          (item.sourceGlobalId != null && item.sourceGlobalId == playlist.id) ||
          (playlist.sourceGlobalId != null &&
              item.sourceGlobalId == playlist.sourceGlobalId)) {
        return item;
      }
    }
    return null;
  }

  bool isPlaylistInLibrary(PlaylistSummary playlist) {
    return findUserPlaylist(playlist) != null;
  }

  bool canEditPlaylist(PlaylistSummary playlist) {
    final item = findUserPlaylist(playlist) ?? playlist;
    return item.isCreatedPlaylist;
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _run(() async {
      await _api.createPlaylist(trimmed, private: private);
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> collectPlaylist(PlaylistSummary playlist) async {
    await _run(() async {
      await _api.collectPlaylist(
        name: playlist.title,
        globalCollectionId: playlist.id,
      );
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> refreshImportedPlaylist(PlaylistSummary playlist) async {
    await _invalidatePlaylistDetailCache(playlist);
    await refreshProfile(silent: true);
  }

  Future<void> deleteOrUncollectPlaylist(PlaylistSummary playlist) async {
    final target = findUserPlaylist(playlist) ?? playlist;
    final listId = _playlistListId(target);
    if (listId == null) return;
    await _run(() async {
      await _api.deletePlaylist(listId);
      playlists = await _loadUserPlaylistsWithCache();
      await _syncLikedSongs();
    });
  }

  Future<void> addSongToPlaylist(PlaylistSummary playlist, Song song) async {
    final listId = _playlistListId(playlist);
    if (listId == null) return;
    final generation = _likeSessionGeneration;
    await _run(() async {
      if (playlist.isLikedPlaylist) {
        await _setLiked(playlist, song, liked: true);
      } else {
        await _api.addToPlaylist(listId, song);
        await _invalidatePlaylistDetailCache(playlist);
      }
      await _refreshPlaylistSummaries(generation);
    });
  }

  Future<void> removeSongFromPlaylist(
    PlaylistSummary playlist,
    Song song,
  ) async {
    final target = findUserPlaylist(playlist) ?? playlist;
    final listId = _playlistListId(target);
    if (listId == null) return;
    final generation = _likeSessionGeneration;
    await _run(() async {
      if (target.isLikedPlaylist) {
        await _setLiked(target, song, liked: false, playlistTrack: song);
      } else {
        await _api.removeFromPlaylist(listId, song);
        await _invalidatePlaylistDetailCache(target);
      }
      await _refreshPlaylistSummaries(generation);
    });
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedUserId = prefs.getString(_userIdKey);
      final restored = LoginSession(
        userId: storedUserId,
        token: prefs.getString(_tokenKey),
        t1: prefs.getString(_t1Key),
        sessionId: prefs.getString(_sessionIdKey),
      );

      if (!restored.isValid) {
        return;
      }

      session = restored;
      _api.setSession(restored);

      try {
        final refreshed = await _api.refreshToken(current: restored);
        if (_hasMismatchedUserId(storedUserId, refreshed.userId)) {
          await _clearSession();
          return;
        }
        session = refreshed;
        _api.setSession(refreshed);
        await prefs.setString(_tokenKey, refreshed.token ?? '');
        await prefs.setString(_t1Key, refreshed.t1 ?? '');
        if (refreshed.userId != null &&
            refreshed.userId!.isNotEmpty &&
            refreshed.userId != '0') {
          await prefs.setString(_userIdKey, refreshed.userId!);
        }
      } catch (_) {
        // /login/token failed, continue with stored token
      }

      playlists = await _loadCachedPlaylists();
      await _loadLikedHashes();
      // 先读缓存的用户信息，静默刷新由 refreshProfile 完成
      final cachedProfile = await _cacheService.read<UserProfile>(
        _userCacheKey,
        decode: UserProfile.fromCache,
        ttl: AppConfig.userProfileTtl,
      );
      if (cachedProfile != null) {
        profile = cachedProfile.data;
      }
      final cachedVip = await _cacheService.read<UserVipInfo>(
        _vipCacheKey,
        decode: UserVipInfo.fromJson,
        ttl: AppConfig.userProfileTtl,
      );
      if (cachedVip != null) {
        vipInfo = cachedVip.data;
      }
      // 缓存数据已就绪，立即通知 UI 显示，API 刷新在后台进行
      isRestoring = false;
      notifyListeners();
      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isRestoring = false;
      notifyListeners();
    }
  }

  String? _playlistListId(PlaylistSummary playlist) {
    if (playlist.listId?.isNotEmpty == true) {
      return playlist.listId;
    }
    if (playlist.id.isNotEmpty) {
      return playlist.id;
    }
    return null;
  }

  bool _hasMismatchedUserId(String? storedUserId, String? refreshedUserId) {
    final stored = storedUserId?.trim() ?? '';
    final refreshed = refreshedUserId?.trim() ?? '';
    if (stored.isEmpty ||
        stored == '0' ||
        refreshed.isEmpty ||
        refreshed == '0') {
      return false;
    }
    return stored != refreshed;
  }

  Future<void> refreshSession() async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    final storedUserId = prefs.getString(_userIdKey);
    try {
      final refreshed = await _api.refreshToken(current: session);
      if (_hasMismatchedUserId(storedUserId, refreshed.userId)) {
        await _clearSession();
        return;
      }
      session = refreshed;
      _api.setSession(refreshed);
      await prefs.setString(_tokenKey, refreshed.token ?? '');
      await prefs.setString(_t1Key, refreshed.t1 ?? '');
      if (refreshed.userId != null &&
          refreshed.userId!.isNotEmpty &&
          refreshed.userId != '0') {
        await prefs.setString(_userIdKey, refreshed.userId!);
      }
    } catch (_) {
      // Refresh failed, continue with existing session
    }
  }

  Future<void> sendCode(String mobile) async {
    await _run(() => _api.sendLoginCode(mobile));
  }

  Future<void> loginWithSession(LoginSession session) async {
    await _run(() async {
      _setLoginSession(session);

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_likedHashesKey);
      await prefs.setString(_tokenKey, session.token ?? '');
      await prefs.setString(_t1Key, session.t1 ?? '');
      // session.sessionId 可能为 null（扫码登录），但 ApiClient 内部
      // 已从登录响应 header 保存了后端的 session key，这里也持久化一份。
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, session.userId ?? '');

      // 扫码登录返回的 QrLoginStatusResponse 只有 token，缺少 t1。
      // 后续 /user/detail 等接口需要 t1 header 鉴权，否则会失败导致
      // profile/歌单拉取不到。这里先调 /login/token 刷新拿到 t1。
      if (session.t1 == null || session.t1!.isEmpty) {
        try {
          final refreshed = await _api.refreshToken(current: session);
          if (refreshed.token != null && refreshed.token!.isNotEmpty) {
            // 合并：保留扫码返回的 nickname/avatar，用刷新结果的 token/t1
            session = LoginSession(
              userId: refreshed.userId ?? session.userId,
              token: refreshed.token,
              t1: refreshed.t1,
              sessionId: _api.clientSessionId,
              nickname: session.nickname,
              avatarUrl: session.avatarUrl,
            );
            this.session = session;
            _api.setSession(session);
            await prefs.setString(_tokenKey, session.token ?? '');
            await prefs.setString(_t1Key, session.t1 ?? '');
            await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
            await prefs.setString(_userIdKey, session.userId ?? '');
          }
        } catch (_) {
          // 刷新失败，继续用原 token
        }
      }

      // 用 session 数据构造临时 profile，UI 立即展示用户信息；
      // refreshProfile 成功后会覆盖为完整数据。
      if (session.nickname != null && session.nickname!.isNotEmpty) {
        profile = UserProfile(
          nickname: session.nickname!,
          avatarUrl: session.avatarUrl,
        );
      }

      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
  }

  Future<PhoneLoginResult?> login(
    String mobile,
    String code, {
    String? userId,
  }) async {
    PhoneLoginResult? result;
    await _run(() async {
      _api.setSession(null);
      result = await _api.loginWithPhone(
        mobile: mobile,
        code: code,
        userId: userId,
      );
      if (result?.requiresUserSelection == true) {
        return;
      }
      final nextSession = result!.session!;
      _setLoginSession(nextSession);

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_likedHashesKey);
      await prefs.setString(_tokenKey, nextSession.token ?? '');
      await prefs.setString(_t1Key, nextSession.t1 ?? '');
      // nextSession.sessionId 可能为 null，用 ApiClient 实际持有的 session key
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, nextSession.userId ?? '');

      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
    return result;
  }

  void _setLoginSession(LoginSession nextSession) {
    playlists = const [];
    _clearLikedSongs();
    session = nextSession;
    _api.setSession(nextSession);
    notifyListeners();
  }

  Future<void> refreshVipInfo() async {
    if (!isLoggedIn) return;
    final generation = _likeSessionGeneration;
    try {
      final latestVip = await _api.vipDetail();
      if (generation != _likeSessionGeneration) return;
      vipInfo = latestVip;
      if (latestVip.userId != null &&
          latestVip.userId!.isNotEmpty &&
          latestVip.userId != '0' &&
          (session?.userId == null ||
              session!.userId!.isEmpty ||
              session!.userId == '0')) {
        session = LoginSession(
          userId: latestVip.userId,
          token: session?.token,
          t1: session?.t1,
          sessionId: session?.sessionId ?? _api.clientSessionId,
          nickname: session?.nickname,
          avatarUrl: session?.avatarUrl,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_userIdKey, latestVip.userId!);
      }
      await _cacheService.write(_vipCacheKey, latestVip.toCache());
      notifyListeners();
    } catch (_) {
      // 静默忽略 VIP 查询异常，不影响主资料加载
    }
  }

  Future<void> refreshProfile({bool silent = false}) async {
    final generation = _likeSessionGeneration;
    await _run(() async {
      final latestProfile = await _api.userDetail();
      if (generation != _likeSessionGeneration) return;
      profile = latestProfile;
      await _cacheService.write(_userCacheKey, latestProfile.toCache());
      if (generation != _likeSessionGeneration) return;
      await refreshVipInfo();
      await _refreshPlaylistSummaries(generation);
      if (generation != _likeSessionGeneration) return;
      await _syncLikedSongs();
    }, silent: silent);
  }

  Future<void> _refreshPlaylistSummaries(int generation) async {
    if (generation != _likeSessionGeneration) return;
    final fetched = await _loadUserPlaylistsWithCache();
    if (generation == _likeSessionGeneration) playlists = fetched;
  }

  Future<void> logout() async {
    await _run(() async {
      try {
        await _api.logout();
      } finally {
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = _playlistCacheKey;
        final emptyCountKey = _playlistEmptyCountKey;
        session = null;
        profile = null;
        playlists = const [];
        _clearLikedSongs();
        _api.setSession(null);
        await prefs.remove(_tokenKey);
        await prefs.remove(_t1Key);
        await prefs.remove(_sessionIdKey);
        await prefs.remove(_userIdKey);
        await prefs.remove(cacheKey);
        await prefs.remove(emptyCountKey);
        await prefs.remove(_likedHashesKey);
        await _clearSession();
      }
    });
  }

  Future<void> _syncLikedSongs() async {
    final playlist = likedPlaylist;
    if (playlist == null) return;
    final revision = _likedStateRevision;
    final generation = _likeSessionGeneration;

    try {
      final songs = await _api.playlistSongs(playlist.id, fetchAll: true);
      // 较早开始的刷新不能覆盖之后已确认的操作或切换账号后的状态。
      if (revision != _likedStateRevision ||
          playlist.id != likedPlaylist?.id ||
          playlist.listId != likedPlaylist?.listId) {
        return;
      }
      _likedHashes.clear();
      _likedPlaylistTracks.clear();
      for (final song in songs) {
        final hash = _likedHash(song);
        if (hash.isEmpty) continue;
        _likedHashes.add(hash);
        if (_hasPlaylistFileId(song)) _likedPlaylistTracks[hash] = song;
      }
      await _persistLikedHashes(generation);
    } catch (_) {
      // 已恢复的缓存或当前内存中的收藏状态仍可用。
    }
  }

  void _clearLikedSongs() {
    _likeSessionGeneration++;
    _likedStateRevision++;
    _likedHashes.clear();
    _likedPlaylistTracks.clear();
    _pendingLikes.clear();
  }

  Future<void> _persistLikedHashes(int generation) async {
    final prefs = await SharedPreferences.getInstance();
    if (generation != _likeSessionGeneration) return;
    await prefs.setString(_likedHashesKey, jsonEncode(_likedHashes.toList()));
  }

  Future<void> _loadLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_likedHashesKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        _likedHashes.addAll(
          list
              .whereType<String>()
              .map((hash) => hash.trim().toLowerCase())
              .where((hash) => hash.isNotEmpty),
        );
      }
    } catch (_) {}
  }

  Future<List<PlaylistSummary>> _loadUserPlaylistsWithCache() async {
    final generation = _likeSessionGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (generation != _likeSessionGeneration) return const [];
    final fetched = await _api.userPlaylists(pageSize: 100);
    if (generation != _likeSessionGeneration) return const [];

    if (fetched.isNotEmpty) {
      await prefs.setInt(_playlistEmptyCountKey, 0);
      if (generation != _likeSessionGeneration) return const [];
      await _saveCachedPlaylists(fetched);
      return fetched;
    }

    final emptyCount = (prefs.getInt(_playlistEmptyCountKey) ?? 0) + 1;
    await prefs.setInt(_playlistEmptyCountKey, emptyCount);
    if (generation != _likeSessionGeneration) return const [];

    final cached = await _loadCachedPlaylists();
    if (generation != _likeSessionGeneration) return const [];
    if (cached.isNotEmpty && emptyCount < 2) {
      return cached;
    }

    // 清理旧 key 与 CacheService 索引
    final cacheKey = _playlistCacheKeyV2;
    await prefs.remove(_playlistCacheKey);
    await _cacheService.remove(cacheKey);
    return const [];
  }

  Future<List<PlaylistSummary>> _loadCachedPlaylists() async {
    // 优先读 CacheService（统一管理），回退旧 key（兼容旧版本）
    final cached = await _cacheService.read<List<PlaylistSummary>>(
      _playlistCacheKeyV2,
      decode: (json) => (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistSummary.fromCache)
          .where((playlist) => playlist.id.isNotEmpty)
          .toList(),
      ttl: AppConfig.userProfileTtl,
    );
    if (cached != null) {
      return cached.data;
    }
    // 回退旧 key
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playlistCacheKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final json = jsonDecode(raw);
      if (json is! List) {
        return const [];
      }
      return json
          .whereType<Map>()
          .map((item) => PlaylistSummary.fromCache(asMap(item)))
          .where((playlist) => playlist.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveCachedPlaylists(List<PlaylistSummary> playlists) async {
    // 双写：CacheService（统一管理）+ 旧 key（兼容）
    final legacyKey = _playlistCacheKey;
    await _cacheService.write(_playlistCacheKeyV2, {
      'playlists': playlists.map((p) => p.toCache()).toList(),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      legacyKey,
      jsonEncode(playlists.map((playlist) => playlist.toCache()).toList()),
    );
  }

  String get _playlistCacheKey {
    return '${_playlistCachePrefix}_${session?.userId ?? 'default'}';
  }

  String get _playlistEmptyCountKey {
    return '${_playlistEmptyCountPrefix}_${session?.userId ?? 'default'}';
  }

  String get _userCacheKey => 'cache_user_${session?.userId ?? 'default'}';

  String get _vipCacheKey => 'cache_vip_${session?.userId ?? 'default'}';

  String get _playlistCacheKeyV2 =>
      'cache_user_playlists_${session?.userId ?? 'default'}';

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    session = null;
    profile = null;
    vipInfo = null;
    playlists = const [];
    _clearLikedSongs();
    _api.setSession(null);
    await prefs.remove(_tokenKey);
    await prefs.remove(_t1Key);
    await prefs.remove(_userIdKey);
    await prefs.remove(_playlistCacheKey);
    await prefs.remove(_playlistEmptyCountKey);
    await prefs.remove(_likedHashesKey);
    await _cacheService.clearUserCache(null);
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool silent = false,
  }) async {
    if (!silent) {
      isLoading = true;
      errorMessage = null;
      notifyListeners();
    }

    try {
      await action();
      errorMessage = null;
    } catch (error) {
      errorMessage = _errorText(error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String _errorText(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toString();
  }

  @override
  void dispose() {
    _clearLikedSongs();
    super.dispose();
  }
}
