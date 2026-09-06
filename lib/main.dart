import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import 'config/app_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client.dart';
import 'services/cache_service.dart';
import 'services/device_info_service.dart';
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

  runApp(KaMusicApp(
    client: client,
    api: api,
    audioHandler: audioHandler,
    themeController: themeController,
  ));
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
    _auth.restore();
    _downloads.initialize();
    _restorePlaybackState();
  }

  /// 恢复上次的播放队列和进度。
  Future<void> _restorePlaybackState() async {
    await _player.restoreQueueState();
    // 开机自启播放（推荐歌单）开启时，不预加载上次的歌曲：首页的自动播放逻辑
    // 会用每日推荐歌单接管，避免恢复队列与自动播放竞争覆盖同一播放源。
    if (await PlayerController.isAutoPlayOnStartup()) {
      return;
    }
    // “恢复上次播放列表”开启时：恢复上次队列/进度并自动播放（与推荐歌单互斥，
    // 不会走到上述分支）。本地无记录则尝试服务端「继续播放」。
    if (await PlayerController.isResumeLastPlaylistOnStartup()) {
      if (_player.currentSong != null) {
        unawaited(_player.prepareRestoredSong(autoPlay: true));
        return;
      }
      try {
        final latest = await _api.latestListenSongs();
        if (_player.currentSong != null || latest.songs.isEmpty) return;
        _player.restoreFromServerQueue(latest.songs);
        unawaited(_player.prepareRestoredSong(autoPlay: true));
      } catch (_) {
        // 服务端恢复失败静默忽略，保持空状态。
      }
      return;
    }
    if (_player.currentSong != null) {
      unawaited(_player.prepareRestoredSong());
      return;
    }
    // 本地无播放记录时，尝试用服务端「继续播放」信息恢复。
    try {
      final latest = await _api.latestListenSongs();
      if (_player.currentSong != null || latest.songs.isEmpty) return;
      _player.restoreFromServerQueue(latest.songs);
      unawaited(_player.prepareRestoredSong());
    } catch (_) {
      // 服务端恢复失败静默忽略，保持空状态。
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (!_player.desktopLyricsEnabled) return;
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
          themeMode: ThemeMode.system,
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
                child: _SystemUiOverlay(child: child ?? const SizedBox.shrink()),
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
