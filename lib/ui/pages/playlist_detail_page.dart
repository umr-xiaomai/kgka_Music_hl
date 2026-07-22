import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
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
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final PlaylistSummary playlist;

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
  bool _isMutating = false;
  bool _isSearching = false;
  bool _isLoadingAllSongs = false;
  bool _allSongsLoaded = false;
  String _searchQuery = '';
  _SongSortMode _sortMode = _SongSortMode.defaultOrder;

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
                  borderRadius: BorderRadius.circular(16),
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

  bool get _isAlbum => widget.playlist.isCollectedAlbum;

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
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SongSortMode.byArtist:
        list.sort((a, b) => a.artist.compareTo(b.artist));
        break;
      case _SongSortMode.byAlbum:
        list.sort((a, b) => (a.albumName ?? '').compareTo(b.albumName ?? ''));
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

  Future<void> _loadAllSongs() async {
    if (_isLoadingAllSongs || _allSongsLoaded) return;
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
          final library = widget.auth.findUserPlaylist(widget.playlist) ??
              widget.playlist;
          _info = library.mergeWithDetail(PlaylistSummary.fromCache(infoJson));
        }
        _songs.clear();
        _songs.addAll((cacheData['songs'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Song.fromCache)
            .toList());
        _isInitialLoading = false;
      });
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
          // 详情接口可能缺 type/listId；与入口/库内元数据合并，保证 canEdit 正确
          final library = widget.auth.findUserPlaylist(widget.playlist) ??
              widget.playlist;
          _info = library.mergeWithDetail(info);
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
      if (cached != null) {
        // 有缓存数据，保持不报错（降级）
        return;
      }
      setState(() {
        _errorMessage = error.toString();
        _isInitialLoading = false;
      });
    }
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

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

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
    }
  }

  PlaylistSummary get _currentPlaylist => _info ?? widget.playlist;

  PlaylistSummary get _libraryPlaylist {
    return widget.auth.findUserPlaylist(_currentPlaylist) ?? _currentPlaylist;
  }

  bool get _isInLibrary => widget.auth.isPlaylistInLibrary(_currentPlaylist);

  /// 优先用库列表里的歌单元数据判断，避免详情接口字段不全导致无法删歌。
  bool get _canEdit => widget.auth.canEditPlaylist(_libraryPlaylist);

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
                  borderRadius: BorderRadius.circular(16),
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

    return Scaffold(
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
                // 头部渐变顶部为半透明 primary，收缩后若 toolbar 无不透明背景，
                // 列表内容会透过与标题/操作按钮重叠。这里用 scaffoldBackgroundColor
                // 作为不透明底色（与头部渐变底部一致，过渡自然），展开态被 _HeroHeader 覆盖。
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
                  if (!_isSearching) ...[
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
                    else if ((!_isAlbum && !_isInLibrary) ||
                        (_isInLibrary && !_libraryPlaylist.isLikedPlaylist))
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
                  child: _DetailError(
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
                          song: song,
                          index: index + 1,
                          player: widget.player,
                          canDelete: _canEdit,
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
                ],
              ],
            ],
          ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: MiniPlayer(player: widget.player, auth: widget.auth),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: isDark ? .28 : .18),
            const Color(0xFFDCEEFF).withValues(alpha: isDark ? .08 : .92),
            Theme.of(context).scaffoldBackgroundColor,
          ],
          stops: const [0, .58, 1],
        ),
      ),
      child: SafeArea(
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
  });

  final int count;
  final int loadedCount;
  final VoidCallback? onPlay;
  final String? searchQuery;
  final int? searchResultCount;
  final String sortLabel;
  final VoidCallback onSortTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSearching = searchQuery != null && searchQuery!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
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
                if (!isSearching) ...[
                  const SizedBox(width: 8),
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
                ],
              ],
            ),
          ),
          if (!isSearching)
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放全部'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const StadiumBorder(),
              ),
            )
          else if (searchResultCount != null && searchResultCount! > 0)
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
    required this.song,
    required this.index,
    required this.player,
    required this.canDelete,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onDelete,
    required this.onViewArtist,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;
  final VoidCallback onViewArtist;

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
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: active
                  ? activeColor.withValues(alpha: .09)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
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
                            borderRadius: BorderRadius.circular(6),
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
                              borderRadius: BorderRadius.circular(7),
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
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: active ? activeColor : null,
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

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, size: 42),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
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

