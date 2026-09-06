import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/app_section.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/marquee_text.dart';
import '../widgets/song_action_sheets.dart';
import '../adaptive_layout.dart';
import 'playlist_detail_page.dart';

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.artist,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final ArtistRef artist;
  final PlayerController player;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  static const _pageSize = 30;

  final _scrollController = ScrollController();
  final _songs = <Song>[];
  final _albums = <ArtistAlbum>[];

  ArtistDetail? _detail;
  String? _resolvedArtistId;
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
      _detail = null;
      _songs.clear();
      _albums.clear();
      _nextPage = 1;
      _hasMore = true;
      _isInitialLoading = true;
      _isLoadingMore = false;
      _errorMessage = null;
      _loadMoreError = null;
    });

    try {
      var artistId = widget.artist.id;

      // If no ID (e.g. from search results), try to find it by name
      if (artistId.isEmpty && widget.artist.name.isNotEmpty) {
        final targetName = widget.artist.name.toLowerCase();

        // Try 1: search songs and match artist name
        final searchResults = await widget.api.searchSongs(
          widget.artist.name,
          pageSize: 10,
        );
        for (final song in searchResults) {
          for (final a in song.artists) {
            if (a.id.isNotEmpty &&
                a.name.toLowerCase().contains(targetName)) {
              artistId = a.id;
              break;
            }
          }
          if (artistId.isNotEmpty) break;
        }

      }

      if (artistId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _errorMessage = '未找到该歌手';
          _isInitialLoading = false;
        });
        return;
      }

      _resolvedArtistId = artistId;

      final results = await Future.wait([
        widget.api.artistDetail(artistId),
        widget.api.artistAudios(
          artistId,
          page: 1,
          pageSize: _pageSize,
          sort: 'hot',
        ),
        widget.api.artistAlbums(artistId, pageSize: 20),
      ]);
      if (!mounted) return;

      final detail = results[0] as ArtistDetail;
      final songs = results[1] as List<Song>;
      final albums = results[2] as List<ArtistAlbum>;
      setState(() {
        _detail = detail;
        _songs.addAll(songs);
        _albums.addAll(albums);
        _nextPage = 2;
        _hasMore = songs.length == _pageSize;
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
      final songs = await widget.api.artistAudios(
        _resolvedArtistId ?? widget.artist.id,
        page: _nextPage,
        pageSize: _pageSize,
        sort: 'hot',
      );
      if (!mounted) return;

      setState(() {
        _songs.addAll(songs);
        _nextPage++;
        _hasMore = songs.length == _pageSize;
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

  void _openAlbum(ArtistAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: PlaylistSummary(
            id: album.id,
            title: album.name,
            subtitle: album.authorName ?? widget.artist.name,
            coverUrl: album.coverUrl,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // MiniPlayer 高度约 64，距底部 16，合计预留空间防止遮挡最后一首歌
    final miniPlayerSpace = bottomInset + 64 + 16;
    return LiquidGlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const SizedBox.shrink(),
        ),
      body: AdaptiveContentPadding(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: _ArtistHeader(detail: _detail, fallback: widget.artist),
                  ),
                  if (_isInitialLoading)
                    const _ArtistDetailSkeleton()
                  else if (_errorMessage case final message?)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _ArtistDetailError(
                        message: message,
                        onRetry: _loadInitial,
                      ),
                    )
                  else ...[
                    if (_albums.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _ArtistAlbumSection(
                          albums: _albums,
                          onTap: _openAlbum,
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: _SongSectionHeader(
                        count: _songs.length,
                        onPlayAll: _songs.isEmpty
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
                        child: _EmptyArtistSongs(),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        sliver: SliverList.separated(
                          itemCount: _songs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final song = _songs[index];
                            return _ArtistSongRow(
                              song: song,
                              auth: widget.auth,
                              player: widget.player,
                              onTap: () => widget.player.playSong(
                                song,
                                queue: List<Song>.of(_songs),
                              ),
                            );
                          },
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _ArtistLoadMoreFooter(
                          hasMore: _hasMore,
                          isLoading: _isLoadingMore,
                          errorMessage: _loadMoreError,
                          onRetry: _loadMore,
                        ),
                      ),
                      // 底部留白：播放中时为 MiniPlayer 预留空间，
                      // 防止卡片遮挡导致用户点不到最底部的几首歌。
                      SliverToBoxAdapter(
                        child: AnimatedBuilder(
                          animation: widget.player,
                          builder: (context, _) {
                            final hasSong = widget.player.currentSong != null;
                            return SizedBox(height: hasSong ? miniPlayerSpace : 0);
                          },
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
              bottom: bottomInset + 16,
              child: MiniPlayer(
                player: widget.player,
                auth: widget.auth,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({required this.detail, required this.fallback});

  final ArtistDetail? detail;
  final ArtistRef fallback;

  @override
  Widget build(BuildContext context) {
    final avatar = detail?.avatarUrl ?? fallback.avatarUrl;
    final topPadding = MediaQuery.paddingOf(context).top;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: SizedBox(
        height: topPadding + 286,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (avatar == null)
              const _ArtistPosterFallback()
            else
              Image.network(
                avatar,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (context, error, stackTrace) =>
                    const _ArtistPosterFallback(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .20),
                    Colors.black.withValues(alpha: .06),
                    Colors.black.withValues(alpha: .58),
                  ],
                  stops: const [0, .48, 1],
                ),
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 26,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    detail?.name ?? fallback.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .22),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        detail?.birthday?.isNotEmpty == true
                            ? '生日 ${detail!.birthday}'
                            : '歌手 ID ${detail?.id ?? fallback.id}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: .88),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistPosterFallback extends StatelessWidget {
  const _ArtistPosterFallback();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .90),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .80),
          ],
        ),
      ),
      child: Icon(
        Icons.person_rounded,
        size: 88,
        color: Colors.white.withValues(alpha: .86),
      ),
    );
  }
}

/// 歌手专辑横向区块。
class _ArtistAlbumSection extends StatelessWidget {
  const _ArtistAlbumSection({required this.albums, required this.onTap});

  final List<ArtistAlbum> albums;
  final ValueChanged<ArtistAlbum> onTap;

  @override
  Widget build(BuildContext context) {
    return AppHorizontalRail<ArtistAlbum>(
      title: '专辑 ${albums.length}',
      items: albums,
      height: 168,
      itemWidth: 120,
      topPadding: 4,
      headerPadding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      itemBuilder: (context, album) => _ArtistAlbumCard(
        album: album,
        onTap: () => onTap(album),
      ),
    );
  }
}


class _ArtistAlbumCard extends StatelessWidget {
  const _ArtistAlbumCard({required this.album, required this.onTap});

  final ArtistAlbum album;
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
              child: Artwork(url: album.coverUrl, size: 120),
            ),
            const SizedBox(height: 6),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            if (album.publishDate case final date?)
              Text(
                date,
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

class _SongSectionHeader extends StatelessWidget {
  const _SongSectionHeader({required this.count, required this.onPlayAll});

  final int count;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 0 ? '歌曲' : '热门歌曲 $count',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          TextButton.icon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放'),
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.primary,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistSongRow extends StatelessWidget {
  const _ArtistSongRow({
    required this.song,
    required this.auth,
    required this.player,
    required this.onTap,
  });

  final Song song;
  final AuthController auth;
  final PlayerController player;
  final VoidCallback onTap;

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
                Stack(
                  children: [
                    Artwork(url: song.coverUrl, size: 50, borderRadius: 9),
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
                        [
                          song.artist,
                          if (song.albumName?.isNotEmpty == true)
                            song.albumName!,
                        ].join(' · '),
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
                          onTap: () => showAddToPlaylistSheet(
                            context: context,
                            auth: auth,
                            song: song,
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

class _ArtistDetailSkeleton extends StatelessWidget {
  const _ArtistDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      sliver: SliverList.list(
        children: [
          const _SkeletonBox(width: 110, height: 22, radius: 8),
          const SizedBox(height: 18),
          for (var index = 0; index < 8; index++) ...[
            const _SkeletonSongRow(),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _SkeletonSongRow extends StatelessWidget {
  const _SkeletonSongRow();

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
              _SkeletonBox(width: 150, height: 14, radius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        _SkeletonBox(width: 42, height: 14, radius: 6),
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

class _EmptyArtistSongs extends StatelessWidget {
  const _EmptyArtistSongs();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        '暂无歌曲',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ArtistLoadMoreFooter extends StatelessWidget {
  const _ArtistLoadMoreFooter({
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
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
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
        padding: EdgeInsets.fromLTRB(18, 14, 18, 30),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
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

class _ArtistDetailError extends StatelessWidget {
  const _ArtistDetailError({required this.message, required this.onRetry});

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
          Text('歌手页面加载失败', style: Theme.of(context).textTheme.titleLarge),
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
