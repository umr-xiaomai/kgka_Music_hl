import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../models/music_models.dart';
import 'toast.dart';

/// 收藏按钮的两种形态：
/// - [FavoriteIconButton]：用于歌曲列表行尾（播放队列、专辑/歌单曲目）。
/// - [FavoriteBadge]：小圆形角标，叠加在迷你播放器的黑胶唱片上。
///
/// 两者共用同一套交互：展示当前收藏状态、点击切换、失败回滚并提示。
class FavoriteAction {
  const FavoriteAction._();

  /// 当前歌曲是否已收藏。
  static bool isLiked(AuthController auth, Song song) => auth.isLiked(song);

  /// 是否允许操作：目前仅酷狗音源支持收藏。
  static bool canToggle(Song song) => song.source == SongSource.kugou;

  /// 执行收藏/取消收藏。
  ///
  /// 收藏依赖登录态与「我喜欢」歌单：未登录或歌单未加载时直接提示，
  /// 避免用户点击后没有任何反馈。
  static Future<void> toggle(
    BuildContext context,
    AuthController auth,
    Song song,
  ) async {
    if (!canToggle(song)) {
      Toast.info('该音源暂不支持收藏');
      return;
    }
    if (!auth.isLoggedIn) {
      Toast.info('请先登录后再收藏');
      return;
    }
    if (auth.likedPlaylist == null) {
      Toast.info('收藏列表加载中，请稍后重试');
      return;
    }
    try {
      await auth.toggleLike(song);
    } catch (_) {
      if (!context.mounted) return;
      Toast.error('操作失败，请稍后重试');
    }
  }
}

/// 列表行尾的收藏图标按钮。
class FavoriteIconButton extends StatelessWidget {
  const FavoriteIconButton({
    super.key,
    required this.song,
    required this.auth,
    this.size = 40,
    this.iconSize = 20,
  });

  final Song song;
  final AuthController auth;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = FavoriteAction.isLiked(auth, song);
        final enabled = FavoriteAction.canToggle(song);
        return Tooltip(
          message: liked ? '取消收藏' : '收藏',
          child: IconButton(
            onPressed: enabled
                ? () => FavoriteAction.toggle(context, auth, song)
                : null,
            iconSize: iconSize,
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: size, height: size),
            padding: EdgeInsets.zero,
            icon: Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: liked
                  ? Colors.redAccent
                  : colorScheme.onSurfaceVariant.withValues(alpha: .78),
            ),
          ),
        );
      },
    );
  }
}

/// 叠加在迷你播放器唱片右上角的收藏角标。
class FavoriteBadge extends StatelessWidget {
  const FavoriteBadge({
    super.key,
    required this.song,
    required this.auth,
    this.size = 22,
  });

  final Song song;
  final AuthController auth;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = FavoriteAction.isLiked(auth, song);
        final enabled = FavoriteAction.canToggle(song);
        return Tooltip(
          message: liked ? '取消收藏' : '收藏',
          child: Material(
            color: (isDark ? const Color(0xFF1E2433) : Colors.white).withValues(
              alpha: .92,
            ),
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: .28),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled
                  ? () => FavoriteAction.toggle(context, auth, song)
                  : null,
              child: SizedBox.square(
                dimension: size,
                child: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: size * .58,
                  color: liked
                      ? Colors.redAccent
                      : (enabled
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.onSurfaceVariant.withValues(
                                alpha: .4,
                              )),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
