import 'dart:ui';
import 'package:flutter/material.dart';
import '../design_tokens.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/mini_player.dart';
import '../widgets/artwork.dart';
import '../widgets/car_left_player_panel.dart';
import '../adaptive_layout.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  var _index = 1; // Default to '推荐' tab (index 1) in landscape
  var _lastHomeTab = 1; // Tracks the last active Home sub-tab (1 for Recommend, 2 for Radio)
  final _navigatorKey = GlobalKey<NavigatorState>();

  // 播放页覆盖层
  bool _playerVisible = false;
  late final AnimationController _playerController;
  double _playerDragStartValue = 1.0; // 手势开始时动画值
  double _playerDragDistance = 0; // 跟随手指的累计拖动距离
  double _playerScreenWidth = 1;

  @override
  void initState() {
    super.initState();
    _playerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _playerController.dispose();
    super.dispose();
  }

  void _openPlayer() {
    setState(() => _playerVisible = true);
    _playerController.forward(from: 0);
  }

  void _closePlayer() {
    _playerController.reverse().then((_) {
      if (mounted) {
        setState(() => _playerVisible = false);
      }
    });
  }

  Widget _wrapPlayerOverlay(Widget shell) {
    return Stack(
      children: [
        shell,
        if (_playerVisible)
          Positioned.fill(
            child: _buildPlayerOverlay(),
          ),
      ],
    );
  }

  Widget _buildPlayerOverlay() {
    // 左缘手势条起点：TopBar（SafeArea + 8 padding + 48 按钮）之下，
    // 避免 opaque 条遮挡播放页左上角返回按钮。
    final topBarBottom = MediaQuery.paddingOf(context).top + 64;
    return Stack(
      children: [
        SlideTransition(
          position: _playerController.drive(
            Tween<Offset>(
              begin: const Offset(1.0, 0.0),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)),
          ),
          // ClipRect 必须放在 SlideTransition 内部、包着 PlayerPage：
          // 1) 播放页内的 _ArtworkBackground 使用 OverflowBox 把封面放大
          //    1.5 倍 + ImageFiltered(blur 34)，模糊层是 offscreen layer
          //    合成，会绕过外层 Stack 的 clip；ClipRect 作为 ImageFiltered
          //    的 RenderObject 祖先能约束其绘制边界；
          // 2) ClipRect 跟随 SlideTransition 移动，裁剪边界 = 移动后的
          //    播放页边界，关闭时放大溢出的模糊封面被裁掉，不再盖在底层
          //    首页上造成"模糊遮罩"。
          child: RepaintBoundary(
            child: ClipRect(
              child: PlayerPage(
                player: widget.player,
                auth: widget.auth,
                onClose: _closePlayer,
              ),
            ),
          ),
        ),
        // 左缘手势条：opaque 独占左缘触摸（Stack 命中测试自上而下，命中后
        // 不再交给下层 PageView），保证"从屏幕左边向右滑动关闭"一定生效。
        Positioned(
          left: 0,
          top: topBarBottom,
          bottom: 0,
          width: 60,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              _playerDragStartValue = _playerController.value;
              _playerScreenWidth = MediaQuery.sizeOf(context).width;
              _playerDragDistance = 0;
            },
            onHorizontalDragUpdate: (details) {
              final delta = details.primaryDelta ?? 0;
              _playerDragDistance += delta;
              final maxDrag = _playerScreenWidth;
              final progress = (_playerDragStartValue -
                      (_playerDragDistance / maxDrag))
                  .clamp(0.0, 1.0);
              _playerController.value = progress;
            },
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              final shouldClose = _playerDragDistance >
                      _playerScreenWidth * 0.25 ||
                  (velocity > 200 && _playerDragDistance > 0);
              _playerDragDistance = 0;
              if (shouldClose) {
                _closePlayer();
              } else {
                _playerController.animateBack(1.0);
              }
            },
          ),
        ),
      ],
    );
  }

  int _getPortraitIndex() {
    return _index == 0 ? 1 : 0;
  }

  void _setPortraitIndex(int index) {
    setState(() {
      _index = index == 0 ? _lastHomeTab : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppShortcutScope(
      player: widget.player,
      child: _buildShell(context),
    );
  }

  Widget _buildShell(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    // 车机布局：仅在横屏且开启车机模式时启用（左侧播放面板 + 顶栏）。
    // 关闭时回到普通布局（宽屏用 NavigationRail），与原项目行为一致；
    // 平板横屏适配留给上游后续开发。
    if (isLandscape && widget.theme.carModeEnabled) {
      // 车机模式下文字相对放大（保留系统无障碍设置）。
      final baseTextScaler = MediaQuery.textScalerOf(context);
      final scaledTextScaler = _RelativeTextScaler(
        base: baseTextScaler,
        multiplier: ThemeController.carModeFontScaleFactor,
      );
      return _wrapPlayerOverlay(MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaledTextScaler),
        child: PopScope(
          // 拦截 Android 返回键：先尝试 pop 内层 Navigator（搜索/设置/歌单等
          // push 到内层 Navigator 的页面），内层无法 pop 时才退出应用。
          // 不加 PopScope 会导致返回键只 pop root Navigator（只有一个 AppShell
          // route），从歌单页面返回直接退出应用。
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_playerVisible) {
              _closePlayer();
              return;
            }
            final nav = _navigatorKey.currentState;
            if (nav != null && nav.canPop()) {
              nav.pop();
            } else {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            body: Row(
              children: [
                // ExcludeSemantics 规避 CarLeftPlayerPanel 频繁响应 player 更新
                // 导致的 Windows AXTree 竞态崩溃（Flutter Windows 引擎 bug）
                ExcludeSemantics(
                  child: CarLeftPlayerPanel(
                    player: widget.player,
                    auth: widget.auth,
                    onOpenPlayer: _openPlayer,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: Navigator(
                    key: _navigatorKey,
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute(
                        builder: (navContext) {
                          final homePage = HomePage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            cache: widget.cache,
                            theme: widget.theme,
                            downloads: widget.downloads,
                            localMusic: widget.localMusic,
                            sectionIndex: _index == 2 ? 1 : 0,
                            onTabSwitch: (index) {
                              setState(() {
                                _index = index;
                                if (index == 1 || index == 2) {
                                  _lastHomeTab = index;
                                }
                              });
                            },
                          );

                          final libraryPage = LibraryPage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            downloads: widget.downloads,
                            theme: widget.theme,
                            localMusic: widget.localMusic,
                          );

                          final pages = [homePage, libraryPage];
                          final activePageIndex = _index == 0 ? 1 : 0;

                          return Scaffold(
                            body: Column(
                              children: [
                                _buildCarTopNavBar(navContext, colorScheme),
                                const Divider(height: 1),
                                Expanded(
                                  child: _LazyIndexedStack(
                                    index: activePageIndex,
                                    children: pages,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
    }

    // Original Portrait Layout
    final useNavRail = size.width >= 720;
    final portraitIndex = _getPortraitIndex();

    final homePage = HomePage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      cache: widget.cache,
      theme: widget.theme,
      downloads: widget.downloads,
      localMusic: widget.localMusic,
      sectionIndex: _index == 2 ? 1 : 0,
      onTabSwitch: (index) {
        setState(() {
          _index = index;
          if (index == 1 || index == 2) {
            _lastHomeTab = index;
          }
        });
      },
    );

    final libraryPage = LibraryPage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      downloads: widget.downloads,
      theme: widget.theme,
      localMusic: widget.localMusic,
    );

    final pages = [homePage, libraryPage];

    Widget mainContent = Stack(
      children: [
        Positioned.fill(
          child: _LazyIndexedStack(
            index: portraitIndex,
            children: pages,
          ),
        ),
        if (useNavRail)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 16,
            child: MiniPlayer(
              player: widget.player,
              auth: widget.auth,
              onOpenPlayer: _openPlayer,
            ),
          ),
      ],
    );

    if (useNavRail) {
      mainContent = Row(
        children: [
          NavigationRail(
            selectedIndex: portraitIndex,
            onDestinationSelected: _setPortraitIndex,
            backgroundColor: colorScheme.surfaceContainerLow,
            labelType: NavigationRailLabelType.all,
            selectedIconTheme: IconThemeData(color: colorScheme.primary),
            unselectedIconTheme: IconThemeData(
              color: colorScheme.onSurfaceVariant,
            ),
            selectedLabelTextStyle: TextStyle(
              color: colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
            unselectedLabelTextStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: Text('首页'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: Text('我的'),
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: mainContent),
        ],
      );
    }

    return _wrapPlayerOverlay(PopScope(
      canPop: !_playerVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_playerVisible) {
          _closePlayer();
        }
      },
      child: Scaffold(
        extendBody: true,
        backgroundColor: Colors.transparent,
        body: LiquidGlassBackground(
          child: AdaptiveContentPadding(child: mainContent),
        ),
        bottomNavigationBar: useNavRail
            ? null
            : _LiquidGlassBottomBar(
                currentIndex: portraitIndex,
                onTap: _setPortraitIndex,
                player: widget.player,
                onOpenPlayer: _openPlayer,
              ),
      ),
    ));
  }

  Widget _buildCarTopNavBar(BuildContext context, ColorScheme colorScheme) {
    final tabs = ['我的', '推荐', '电台'];
    final topInset = MediaQuery.paddingOf(context).top;
    return Container(
      // 顶部加上状态栏高度，避免导航栏内容被状态栏遮挡
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      height: 72 + topInset, // Increased from 64
      child: Row(
        children: [
          // Search Pill Button
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            child: Container(
              height: 46, // Increased from 38
              padding: const EdgeInsets.symmetric(horizontal: 20), // Increased from 16
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: .54,
                ),
                borderRadius: BorderRadius.circular(AppRadius.xxl), // Increased from 19 (height/2)
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    color: colorScheme.onSurfaceVariant,
                    size: 22, // Increased from 20
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 16, // Increased from default
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 32), // Increased from 24
          // Choice Chip Tabs
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in tabs.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10), // Increased from 6
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: Text(
                          entry.$2,
                          style: TextStyle(
                            fontSize: 17, // Increased from default
                            fontWeight: _index == entry.$1
                                ? FontWeight.w900
                                : FontWeight.w600,
                          ),
                        ),
                        selected: _index == entry.$1,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _index = entry.$1;
                              if (entry.$1 == 1 || entry.$1 == 2) {
                                _lastHomeTab = entry.$1;
                              }
                            });
                          }
                        },
                        selectedColor: colorScheme.primary.withValues(
                          alpha: 0.18,
                        ),
                        labelStyle: TextStyle(
                          color: _index == entry.$1
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        backgroundColor: Colors.transparent,
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), // Added explicit padding
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md), // Added explicit shape for larger tap area
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Settings Icon
          IconButton(
            tooltip: '设置',
            iconSize: 28, // Increased iconSize from default (24)
            icon: const Icon(Icons.settings_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    api: widget.api,
                    auth: widget.auth,
                    player: widget.player,
                    theme: widget.theme,
                    downloads: widget.downloads,
                    cache: widget.cache,
                    localMusic: widget.localMusic,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 只在首次被选中时才构建对应 child 的 [IndexedStack]。
///
/// 普通 IndexedStack 会一次性构建全部 children，导致所有页面
/// 都在 initState 中发起网络请求。这里通过懒构建
/// 保证只有被访问过的 tab 才会真正初始化，避免重复请求与重复监听。
class _LazyIndexedStack extends StatefulWidget {
  const _LazyIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<_LazyIndexedStack> {
  final _built = <int>{};

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
  }

  @override
  void didUpdateWidget(covariant _LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built.add(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _built.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}

/// 在已有 [TextScaler] 基础上再乘固定倍数（Flutter 内置 TextScaler 无 `*` 运算符）。
class _RelativeTextScaler extends TextScaler {
  const _RelativeTextScaler({required this.base, required this.multiplier});

  final TextScaler base;
  final double multiplier;

  @override
  double scale(double fontSize) => base.scale(fontSize) * multiplier;

  @override
  double get textScaleFactor {
    // ignore: deprecated_member_use
    final baseFactor = base.textScaleFactor;
    return baseFactor * multiplier;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _RelativeTextScaler &&
          base == other.base &&
          multiplier == other.multiplier;

  @override
  int get hashCode => Object.hash(base, multiplier);

  @override
  String toString() => '$base × $multiplier';
}

/// 全局快捷键作用域（桌面端）：空格播放/暂停，左右键切歌。
class AppShortcutScope extends StatelessWidget {
  const AppShortcutScope({
    super.key,
    required this.player,
    required this.child,
  });

  final PlayerController player;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space):
            const _PlayPauseIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _NextIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _PreviousIntent(),
      },
      child: Actions(
        actions: {
          _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
            onInvoke: (_) {
              // 输入框聚焦时不拦截空格。
              final focused = FocusManager.instance.primaryFocus;
              final editing = focused
                  ?.context
                  ?.findAncestorWidgetOfExactType<EditableText>();
              if (editing == null) player.togglePlay();
              return null;
            },
          ),
          _NextIntent: CallbackAction<_NextIntent>(
            onInvoke: (_) {
              player.next();
              return null;
            },
          ),
          _PreviousIntent: CallbackAction<_PreviousIntent>(
            onInvoke: (_) {
              player.previous();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}
class _NextIntent extends Intent {
  const _NextIntent();
}
class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

/// 悬浮胶囊形态的液态玻璃底栏（集成居中圆形音乐封面与环形进度条）。
class _LiquidGlassBottomBar extends StatelessWidget {
  const _LiquidGlassBottomBar({
    required this.currentIndex,
    required this.onTap,
    required this.player,
    required this.onOpenPlayer,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final PlayerController player;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return RepaintBoundary(
      child: Align(
        alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          28,
          0,
          28,
          bottomInset > 0 ? bottomInset : 14,
        ),
        child: Container(
          height: 60,
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            // iOS 26 超柔焦散深度悬浮阴影
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: .45)
                    : const Color(0x14000000),
                blurRadius: 36,
                spreadRadius: -4,
                offset: const Offset(0, 14),
              ),
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: .20)
                    : const Color(0x0A000000),
                blurRadius: 12,
                offset: const Offset(0, 4),
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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(100),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(100),
                  // iOS 26 极透微光物理透镜折射渐变
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? [
                            const Color(0xFF1E2433).withValues(alpha: .52),
                            const Color(0xFF10141D).withValues(alpha: .36),
                          ]
                        : [
                            Colors.white.withValues(alpha: .52),
                            Colors.white.withValues(alpha: .26),
                          ],
                  ),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: .22)
                        : Colors.white.withValues(alpha: .92),
                    width: 1.1,
                  ),
                ),
                child: Row(
                  children: [
                    _LiquidNavItem(
                      icon: Icons.home_outlined,
                      activeIcon: Icons.home_rounded,
                      label: '首页',
                      isSelected: currentIndex == 0,
                      onTap: () => onTap(0),
                    ),
                    _CenterPlayerDisc(
                      player: player,
                      onOpenPlayer: onOpenPlayer,
                    ),
                    _LiquidNavItem(
                      icon: Icons.person_outline_rounded,
                      activeIcon: Icons.person_rounded,
                      label: '我的',
                      isSelected: currentIndex == 1,
                      onTap: () => onTap(1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// 底栏中央圆形黑胶唱片封面与环形进度条控制器。
class _CenterPlayerDisc extends StatefulWidget {
  const _CenterPlayerDisc({
    required this.player,
    required this.onOpenPlayer,
  });

  final PlayerController player;
  final VoidCallback onOpenPlayer;

  @override
  State<_CenterPlayerDisc> createState() => _CenterPlayerDiscState();
}

class _CenterPlayerDiscState extends State<_CenterPlayerDisc>
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
  void didUpdateWidget(covariant _CenterPlayerDisc oldWidget) {
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: widget.player,
      builder: (context, _) {
        _syncRotation();
        final song = widget.player.currentSong;
        final hasSong = song != null;
        final durationMs = widget.player.duration.inMilliseconds;
        final positionMs = widget.player.position.inMilliseconds;
        final progress = (durationMs > 0 ? (positionMs / durationMs) : 0.0)
            .clamp(0.0, 1.0);

        return RepaintBoundary(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenPlayer,
            onLongPress: () {
              if (hasSong) {
                HapticFeedback.lightImpact();
                widget.player.togglePlay();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox.square(
                dimension: 46,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 1. 外圈环形播放进度条（仅显示已播放进度弧线）
                    SizedBox.square(
                      dimension: 46,
                      child: CircularProgressIndicator(
                        value: hasSong ? progress : 0.0,
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
                        child: hasSong
                            ? RepaintBoundary(
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
                                            color: const Color(0xFF0F131A),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.black.withValues(alpha: .35),
                                              width: 0.8,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Container(
                                color: colorScheme.primaryContainer,
                                child: Icon(
                                  Icons.music_note_rounded,
                                  size: 20,
                                  color: colorScheme.primary,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LiquidNavItem extends StatelessWidget {
  const _LiquidNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selectedColor = colorScheme.primary;
    final unselectedColor = colorScheme.onSurfaceVariant.withValues(alpha: .85);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(100),
          splashColor: selectedColor.withValues(alpha: .12),
          highlightColor: selectedColor.withValues(alpha: .06),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: child,
                    ),
                    child: Icon(
                      isSelected ? activeIcon : icon,
                      key: ValueKey<bool>(isSelected),
                      color: isSelected ? selectedColor : unselectedColor,
                      size: isSelected ? 23 : 22,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                      color: isSelected ? selectedColor : unselectedColor,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
