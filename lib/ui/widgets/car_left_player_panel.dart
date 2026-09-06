import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'marquee_text.dart';
import 'toast.dart';

class CarLeftPlayerPanel extends StatelessWidget {
  const CarLeftPlayerPanel({
    super.key,
    required this.player,
    required this.auth,
    required this.onOpenPlayer,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isSmallScreen = size.width < 960;
    final panelWidth = isSmallScreen ? 320.0 : 380.0;
    final panelPadding = isSmallScreen ? 14.0 : 20.0;

    if (size.height < 150) {
      return SizedBox(width: panelWidth);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        if (song == null) {
          final height = MediaQuery.sizeOf(context).height;
          final verticalPadding = height < 400 ? 10.0 : 24.0;
          final sysPadding = MediaQuery.paddingOf(context);
          return Container(
            width: panelWidth,
            color: isDark
                ? colorScheme.surfaceContainerLow
                : const Color(0xFFF2F4F7),
            padding: EdgeInsets.fromLTRB(
              panelPadding,
              sysPadding.top + verticalPadding,
              panelPadding,
              sysPadding.bottom + verticalPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, colorScheme),
                const Expanded(
                  child: Center(
                    child: Text(
                      '暂无播放歌曲',
                      style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return AnimatedBuilder(
          animation: auth,
          builder: (context, _) {
            final liked = auth.isLiked(song);
            final height = MediaQuery.sizeOf(context).height;
            final sysPadding = MediaQuery.paddingOf(context);
            final availableHeight = height - sysPadding.top - sysPadding.bottom;

            final isShortScreen = height < 500;
            final verticalPadding = isShortScreen ? 8.0 : 20.0;
            final bottomGap = isShortScreen ? 10.0 : 32.0;
            final controlsHeight = isShortScreen ? 68.0 : 80.0;

            final artworkSizeSubtractor = isShortScreen ? 250.0 : 340.0;
            final artworkSize = (availableHeight - artworkSizeSubtractor).clamp(80.0, 280.0);

            final gapSize = isShortScreen ? 10.0 : 20.0;
            final titleGap = isShortScreen ? 14.0 : 24.0;
            final progressGap = isShortScreen ? 16.0 : 28.0;

            final buttonMinWidth = isSmallScreen ? 42.0 : 52.0;
            final playBtnSize = isSmallScreen ? 56.0 : 64.0;
            final playIconSize = isSmallScreen ? 32.0 : 40.0;

            return Container(
              width: panelWidth,
              // 加上状态栏（top）和车机系统栏（bottom）的高度，避免被系统 UI 隐藏
              padding: EdgeInsets.fromLTRB(
                panelPadding,
                sysPadding.top + verticalPadding,
                panelPadding,
                sysPadding.bottom + verticalPadding,
              ),
              color: isDark
                  ? colorScheme.surfaceContainerLow
                  : const Color(0xFFF2F4F7), // Light grey background
              child: ClipRect(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, colorScheme),
                  const Spacer(),
                  // Album Art
                  Center(
                    child: GestureDetector(
                      onTap: onOpenPlayer,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          child: Artwork(
                            url: song.coverUrl,
                            size: artworkSize,
                            borderRadius: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: gapSize),
                  // Title + Artist + Heart
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MarqueeText(
                              text: song.title,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: song.source == SongSource.kugou
                            ? () => auth.toggleLike(song)
                            : null,
                        icon: Icon(
                          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: liked ? Colors.redAccent : colorScheme.onSurfaceVariant,
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: titleGap),
                  // Progress Bar
                  Builder(
                    builder: (context) {
                      final duration = player.duration;
                      final position = player.smoothPosition;
                      final max = duration.inMilliseconds <= 0
                          ? 1.0
                          : duration.inMilliseconds.toDouble();
                      final value = position.inMilliseconds
                          .clamp(0, max.toInt())
                          .toDouble();

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                              activeTrackColor: colorScheme.primary,
                              inactiveTrackColor: isDark
                                  ? Colors.white.withValues(alpha: 0.16)
                                  : Colors.black.withValues(alpha: 0.08),
                              thumbColor: colorScheme.primary,
                            ),
                            child: Slider(
                              value: value,
                              max: max,
                              onChanged: (val) =>
                                  player.previewSeek(Duration(milliseconds: val.round())),
                              onChangeEnd: (val) =>
                                  player.seek(Duration(milliseconds: val.round())),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  SizedBox(height: progressGap),
                  Container(
                    height: controlsHeight,
                    decoration: BoxDecoration(
                      color: isDark
                          ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.8)
                          : Colors.black.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(40),
                    ),
                    padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 8 : 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Loop mode
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints(minWidth: buttonMinWidth, minHeight: buttonMinWidth),
                          icon: Icon(
                            _getPlaybackModeIcon(player.playbackMode),
                            size: isSmallScreen ? 24 : 28,
                            color: colorScheme.onSurface,
                          ),
                          onPressed: player.cyclePlaybackMode,
                        ),
                        // Prev
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints(minWidth: buttonMinWidth, minHeight: buttonMinWidth),
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            size: isSmallScreen ? 30 : 36,
                            color: colorScheme.onSurface,
                          ),
                          onPressed: player.isPreparing ? null : player.previous,
                        ),
                        // Play/Pause (large circle/white or themed)
                        Container(
                          width: playBtnSize,
                          height: playBtnSize,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: colorScheme.onPrimary,
                              size: playIconSize,
                            ),
                            onPressed: player.isPreparing ? null : player.togglePlay,
                          ),
                        ),
                        // Next
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints(minWidth: buttonMinWidth, minHeight: buttonMinWidth),
                          icon: Icon(
                            Icons.skip_next_rounded,
                            size: isSmallScreen ? 30 : 36,
                            color: colorScheme.onSurface,
                          ),
                          onPressed: player.isPreparing ? null : player.next,
                        ),
                        // Queue
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints(minWidth: buttonMinWidth, minHeight: buttonMinWidth),
                          icon: Icon(
                            Icons.queue_music_rounded,
                            size: isSmallScreen ? 24 : 28,
                            color: colorScheme.onSurface,
                          ),
                          onPressed: () => _showQueue(context),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  SizedBox(height: bottomGap),
                ],
              ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.music_note_rounded,
            color: colorScheme.primary,
            size: 18,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'KA Music',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: colorScheme.onSurface,
              ),
        ),
      ],
    );
  }

  IconData _getPlaybackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }

  void _showQueue(BuildContext context) {
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Text(
                        '播放队列',
                        style: Theme.of(sheetContext)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${player.queue.length} 首',
                        style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: player.queue.length > 1
                            ? () {
                                final current = player.currentSong;
                                if (current == null) return;
                                Navigator.of(sheetContext).pop();
                                player.playSong(current, queue: [current]);
                                Toast.success('已清空播放队列');
                              }
                            : null,
                        child: Text(
                          '清空',
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: AnimatedBuilder(
                    animation: player,
                    builder: (context, _) {
                      if (player.queue.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Text(
                              '播放队列为空',
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        );
                      }
                      return ListView.separated(
                        shrinkWrap: true,
                        itemCount: player.queue.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) {
                          final song = player.queue[index];
                          final active = player.currentSong?.hash == song.hash;
                          return ListTile(
                            selected: active,
                            leading: Artwork(url: song.coverUrl, size: 40, borderRadius: 8),
                            title: active
                                ? MarqueeText(
                                    text: song.title,
                                    style: TextStyle(
                                      color: colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            subtitle: Text(song.artist),
                            trailing: active
                                ? Icon(
                                    player.isPlaying ? Icons.equalizer_rounded : Icons.pause_rounded,
                                    color: colorScheme.primary,
                                  )
                                : null,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              player.playSong(song, queue: player.queue);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return '00:00';
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
