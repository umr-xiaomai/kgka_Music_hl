import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/app_section.dart';
import '../widgets/app_feedback.dart';
import '../design_tokens.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../core/pinyin_utils.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/import_playlist_sheet.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../widgets/marquee_text.dart';
import '../adaptive_layout.dart';
import 'artist_detail_page.dart';

/// 缓存中完整歌单歌曲列表的 key 后缀。
const _fullSongsCacheSuffix = '_full';



class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.playlist,
    this.initialSongs,
    this.readOnly = false,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final PlaylistSummary playlist;
  final List<Song>? initialSongs;
  final bool readOnly;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  static const _pageSize = 50;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _songs = <Song>[];
  final _cache = CacheService();

  PlaylistSummary? _info;
  var _nextPage = 1;
  var _hasMore = true;
  var _isInitialLoading = true;
  var _isLoadingMore = false;
  String? _errorMessage;
  String? _loadMoreError;
  List<PlaylistSummary> _similarPlaylists = const [];
  bool _isMutating = false;
  bool _isSearching = false;
  bool _isLoadingAllSongs = false;
  bool _allSongsLoaded = false;
  String _searchQuery = '';
  _SongSortMode _sortMode = _SongSortMode.defaultOrder;

  /// 多选模式（用于批量下载）。
  bool _selectionMode = false;
  final Set<String> _selectedHashes = {};
  bool _batchDownloading = false;

  /// 自动定位当前播放歌曲相关状态。
  bool _autoLocateDone = false;
  bool _isLocating = false;
  int? _locateTargetIndex;
  final GlobalKey _locateRowKey = GlobalKey();

  int get _selectedCount => _selectedHashes.length;

  String get _sortModeLabel {
    return switch (_sortMode) {
      _SongSortMode.defaultOrder => '默认排序',
      _SongSortMode.byTitle => '按歌名',
      _SongSortMode.byArtist => '按歌手',
      _SongSortMode.byAlbum => '按专辑',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_SongSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_SongSortMode.defaultOrder, '默认排序'),
          (_SongSortMode.byTitle, '按歌名'),
          (_SongSortMode.byArtist, '按歌手'),
          (_SongSortMode.byAlbum, '按专辑'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '排序方式',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _SortOptionTile(
                          label: options[i].$2,
                          selected: _sortMode == options[i].$1,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(options[i].$1),
                        ),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 16,
                            color: colorScheme.outlineVariant
                                .withValues(alpha: .3),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && selected != _sortMode) {
      setState(() => _sortMode = selected);
    }
  }

  bool get _isStaticCollection => widget.initialSongs != null;

  bool get _isAlbum =>
      !_isStaticCollection && widget.playlist.isCollectedAlbum;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<Song> get _filteredSongs {
    List<Song> list;
    if (_searchQuery.isEmpty) {
      list = List<Song>.of(_songs);
    } else {
      final q = _searchQuery.toLowerCase();
      list = _songs.where((song) {
        return song.title.toLowerCase().contains(q) ||
            song.artist.toLowerCase().contains(q) ||
            (song.albumName?.toLowerCase().contains(q) ?? false);
      }).toList();
    }

    switch (_sortMode) {
      case _SongSortMode.byTitle:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        break;
      case _SongSortMode.byArtist:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.artist, b.artist));
        break;
      case _SongSortMode.byAlbum:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.albumName ?? '', b.albumName ?? ''));
        break;
      case _SongSortMode.defaultOrder:
        break;
    }
    return list;
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
    if (_isSearching && !_allSongsLoaded) {
      _loadAllSongs();
    }
  }

  Future<void>? _allSongsFuture;

  /// 加载完整歌单（已加载/正在加载时复用同一个 Future）。
  Future<void> _loadAllSongs() {
    if (_isStaticCollection || _allSongsLoaded) return Future.value();
    return _allSongsFuture ??= _fetchAllSongs();
  }

  Future<void> _fetchAllSongs() async {
    setState(() => _isLoadingAllSongs = true);
    try {
      final id = _isAlbum
          ? (widget.playlist.albumId ?? widget.playlist.id)
          : widget.playlist.id;

      // 优先尝试从完整歌单缓存读取（命中则跳过网络请求）
      final fullCacheKey = _isAlbum
          ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}$_fullSongsCacheSuffix'
          : 'cache_playlist_${widget.playlist.id}$_fullSongsCacheSuffix';

      CacheResult<Map<String, dynamic>>? fullCached;
      try {
        fullCached = await _cache.read<Map<String, dynamic>>(
          fullCacheKey,
          decode: (json) => json,
          ttl: AppConfig.playlistDetailTtl,
        );
      } catch (_) {}

      List<Song> allSongs;
      if (fullCached != null) {
        allSongs = (fullCached.data['songs'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Song.fromCache)
            .where((song) => song.hash.isNotEmpty)
            .toList();
      } else {
        allSongs = _isAlbum
            ? await widget.api.albumSongs(id, page: 1, pageSize: 5000)
            : await widget.api.playlistSongs(id, fetchAll: true);
        // 写入完整歌单缓存，后续播放可直接复用
        await _cache.write(fullCacheKey, {
          'songs': allSongs.map((s) => s.toCache()).toList(),
        });
      }

      if (!mounted) return;
      setState(() {
        // 增量追加：保留已有歌曲，仅追加尚未加载的歌曲，
        // 避免先清空再重建列表导致滚动位置被强制重置。
        final existingHashes = _songs.map((s) => s.hash).toSet();
        for (final song in allSongs) {
          if (song.hash.isNotEmpty && !existingHashes.contains(song.hash)) {
            _songs.add(song);
            existingHashes.add(song.hash);
          }
        }
        _allSongsLoaded = true;
        _hasMore = false;
        _isLoadingAllSongs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingAllSongs = false);
    } finally {
      _allSongsFuture = null;
    }
  }

  /// 多选模式下，确保完整歌单已加载（全选/反选需针对整个歌单）。
  Future<void> _ensureAllSongsForSelection() async {
    if (_allSongsLoaded || !_hasMore) return;
    Toast.info('正在加载完整歌单…');
    await _loadAllSongs();
    if (!mounted) return;
    if (!_allSongsLoaded) {
      Toast.error('完整歌单加载失败，仅对已加载的歌曲生效');
    }
  }

  void _enterSelectionMode() {
    if (_filteredSongs.isEmpty) {
      Toast.info('歌单还没有歌曲');
      return;
    }
    setState(() {
      _selectionMode = true;
      _selectedHashes.clear();
      _batchDownloading = false;
    });
  }

  void _exitSelectionMode() {
    if (!_selectionMode) return;
    setState(() {
      _selectionMode = false;
      _selectedHashes.clear();
    });
  }

  void _toggleSongSelection(Song song) {
    setState(() {
      if (!_selectedHashes.add(song.hash)) {
        _selectedHashes.remove(song.hash);
      }
    });
  }

  bool get _isAllSelected =>
      _songs.isNotEmpty && _songs.every((s) => _selectedHashes.contains(s.hash));

  /// 全选 / 取消全选（针对完整歌单）。
  Future<void> _toggleSelectAll() async {
    await _ensureAllSongsForSelection();
    if (!mounted) return;
    setState(() {
      if (_isAllSelected) {
        _selectedHashes.clear();
      } else {
        _selectedHashes.addAll(_songs.map((s) => s.hash));
      }
    });
  }

  /// 反选（针对完整歌单）。
  Future<void> _toggleInvertSelection() async {
    await _ensureAllSongsForSelection();
    if (!mounted) return;
    setState(() {
      for (final song in _songs) {
        if (!_selectedHashes.add(song.hash)) {
          _selectedHashes.remove(song.hash);
        }
      }
    });
  }

  /// 把选中的歌曲批量加入下载队列。
  Future<void> _downloadSelected() async {
    final downloads = widget.player.downloadController;
    if (downloads == null) {
      Toast.error('下载功能不可用');
      return;
    }
    if (_batchDownloading) return;
    final selected =
        _songs.where((s) => _selectedHashes.contains(s.hash)).toList();
    if (selected.isEmpty) {
      Toast.info('请先选择歌曲');
      return;
    }

    setState(() => _batchDownloading = true);
    try {
      final result =
          await downloads.enqueueBatch(selected, widget.player.audioQuality);
      final parts = <String>['已加入下载队列 ${result.enqueued} 首'];
      if (result.skipped > 0) {
        parts.add('已跳过 ${result.skipped} 首（已下载/下载中）');
      }
      if (result.failed > 0) {
        parts.add('失败 ${result.failed} 首');
      }
      Toast.success(parts.join('，'));
    } catch (_) {
      Toast.error('加入下载队列失败');
    } finally {
      if (mounted) {
        setState(() => _batchDownloading = false);
      }
    }
    if (mounted) {
      _exitSelectionMode();
    }
  }

  /// 确保播放队列包含完整歌单内容。
  ///
  /// 当歌单因分页仅加载前 N 首时，对比播放队列与歌单总歌曲数量。
  /// 若不一致则自动获取完整歌单数据（优先读缓存），保障播放队列完整。
  /// 搜索模式下仅返回过滤后的结果。
  Future<List<Song>> _ensureFullQueueForPlayback() async {
    // 搜索模式下仅播放搜索结果
    if (_searchQuery.isNotEmpty) {
      return _filteredSongs;
    }
    // 已加载全部或总数未知，直接返回当前列表
    final totalCount = _currentPlaylist.songCount;
    if (_allSongsLoaded || totalCount == null || _songs.length >= totalCount) {
      return _filteredSongs;
    }
    // 队列数量与歌单总数不一致，需要加载完整歌单
    Toast.info('正在加载完整歌单…');
    await _loadAllSongs();
    return _filteredSongs;
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _errorMessage = null;
      _loadMoreError = null;
      _nextPage = 1;
      _hasMore = true;
      _info = null;
      _songs.clear();
    });

    if (_isStaticCollection) {
      final songs = List<Song>.of(widget.initialSongs!);
      if (!mounted) return;
      setState(() {
        _info = widget.playlist;
        _songs
          ..clear()
          ..addAll(songs);
        _isInitialLoading = false;
        _allSongsLoaded = true;
        _hasMore = false;
      });
      if (widget.player.currentSong != null) {
        unawaited(_autoLocateCurrentSong());
      }
      return;
    }

    final cacheKey = _isAlbum
        ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}'
        : 'cache_playlist_${widget.playlist.id}';

    // 先读缓存，命中则立即显示
    CacheResult<Map<String, dynamic>>? cached;
    try {
      cached = await _cache.read<Map<String, dynamic>>(
        cacheKey,
        decode: (json) => json,
        ttl: AppConfig.playlistDetailTtl,
      );
    } catch (_) {}
    if (cached != null && mounted) {
      final cacheData = cached.data;
      final infoJson = cacheData['info'];
      setState(() {
        if (infoJson is Map<String, dynamic>) {
          _info = PlaylistSummary.fromCache(infoJson);
        }
        _songs.clear();
        _songs.addAll((cacheData['songs'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Song.fromCache)
            .toList());
        _isInitialLoading = false;
      });
      if (widget.player.currentSong != null) {
        unawaited(_autoLocateCurrentSong());
      }
    }

    try {
      if (_isAlbum) {
        final songPage = await widget.api.albumSongPage(
          widget.playlist.albumId ?? widget.playlist.id,
          page: 1,
          pageSize: _pageSize,
        );
        if (!mounted) return;

        setState(() {
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed = _songs.length != songs.length ||
              !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (widget.playlist.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'songs': songPage.songs.map((s) => s.toCache()).toList(),
        });
      } else {
        final results = await Future.wait([
          widget.api.playlistInfo(widget.playlist.id),
          widget.api.playlistSongPage(
            widget.playlist.id,
            page: 1,
            pageSize: _pageSize,
          ),
        ]);
        if (!mounted) return;

        final info = results[0] as PlaylistSummary;
        final songPage = results[1] as SongPage;
        final songs = songPage.songs;
        setState(() {
          _info = info;
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed = _songs.length != songs.length ||
              !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (info.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'info': info.toCache(),
          'songs': songs.map((s) => s.toCache()).toList(),
        });
      }
    } catch (error) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _errorMessage = error.toString();
          _isInitialLoading = false;
        });
        return;
      }
      // 有缓存数据，保持不报错（降级），继续走自动定位。
    }
    unawaited(_loadSimilarPlaylists());
    if (widget.player.currentSong != null) {
      unawaited(_autoLocateCurrentSong());
    }
  }

  /// 加载相似歌单（增强展示，失败静默忽略）。
  Future<void> _loadSimilarPlaylists() async {
    if (_isStaticCollection) return;
    try {
      final similar = await widget.api.similarPlaylists(widget.playlist.id);
      if (!mounted || similar.isEmpty) return;
      setState(() => _similarPlaylists = similar);
    } catch (_) {}
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) {
      return;
    }

    final position = _scrollController.position;
    if (position.extentAfter < 520) {
      _loadMore();
    }
  }

  /// 比较两份歌曲列表是否内容一致（按 hash 逐项比较）。
  bool _listEquals(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].hash != b[i].hash) return false;
    }
    return true;
  }

  Future<void>? _loadMoreFuture;

  /// 加载下一页（进行中的请求复用同一个 Future）。
  Future<void> _loadMore() {
    if (!_hasMore) return Future.value();
    return _loadMoreFuture ??= _fetchMore();
  }

  Future<void> _fetchMore() async {
    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    try {
      final songPage = _isAlbum
          ? await widget.api.albumSongPage(
              widget.playlist.albumId ?? widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            )
          : await widget.api.playlistSongPage(
              widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            );
      if (!mounted) return;

      setState(() {
        final songs = songPage.songs;
        _songs.addAll(songs);
        _nextPage++;
        _hasMore =
            songPage.rawItemCount == _pageSize &&
            _songs.length < (_currentPlaylist.songCount ?? 1 << 31);
        _isLoadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadMoreError = error.toString();
        _isLoadingMore = false;
      });
    } finally {
      _loadMoreFuture = null;
    }
  }

  /// 打开页面时自动定位到当前播放的歌曲（滚动到其所在行）。
  ///
  /// 当前歌曲尚未加载（分页懒加载）时：若播放队列与当前歌单匹配
  /// （已加载歌曲全部属于当前队列），逐页加载直到找到；否则不再额外请求，
  /// 避免打开任意歌单都触发全量加载。
  Future<void> _autoLocateCurrentSong() async {
    if (_autoLocateDone || _isLocating) return;
    final current = widget.player.currentSong;
    if (current == null) return;
    _isLocating = true;
    try {
      var index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
      if (index < 0 && _shouldSearchForCurrentSong(current)) {
        // 逐页加载直到找到（上限 24 页，异常情况不再继续）
        var pages = 0;
        while (index < 0 &&
            pages++ < 24 &&
            _hasMore &&
            _loadMoreError == null) {
          await _loadMore();
          if (!mounted) return;
          index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
        }
      }
      if (index >= 0 && mounted) {
        _autoLocateDone = true;
        await _scrollToSong(index);
      }
    } finally {
      _isLocating = false;
    }
  }

  /// 判断当前播放歌曲是否属于本歌单/专辑，需要向下翻页查找。
  bool _shouldSearchForCurrentSong(Song current) {
    if (_songs.isEmpty) return false;
    // 专辑详情页：比对专辑 ID 或专辑名
    if (_isAlbum) {
      final targetAlbumId = widget.playlist.albumId ?? widget.playlist.id;
      if (current.albumId != null && current.albumId == targetAlbumId) {
        return true;
      }
      if (current.albumName != null &&
          current.albumName!.isNotEmpty &&
          current.albumName == widget.playlist.title) {
        return true;
      }
    }
    // 歌单详情页：若播放队列中包含当前歌曲且与歌单歌曲有交集
    final queueHashes = widget.player.queue.map((s) => s.hash).toSet();
    if (queueHashes.contains(current.hash)) {
      if (_songs.any((s) => queueHashes.contains(s.hash))) {
        return true;
      }
      final total = _info?.songCount ?? widget.playlist.songCount;
      if (total != null && (total - widget.player.queue.length).abs() <= 10) {
        return true;
      }
    }
    return false;
  }

  /// 滚动到展示列表中 [displayIndex] 所在行：先按固定行高估算偏移跳转，
  /// 再用目标行 key 精确校正（兼容字体缩放等导致的估算误差）。
  Future<void> _scrollToSong(int displayIndex) async {
    if (displayIndex < 0 || displayIndex >= _filteredSongs.length) return;
    if (!_scrollController.hasClients) {
      // 等待首帧布局完成（内容刚加载完时 ScrollView 可能尚未 attach）
      for (var i = 0; i < 20 && !_scrollController.hasClients && mounted; i++) {
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !_scrollController.hasClients) return;
    }

    final topInset = MediaQuery.paddingOf(context).top;
    const actionsHeight = 70.0;
    const listTopPadding = 4.0;
    const rowExtent = 72.0;
    final collapseDelta = 198.0 - (kToolbarHeight + topInset);
    final targetOffset = displayIndex == 0
        ? 0.0
        : (collapseDelta.clamp(0.0, 198.0) +
            actionsHeight +
            listTopPadding +
            (displayIndex * rowExtent));

    setState(() => _locateTargetIndex = displayIndex);

    final position = _scrollController.position;
    _scrollController.jumpTo(targetOffset.clamp(0.0, position.maxScrollExtent));

    // 精确校正：定位行 key 一旦构建，用 ensureVisible 对齐到视口上 1/4 处。
    for (var attempt = 0; attempt < 6; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final rowContext = _locateRowKey.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: 0.25,
          duration: const Duration(milliseconds: 220),
        );
        if (mounted) setState(() => _locateTargetIndex = null);
        return;
      }
    }
    if (mounted) setState(() => _locateTargetIndex = null);
  }

  PlaylistSummary get _currentPlaylist => _info ?? widget.playlist;

  PlaylistSummary get _libraryPlaylist {
    return widget.auth.findUserPlaylist(_currentPlaylist) ?? _currentPlaylist;
  }

  bool get _isInLibrary =>
      !widget.readOnly && widget.auth.isPlaylistInLibrary(_currentPlaylist);

  bool get _canEdit =>
      !widget.readOnly && widget.auth.canEditPlaylist(_currentPlaylist);

  Future<void> _collectPlaylist() async {
    if (_isAlbum) return;
    await _runMutation(() => widget.auth.collectPlaylist(_currentPlaylist));
  }

  Future<void> _deleteOrUncollectPlaylist() async {
    final target = _libraryPlaylist;
    final title = target.isCollectedAlbum
        ? '取消收藏专辑'
        : target.isCreatedPlaylist
        ? '删除歌单'
        : '取消收藏';
    final message = target.isCollectedAlbum
        ? '确定要取消收藏这个专辑吗？'
        : target.isCreatedPlaylist
        ? '确定要删除这个歌单吗？'
        : '确定要取消收藏这个歌单吗？';
    final confirmed = await _confirm(title: title, message: message);
    if (confirmed != true) return;

    await _runMutation(() => widget.auth.deleteOrUncollectPlaylist(target));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _removeSong(Song song) async {
    final confirmed = await _confirm(title: '删除歌曲', message: '从当前歌单删除这首歌？');
    if (confirmed != true) return;
    await _runMutation(() async {
      await widget.auth.removeSongFromPlaylist(_libraryPlaylist, song);
      if (mounted) {
        setState(() => _songs.removeWhere((item) => item.id == song.id));
      }
    });
  }

  Future<void> _addSongToPlaylist(Song song) async {
    await showAddToPlaylistSheet(
      context: context,
      auth: widget.auth,
      song: song,
    );
  }

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  /// 分享歌单：将歌单信息与歌曲列表复制到剪贴板。
  void _sharePlaylist() {
    final info = _currentPlaylist;
    final songs = _songs;
    final buffer = StringBuffer();
    buffer.writeln('🎵 ${info.title}');
    if (info.subtitle != null && info.subtitle!.trim().isNotEmpty) {
      buffer.writeln('by ${info.subtitle}');
    }
    buffer.writeln('共 ${songs.length} 首');
    buffer.writeln('---');
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      buffer.writeln('${i + 1}. ${song.title} - ${song.artist}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    Toast.success('歌单信息已复制到剪贴板');
  }

  /// 显示歌单操作 BottomSheet（收藏/删除/取消收藏）。
  void _showPlaylistActionSheet() {
    final options = <_ActionOption>[];
    if (!_isAlbum && !_isInLibrary) {
      options.add(_ActionOption(
        icon: Icons.bookmark_add_outlined,
        title: '收藏歌单',
        onTap: _collectPlaylist,
      ));
    }
    if (_isInLibrary && !_libraryPlaylist.isLikedPlaylist) {
      final isAlbum = _libraryPlaylist.isCollectedAlbum;
      final isCreated = _libraryPlaylist.isCreatedPlaylist;
      options.add(_ActionOption(
        icon: isCreated
            ? Icons.delete_outline_rounded
            : Icons.bookmark_remove_outlined,
        title: isAlbum
            ? '取消收藏专辑'
            : isCreated
                ? '删除歌单'
                : '取消收藏',
        danger: isCreated,
        onTap: _deleteOrUncollectPlaylist,
      ));
    }
    if (options.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '歌单操作',
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _ActionOptionTile(option: options[i]),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 58,
                            color: colorScheme.outlineVariant
                                .withValues(alpha: .3),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 通过歌单 ID 导入并打开歌单详情。
  /// 公开静态 API，供外部调用。
  // ignore: unused_element
  static Future<void> importPlaylistById({
    required BuildContext context,
    required MusicApi api,
    required AuthController auth,
    required PlayerController player,
    required String playlistId,
  }) async {
    Toast.info('正在导入歌单...');
    try {
      final info = await api.playlistInfo(playlistId);
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: info,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) Toast.error('导入失败：$e');
    }
  }

  void _openSimilarPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  Future<void> _runMutation(Future<void> Function() action) async {
    if (_isMutating) return;
    setState(() => _isMutating = true);
    try {
      await action();
      if (widget.auth.errorMessage != null) {
        throw Exception(widget.auth.errorMessage);
      }
      Toast.success('操作完成');
    } catch (error) {
      Toast.error('操作失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<bool?> _confirm({required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return LiquidGlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: AdaptiveContentPadding(
          child: Stack(
          children: [
            // Windows 平台滚动时 sliver item 回收重建会产生大量语义节点更新，
            // 触发 Flutter Windows 引擎 AXTree 更新 bug（console 提示
            // "Failed to update ui::AXTree"）。在 Windows 上排除语义树消除提示，
            // 移动端保留无障碍功能。
            ExcludeSemantics(
              excluding: !Platform.isWindows,
              child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  stretch: !_isSearching,
                  expandedHeight: _isSearching ? 0 : 198,
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                title: _isSearching
                    ? TextField(
                        controller: _searchController,
                        autofocus: true,
                        onChanged: (value) =>
                            setState(() => _searchQuery = value),
                        decoration: InputDecoration(
                          hintText: _isLoadingAllSongs
                              ? '正在加载全部歌曲…'
                              : '搜索歌曲名或歌手名',
                          border: InputBorder.none,
                          hintStyle: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Text(
                        (_info ?? widget.playlist).title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                actions: [
                  if (_selectionMode)
                    TextButton(
                      onPressed: _exitSelectionMode,
                      child: const Text('取消'),
                    )
                  else if (!_isSearching) ...[
                    IconButton(
                      tooltip: '搜索',
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.search_rounded),
                    ),
                    IconButton(
                      tooltip: '分享',
                      onPressed: _sharePlaylist,
                      icon: const Icon(Icons.share_rounded),
                    ),
                    if (!widget.readOnly)
                      IconButton(
                        tooltip: '导入歌单',
                        onPressed: () => showImportPlaylistSheet(
                          context: context,
                          api: widget.api,
                          auth: widget.auth,
                        ),
                        icon: const Icon(Icons.playlist_add_rounded),
                      ),
                    if (_isMutating)
                      const Padding(
                        padding: EdgeInsets.only(right: 16),
                        child: Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          ),
                        ),
                      )
                    else if (!widget.readOnly &&
                        ((!_isAlbum && !_isInLibrary) ||
                            (_isInLibrary &&
                                !_libraryPlaylist.isLikedPlaylist)))
                      IconButton(
                        tooltip: '更多',
                        onPressed: _showPlaylistActionSheet,
                        icon: const Icon(Icons.more_vert_rounded),
                      ),
                  ] else
                    IconButton(
                      tooltip: '关闭搜索',
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
                flexibleSpace: _isSearching
                    ? null
                    : FlexibleSpaceBar(
                        stretchModes: const [StretchMode.zoomBackground],
                        background: _HeroHeader(info: _info ?? widget.playlist),
                      ),
              ),
              if (_isInitialLoading)
                const _PlaylistDetailSkeleton()
              else if (_errorMessage case final message?)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppErrorView(
                    title: _isAlbum ? '专辑加载失败' : '歌单加载失败',
                    message: message,
                    onRetry: _loadInitial,
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: _Actions(
                    count: _info?.songCount ?? _songs.length,
                    loadedCount: _songs.length,
                    sortLabel: _sortModeLabel,
                    onSortTap: () => _showSortSheet(context),
                    onPlay: _filteredSongs.isEmpty
                        ? null
                        : () async {
                            final queue = await _ensureFullQueueForPlayback();
                            if (!mounted || queue.isEmpty) return;
                            widget.player.playSong(
                              queue.first,
                              queue: List<Song>.of(queue),
                            );
                          },
                    searchQuery: _searchQuery,
                    searchResultCount: _searchQuery.isNotEmpty
                        ? _filteredSongs.length
                        : null,
                    selectionMode: _selectionMode,
                    selectedCount: _selectedCount,
                    onSelectTap: _filteredSongs.isEmpty
                        ? null
                        : _enterSelectionMode,
                  ),
                ),
                if (_isLoadingAllSongs)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Column(
                          children: [
                            CircularProgressIndicator(strokeWidth: 2.4),
                            SizedBox(height: 12),
                            Text('正在加载全部歌曲…'),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (_searchQuery.isNotEmpty && _filteredSongs.isEmpty)
                  const SliverToBoxAdapter(child: _SearchEmpty())
                else ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    sliver: SliverList.separated(
                      itemCount: _filteredSongs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final song = _filteredSongs[index];
                        return _SongRow(
                          key: _locateTargetIndex == index
                              ? _locateRowKey
                              : null,
                          song: song,
                          index: index + 1,
                          player: widget.player,
                          canDelete: _canEdit,
                          selectionMode: _selectionMode,
                          selected: _selectedHashes.contains(song.hash),
                          onToggleSelect: () => _toggleSongSelection(song),
                          onTap: () async {
                            final queue = await _ensureFullQueueForPlayback();
                            if (!mounted || queue.isEmpty) return;
                            widget.player.playSong(
                              song,
                              queue: List<Song>.of(queue),
                            );
                          },
                          onAddToPlaylist: () => _addSongToPlaylist(song),
                          onDelete: () => _removeSong(song),
                          onViewArtist: () => _openArtist(song),
                        );
                      },
                    ),
                  ),
                  if (_searchQuery.isEmpty)
                    SliverToBoxAdapter(
                      child: _LoadMoreFooter(
                        hasMore: _hasMore,
                        isLoading: _isLoadingMore,
                        errorMessage: _loadMoreError,
                        onRetry: _loadMore,
                      ),
                    ),
                  if (_searchQuery.isEmpty && _similarPlaylists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _SimilarPlaylistsSection(
                        playlists: _similarPlaylists,
                        onTap: _openSimilarPlaylist,
                      ),
                    ),
                ],
              ],
            ],
          ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: _selectionMode
                ? _SelectionBar(
                    selectedCount: _selectedCount,
                    allSelected: _isAllSelected,
                    downloading: _batchDownloading,
                    onToggleAll: _toggleSelectAll,
                    onInvert: _toggleInvertSelection,
                    onDownload: _selectedCount == 0 ? null : _downloadSelected,
                  )
                : MiniPlayer(player: widget.player, auth: widget.auth),
          ),
        ],
      ),
    ),
    ),
  );
  }
}

/// 相似歌单横向区块。
class _SimilarPlaylistsSection extends StatelessWidget {
  const _SimilarPlaylistsSection({
    required this.playlists,
    required this.onTap,
  });

  final List<PlaylistSummary> playlists;
  final ValueChanged<PlaylistSummary> onTap;

  @override
  Widget build(BuildContext context) {
    return AppHorizontalRail<PlaylistSummary>(
      title: '相似歌单',
      items: playlists,
      height: 170,
      itemWidth: 120,
      topPadding: 20,
      itemBuilder: (context, playlist) => _SimilarPlaylistCard(
        playlist: playlist,
        onTap: () => onTap(playlist),
      ),
    );
  }
}


class _SimilarPlaylistCard extends StatelessWidget {
  const _SimilarPlaylistCard({required this.playlist, required this.onTap});

  final PlaylistSummary playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Artwork(url: playlist.coverUrl, size: 120),
            ),
            const SizedBox(height: 6),
            Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            Text(
              playlist.creatorName ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单操作选项数据。
class _ActionOption {
  const _ActionOption({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;
}

/// 歌单操作选项条目。
class _ActionOptionTile extends StatelessWidget {
  const _ActionOptionTile({required this.option});

  final _ActionOption option;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = option.danger ? colorScheme.error : colorScheme.onSurface;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        option.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(option.icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                option.title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({required this.info});

  final PlaylistSummary info;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 380;
              final artworkSize = compact ? 90.0 : 102.0;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Artwork(
                    url: info.coverUrl,
                    size: artworkSize,
                    borderRadius: 16,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          info.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                height: 1.05,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          info.subtitle?.trim().isNotEmpty == true
                              ? info.subtitle!
                              : _detailMeta(info),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _detailMeta(info),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
  }
}

class _PlaylistDetailSkeleton extends StatelessWidget {
  const _PlaylistDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 118),
      sliver: SliverList.list(
        children: [
          Row(
            children: [
              const _SkeletonBox(width: 108, height: 18, radius: 7),
              const Spacer(),
              _SkeletonBox(width: 104, height: 40, radius: 20),
            ],
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < 10; index++) ...[
            const _PlaylistSkeletonSongRow(),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}


class _PlaylistSkeletonSongRow extends StatelessWidget {
  const _PlaylistSkeletonSongRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _SkeletonBox(width: 50, height: 50, radius: 9),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SkeletonBox(width: double.infinity, height: 16, radius: 6),
              SizedBox(height: 8),
              _SkeletonBox(width: 142, height: 14, radius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        _SkeletonBox(width: 38, height: 14, radius: 6),
        SizedBox(width: 18),
        _SkeletonBox(width: 24, height: 24, radius: 12),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.count,
    required this.loadedCount,
    required this.onPlay,
    required this.sortLabel,
    required this.onSortTap,
    this.searchQuery,
    this.searchResultCount,
    this.selectionMode = false,
    this.selectedCount = 0,
    this.onSelectTap,
  });

  final int count;
  final int loadedCount;
  final VoidCallback? onPlay;
  final String? searchQuery;
  final int? searchResultCount;
  final String sortLabel;
  final VoidCallback onSortTap;
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback? onSelectTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSearching = searchQuery != null && searchQuery!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      child: selectionMode
          ? Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '已选择 $selectedCount 首',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (!isSearching) ...[
                        TextButton.icon(
                          onPressed: onSortTap,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.sort_rounded, size: 16),
                          label: Text(
                            sortLabel,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          isSearching
                              ? '搜索结果：$searchResultCount 首'
                              : loadedCount >= count
                              ? '$count 首歌曲'
                              : '已加载 $loadedCount / $count 首',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isSearching) ...[
                  if (onSelectTap != null) ...[
                    const SizedBox(width: 6),
                    TextButton.icon(
                      onPressed: onSelectTap,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.checklist_rounded, size: 16),
                      label: Text(
                        '选择',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    onPressed: onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('播放全部'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ] else if (searchResultCount != null && searchResultCount! > 0)
                  FilledButton.icon(
                    onPressed: onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('播放结果'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: const StadiumBorder(),
                    ),
                  ),
              ],
            ),
    );
  }
}


class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 40, 18, 160),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          const SizedBox(height: 12),
          Text(
            '没有找到匹配的歌曲',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}


class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({
    required this.hasMore,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  final bool hasMore;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 118),
        child: Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(18, 14, 18, 118),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 118),
      child: Center(
        child: Text(
          hasMore ? '继续下滑加载更多' : '已加载全部',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    super.key,
    required this.song,
    required this.index,
    required this.player,
    required this.canDelete,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onDelete,
    required this.onViewArtist,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;
  final VoidCallback onViewArtist;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 歌曲行响应 player 重建，高频更新会触发 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final active = player.currentSong?.hash == song.hash;
          final activeColor = colorScheme.primary;
          return InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: selectionMode ? onToggleSelect : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: active
                  ? activeColor.withValues(alpha: .09)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Row(
              children: [
                if (selectionMode) ...[
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onToggleSelect?.call(),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 2),
                ],
                SizedBox.square(
                  dimension: 50,
                  child: Stack(
                    children: [
                      Artwork(url: song.coverUrl, size: 50, borderRadius: 9),
                      Positioned(
                        left: 4,
                        top: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .42),
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            child: Text(
                              '$index',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: .78),
                                    fontWeight: FontWeight.w800,
                                    height: 1.1,
                                  ),
                            ),
                          ),
                        ),
                      ),
                      if (active)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.surface.withValues(alpha: .9),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: NowPlayingBadge(
                                active: active,
                                playing: player.isPlaying,
                                color: activeColor,
                                size: 14,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      active
                          ? MarqueeText(
                              text: song.title,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: activeColor,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                      const SizedBox(height: 3),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: active
                              ? activeColor.withValues(alpha: .72)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  formatDuration(song.duration),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active
                        ? activeColor.withValues(alpha: .72)
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!selectionMode)
                  IconButton(
                    tooltip: '更多',
                    onPressed: () {
                      showSongActionSheet(
                        context: context,
                        song: song,
                        actions: [
                          SongSheetAction(
                            icon: Icons.queue_music_rounded,
                            title: '下一首播放',
                            onTap: () => addSongToQueueWithFeedback(
                              context: context,
                              player: player,
                              song: song,
                            ),
                          ),
                          SongSheetAction(
                            icon: Icons.playlist_add_rounded,
                            title: '添加到歌单',
                            onTap: onAddToPlaylist,
                          ),
                          SongSheetAction(
                            icon: Icons.person_rounded,
                            title: '查看歌手',
                            onTap: onViewArtist,
                          ),
                          if (canDelete)
                            SongSheetAction(
                              icon: Icons.delete_outline_rounded,
                              title: '从歌单删除',
                              danger: true,
                              onTap: onDelete,
                            ),
                          if (player.downloadController != null)
                            SongSheetAction(
                              icon: player.downloadController!.isDownloaded(song)
                                  ? Icons.download_done_rounded
                                  : Icons.download_rounded,
                              title: player.downloadController!.isDownloaded(song)
                                  ? '已下载'
                                  : '下载',
                              onTap: () => player.downloadController!.download(
                                song,
                                player.audioQuality,
                              ),
                            ),
                        ],
                      );
                    },
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
              ],
            ),
          ),
        );
        },
      ),
    );
  }
}

/// 多选模式底部操作栏：全选 / 反选 / 批量下载。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.allSelected,
    required this.downloading,
    required this.onToggleAll,
    required this.onInvert,
    required this.onDownload,
  });

  final int selectedCount;
  final bool allSelected;
  final bool downloading;
  final VoidCallback onToggleAll;
  final VoidCallback onInvert;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LiquidGlassCard(
        borderRadius: AppRadius.xl,
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
        enableTouchFlex: false,
        child: Row(
          children: [
            TextButton(
              onPressed: onToggleAll,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
            TextButton(
              onPressed: onInvert,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('反选'),
            ),
            Expanded(
              child: Text(
                '已选择 $selectedCount 首',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            FilledButton.icon(
              onPressed: downloading ? null : onDownload,
              icon: downloading
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, size: 18),
              label: Text(
                downloading ? '加入中…' : '下载($selectedCount)',
              ),
              style: FilledButton.styleFrom(
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SongSortMode {
  defaultOrder,
  byTitle,
  byArtist,
  byAlbum,
}

class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: selected ? colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}


String _detailMeta(PlaylistSummary info) {
  if (info.isCollectedAlbum) {
    if (info.songCount != null) {
      return '${info.songCount} 首歌';
    }
    return '新专辑';
  }
  final parts = <String>[];
  if (info.songCount != null) {
    parts.add('${info.songCount} 首歌');
  }
  if (info.playCount != null) {
    parts.add(_playCount(info.playCount));
  }
  return parts.isEmpty ? '来自 KA Music' : parts.join(' · ');
}

String _playCount(int? value) {
  if (value == null) {
    return '精选歌单';
  }
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(1)} 万次播放';
  }
  return '$value 次播放';
}
