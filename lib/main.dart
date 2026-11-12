import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import 'config/app_config.dart';
import 'models/music_models.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client.dart';
import 'services/cache_service.dart';
import 'services/deep_link_service.dart';
import 'services/device_info_service.dart';
import 'services/log_service.dart';
import 'services/download_service.dart';
import 'services/music_audio_handler.dart';
import 'services/music_api.dart';
import 'ui/adaptive_layout.dart';
import 'ui/app_theme.dart';
import 'ui/pages/app_shell.dart';
import 'ui/pages/login_page.dart';
import 'ui/widgets/toast.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.instance.init();
  await AppConfig.loadCustomBaseUrl();

  final client = ApiClient();
  final api = MusicApi(client);
  final audioHandler = await AudioService.init(
    builder: MusicAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'kgka_music_hl.playback',
      androidNotificationChannelName: 'KA Music 播放控制',
      androidStopForegroundOnPause: false,
    ),
  );

  final themeController = ThemeController();
  // 先检测车机，再加载设置：首次安装时据检测结果决定车机模式默认值。
  await themeController.detectAutomotive(const DeviceInfoService());
  await themeController.load();

  runApp(
    KaMusicApp(
      client: client,
      api: api,
      audioHandler: audioHandler,
      themeController: themeController,
    ),
  );
}

class KaMusicApp extends StatefulWidget {
  const KaMusicApp({
    super.key,
    required this.client,
    required this.api,
    required this.audioHandler,
    required this.themeController,
  });

  final ApiClient client;
  final MusicApi api;
  final MusicAudioHandler audioHandler;
  final ThemeController themeController;

  @override
  State<KaMusicApp> createState() => _KaMusicAppState();
}

class _KaMusicAppState extends State<KaMusicApp> with WidgetsBindingObserver {
  late final ApiClient _client;
  late final MusicApi _api;
  late final CacheService _cacheService;
  late final DownloadService _downloadService;
  late final DownloadController _downloads;
  late final AuthController _auth;
  late final PlayerController _player;
  late final ThemeController _theme;
  late final LocalMusicController _localMusic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _api = widget.api;
    _cacheService = CacheService();
    _downloadService = DownloadService();
    _downloads = DownloadController(_downloadService, _api);
    _auth = AuthController(_api, _cacheService);
    _localMusic = LocalMusicController();
    _player = PlayerController(_api, widget.audioHandler)
      ..downloadController = _downloads
      ..cacheService = _cacheService
      ..localMusic = _localMusic;
    _theme = widget.themeController;
    _wireSystemMediaFavorite();
    _auth.restore();
    _downloads.initialize();
    _restorePlaybackState();
    DeepLinkService.initialize(player: _player, api: _api);
  }

  /// 把收藏能力接入系统媒体通知（锁屏/状态栏下拉的播放器）。
  ///
  /// audio_service 0.18 的 MediaControl.custom 会在 Android 13+ 的系统
  /// 媒体控制中渲染自定义按钮（占用自定义动作槽位）；点击经插件转发到
  /// [MusicAudioHandler.customAction]，最终执行 [_toggleFavoriteFromControls]。
  void _wireSystemMediaFavorite() {
    widget.audioHandler.attachFavoriteControl(
      isFavorite: () {
        final song = _player.currentSong;
        return song != null && _auth.isLiked(song);
      },
      onToggle: _toggleFavoriteFromControls,
    );
    // 收藏状态、登录态、歌单加载、切歌都会改变按钮图标/可用性。
    _auth.addListener(_refreshSystemMediaControls);
    _player.addListener(_refreshSystemMediaControls);
  }

  /// 收藏状态等外部变化后刷新系统媒体通知。
  void _refreshSystemMediaControls() {
    if (!mounted) return;
    widget.audioHandler.refreshMediaControls();
  }

  /// 系统媒体通知收藏按钮的点击处理：与界面内 FavoriteAction 同一守卫逻辑，
  /// 走酷狗「我喜欢」歌单接口，失败回滚由 AuthController 内部处理。
  Future<void> _toggleFavoriteFromControls() async {
    final song = _player.currentSong;
    if (song == null) return;
    if (song.source != SongSource.kugou) {
      Toast.info('该音源暂不支持收藏');
      return;
    }
    if (!_auth.isLoggedIn) {
      Toast.info('请先登录后再收藏');
      return;
    }
    if (_auth.likedPlaylist == null) {
      Toast.info('收藏列表加载中，请稍后重试');
      return;
    }
    try {
      await _auth.toggleLike(song);
    } catch (_) {
      Toast.error('操作失败，请稍后重试');
    }
  }

  /// 恢复上次的播放队列和进度。
  Future<void> _restorePlaybackState() async {
    // 如果用户在本地状态读取完成前已经主动点歌，恢复流程会取消，
    // 避免已保存的旧队列覆盖用户刚刚选择的歌曲。
    if (!await _player.restoreQueueState()) return;
    final restoredSong = _player.currentSong;
    // 开机自启播放（推荐歌单）开启时，不预加载上次的歌曲：首页的自动播放逻辑
    // 会用每日推荐歌单接管，避免恢复队列与自动播放竞争覆盖同一播放源。
    if (await PlayerController.isAutoPlayOnStartup()) {
      return;
    }
    // “恢复上次播放列表”开启时：恢复上次队列/进度并自动播放（与推荐歌单互斥，
    // 不会走到上述分支）。本地无记录则尝试服务端「继续播放」。
    if (await PlayerController.isResumeLastPlaylistOnStartup()) {
      if (restoredSong != null) {
        if (!identical(_player.currentSong, restoredSong)) return;
        unawaited(
          _player.prepareRestoredSong(
            autoPlay: true,
            expectedSong: restoredSong,
          ),
        );
        return;
      }
      // 本地恢复期间用户已主动点歌，不再用服务端记录覆盖。
      if (_player.currentSong != null) return;
      try {
        final latest = await _api.latestListenSongs();
        if (_player.currentSong != null || latest.songs.isEmpty) return;
        _player.restoreFromServerQueue(latest.songs);
        final serverRestoredSong = _player.currentSong;
        if (serverRestoredSong != null) {
          unawaited(
            _player.prepareRestoredSong(
              autoPlay: true,
              expectedSong: serverRestoredSong,
            ),
          );
        }
      } catch (_) {
        // 服务端恢复失败静默忽略，保持空状态。
      }
      return;
    }
    if (restoredSong != null) {
      if (!identical(_player.currentSong, restoredSong)) return;
      unawaited(_player.prepareRestoredSong(expectedSong: restoredSong));
      return;
    }
    // 读取开关期间用户已主动点歌，不能把这首新歌当成旧记录预加载。
    if (_player.currentSong != null) return;
    // 本地无播放记录时，尝试用服务端「继续播放」信息恢复。
    try {
      final latest = await _api.latestListenSongs();
      if (_player.currentSong != null || latest.songs.isEmpty) return;
      _player.restoreFromServerQueue(latest.songs);
      final serverRestoredSong = _player.currentSong;
      if (serverRestoredSong != null) {
        unawaited(
          _player.prepareRestoredSong(expectedSong: serverRestoredSong),
        );
      }
    } catch (_) {
      // 服务端恢复失败静默忽略，保持空状态。
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_refreshSystemMediaControls);
    _player.removeListener(_refreshSystemMediaControls);
    widget.audioHandler.detachFavoriteControl();
    _auth.dispose();
    // 退出前保存播放状态
    _player.persistCurrentStateSync();
    _player.dispose();
    _downloads.dispose();
    _localMusic.dispose();
    _downloadService.dispose();
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _player.setAppForeground(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _player.setAppForeground(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _theme.applyOrientations(AdaptiveLayout.isTablet(context));
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: Toast.navigatorKey,
          themeMode: _theme.themeMode,
          theme: AppTheme.light(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          darkTheme: AppTheme.dark(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          builder: (context, child) {
            // 全局字体大小（保留系统无障碍缩放）。
            final baseScale = MediaQuery.textScalerOf(context).scale(1.0);
            final textScaler = TextScaler.linear(baseScale * _theme.fontScale);
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: _AppBackground(
                themeController: _theme,
                child: _SystemUiOverlay(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },
          home: AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              if (!_auth.isRestoring && !_auth.isLoggedIn) {
                return LoginPage(auth: _auth, api: _api);
              }

              return AppShell(
                api: _api,
                auth: _auth,
                player: _player,
                cache: _cacheService,
                downloads: _downloads,
                theme: _theme,
                localMusic: _localMusic,
              );
            },
          ),
        );
      },
    );
  }
}

/// 全局背景图层。
///
/// 当用户启用了自定义背景图时，在所有页面内容下方显示背景图，
/// 并叠加半透明遮罩（由 [ThemeController.backgroundOpacity] 控制）。
class _AppBackground extends StatefulWidget {
  const _AppBackground({required this.themeController, required this.child});

  final ThemeController themeController;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  FileImage? _imageProvider;
  String? _cachedPath;

  @override
  void initState() {
    super.initState();
    widget.themeController.addListener(_onThemeChanged);
    _updateProvider();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheBackground();
  }

  @override
  void didUpdateWidget(covariant _AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeController != widget.themeController) {
      oldWidget.themeController.removeListener(_onThemeChanged);
      widget.themeController.addListener(_onThemeChanged);
      _updateProvider();
      _precacheBackground();
    }
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    _updateProvider();
    _precacheBackground();
    setState(() {});
  }

  void _updateProvider() {
    final path = widget.themeController.backgroundImagePath;
    if (path != null && path != _cachedPath) {
      _cachedPath = path;
      _imageProvider = FileImage(File(path));
    }
  }

  void _precacheBackground() {
    if (_imageProvider != null) {
      precacheImage(_imageProvider!, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.themeController.backgroundEnabled;
    final path = widget.themeController.backgroundImagePath;

    if (!enabled || path == null || _imageProvider == null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayColor = isDark ? const Color(0xFF06070A) : Colors.white;
    final opacity = widget.themeController.backgroundOpacity;

    return Stack(
      children: [
        // 背景图层（复用同一个 FileImage provider，避免重复解码）
        Positioned.fill(
          child: Image(
            image: _imageProvider!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩（opacity 越大遮罩越透明，背景图越明显）
        Positioned.fill(
          child: ColoredBox(
            color: overlayColor.withValues(alpha: 1.0 - opacity),
          ),
        ),
        // 页面内容
        widget.child,
      ],
    );
  }
}

class _SystemUiOverlay extends StatelessWidget {
  const _SystemUiOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: child,
    );
  }
}
