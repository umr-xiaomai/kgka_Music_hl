import 'dart:async';

import 'package:flutter/material.dart';

import '../adaptive_layout.dart';
import '../design_tokens.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/song_artwork.dart';
import '../widgets/status_bar_overlay.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import 'artist_detail_page.dart';

/// 排行榜页面。
///
/// 顶部是可横向滑动的榜单选择条，下面依次是「播放全部」与榜单歌曲列表。
/// 榜单来源记录到 [QueueOrigin.rank]，重启后队列残缺也能按榜单重建。
class RankPage extends StatefulWidget {
  const RankPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    this.initialBoardId,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  /// 从其它入口进入时希望直接选中的榜单 id。
  final String? initialBoardId;

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  final _scrollController = ScrollController();
  final _boardScrollController = ScrollController();
  final _songs = <Song>[];

  List<RankBoard> _boards = const [];
  RankBoard? _selectedBoard;

  bool _boardsLoading = true;
  String? _boardsError;

  bool _songsLoading = false;
  String? _songsError;
  int _total = 0;

  /// 榜单歌曲请求代次：快速切换榜单时丢弃过期结果。
  int _songsSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBoards());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _boardScrollController.dispose();
    super.dispose();
  }

  /// 拉取榜单列表。
  ///
  /// [selectBoard] 为 true 时自动选中（并加载）目标榜单；下拉刷新时传 false，
  /// 由 [_reloadAll] 统一刷新当前榜单歌曲，避免重复请求。
  Future<void> _loadBoards({bool selectBoard = true}) async {
    setState(() {
      _boardsLoading = true;
      _boardsError = null;
    });
    try {
      final boards = await widget.api.rankBoards();
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _boardsLoading = false;
        _boardsError = boards.isEmpty ? '暂时没有可用的榜单' : null;
      });
      if (boards.isEmpty) return;
      if (!selectBoard && _selectedBoard != null) return;
      final initial = widget.initialBoardId;
      final target = initial == null
          ? boards.first
          : boards.firstWhere(
              (board) => board.id == initial,
              orElse: () => boards.first,
            );
      _selectBoard(target);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _boardsLoading = false;
        _boardsError = error.toString();
      });
    }
  }

  void _selectBoard(RankBoard board) {
    if (_selectedBoard?.id == board.id && _songs.isNotEmpty) return;
    setState(() {
      _selectedBoard = board;
      _songs.clear();
      _total = 0;
      _songsError = null;
    });
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    unawaited(_loadSongs(board));
  }

  Future<void> _loadSongs(RankBoard board) async {
    final serial = ++_songsSerial;
    setState(() {
      _songsLoading = true;
      _songsError = null;
    });
    try {
      final result = await widget.api.rankSongs(board.id, pageSize: 500);
      if (!mounted || serial != _songsSerial) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(result.songs);
        _total = result.total > 0 ? result.total : result.songs.length;
        _songsLoading = false;
      });
    } catch (error) {
      if (!mounted || serial != _songsSerial) return;
      setState(() {
        _songsLoading = false;
        _songsError = error.toString();
      });
    }
  }

  /// 下拉刷新：榜单列表与当前榜单歌曲一起重新拉取。
  Future<void> _reloadAll() async {
    await _loadBoards(selectBoard: false);
    final board = _selectedBoard;
    if (board != null) await _loadSongs(board);
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    _play(_songs.first);
  }

  void _play(Song song) {
    final board = _selectedBoard;
    widget.player.playSong(
      song,
      queue: List<Song>.of(_songs),
      origin: board == null
          ? null
          : QueueOrigin.rank(id: board.id, title: board.name),
    );
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
      (item) => item.name.isNotEmpty,
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

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return StatusBarOverlay(
      brightness: Theme.of(context).brightness,
      child: LiquidGlassBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AdaptiveContentPadding(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _reloadAll,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      _buildAppBar(),
                      if (_boardsLoading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(18, 60, 18, 0),
                            child: Center(
                              child: SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                ),
                              ),
                            ),
                          ),
                        )
                      else if (_boardsError != null)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _RankEmpty(
                            icon: Icons.error_outline_rounded,
                            title: '榜单加载失败',
                            message: _boardsError!,
                            action: FilledButton.icon(
                              onPressed: _loadBoards,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('重试'),
                            ),
                          ),
                        )
                      else ...[
                        SliverToBoxAdapter(
                          child: _BoardSelector(
                            boards: _boards,
                            selectedId: _selectedBoard?.id,
                            controller: _boardScrollController,
                            onSelected: _selectBoard,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: _RankActions(
                            board: _selectedBoard,
                            count: _total,
                            loadedCount: _songs.length,
                            loading: _songsLoading,
                            onPlayAll: _songs.isEmpty ? null : _playAll,
                          ),
                        ),
                        if (_songsLoading && _songs.isEmpty)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(18, 40, 18, 0),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else if (_songsError != null && _songs.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _RankEmpty(
                              icon: Icons.cloud_off_rounded,
                              title: '榜单歌曲加载失败',
                              message: _songsError!,
                              action: FilledButton.icon(
                                onPressed: () {
                                  final board = _selectedBoard;
                                  if (board != null) _loadSongs(board);
                                },
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('重试'),
                              ),
                            ),
                          )
                        else if (_songs.isEmpty)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: _RankEmpty(
                              icon: Icons.queue_music_rounded,
                              title: '这个榜单还没有歌曲',
                              message: '换一个榜单看看吧',
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            sliver: SliverList.separated(
                              itemCount: _songs.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 2),
                              itemBuilder: (context, index) {
                                final song = _songs[index];
                                return _RankSongRow(
                                  song: song,
                                  index: index + 1,
                                  player: widget.player,
                                  onTap: () => _play(song),
                                  onAddToPlaylist: () =>
                                      _addSongToPlaylist(song),
                                  onViewArtist: () => _openArtist(song),
                                );
                              },
                            ),
                          ),
                        const SliverToBoxAdapter(
                          child: SizedBox(height: 150),
                        ),
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
        ),
      ),
    );
  }

  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      title: const Text(
        '排行榜',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _boardsLoading ? null : _reloadAll,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }
}

/// 顶部可横向滑动的榜单选择条。
class _BoardSelector extends StatefulWidget {
  const _BoardSelector({
    required this.boards,
    required this.selectedId,
    required this.controller,
    required this.onSelected,
  });

  final List<RankBoard> boards;
  final String? selectedId;
  final ScrollController controller;
  final ValueChanged<RankBoard> onSelected;

  @override
  State<_BoardSelector> createState() => _BoardSelectorState();
}

class _BoardSelectorState extends State<_BoardSelector> {
  /// 每项宽度 84 + 间距 12，用于把选中项滚进可视区。
  static const _itemExtent = 96.0;

  @override
  void didUpdateWidget(covariant _BoardSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId) {
      _revealSelected();
    }
  }

  /// 选中项滚动到可视区中段，避免它在屏幕外时用户看不到当前选中的是哪个。
  void _revealSelected() {
    final index = widget.boards.indexWhere(
      (board) => board.id == widget.selectedId,
    );
    if (index < 0 || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final target = (index * _itemExtent - position.viewportDimension / 2 + 48)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        controller: widget.controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
        itemCount: widget.boards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final board = widget.boards[index];
          return _BoardChip(
            board: board,
            selected: board.id == widget.selectedId,
            onTap: () => widget.onSelected(board),
          );
        },
      ),
    );
  }
}

class _BoardChip extends StatelessWidget {
  const _BoardChip({
    required this.board,
    required this.selected,
    required this.onTap,
  });

  final RankBoard board;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 84,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(
                  color: selected
                      ? colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Artwork(
                url: board.coverUrl,
                size: 68,
                borderRadius: 12,
                icon: Icons.leaderboard_rounded,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              board.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前榜单的「播放全部」操作区。
class _RankActions extends StatelessWidget {
  const _RankActions({
    required this.board,
    required this.count,
    required this.loadedCount,
    required this.loading,
    required this.onPlayAll,
  });

  final RankBoard? board;
  final int count;
  final int loadedCount;
  final bool loading;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = loading && loadedCount == 0
        ? '加载中…'
        : (count > 0 ? '$count 首歌曲' : '暂无歌曲');

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            board?.name ?? '排行榜',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (board != null && board!.previewSongs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              board!.previewSongs.take(3).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: const StadiumBorder(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 榜单歌曲行，样式与播放历史 / 歌单详情保持一致。
class _RankSongRow extends StatelessWidget {
  const _RankSongRow({
    required this.song,
    required this.index,
    required this.player,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onViewArtist,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 歌曲行随 player 重建，排除语义树避免 Windows AXTree 竞态崩溃。
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final active = player.currentSong?.hash == song.hash;
          final activeColor = colorScheme.primary;
          return InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onTap,
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
                  SizedBox.square(
                    dimension: 50,
                    child: Stack(
                      children: [
                        SongArtwork(song: song, size: 50, borderRadius: 9),
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
                                      color: Colors.white.withValues(
                                        alpha: .78,
                                      ),
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
                                color: colorScheme.surface.withValues(
                                  alpha: .9,
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
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
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: active ? activeColor : null,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
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
                        api: player.api,
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
                          if (player.downloadController != null)
                            SongSheetAction(
                              icon:
                                  player.downloadController!.isDownloaded(song)
                                  ? Icons.download_done_rounded
                                  : Icons.download_rounded,
                              title:
                                  player.downloadController!.isDownloaded(song)
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

class _RankEmpty extends StatelessWidget {
  const _RankEmpty({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
