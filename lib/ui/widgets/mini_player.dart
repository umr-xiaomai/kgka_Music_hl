import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../pages/player_page.dart';
import 'artwork.dart';

/// 全局通用的悬浮液态玻璃音乐唱片控制器（Floating Liquid Glass Disc Pod）。
/// 在所有二级页面底部居中悬浮，与主页底栏唱片无缝位置与空间衔接。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({
    super.key,
    required this.player,
    required this.auth,
    this.onOpenPlayer,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onOpenPlayer;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  bool _appInBackground = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    WidgetsBinding.instance.addObserver(this);
    _syncRotation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state != AppLifecycleState.resumed;
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotationController.dispose();
    super.dispose();
  }

  void _syncRotation() {
    if (widget.player.isPlaying && !_appInBackground) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  void _openPlayerByRoute(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) =>
            PlayerPage(player: widget.player, auth: widget.auth),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final tween = Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic));
          return SlideTransition(
            position: animation.drive(tween),
            child: ClipRect(child: child),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 仅车机模式隐藏（由左侧播放面板替代）；普通横屏仍显示。
    if (isLandscape && ThemeController.instance.carModeEnabled) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return RepaintBoundary(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
        animation: widget.player,
        builder: (context, _) {
          _syncRotation();
          final song = widget.player.currentSong;
          if (song == null) {
            return const SizedBox.shrink();
          }

          final durationMs = widget.player.duration.inMilliseconds;
          final positionMs = widget.player.position.inMilliseconds;
          final progress = (durationMs > 0 ? (positionMs / durationMs) : 0.0)
              .clamp(0.0, 1.0);

          return Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // iOS 26 超柔焦散深度悬浮阴影
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: .50)
                        : const Color(0x18000000),
                    blurRadius: 28,
                    spreadRadius: -2,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: .25)
                        : const Color(0x0C000000),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                  if (!isDark)
                    BoxShadow(
                      color: Colors.white.withValues(alpha: .95),
                      blurRadius: 10,
                      spreadRadius: 1,
                      offset: const Offset(0, -1),
                    ),
                ],
              ),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // iOS 26 极透微光物理透镜折射渐变
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [
                                const Color(0xFF1E2433).withValues(alpha: .55),
                                const Color(0xFF10141D).withValues(alpha: .38),
                              ]
                            : [
                                Colors.white.withValues(alpha: .55),
                                Colors.white.withValues(alpha: .28),
                              ],
                      ),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: .22)
                            : Colors.white.withValues(alpha: .95),
                        width: 1.2,
                      ),
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onOpenPlayer ?? () => _openPlayerByRoute(context),
                      onLongPress: () {
                        HapticFeedback.lightImpact();
                        widget.player.togglePlay();
                      },
                      child: Center(
                        child: SizedBox.square(
                          dimension: 46,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // 1. 外圈环形播放进度条（仅显示已播放进度弧线）
                              SizedBox.square(
                                dimension: 46,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 2.2,
                                  strokeCap: StrokeCap.round,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    colorScheme.primary,
                                  ),
                                  backgroundColor: Colors.transparent,
                                ),
                              ),
                              // 2. 内部黑胶唱片/专辑封面
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: .20),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: ClipOval(
                                  child: RepaintBoundary(
                                    child: RotationTransition(
                                      turns: _rotationController,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Artwork(
                                            url: song.coverUrl,
                                            size: 38,
                                            borderRadius: 38,
                                          ),
                                          // 唱片同心圆边缘纹理
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white.withValues(alpha: .25),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: const SizedBox.expand(),
                                          ),
                                          // 中心轴孔微光
                                          Center(
                                            child: Container(
                                              width: 6,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: isDark
                                                    ? const Color(0xFF0F131A)
                                                    : Colors.white,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white.withValues(alpha: .6),
                                                  width: 0.8,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
    );
  }
}
