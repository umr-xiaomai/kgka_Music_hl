import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/app_feedback.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import 'artist_detail_page.dart';
import '../adaptive_layout.dart';

/// 用户云盘音乐页面。
class CloudDrivePage extends StatefulWidget {
  const CloudDrivePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<CloudDrivePage> createState() => _CloudDrivePageState();
}

class _CloudDrivePageState extends State<CloudDrivePage> {
  static const _pageSize = 50;

  final _scrollController = ScrollController();
  final _songs = <Song>[];

  CloudDriveInfo? _info;
  var _nextPage = 1;
  var _hasMore = true;
  var _isInitialLoading = true;
  var _isLoadingMore = false;
  String? _errorMessage;
  String? _loadMoreError;

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
    super.dispose();
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

    try {
      final page = await widget.api.cloudDrive(page: 1, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _info = page.info;
        _songs.addAll(page.songs);
        _nextPage = 2;
        _hasMore =
            page.songs.length == _pageSize &&
            (_info?.totalCount == null || _songs.length < _info!.totalCount!);
        _isInitialLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
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

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    try {
      final page = await widget.api.cloudDrive(
        page: _nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _songs.addAll(page.songs);
        _nextPage++;
        _hasMore =
            page.songs.length == _pageSize &&
            (_info?.totalCount == null || _songs.length < _info!.totalCount!);
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
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    expandedHeight: 198,
                    surfaceTintColor: Colors.transparent,
                    backgroundColor: Colors.transparent,
                    title: const Text(
                      '云盘',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      stretchModes: const [StretchMode.zoomBackground],
                      background: _CloudHeader(info: _info),
                    ),
                  ),
                if (_isInitialLoading)
                  const _CloudSkeleton()
                else if (_errorMessage case final message?)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _CloudError(message: message, onRetry: _loadInitial),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: _Actions(
                      count: _info?.totalCount ?? _songs.length,
                      loadedCount: _songs.length,
                      onPlay: _songs.isEmpty
                          ? null
                          : () => widget.player.playSong(
                              _songs.first,
                              queue: List<Song>.of(_songs),
                            ),
                    ),
                  ),
                  if (_songs.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: AppEmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: '云盘里还没有歌曲',
                    subtitle: '在酷狗概念版 App 上传音乐到云盘后即可在这里播放',
                  ),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      sliver: SliverList.separated(
                        itemCount: _songs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) {
                          final song = _songs[index];
                          return _CloudSongRow(
                            song: song,
                            index: index + 1,
                            player: widget.player,
                            onTap: () => widget.player.playSong(
                              song,
                              queue: List<Song>.of(_songs),
                            ),
                            onViewArtist: () => _openArtist(song),
                          );
                        },
                      ),
                    ),
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
    );
  }
}

class _CloudHeader extends StatelessWidget {
  const _CloudHeader({this.info});

  final CloudDriveInfo? info;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Row(
                children: [
                  LiquidGlassCard(
                    borderRadius: AppRadius.xl,
                    padding: const EdgeInsets.all(18),
                    child: Icon(
                      Icons.cloud_rounded,
                      size: 44,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '我的云盘',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          info?.totalCount != null
                              ? '${info!.totalCount} 首歌曲'
                              : '云盘音乐',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (info != null && info!.maxBytes != null) ...[
                const SizedBox(height: 14),
                _CapacityBar(info: info!),
              ],
            ],
          ),
        ),
      );
  }
}

class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.info});

  final CloudDriveInfo info;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: LinearProgressIndicator(
            value: info.usageRatio,
            minHeight: 6,
            backgroundColor: colorScheme.surfaceContainerHighest,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${_formatBytes(info.usedBytes ?? 0)} / ${_formatBytes(info.maxBytes ?? 0)}'
          '${info.availableBytes != null ? '  ·  剩余 ${_formatBytes(info.availableBytes!)}' : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.count,
    required this.loadedCount,
    required this.onPlay,
  });

  final int count;
  final int loadedCount;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              loadedCount >= count
                  ? '$count 首歌曲'
                  : '已加载 $loadedCount / $count 首',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放全部'),
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

class _CloudSongRow extends StatelessWidget {
  const _CloudSongRow({
    required this.song,
    required this.index,
    required this.player,
    required this.onTap,
    required this.onViewArtist,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final VoidCallback onTap;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
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
                          icon: Icons.person_rounded,
                          title: '查看歌手',
                          onTap: onViewArtist,
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
    );
  }
}

class _CloudSkeleton extends StatelessWidget {
  const _CloudSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 118),
      sliver: SliverList.list(
        children: [
          for (var index = 0; index < 10; index++) ...[
            const _SkeletonRow(),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _buildBox(colorScheme, 50, 50, 9),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBox(colorScheme, double.infinity, 16),
              const SizedBox(height: 8),
              _buildBox(colorScheme, 142, 14),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _buildBox(colorScheme, 38, 14),
        const SizedBox(width: 18),
        _buildBox(colorScheme, 24, 24, 12),
      ],
    );
  }

  Widget _buildBox(
    ColorScheme colorScheme,
    double w,
    double h, [
    double r = 6,
  ]) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(r),
      ),
      child: SizedBox(width: w, height: h),
    );
  }
}

class _CloudError extends StatelessWidget {
  const _CloudError({required this.message, required this.onRetry});

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
          Text('云盘加载失败', style: Theme.of(context).textTheme.titleLarge),
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

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
