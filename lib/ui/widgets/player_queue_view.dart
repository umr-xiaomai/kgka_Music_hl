import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import 'favorite_button.dart';
import 'marquee_text.dart';
import 'scroll_to_list_row.dart';
import 'song_artwork.dart';

class PlayerQueueView extends StatefulWidget {
  const PlayerQueueView({
    super.key,
    required this.player,
    required this.auth,
    this.onSongSelected,
    this.onClear,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onSongSelected;
  final VoidCallback? onClear;

  @override
  State<PlayerQueueView> createState() => _PlayerQueueViewState();
}

class _PlayerQueueViewState extends State<PlayerQueueView> {
  final _scrollController = ScrollController();
  final _listKey = GlobalKey();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final player = widget.player;
        final queue = player.queue;
        final currentIndex = player.currentIndex;
        final colors = Theme.of(context).colorScheme;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放队列 · ${queue.length} 首',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (widget.onClear case final onClear?)
                    TextButton(
                      onPressed: queue.length > 1 ? onClear : null,
                      child: const Text('清空'),
                    ),
                  IconButton(
                    tooltip: '定位到当前歌曲',
                    icon: const Icon(Icons.my_location_rounded),
                    onPressed: currentIndex < 0
                        ? null
                        : () => scrollToListRow(
                            controller: _scrollController,
                            listKey: _listKey,
                            index: currentIndex,
                          ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: queue.isEmpty
                  ? const Center(child: Text('播放队列为空'))
                  : CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        SliverPrototypeExtentList.builder(
                          key: _listKey,
                          itemCount: queue.length,
                          prototypeItem: const ListTile(
                            leading: SizedBox.square(dimension: 44),
                            title: Text('曲目', maxLines: 1),
                            subtitle: Text('歌手', maxLines: 1),
                            trailing: SizedBox.square(dimension: 48),
                          ),
                          itemBuilder: (context, index) {
                            final song = queue[index];
                            final active = index == currentIndex;
                            return ListTile(
                              selected: active,
                              selectedTileColor: colors.primary.withValues(
                                alpha: .12,
                              ),
                              leading: SongArtwork(song: song, size: 44),
                              title: active
                                  ? MarqueeText(
                                      text: song.title,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: colors.primary,
                                      ),
                                    )
                                  : Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FavoriteIconButton(
                                    song: song,
                                    auth: widget.auth,
                                  ),
                                  if (active)
                                    Icon(
                                      player.isPlaying
                                          ? Icons.equalizer_rounded
                                          : Icons.pause_rounded,
                                      color: colors.primary,
                                    ),
                                ],
                              ),
                              onTap: () {
                                widget.onSongSelected?.call();
                                unawaited(
                                  player.playSong(
                                    song,
                                    queue: queue,
                                    preservePersonalFmSession:
                                        player.isPersonalFmActive,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
