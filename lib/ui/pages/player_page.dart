import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../adaptive_layout.dart';
import '../design_tokens.dart';
import '../widgets/song_artwork.dart';
import '../widgets/status_bar_overlay.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/cover_service.dart';
import '../../services/lyric_converter.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/blurred_lyric_view.dart';
import '../widgets/retryable_network_image.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../widgets/marquee_text.dart';
import '../widgets/clickable_artist_text.dart';
import 'comment_page.dart';
import 'song_detail_page.dart';
import 'desktop_lyrics_settings_page.dart';
import 'rhythm_game/rhythm_game_page.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.player,
    required this.auth,
    this.onClose, // 新增：由宿主（AppShell）提供关闭回调
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onClose; // 新增

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _screenChannel = MethodChannel('kgka_music_hl/screen');
  Song? _currentSong;
  bool _isScreenOn = false;

  @override
  void initState() {
    super.initState();
    _currentSong = widget.player.currentSong;
    widget.player.addListener(_onPlayerStateChanged);
    if (widget.player.keepScreenOnEnabled) {
      unawaited(_setKeepScreenOn(true));
      _isScreenOn = true;
    }
    // 不在此处调用 setPreferredOrientations：方向策略由 ThemeController 全局管理。
    // 如果这里解锁方向，即使用户在设置里没开横屏模式，旋转手机时播放页也会
    // 跟着旋转，影响竖屏体验。
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerStateChanged);
    if (_isScreenOn) {
      unawaited(_setKeepScreenOn(false));
      _isScreenOn = false;
    }
    super.dispose();
  }

  void _onPlayerStateChanged() {
    final newSong = widget.player.currentSong;
    final keepScreenOn = widget.player.keepScreenOnEnabled;
    if (_isScreenOn != keepScreenOn) {
      _isScreenOn = keepScreenOn;
      unawaited(_setKeepScreenOn(keepScreenOn));
    }
    if (_currentSong?.hash != newSong?.hash ||
        _currentSong?.id != newSong?.id ||
        (_currentSong == null) != (newSong == null)) {
      setState(() {
        _currentSong = newSong;
      });
    }
  }

  Future<void> _setKeepScreenOn(bool enabled) async {
    try {
      await _screenChannel.invokeMethod<void>('setKeepScreenOn', enabled);
    } on MissingPluginException {
      // Non-Android targets can ignore this page-level screen setting.
    } on PlatformException {
      // Keeping playback usable is more important than failing the page open.
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = _currentSong;
    if (song == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    return _PlayerBody(
      player: widget.player,
      auth: widget.auth,
      song: song,
      onClose: widget.onClose ?? () => Navigator.of(context).pop(),
      onQueue: () => _showQueue(context),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return AnimatedBuilder(
          animation: widget.player,
          builder: (context, _) {
            return ListView.builder(
              itemCount: widget.player.queue.length,
              itemBuilder: (context, index) {
                final song = widget.player.queue[index];
                final active = widget.player.currentSong?.hash == song.hash;
                return ListTile(
                  selected: active,
                  leading: SongArtwork(song: song, size: 44),
                  title: active
                      ? MarqueeText(
                          text: song.title,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
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
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.player.playSong(
                      song,
                      queue: widget.player.queue,
                      preservePersonalFmSession:
                          widget.player.isPersonalFmActive,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _PlayerBody extends StatefulWidget {
  const _PlayerBody({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

Future<void> _showAudioQualityPicker(
  BuildContext context,
  PlayerController player,
) async {
  final quality = await showAudioQualitySheet(
    context: context,
    selected: player.audioQuality,
    title: '切换音质',
    subtitle: '会重新加载当前歌曲并尽量保持播放进度',
  );
  if (quality == null) {
    return;
  }

  await player.setAudioQuality(quality, reloadCurrent: true);
  Toast.success('已切换到 ${quality.label}');
}

class _PlayerBodyState extends State<_PlayerBody> {
  final _pageController = PageController();
  var _page = 0;
  var _pageScrolling = false;
  bool? _lastSystemUiLandscape;

  bool get _lyricPageVisible => _page == 1 || _pageScrolling;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.height < 150 || size.width < 150) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }
    final landscape = size.width > size.height;
    _syncSystemUi(landscape);
    // 横屏分栏布局是车机专属，普通横屏仍用竖屏的翻页布局。
    final isCarLayout = landscape && ThemeController.instance.carModeEnabled;
    // 手表等极小屏（shortestSide < 300dp）：一屏放不下全部内容，
    // 播放页需要切换成"纵向可滚动 + 压缩尺寸"的布局。
    final isWatch = AdaptiveLayout.isWatchSize(size);

    return StatusBarOverlay(
      brightness: Brightness.dark,
      child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              _ArtworkBackground(
                song: widget.song,
              ),
            SafeArea(
              // 横屏时同样需要处理顶部状态栏和底部系统导航栏（如车机空调控制栏）的遮挡。
              // 竖屏已由外层 Scaffold 处理，这里对所有方向统一保留 SafeArea。
              child: Column(
                children: [
                  if (!isCarLayout)
                    _TopBar(
                      player: widget.player,
                      auth: widget.auth,
                      song: widget.song,
                      onClose: widget.onClose,
                      onArtistTap: _openArtist,
                      compact: isWatch,
                    ),
                  Expanded(
                    child: isCarLayout
                        ? ExcludeSemantics(
                            child: _LandscapePlayerContent(
                              player: widget.player,
                              auth: widget.auth,
                              song: widget.song,
                              onClose: widget.onClose,
                              onQueue: widget.onQueue,
                              onArtistTap: _openArtist,
                            ),
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: _handlePageScrollNotification,
                            child: PageView(
                              controller: _pageController,
                              allowImplicitScrolling: true,
                              onPageChanged: (value) =>
                                  _setPageState(page: value),
                              children: [
                                _PosterPlayerPage(
                                  key: const PageStorageKey(
                                    'poster-player-page',
                                  ),
                                  player: widget.player,
                                  song: widget.song,
                                  onQueue: widget.onQueue,
                                  isPageVisible: _page == 0 || _pageScrolling,
                                  isWatch: isWatch,
                                ),
                                _LyricPlayerPage(
                                  key: const PageStorageKey(
                                    'lyric-player-page',
                                  ),
                                  player: widget.player,
                                  song: widget.song,
                                  isPageVisible: _lyricPageVisible,
                                  isWatch: isWatch,
                                ),
                              ],
                            ),
                          ),
                  ),
                  if (!isCarLayout) _PageDots(page: _page, compact: isWatch),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _syncSystemUi(bool landscape) {
    if (_lastSystemUiLandscape == landscape) {
      return;
    }
    _lastSystemUiLandscape = landscape;
    // 仅在 Android 上保持沉浸式全屏；iOS 上重置 SystemUiMode 会污染状态栏前景色，
    // 由本页的 StatusBarOverlay（及全局 _SystemUiOverlay）负责状态栏样式。
    if (Platform.isAndroid) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      });
    }
  }

  bool _handlePageScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) {
      return false;
    }

    if (notification is ScrollStartNotification) {
      _setPageState(scrolling: true);
    } else if (notification is ScrollEndNotification) {
      final page = (_pageController.page ?? _page.toDouble()).round().clamp(
        0,
        1,
      );
      _setPageState(page: page, scrolling: false);
    }
    return false;
  }

  void _setPageState({int? page, bool? scrolling}) {
    final nextPage = page ?? _page;
    final nextScrolling = scrolling ?? _pageScrolling;

    if (nextPage == _page && nextScrolling == _pageScrolling) {
      return;
    }

    setState(() {
      _page = nextPage;
      _pageScrolling = nextScrolling;
    });
  }

  Future<void> _openArtist(Song song) async {
    await openArtistDetail(
      context: context,
      api: widget.player.api,
      auth: widget.auth,
      player: widget.player,
      song: song,
    );
  }
}

enum _LyricDisplayMode {
  lyricsWithTranslation,
  lyricsOnly,
  lyricsWithRomanization,
}

List<_LyricDisplayMode> _availableLyricDisplayModes(List<LyricLine> lyrics) {
  if (lyrics.isEmpty) {
    return const [];
  }

  final modes = <_LyricDisplayMode>[];
  final hasTranslation = lyrics.any(
    (line) => line.translation != null && line.translation!.isNotEmpty,
  );
  final hasRomanization = lyrics.any(
    (line) => line.romanization != null && line.romanization!.isNotEmpty,
  );

  if (hasTranslation) {
    modes.add(_LyricDisplayMode.lyricsWithTranslation);
  }
  modes.add(_LyricDisplayMode.lyricsOnly);
  if (hasRomanization) {
    modes.add(_LyricDisplayMode.lyricsWithRomanization);
  }
  return modes;
}

String _lyricDisplayModeLabel(_LyricDisplayMode mode) {
  return switch (mode) {
    _LyricDisplayMode.lyricsWithTranslation => '歌词 + 翻译',
    _LyricDisplayMode.lyricsWithRomanization => '歌词 + 音译',
    _LyricDisplayMode.lyricsOnly => '仅歌词',
  };
}

class _ArtworkBackground extends StatefulWidget {
  const _ArtworkBackground({
    required this.song,
  });

  final Song song;

  @override
  State<_ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<_ArtworkBackground> {
  /// 背景封面：自带封面按 360px 取图；缺封面时由 CoverService 补取后刷新。
  String? _coverUrl;

  @override
  void initState() {
    super.initState();
    _coverUrl = widget.song.coverUrl;
    unawaited(_resolveCover());
  }

  Future<void> _resolveCover() async {
    if (_coverUrl != null && _coverUrl!.isNotEmpty) return;
    final song = widget.song;
    final url = await CoverService.instance.resolve(song);
    if (!mounted || url == null || url.isEmpty) return;
    if (widget.song.hash != song.hash || widget.song.id != song.id) return;
    setState(() => _coverUrl = url);
  }

  @override
  void didUpdateWidget(covariant _ArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash ||
        oldWidget.song.id != widget.song.id ||
        oldWidget.song.coverUrl != widget.song.coverUrl) {
      _coverUrl = widget.song.coverUrl;
      unawaited(_resolveCover());
    }
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = _coverUrl;

    return RepaintBoundary(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 始终显示渐变兜底背景，避免封面加载期间出现纯黑背景
            const _FallbackBackground(),
            if (coverUrl != null)
              ClipRect(
                child: ThemeController.instance.liquidGlassEnabled
                    ? ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: 18,
                          sigmaY: 18,
                        ),
                        child: RetryableNetworkImage(
                          url: coverUrl,
                          cacheWidth: 720,
                          cacheHeight: 720,
                        ),
                      )
                    : RetryableNetworkImage(
                        url: coverUrl,
                        cacheWidth: 720,
                        cacheHeight: 720,
                      ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .32),
                    Colors.black.withValues(alpha: .56),
                    Colors.black.withValues(alpha: .82),
                  ],
                ),
              ),
            ),
            ColoredBox(color: Colors.black.withValues(alpha: .12)),
          ],
        ),
      ),
    );
  }
}

class _FallbackBackground extends StatelessWidget {
  const _FallbackBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF153D35), Color(0xFF061219), Color(0xFF2C1320)],
        ),
      ),
    );
  }
}

class _LandscapePlayerContent extends StatelessWidget {
  const _LandscapePlayerContent({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 350;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 14 : 24,
            compact ? 4 : 10,
            compact ? 16 : 30,
            compact ? 24 : 36,
          ),
          child: Column(
            children: [
              _LandscapeHeader(
                player: player,
                auth: auth,
                song: song,
                onClose: onClose,
                compact: compact,
                onArtistTap: onArtistTap,
              ),
              SizedBox(height: compact ? 2 : 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 9,
                      child: _LandscapeArtworkShowcase(
                        player: player,
                        song: song,
                        compact: compact,
                      ),
                    ),
                    SizedBox(width: compact ? 18 : 34),
                    Expanded(
                      flex: 12,
                      child: _LandscapeRightPanel(
                        player: player,
                        auth: auth,
                        onQueue: onQueue,
                        compact: compact,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LandscapeHeader extends StatelessWidget {
  const _LandscapeHeader({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.compact,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final bool compact;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = auth.isLiked(song);
        return SizedBox(
          height: compact ? 40 : 48,
          child: Row(
            children: [
              _LandscapeHeaderButton(
                tooltip: '返回',
                size: compact ? 38 : 44,
                iconSize: compact ? 30 : 34,
                onPressed: onClose,
                icon: Icons.keyboard_arrow_left_rounded,
              ),
              SizedBox(width: compact ? 10 : 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      text: song.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .92),
                        fontSize: compact ? 14 : 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (!compact)
                      ClickableArtistText(
                        song: song,
                        api: player.api,
                        auth: auth,
                        player: player,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.white.withValues(alpha: .7),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                  ],
                ),
              ),
              _LandscapeHeaderButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                size: compact ? 38 : 44,
                iconSize: compact ? 22 : 24,
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              SizedBox(width: compact ? 6 : 8),
              _LandscapeHeaderButton(
                tooltip: '更多',
                size: compact ? 38 : 44,
                iconSize: compact ? 22 : 24,
                onPressed: () => _showMoreSheet(context),
                icon: Icons.more_horiz_rounded,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      actions: [
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速播放',
          subtitle: player.playbackSpeedLabel,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质：${player.audioQuality.label}',
          subtitle: '切换当前播放音质',
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '试听高潮',
          subtitle: '播放歌曲高潮片段',
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          subtitle: player.audioEffectsLabel,
          onTap: () => showAudioEffectsSheet(context: context, player: player),
        ),
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () =>
                showAddToPlaylistSheet(context: context, auth: auth, song: song),
          ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时播放',
          subtitle: player.isSleepTimerActive
              ? '剩余 ${_formatSleepRemaining(player.sleepTimerRemaining)}'
              : player.isSleepFinishCurrentSong
                  ? '播完歌曲后停止'
                  : null,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),
        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            subtitle: player.desktopLyricsEnabled ? '已开启' : '已关闭',
            onTap: () async {
              Navigator.of(context).pop();
              await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _LandscapeHeaderButton extends StatelessWidget {
  const _LandscapeHeaderButton({
    required this.tooltip,
    required this.size,
    required this.iconSize,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            color: Colors.white,
            iconSize: iconSize,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: size, height: size),
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}

class _LandscapeArtworkShowcase extends StatefulWidget {
  const _LandscapeArtworkShowcase({
    required this.player,
    required this.song,
    required this.compact,
  });

  final PlayerController player;
  final Song song;
  final bool compact;

  @override
  State<_LandscapeArtworkShowcase> createState() =>
      _LandscapeArtworkShowcaseState();
}

class _LandscapeArtworkShowcaseState extends State<_LandscapeArtworkShowcase>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    );
    widget.player.addListener(_syncRotation);
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant _LandscapeArtworkShowcase oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_syncRotation);
      widget.player.addListener(_syncRotation);
    }
    if (oldWidget.song.hash != widget.song.hash) {
      _rotationController.value = 0;
    }
    _syncRotation();
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncRotation);
    _rotationController.dispose();
    super.dispose();
  }

  void _syncRotation() {
    if (widget.player.isPlaying) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        if (velocity < -200) {
          widget.player.next();
        } else if (velocity > 200) {
          widget.player.previous();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = math.min(constraints.maxWidth, constraints.maxHeight);
          final discSize = (available * (widget.compact ? .84 : .9))
              .clamp(150.0, 330.0)
              .toDouble();
          final coverSize = discSize * (widget.compact ? .58 : .70);

          return Center(
            // 旋转唱片是纯装饰动画，排除语义树防止 Windows AXTree 竞态崩溃，并外包 RepaintBoundary 隔离图层
            child: RepaintBoundary(
              child: ExcludeSemantics(
                child: SizedBox.square(
                dimension: discSize,
                child: AnimatedBuilder(
                  animation: _rotationController,
                  builder: (context, child) {
                    return Transform.rotate(
                      angle: _rotationController.value * math.pi * 2,
                      child: child,
                    );
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(alpha: .88),
                              Colors.white.withValues(alpha: .58),
                              Colors.white.withValues(alpha: .22),
                            ],
                            stops: const [0, .62, 1],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .26),
                              blurRadius: 30,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: const SizedBox.expand(),
                      ),
                      for (final ratio in const [.36, .52, .68, .82])
                        SizedBox.square(
                          dimension: discSize * ratio,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .16),
                              ),
                            ),
                          ),
                        ),
                      ClipOval(
                        child: SongArtwork(
                          song: widget.song,
                          size: coverSize,
                          borderRadius: coverSize,
                        ),
                      ),
                      SizedBox.square(
                        dimension: discSize * .08,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: .82),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        },
      ),
    );
  }
}

class _LandscapeRightPanel extends StatelessWidget {
  const _LandscapeRightPanel({
    required this.player,
    required this.auth,
    required this.onQueue,
    required this.compact,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback onQueue;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    return LayoutBuilder(
      builder: (context, constraints) {
        final veryTight = constraints.maxHeight < 250;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _LandscapeLyricPanel(
                player: player,
                songHash: song?.hash ?? '',
                lyrics: player.lyrics,
                compact: compact || veryTight,
              ),
            ),
            SizedBox(height: veryTight ? 2 : 6),
            _Progress(player: player, bright: true, compact: true),
            SizedBox(height: veryTight ? 0 : 4),
            _Controls(
              player: player,
              bright: true,
              onQueue: onQueue,
              compactOverride: true,
              denseOverride: veryTight,
            ),
          ],
        );
      },
    );
  }
}

class _LandscapeLyricPanel extends StatefulWidget {
  const _LandscapeLyricPanel({
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.compact,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final bool compact;

  @override
  State<_LandscapeLyricPanel> createState() => _LandscapeLyricPanelState();
}

class _LandscapeLyricPanelState extends State<_LandscapeLyricPanel> {
  static const _lyricScaleKey = 'settings.lyric_scale';

  late final LyricController _lyricController;
  late final Ticker _ticker;
  bool _isUserSelecting = false;
  /// 已加载歌词的快照：用于区分"歌词为空但准备中"与"歌词为空且加载完成"。
  List<LyricLine> _loadedLyrics = const [];
  /// 上次的准备状态快照：isPreparing 变化时也要刷新（"正在准备音乐..."->"暂无歌词"）。
  bool _lastPreparing = false;
  double _lyricScale = 1.0;
  late _LyricDisplayMode _displayMode;

  @override
  void initState() {
    super.initState();
    _loadedLyrics = widget.lyrics;
    _lastPreparing = widget.player.isPreparing;
    _displayMode = _initialDisplayMode(_loadedLyrics);
    _loadLyricScale();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seek(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    // 车机全屏布局下，歌词并非由父级 rebuild 传入（_PlayerPage 仅在
    // currentSong 变化时 setState），切歌后 isPreparing/lyrics 的后续变化
    // 必须由本组件自己监听 player，否则歌词会一直卡在"正在准备音乐..."。
    widget.player.addListener(_onPlayerChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  Future<void> _loadLyricScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0);
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.6);
    setState(() => _lyricScale = clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  _LyricDisplayMode _initialDisplayMode(List<LyricLine> lyrics) {
    final modes = _availableLyricDisplayModes(lyrics);
    return modes.isNotEmpty ? modes.first : _LyricDisplayMode.lyricsOnly;
  }

  _LyricDisplayMode _normalizeDisplayMode(
    List<LyricLine> lyrics,
    _LyricDisplayMode currentMode,
  ) {
    final modes = _availableLyricDisplayModes(lyrics);
    if (modes.contains(currentMode)) return currentMode;
    return modes.isNotEmpty ? modes.first : _LyricDisplayMode.lyricsOnly;
  }

  void _toggleDisplayMode() {
    final modes = _availableLyricDisplayModes(_loadedLyrics);
    if (modes.length <= 1) return;
    final idx = modes.indexOf(_displayMode);
    final nextIdx = idx >= 0 ? (idx + 1) % modes.length : 0;
    setState(() {
      _displayMode = modes[nextIdx];
      _syncLyrics();
    });
  }

  @override
  void didUpdateWidget(covariant _LandscapeLyricPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
    }
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.lyrics != widget.lyrics) {
      _loadedLyrics = widget.lyrics;
      _displayMode = _normalizeDisplayMode(_loadedLyrics, _displayMode);
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  /// player 状态变化（切歌/加载完成/歌词到达）时自动刷新，不依赖父级 rebuild。
  void _onPlayerChanged() {
    if (!mounted) return;
    final current = List.of(widget.player.lyrics);
    final changed = !listEquals(current, _loadedLyrics) ||
        _lastPreparing != widget.player.isPreparing;
    if (changed) {
      _loadedLyrics = current;
      _lastPreparing = widget.player.isPreparing;
      _displayMode = _normalizeDisplayMode(_loadedLyrics, _displayMode);
      setState(() {
        _syncLyrics();
        _syncTicker();
      });
      return;
    }
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = _loadedLyrics;
    if (lyrics.isNotEmpty) {
      final mode = _normalizeDisplayMode(lyrics, _displayMode);
      final model = convertToFlutterLyricModel(
        lyrics,
        showTranslation: mode == _LyricDisplayMode.lyricsWithTranslation,
        showRomanization: mode == _LyricDisplayMode.lyricsWithRomanization,
      );
      _lyricController.loadLyricModel(model);
    }
  }

  void _syncTicker() {
    final shouldTick =
        widget.player.isPlaying &&
        _loadedLyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    _lyricController.setProgress(widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = _loadedLyrics;
    if (lyrics.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          player.isPreparing ? '正在准备音乐...' : '暂无歌词',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white.withValues(alpha: .82),
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    final fontSize = (widget.compact ? 26.0 : 34.0) * _lyricScale;
    final inactiveFontSize = (widget.compact ? 18.0 : 24.0) * _lyricScale;
    final translationFontSize = (widget.compact ? 14.0 : 18.0) * _lyricScale;
    final availableModes = _availableLyricDisplayModes(lyrics);
    final canToggleMode = availableModes.length > 1;
    final displayMode = _normalizeDisplayMode(lyrics, _displayMode);

    return Stack(
      children: [
        ExcludeSemantics(
          // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
          child: LyricView(
            controller: _lyricController,
            style: LyricStyles.default1.copyWith(
              textStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
                color: Colors.white.withValues(alpha: .34),
                fontSize: inactiveFontSize,
                height: 1.18,
                fontWeight: FontWeight.w800,
              ),
              activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
                color: Colors.white.withValues(alpha: .34),
                fontSize: fontSize,
                height: 1.18,
                fontWeight: FontWeight.w900,
              ),
              translationStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: Colors.white.withValues(alpha: .42),
                fontSize: translationFontSize,
                height: 1.24,
                fontWeight: FontWeight.w700,
              ),
              lineGap: widget.compact ? 10 : 16,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 24,
                vertical: widget.compact ? 16 : 32,
              ),
              fadeRange: FadeRange(top: 32, bottom: 32),
              textAlign: TextAlign.left,
              contentAlignment: CrossAxisAlignment.start,
              activeHighlightColor: Colors.white,
            ),
          ),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GlassIconButton(
                tooltip: '缩小歌词',
                size: 32,
                onPressed: () => _setLyricScale(_lyricScale - 0.1),
                icon: Icons.text_decrease_rounded,
              ),
              const SizedBox(width: 6),
              _GlassIconButton(
                tooltip: '放大歌词',
                size: 32,
                onPressed: () => _setLyricScale(_lyricScale + 0.1),
                icon: Icons.text_increase_rounded,
              ),
              if (canToggleMode) ...[
                const SizedBox(width: 6),
                _GlassIconButton(
                  tooltip: '切换歌词模式（当前：${_lyricDisplayModeLabel(displayMode)}）',
                  size: 32,
                  onPressed: _toggleDisplayMode,
                  icon: switch (displayMode) {
                    _LyricDisplayMode.lyricsWithTranslation =>
                      Icons.translate_rounded,
                    _LyricDisplayMode.lyricsWithRomanization =>
                      Icons.record_voice_over_rounded,
                    _LyricDisplayMode.lyricsOnly => Icons.lyrics_rounded,
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onArtistTap,
    this.compact = false,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final ValueChanged<Song> onArtistTap;

  /// 手表等极小屏：压缩内边距与按钮尺寸，避免横向溢出。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = auth.isLiked(song);
        final buttonSize = compact ? 32.0 : null;
        return Padding(
          padding: compact
              ? const EdgeInsets.fromLTRB(2, 2, 6, 2)
              : const EdgeInsets.fromLTRB(8, 8, 16, 6),
          child: Row(
            children: [
              if (compact)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onClose,
                  child: const SizedBox.square(
                    dimension: 30,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: '返回',
                  color: Colors.white,
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              SizedBox(width: compact ? 2 : 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MarqueeText(
                      text: song.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: compact ? 13 : null,
                      ),
                    ),
                    ClickableArtistText(
                      song: song,
                      api: player.api,
                      auth: auth,
                      player: player,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .82),
                        fontWeight: FontWeight.w600,
                        fontSize: compact ? 11 : null,
                      ),
                    ),
                  ],
                ),
              ),
              _GlassIconButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                size: buttonSize,
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              SizedBox(width: compact ? 4 : 8),
              _GlassIconButton(
                tooltip: '更多',
                size: buttonSize,
                onPressed: () => _showMoreSheet(context),
                icon: Icons.more_horiz_rounded,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      actions: [
        // Grid actions
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速',
          subtitle: player.playbackSpeedLabel,
          isGrid: true,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质',
          subtitle: player.audioQuality.badge,
          isGrid: true,
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          isGrid: true,
          onTap: () => showAudioEffectsSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '高潮',
          isGrid: true,
          onTap: () async {
            if (!player.isClimaxSupported) {
              Toast.error(
                player.currentSong?.source == SongSource.netease
                    ? '网易云歌曲暂不支持高潮片段'
                    : '这首歌暂不支持高潮片段',
              );
              return;
            }
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时',
          isGrid: true,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),

        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            isGrid: true,
            onTap: () async {
              Navigator.of(context).pop();
              await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              isGrid: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首',
          isGrid: true,
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: player,
            song: song,
          ),
        ),
        // List actions
        SongSheetAction(
          icon: Icons.info_outline_rounded,
          title: '详细信息',
          subtitle: '专辑、发行年份、时长、音源',
          onTap: () => openSongDetailPage(context, song, api: player.api),
        ),
        if (supportsComments(song))
          SongSheetAction(
            icon: Icons.comment_outlined,
            title: '查看评论',
            subtitle: '热门 / 最新、楼层回复',
            onTap: () => openCommentPage(context, song),
          ),
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () =>
                showAddToPlaylistSheet(context: context, auth: auth, song: song),
          ),
      ],
    );
  }
}

String _formatSleepRemaining(Duration? remaining) {
  if (remaining == null || remaining <= Duration.zero) return '';
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _PosterPlayerPage extends StatefulWidget {
  const _PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
    this.isPageVisible = true,
    this.isWatch = false,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;
  final bool isPageVisible;

  /// 手表等极小屏：整页改为纵向滚动，控件尺寸同时压缩。
  final bool isWatch;

  @override
  State<_PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<_PosterPlayerPage>
    with AutomaticKeepAliveClientMixin {
  void _openMoreMenu(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: widget.song,
      actions: [
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速',
          subtitle: widget.player.playbackSpeedLabel,
          isGrid: true,
          onTap: () => showPlaybackSpeedSheet(context: context, player: widget.player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质',
          subtitle: widget.player.audioQuality.badge,
          isGrid: true,
          onTap: () => _showAudioQualityPicker(context, widget.player),
        ),
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          isGrid: true,
          onTap: () => showAudioEffectsSheet(context: context, player: widget.player),
        ),
        SongSheetAction(
          icon: Icons.bedtime_outlined,
          title: '定时关闭',
          subtitle: widget.player.sleepTimerRemaining == null
              ? null
              : formatDuration(widget.player.sleepTimerRemaining!),
          isGrid: true,
          onTap: () => showSleepTimerSheet(context: context, player: widget.player),
        ),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.isWatch) {
          return _buildWatchScrollable(constraints);
        }

        final compact = constraints.maxHeight < 620;
        // 极矮横屏（某些分辨率）下：唱片区弹性缩放，控制按钮永不被挤出屏幕
        final tiny = constraints.maxHeight < 460;
        final artworkMaxWidth = compact ? 250.0 : 330.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 18),
          child: Column(
            children: [
              if (tiny) ...[
                // 高度不足时封面自动缩放，优先保证控制按钮完整可见
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox.square(
                        dimension: artworkMaxWidth,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _openMoreMenu(context),
                          child: Hero(
                            tag: 'player_cover',
                            child: SongArtwork(
                              song: widget.song,
                              size: double.infinity,
                              borderRadius: 8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 矮屏没有歌词预览区，评论入口同样要保留，否则会找不到。
                _CommentEntry(player: widget.player, song: widget.song),
              ] else ...[
                // 常规竖屏/横屏：保持原有固定尺寸布局
                const Spacer(),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: artworkMaxWidth),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openMoreMenu(context),
                      child: Hero(
                        tag: 'player_cover',
                        child: SongArtwork(
                          song: widget.song,
                          size: double.infinity,
                          borderRadius: 8,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: compact ? 14 : 26),
                _PosterLyricPreview(
                  player: widget.player,
                  isPageVisible: widget.isPageVisible,
                ),
                if (!compact) const SizedBox(height: 4),
                _CommentEntry(player: widget.player, song: widget.song),
                const Spacer(),
              ],
              _Progress(player: widget.player, bright: true),
              const SizedBox(height: 10),
              _Controls(
                player: widget.player,
                bright: true,
                onQueue: widget.onQueue,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 手表等极小屏布局：内容一屏放不下，改为纵向滚动。
  ///
  /// 封面按屏宽弹性缩放，歌词预览 / 进度条 / 控制按钮依次排布；
  /// 使用 [AlwaysScrollableScrollPhysics] 保证即使内容刚好铺满也能拖动，
  /// 不会出现"整页滑不动、底部控件看不到"的情况。
  Widget _buildWatchScrollable(BoxConstraints constraints) {
    final artworkSize = (constraints.maxWidth * .58).clamp(64.0, 132.0);
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: artworkSize.toDouble(),
            child: Hero(
              tag: 'player_cover',
              child: SongArtwork(
                song: widget.song,
                size: double.infinity,
                borderRadius: 6,
              ),
            ),
          ),
          const SizedBox(height: 4),
          _PosterLyricPreview(
            player: widget.player,
            isPageVisible: widget.isPageVisible,
            compact: true,
          ),
          const SizedBox(height: 2),
          _CommentEntry(player: widget.player, song: widget.song),
          _Progress(player: widget.player, bright: true, compact: true),
          const SizedBox(height: 2),
          // 控件行最宽约 220dp，小屏上等比缩小到可见区域内，避免横向溢出。
          FittedBox(
            fit: BoxFit.scaleDown,
            child: _Controls(
              player: widget.player,
              bright: true,
              compactOverride: true,
              denseOverride: true,
              onQueue: widget.onQueue,
            ),
          ),
        ],
      ),
    );
  }
}

int _activeLyricIndexFor(List<LyricLine> lyrics, Duration position) {
  if (lyrics.isEmpty) return -1;
  var index = 0;
  for (var i = 0; i < lyrics.length; i++) {
    if (position >= lyrics[i].time) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

class _PosterLyricPreview extends StatefulWidget {
  const _PosterLyricPreview({
    required this.player,
    this.isPageVisible = true,
    this.compact = false,
  });

  final PlayerController player;
  final bool isPageVisible;

  /// 手表等极小屏：缩小行高与字号，减少占用的竖向空间。
  final bool compact;

  @override
  State<_PosterLyricPreview> createState() => _PosterLyricPreviewState();
}

class _PosterLyricPreviewState extends State<_PosterLyricPreview> {
  late final Ticker _ticker;
  final _positionNotifier = ValueNotifier<Duration>(Duration.zero);
  int _currentIndex = -1;
  List<LyricLine> _lastLyrics = const [];
  bool _lastIsPreparing = false;

  @override
  void initState() {
    super.initState();
    _positionNotifier.value = widget.player.smoothPosition;
    _lastLyrics = widget.player.lyrics;
    _lastIsPreparing = widget.player.isPreparing;
    _currentIndex = _activeLyricIndexFor(_lastLyrics, _positionNotifier.value);
    _ticker = Ticker(_onTick);
    widget.player.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _PosterLyricPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_syncTicker);
      widget.player.addListener(_syncTicker);
    }
    if (!widget.player.isScrubbing) {
      _positionNotifier.value = widget.player.smoothPosition;
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncTicker);
    _ticker.dispose();
    _positionNotifier.dispose();
    super.dispose();
  }

  void _syncTicker() {
    final lyricsChanged = !identical(widget.player.lyrics, _lastLyrics);
    final preparingChanged = widget.player.isPreparing != _lastIsPreparing;
    if (lyricsChanged || preparingChanged) {
      _lastLyrics = widget.player.lyrics;
      _lastIsPreparing = widget.player.isPreparing;
      _positionNotifier.value = widget.player.smoothPosition;
      _currentIndex = _activeLyricIndexFor(
        _lastLyrics,
        _positionNotifier.value,
      );
      if (mounted) {
        setState(() {});
      }
    }
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isPlaying &&
        widget.player.lyrics.isNotEmpty &&
        !widget.player.isScrubbing;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    final lyrics = widget.player.lyrics;
    if (lyrics.isEmpty) return;
    final newPos = widget.player.smoothPosition;
    _positionNotifier.value = newPos;
    final newIndex = _activeLyricIndexFor(lyrics, newPos);
    // 只有换行时才调用 setState 重建组件树，避免卡拉OK逐字进度每帧全量 rebuild
    if (newIndex != _currentIndex) {
      setState(() {
        _currentIndex = newIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.player.lyrics;
    final compact = widget.compact;
    if (lyrics.isEmpty) {
      return SizedBox(
        height: compact ? 56 : 104,
        child: Center(
          child: Text(
            widget.player.isPreparing ? '歌词加载中...' : '暂无歌词',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white.withValues(alpha: .78),
              fontWeight: FontWeight.w800,
              fontSize: compact ? 15 : null,
            ),
          ),
        ),
      );
    }

    final index = _currentIndex >= 0 && _currentIndex < lyrics.length
        ? _currentIndex
        : _activeLyricIndexFor(lyrics, _positionNotifier.value);
    final current = lyrics[index];
    final next = index + 1 < lyrics.length ? lyrics[index + 1] : null;
    final currentStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: Colors.white,
      fontSize: compact ? 15 : 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white.withValues(alpha: .46),
      fontSize: compact ? 12 : null,
      height: 1.18,
      fontWeight: FontWeight.w700,
    );

    // 歌词预览每帧更新位置，用 ExcludeSemantics 防止 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: SizedBox(
        height: compact ? 58 : 96,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: Column(
            key: ValueKey(current.time.inMilliseconds),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: compact ? 22 : 36,
                child: _MarqueeSingleLine(
                  textKey: current.time.inMilliseconds,
                  child: _LyricText(
                    line: current,
                    active: true,
                    positionListenable: _positionNotifier,
                    styleOverride: currentStyle,
                    textAlign: TextAlign.center,
                    singleLine: true,
                  ),
                ),
              ),
              SizedBox(height: compact ? 3 : 8),
              SizedBox(
                height: compact ? 16 : 25,
                child: _MarqueeSingleLine(
                  textKey: current.translation != null && current.translation!.isNotEmpty
                      ? current.time.inMilliseconds
                      : (next?.time.inMilliseconds ?? -1),
                  child: Text(
                    current.translation != null && current.translation!.isNotEmpty
                        ? current.translation!
                        : (next?.text ?? ''),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: nextStyle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarqueeSingleLine extends StatefulWidget {
  const _MarqueeSingleLine({required this.child, required this.textKey});

  final Widget child;
  final Object textKey;

  @override
  State<_MarqueeSingleLine> createState() => _MarqueeSingleLineState();
}

class _MarqueeSingleLineState extends State<_MarqueeSingleLine>
    with SingleTickerProviderStateMixin {
  final _viewportKey = GlobalKey();
  final _contentKey = GlobalKey();
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _MarqueeSingleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textKey != widget.textKey) {
      _controller
        ..stop()
        ..reset();
      _overflow = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) {
      return;
    }
    final viewport = _viewportKey.currentContext?.size?.width ?? 0;
    final content = _contentKey.currentContext?.size?.width ?? 0;
    final overflow = math.max(0.0, content - viewport);
    if ((overflow - _overflow).abs() < 1) {
      return;
    }
    setState(() => _overflow = overflow);
    if (overflow > 0) {
      _controller
        ..duration = Duration(milliseconds: (overflow * 42).round() + 2600)
        ..repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          key: _viewportKey,
          child: SizedBox(
            width: constraints.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final offset = _overflow <= 0
                    ? 0.0
                    : -_overflow * _controller.value;
                return Align(
                  alignment: _overflow <= 0
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                );
              },
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(key: _contentKey, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LyricPlayerPage extends StatefulWidget {
  const _LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.isPageVisible,
    this.isWatch = false,
  });

  final PlayerController player;
  final Song song;
  final bool isPageVisible;

  /// 手表等极小屏：压缩内边距、字号与悬浮按钮尺寸。
  final bool isWatch;

  @override
  State<_LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<_LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  late _LyricDisplayMode _displayMode;
  List<LyricLine> _lastLyrics = const [];

  /// 歌词字体缩放倍率（持久化）。
  static const _lyricScaleKey = 'settings.lyric_scale';
  double _lyricScale = 1.0;
  bool _showBottomControls = true;

  bool _lastLyricBlurEnabled = false;
  bool _lastIsPreparing = false;

  @override
  void initState() {
    super.initState();
    _lastLyrics = widget.player.lyrics;
    _lastLyricBlurEnabled = widget.player.lyricBlurEnabled;
    _lastIsPreparing = widget.player.isPreparing;
    _displayMode = _initialLyricDisplayMode(_lastLyrics);
    _loadLyricScale();
    widget.player.addListener(_onPlayerLyricsChanged);
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerLyricsChanged);
    super.dispose();
  }

  void _onPlayerLyricsChanged() {
    final blurChanged = widget.player.lyricBlurEnabled != _lastLyricBlurEnabled;
    final preparingChanged = widget.player.isPreparing != _lastIsPreparing;
    if (widget.player.lyrics != _lastLyrics ||
        blurChanged ||
        preparingChanged) {
      _lastLyrics = widget.player.lyrics;
      _lastLyricBlurEnabled = widget.player.lyricBlurEnabled;
      _lastIsPreparing = widget.player.isPreparing;
      setState(() {
        _displayMode = _normalizeLyricDisplayMode(
          _lastLyrics,
          _displayMode,
        );
      });
    }
  }

  Future<void> _loadLyricScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0);
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.6);
    setState(() => _lyricScale = clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _LyricPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerLyricsChanged);
      widget.player.addListener(_onPlayerLyricsChanged);
    }
    if (oldWidget.song.hash != widget.song.hash ||
        oldWidget.player.lyrics != widget.player.lyrics) {
      _displayMode = _normalizeLyricDisplayMode(
        widget.player.lyrics,
        _displayMode,
      );
    }
  }

  _LyricDisplayMode _initialLyricDisplayMode(List<LyricLine> lyrics) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  _LyricDisplayMode _normalizeLyricDisplayMode(
    List<LyricLine> lyrics,
    _LyricDisplayMode currentMode,
  ) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    if (availableModes.contains(currentMode)) {
      return currentMode;
    }
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  void _toggleLyricDisplayMode() {
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    if (availableModes.length <= 1) {
      return;
    }

    final currentIndex = availableModes.indexOf(_displayMode);
    final nextIndex = currentIndex >= 0
        ? (currentIndex + 1) % availableModes.length
        : 0;
    setState(() => _displayMode = availableModes[nextIndex]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    final canToggleLyricDisplayMode = availableModes.length > 1;
    final displayMode = _normalizeLyricDisplayMode(
      widget.player.lyrics,
      _displayMode,
    );

    return Padding(
      padding: widget.isWatch
          ? const EdgeInsets.fromLTRB(6, 2, 6, 6)
          : const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              setState(() {
                _showBottomControls = !_showBottomControls;
              });
            },
            child: _LyricViewport(
              player: widget.player,
              lyrics: widget.player.lyrics,
              isPreparing: widget.player.isPreparing,
              displayMode: displayMode,
              isPageVisible: widget.isPageVisible,
              lyricScale: _lyricScale,
              compact: widget.isWatch,
            ),
          ),
          // 字体大小调节按钮（左侧底部，左对齐）
          Positioned(
            left: 0,
            bottom: widget.isWatch ? 2 : 16,
            child: AnimatedOpacity(
              opacity: _showBottomControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showBottomControls,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _GlassIconButton(
                      tooltip: '缩小歌词',
                      size: widget.isWatch ? 30 : null,
                      onPressed: () => _setLyricScale(_lyricScale - 0.1),
                      icon: Icons.text_decrease_rounded,
                    ),
                    SizedBox(width: widget.isWatch ? 4 : 8),
                    _GlassIconButton(
                      tooltip: '放大歌词',
                      size: widget.isWatch ? 30 : null,
                      onPressed: () => _setLyricScale(_lyricScale + 0.1),
                      icon: Icons.text_increase_rounded,
                    ),
                    // 歌词页也放一个评论入口，避免必须滑回封面页才能看评论。
                    if (supportsComments(widget.song)) ...[
                      SizedBox(width: widget.isWatch ? 4 : 8),
                      _GlassIconButton(
                        tooltip: '查看评论',
                        size: widget.isWatch ? 30 : null,
                        onPressed: () => openCommentPage(context, widget.song),
                        icon: Icons.comment_outlined,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (canToggleLyricDisplayMode)
            Positioned(
              right: 0,
              bottom: widget.isWatch ? 2 : 16,
              child: AnimatedOpacity(
                opacity: _showBottomControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showBottomControls,
                  child: _GlassIconButton(
                    tooltip: '切换歌词模式（当前：${_lyricDisplayModeLabel(displayMode)}）',
                    size: widget.isWatch ? 30 : null,
                    onPressed: _toggleLyricDisplayMode,
                    icon: switch (displayMode) {
                      _LyricDisplayMode.lyricsWithTranslation =>
                        Icons.translate_rounded,
                      _LyricDisplayMode.lyricsWithRomanization =>
                        Icons.record_voice_over_rounded,
                      _LyricDisplayMode.lyricsOnly => Icons.lyrics_rounded,
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LyricViewport extends StatefulWidget {
  const _LyricViewport({
    required this.player,
    required this.lyrics,
    required this.isPreparing,
    required this.displayMode,
    required this.isPageVisible,
    required this.lyricScale,
    this.compact = false,
  });

  final PlayerController player;
  final List<LyricLine> lyrics;
  final bool isPreparing;
  final _LyricDisplayMode displayMode;
  final bool isPageVisible;
  final double lyricScale;

  /// 手表等极小屏：整体缩小歌词字号与行距。
  final bool compact;

  @override
  State<_LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<_LyricViewport> {
  static const double _lyricAnchorFraction = 0.43;
  static const double _lyricBlurSigma = 3.0;
  static const double _lyricBlurStep = 0.7;

  late final LyricController _lyricController;
  late final Ticker _ticker;
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seek(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    widget.player.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_syncTicker);
      widget.player.addListener(_syncTicker);
    }
    if (oldWidget.lyrics != widget.lyrics ||
        oldWidget.displayMode != widget.displayMode) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncTicker);
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) return;
    final showTranslation =
        widget.displayMode == _LyricDisplayMode.lyricsWithTranslation;
    final showRomanization =
        widget.displayMode == _LyricDisplayMode.lyricsWithRomanization;
    _lyricController.loadLyricModel(
      convertToFlutterLyricModel(
        lyrics,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
      ),
    );
  }

  void _syncTicker() {
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    _lyricController.setProgress(widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Center(
        child: Text(
          widget.isPreparing ? '正在准备音乐...' : '暂无歌词',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: widget.compact ? 15 : null,
          ),
        ),
      );
    }

    final scale = widget.lyricScale;
    // 手表等极小屏上再乘一个基础缩小系数，避免一行歌词占满整屏。
    final baseScale = widget.compact ? .58 : 1.0;
    final mainFontSize = 38.0 * scale * baseScale;
    final inactiveFontSize = 30.0 * scale * baseScale;
    final subtitleFontSize = 20.0 * scale * baseScale;

    final lyricStyle = LyricStyles.default1.copyWith(
      textStyle: Theme.of(context).textTheme.headlineSmall!.copyWith(
        color: Colors.white.withValues(alpha: .30),
        fontSize: inactiveFontSize,
        height: 1.24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: mainFontSize,
        height: 1.24,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
      ),
      translationStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
        color: Colors.white.withValues(alpha: .25),
        fontSize: subtitleFontSize,
        height: 1.3,
        fontWeight: FontWeight.w500,
      ),
      translationActiveColor: Colors.white.withValues(alpha: .95),
      lineGap: 16 * scale * baseScale,
      translationLineGap: 6 * scale * baseScale,
      contentPadding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 8 : 20,
        vertical: 40 * scale * baseScale,
      ),
      anchorPosition: _lyricAnchorFraction,
      activeAnchorPosition: _lyricAnchorFraction,
      fadeRange: FadeRange(top: 40, bottom: 40),
      textAlign: TextAlign.left,
      contentAlignment: CrossAxisAlignment.start,
      activeHighlightColor: Colors.white,
      scrollDuration: const Duration(milliseconds: 480),
      scrollCurve: const Cubic(0.16, 1.0, 0.3, 1.0),
    );

    final blurEnabled = widget.player.lyricBlurEnabled;
    final maxBlurSigma = blurEnabled ? _lyricBlurSigma : 0.0;
    final blurStep = blurEnabled ? _lyricBlurStep : 0.0;

    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: BlurredLyricView(
        controller: _lyricController,
        style: lyricStyle,
        maxBlurSigma: maxBlurSigma,
        blurStep: blurStep,
      ),
    );
  }
}

class _LyricText extends StatelessWidget {
  const _LyricText({
    required this.line,
    required this.active,
    this.positionListenable,
    this.styleOverride,
    this.textAlign = TextAlign.start,
    this.singleLine = false,
  });

  final LyricLine line;
  final bool active;
  final ValueListenable<Duration>? positionListenable;
  final TextStyle? styleOverride;
  final TextAlign textAlign;
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final style =
        styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: active ? 34 : 27,
          height: 1.24,
          fontWeight: active ? FontWeight.w900 : FontWeight.w800,
        );

    if (!active || line.words.isEmpty) {
      if (singleLine) {
        return Text(
          line.text,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(line.text, textAlign: textAlign, style: style);
    }

    if (singleLine) {
      final painter = _KaraokeLinePainter(
        line: line,
        positionListenable: positionListenable,
        style: style,
        baseColor: Colors.white.withValues(alpha: .34),
        activeColor: Colors.white,
        textDirection: Directionality.of(context),
        textAlign: textAlign,
        maxLines: 1,
        maxWidth: double.infinity,
      );
      return CustomPaint(
        size: Size(painter.width, painter.height),
        painter: painter,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _KaraokeLinePainter(
          line: line,
          positionListenable: positionListenable,
          style: style,
          baseColor: Colors.white.withValues(alpha: .34),
          activeColor: Colors.white,
          textDirection: Directionality.of(context),
          textAlign: textAlign,
          maxLines: null,
          maxWidth: constraints.maxWidth,
        );
        return CustomPaint(
          size: Size(constraints.maxWidth, painter.height),
          painter: painter,
        );
      },
    );
  }
}

class _KaraokeLinePainter extends CustomPainter {
  _KaraokeLinePainter({
    required this.line,
    this.positionListenable,
    required this.style,
    required this.baseColor,
    required this.activeColor,
    required this.textDirection,
    required this.textAlign,
    required this.maxLines,
    required this.maxWidth,
  }) : super(repaint: positionListenable) {
    _textPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: baseColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);

    // 预先排版高亮文本画笔，避免在 paint() 循环中每帧重复 new TextPainter()..layout()
    _highlightPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: activeColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
  }

  final LyricLine line;
  final ValueListenable<Duration>? positionListenable;
  final TextStyle style;
  final Color baseColor;
  final Color activeColor;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final int? maxLines;
  final double maxWidth;
  late final TextPainter _textPainter;
  late final TextPainter _highlightPainter;

  Duration get _currentPosition => positionListenable?.value ?? Duration.zero;
  double get width => _textPainter.width;
  double get height => _textPainter.height;

  @override
  void paint(Canvas canvas, Size size) {
    _textPainter.paint(canvas, Offset.zero);

    final currentPos = _currentPosition;
    var start = 0;
    for (final word in line.words) {
      final end = start + word.text.length;
      final progress = _wordProgress(word, currentPos);
      if (progress > 0) {
        _paintWordProgress(canvas, start, end, progress);
      }
      start = end;
    }
  }

  double _wordProgress(LyricWord word, Duration currentPos) {
    if (currentPos < word.time) return 0;
    final durationMs = word.duration.inMilliseconds;
    if (durationMs <= 0) return 1;
    final elapsed = currentPos.inMilliseconds - word.time.inMilliseconds;
    return (elapsed / durationMs).clamp(0, 1).toDouble();
  }

  void _paintWordProgress(Canvas canvas, int start, int end, double progress) {
    final selection = TextSelection(baseOffset: start, extentOffset: end);
    final boxes = _textPainter.getBoxesForSelection(selection);
    if (boxes.isEmpty) return;

    for (final box in boxes) {
      final rect = box.toRect();
      final clipWidth = rect.width * progress.clamp(0, 1);
      if (clipWidth <= 0) continue;

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(rect.left, rect.top, clipWidth, rect.height));
      _highlightPainter.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeLinePainter oldDelegate) {
    return oldDelegate.positionListenable != positionListenable ||
        oldDelegate.line != line ||
        oldDelegate.style != style ||
        oldDelegate.maxWidth != maxWidth;
  }
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.player,
    this.bright = false,
    this.compact = false,
  });

  final PlayerController player;
  final bool bright;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 进度高频变化：仅订阅 positionNotifier 重建本组件，
    // 不依赖外层 AnimatedBuilder(player) 的全量广播。
    // 联合监听 player：暂停状态下歌曲 load 完成时 duration/climax
    // 异步解析完成后也能驱动重绘（暂停期间 positionNotifier 不派发）。
    return ListenableBuilder(
      listenable: Listenable.merge([player, player.positionNotifier]),
      builder: (context, _) {
    final position = player.positionNotifier.value;
    final max = player.duration.inMilliseconds <= 0
        ? 1.0
        : player.duration.inMilliseconds.toDouble();
    final value = position.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    final textColor = bright
        ? Colors.white.withValues(alpha: .64)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    // 高潮片段时间点（进度条小圆点），无高潮或无效时为空。
    final climax = player.climax;
    final climaxFraction = climax != null &&
            climax.isValid &&
            max > 0 &&
            climax.startTime.inMilliseconds <= max.toInt()
        ? climax.startTime.inMilliseconds / max
        : null;

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final thumbRadius = compact ? 4.0 : 5.0;
            final dotSize = compact ? 7.0 : 8.0;
            return Stack(
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.none,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: compact ? 3 : 5,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: compact ? 4 : 5,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: compact ? 10 : 14,
                    ),
                    activeTrackColor: bright
                        ? Colors.white.withValues(alpha: .86)
                        : Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: bright
                        ? Colors.white.withValues(alpha: .25)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    max: max,
                    onChanged: (value) =>
                        player.previewSeek(
                            Duration(milliseconds: value.round())),
                    onChangeEnd: (value) =>
                        player.seek(Duration(milliseconds: value.round())),
                  ),
                ),
                if (climaxFraction != null)
                  // 用 Stack 的 Alignment 定位垂直方向，而不是写死 top 值：
                  // Slider 的实际高度随主题 / 紧凑档变化，硬编码会错位（手表上会跑到轨道下方）。
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: thumbRadius +
                            climaxFraction * (width - 2 * thumbRadius) -
                            dotSize / 2,
                      ),
                      child: IgnorePointer(
                        child: Container(
                          width: dotSize,
                          height: dotSize,
                          decoration: BoxDecoration(
                            color: bright
                                ? Colors.white
                                : Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: bright
                                  ? Colors.black.withValues(alpha: .4)
                                  : Colors.white,
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
          child: Row(
            children: [
              Text(
                formatDuration(position),
                style: TextStyle(
                  color: textColor,
                  fontSize: compact ? 12 : null,
                ),
              ),
              const Spacer(),
              Text(
                formatDuration(player.duration),
                style: TextStyle(
                  color: textColor,
                  fontSize: compact ? 12 : null,
                ),
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

class _Controls extends StatefulWidget {
  const _Controls({
    required this.player,
    required this.onQueue,
    this.bright = false,
    this.compactOverride = false,
    this.denseOverride = false,
  });

  final PlayerController player;
  final VoidCallback onQueue;
  final bool bright;
  final bool compactOverride;
  final bool denseOverride;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  late bool _isPlaying;
  late PlaybackMode _playbackMode;
  late bool _isBuffering;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.player.isPlaying;
    _playbackMode = widget.player.playbackMode;
    _isBuffering = widget.player.isBuffering;
    widget.player.addListener(_onPlayerChanged);
  }

  @override
  void didUpdateWidget(covariant _Controls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      _isPlaying = widget.player.isPlaying;
      _playbackMode = widget.player.playbackMode;
      _isBuffering = widget.player.isBuffering;
      widget.player.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    final newIsPlaying = widget.player.isPlaying;
    final newPlaybackMode = widget.player.playbackMode;
    final newIsBuffering = widget.player.isBuffering;

    if (newIsPlaying != _isPlaying ||
        newPlaybackMode != _playbackMode ||
        newIsBuffering != _isBuffering) {
      setState(() {
        _isPlaying = newIsPlaying;
        _playbackMode = newPlaybackMode;
        _isBuffering = newIsBuffering;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.bright
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = widget.compactOverride || constraints.maxWidth < 360;
        final dense = widget.denseOverride;
        // 超大按钮仅在车机模式开启时使用，普通横屏用标准尺寸。
        final isCar = isLandscape && ThemeController.instance.carModeEnabled;
        final edgeButtonSize = dense ? 34.0 : (isCar ? 56.0 : (compact ? 40.0 : 44.0));
        final edgeIconSize = dense ? 21.0 : (isCar ? 34.0 : (compact ? 24.0 : 27.0));
        final skipButtonSize = dense ? 42.0 : (isCar ? 72.0 : (compact ? 50.0 : 56.0));
        final skipIconSize = dense ? 33.0 : (isCar ? 54.0 : (compact ? 40.0 : 46.0));
        final playButtonSize = dense ? 58.0 : (isCar ? 96.0 : (compact ? 72.0 : 82.0));
        final playIconSize = dense ? 46.0 : (isCar ? 72.0 : (compact ? 56.0 : 64.0));
        final gap = dense ? 3.0 : (isCar ? 24.0 : (compact ? 5.0 : 9.0));

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: widget.player.playbackModeLabel,
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: () {
                  widget.player.cyclePlaybackMode();
                  Toast.show(
                    '已切换到${widget.player.playbackModeLabel}',
                    duration: const Duration(milliseconds: 1100),
                  );
                },
                icon: Icon(_playbackModeIcon(_playbackMode)),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '上一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: widget.player.previous,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: playButtonSize,
              child: Material(
                color: widget.bright
                    ? Colors.white.withValues(alpha: .18)
                    : Theme.of(context).colorScheme.primaryContainer,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: _isPlaying ? '暂停' : '播放',
                  color: color,
                  iconSize: playIconSize,
                  padding: EdgeInsets.zero,
                  onPressed: widget.player.togglePlay,
                  icon: _isBuffering
                      ? SizedBox.square(
                          dimension: playIconSize * .58,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '下一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: widget.player.next,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: '播放列表',
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: widget.onQueue,
                icon: const Icon(Icons.queue_music_rounded),
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _playbackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.size,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  /// 传入后按钮按此边长渲染（手表等极小屏使用）；
  /// 为空时保持 IconButton 的默认尺寸与点击热区。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final buttonSize = size;
    if (buttonSize != null) {
      // IconButton 会补足 48dp 的最小点击热区，极小屏上会撑破布局，
      // 这里改用固定边长的 InkWell 自行控制尺寸。
      return Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withValues(alpha: .14),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: buttonSize,
              child: Icon(
                icon,
                size: buttonSize * .62,
                color: Colors.white.withValues(
                  alpha: onPressed == null ? .4 : 1,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          color: Colors.white,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

class _CommentEntry extends StatelessWidget {
  const _CommentEntry({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    // 按钮组靠右对齐（用户要求放最右边）；右缘无手势条，不会被遮挡，
    // 也自然避开了左缘 60px opaque 手势条。
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 评论按钮（在左侧）
            if (supportsComments(song))
            Tooltip(
              message: '查看评论',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  onTap: () => openCommentPage(context, song),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Icon(
                      Icons.comment_outlined,
                      size: 22,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),

          if (supportsComments(song)) const SizedBox(width: 4),

          // 音乐游戏按钮（在评论按钮右侧）
          if (player.playerGameEnabled) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RhythmGamePage(player: player),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Icon(
                    Icons.sports_esports_outlined,
                    size: 22,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.page, this.compact = false});

  final int page;

  /// 手表等极小屏：缩小指示点与下边距，给内容多留几像素。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dotHeight = compact ? 5.0 : 7.0;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(2, (index) {
          final active = index == page;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: active ? (compact ? 12.0 : 18.0) : dotHeight,
            height: dotHeight,
            margin: EdgeInsets.symmetric(horizontal: compact ? 3 : 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? .86 : .32),
              borderRadius: BorderRadius.circular(99),
            ),
          );
        }),
      ),
    );
  }
}

