import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/shuffle_cycle.dart';
import '../models/music_models.dart';
import '../services/audio_effects_service.dart';
import '../services/cache_service.dart';
import '../services/cover_service.dart';
import '../services/desktop_lyrics_service.dart';
import '../services/music_api.dart';
import '../services/local_lyrics_service.dart';
import '../services/music_audio_handler.dart';
import '../services/bluetooth_lyrics_service.dart';
import '../services/playback_history_service.dart';
import '../services/playback_stats_service.dart';
import '../services/super_lyric_service.dart';
import '../services/netease_image_provider.dart';
import 'download_controller.dart';
import 'local_music_controller.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

/// 播放队列的来源（歌单 / 专辑）。
///
/// 只持久化队列本身不够：进程被系统回收时快照可能缺失或残缺，重启后队列
/// 退化成单曲，点「下一首」看起来毫无反应。记住来源后，恢复时发现队列
/// 不完整就能按来源重新拉一遍，保证切歌始终在原来的歌单里进行。
class QueueOrigin {
  const QueueOrigin({required this.kind, required this.id, this.title});

  const QueueOrigin.playlist({required String id, String? title})
    : this(kind: 'playlist', id: id, title: title);

  const QueueOrigin.album({required String id, String? title})
    : this(kind: 'album', id: id, title: title);

  final String kind;
  final String id;
  final String? title;

  bool get isAlbum => kind == 'album';

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    if (title != null) 'title': title,
  };

  static QueueOrigin? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = asMap(value);
    final kind = asString(map['kind']);
    final id = asString(map['id']);
    if (kind == null || id == null || id.isEmpty) return null;
    return QueueOrigin(kind: kind, id: id, title: asString(map['title']));
  }
}

/// 解析磁盘上保存的播放进度。
///
/// 新格式是 `{"hash": "...", "ms": 12345}`，只有 hash 与 [songHash] 一致
/// 才采用，避免把上一首的位置套到新歌上；旧格式是纯 int 毫秒值，直接兼容。
/// 返回 null 表示没有可用进度。
Duration? parseSavedPosition(Object? raw, String? songHash) {
  if (raw is int) {
    return raw > 0 ? Duration(milliseconds: raw) : null;
  }
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final hash = asString(decoded['hash']);
    final ms = asInt(decoded['ms']);
    if (ms == null || ms <= 0) return null;
    if (songHash != null && songHash.isNotEmpty && hash != songHash) {
      return null;
    }
    return Duration(milliseconds: ms);
  } catch (_) {
    return null;
  }
}

class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

class PlayerController extends ChangeNotifier {
  static const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
  static const _audioQualitySettingKey = 'settings.audio_quality';
  static const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
  static const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
  static const _equalizerPresetSettingKey = 'settings.equalizer_preset';
  static const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
  static const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
  static const _audioInterruptionEnabledSettingKey =
      'settings.audio_interruption_enabled';
  static const _autoResumeAfterInterruptionSettingKey =
      'settings.auto_resume_after_interruption';
  static const _playbackSpeedSettingKey = 'settings.playback_speed';
  static const _desktopLyricsEnabledSettingKey =
      'settings.desktop_lyrics_enabled';
  static const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
  static const _smartQualitySettingKey = 'settings.smart_quality_enabled';
  static const _autoPlayOnStartupSettingKey = 'settings.auto_play_on_startup';
  static const _resumeLastPlaylistOnStartupSettingKey =
      'settings.resume_last_playlist_on_startup';
  static const _autoPlayOnDeviceConnectedSettingKey =
      'settings.auto_play_on_device_connected';
  static const _volumeNormalizationEnabledSettingKey =
      'settings.volume_normalization_enabled';
  static const _bluetoothLyricsEnabledSettingKey =
      'settings.bluetooth_lyrics_enabled';
  static const _keepScreenOnSettingKey = 'settings.keep_screen_on';
  static const _lyricBlurSettingKey = 'settings.lyric_blur_enabled';
  static const _playerGameEnabledSettingKey = 'settings.player_game_enabled';
  static const _queueKey = 'playback.queue';
  static const _currentSongKey = 'playback.current_song';
  static const _currentPositionKey = 'playback.current_position';
  static const _playbackModeKey = 'playback.mode';

  /// 播放状态快照（队列 + 当前歌曲 + 播放模式一次写入）。
  ///
  /// 旧实现把这几个字段拆成多次 `setString` 写入，进程在两次写入之间被杀
  /// 就会出现「当前歌曲已保存、队列没保存」的残缺状态：重启后只剩一首歌，
  /// 点「下一首」永远原地不动，必须重新进歌单点播才能恢复。
  static const _stateKey = 'playback.state_snapshot';
  static const _queueSaveDebounceMs = 500;
  static const _positionSaveInterval = Duration(seconds: 5);
  static const _listenTimeReportInterval = Duration(minutes: 5);
  static const _listenTimeCheckInterval = Duration(seconds: 15);
  static const _pendingListenTimeKey = 'settings.pending_listen_time_ms';
  static const _bluetoothLyricsTitleSyncSettingKey =
      'settings.bluetooth_lyrics_title_sync_enabled';
  static const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  static const equalizerPresets = [
    AudioEffectPreset(name: '平直', levels: _defaultEqualizerLevels),
    AudioEffectPreset(
      name: '流行',
      levels: [0, 250, 450, 350, 100, -100, 50, 300, 450, 500],
    ),
    AudioEffectPreset(
      name: '摇滚',
      levels: [500, 350, 150, -100, -250, -150, 150, 350, 550, 650],
    ),
    AudioEffectPreset(
      name: '人声',
      levels: [-250, -150, 0, 250, 500, 550, 350, 100, -100, -200],
    ),
    AudioEffectPreset(
      name: '低音',
      levels: [750, 650, 500, 250, 0, -100, -150, -200, -250, -300],
    ),
    AudioEffectPreset(
      name: '古典',
      levels: [350, 250, 100, 0, 150, 250, 300, 350, 250, 100],
    ),
    AudioEffectPreset(
      name: '电子',
      levels: [650, 450, 120, -120, -180, 100, 350, 550, 650, 700],
    ),
  ];

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  /// 本地音乐控制器（由 main.dart 在创建后注入，用于读取内嵌歌词等）。
  LocalMusicController? localMusic;

  PlayerController(this._api, this._audioHandler) {
    final settingsRestore = _restoreSettings();
    unawaited(settingsRestore);
    unawaited(_superLyric.registerPublisher());
    _audioHandler.attachTransportControls(onNext: next, onPrevious: previous);
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeStopClimaxPreview(value);
      _maybeSyncDesktopLyricFromPosition();
      _syncSuperLyricFromPosition();
      _syncBluetoothLyricsFromPosition();
      // position 高频变化仅推送到 positionNotifier，避免全量广播触发整页 rebuild
    });
    // Send timing anchors; Android animates karaoke progress at display refresh.
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_shouldShowDesktopLyrics &&
          isPlaying &&
          lyrics.isNotEmpty &&
          !_isScrubbing) {
        _syncDesktopKaraokeProgress();
      }
    });
    _durationSub = audioPlayer.durationStream.listen((value) {
      duration = value ?? Duration.zero;
      notifyListeners();
    });
    _stateSub = audioPlayer.playerStateStream.listen((value) {
      isPlaying = value.playing;
      isBuffering =
          value.processingState == ProcessingState.loading ||
          value.processingState == ProcessingState.buffering;
      if (!_isSeeking) {
        _setPositionBase(audioPlayer.position, playing: isPlaying);
      }
      _syncListeningTimeTracker();
      _syncDesktopPlayState();
      notifyListeners();
    });
    _processingStateSub = audioPlayer.processingStateStream.distinct().listen((
      state,
    ) {
      if (state == ProcessingState.completed) {
        if (!_isChangingSource) {
          unawaited(_handleCompleted());
        }
      }
    });
    _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      _androidAudioSessionId = sessionId;
      unawaited(_refreshEqualizerConfig());
      unawaited(_applyEqualizer());
      unawaited(_applyBassBoost());
      unawaited(_applyVolumeNormalization());
    });
    // 先恢复用户的打断设置，再配置 AudioSession，避免首次播放与
    // 异步会话配置竞态，导致点歌后停在暂停状态。
    _audioSessionReady = settingsRestore.then(
      (_) => _setupAudioSessionListeners(),
    );
    unawaited(_audioSessionReady);
  }

  final MusicApi _api;
  final MusicAudioHandler _audioHandler;
  late final Future<void> _audioSessionReady;

  /// 持久化设置恢复完成信号。
  ///
  /// 用于“开机自启播放”等依赖持久化开关值的流程等待设置加载完成，
  /// 避免在 [_restoreSettings] 完成前把开关误读为默认值。
  final Completer<void> _settingsRestored = Completer<void>();

  /// 设置（含开机自启开关）从本地恢复完成的 Future。
  Future<void> get settingsRestored => _settingsRestored.future;
  final AudioEffectsService _audioEffects = AudioEffectsService();
  final DesktopLyricsService _desktopLyrics = DesktopLyricsService();
  final PlaybackHistoryService _historyService = PlaybackHistoryService();
  final PlaybackStatsService _statsService = PlaybackStatsService();
  final SuperLyricService _superLyric = SuperLyricService();
  final BluetoothLyricsService _bluetoothLyrics = BluetoothLyricsService();

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _durationSub;
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<ProcessingState> _processingStateSub;
  late final StreamSubscription<int?> _androidAudioSessionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  Set<AudioDevice>? _previousDevices;
  final Stopwatch _positionClock = Stopwatch();
  // 平滑位置的上一次取值：用于过滤位置流的小幅倒退（音频缓冲/时钟抖动），
  // 避免歌词高亮和卡拉OK进度出现回跳。seek/换歌的大跨度回退会重建基线。
  Duration _lastSmoothPosition = Duration.zero;
  final _shuffleCycle = ShuffleCycle<String>();

  /// 高潮试听结束时间（播放到该时间自动暂停）。
  Duration? _climaxEndTime;

  /// 当前歌曲的高潮片段时间（用于进度条标记），可能为 null。
  SongClimax? climax;
  Timer? _completionFallbackTimer;
  Timer? _listenTimeTimer;
  Timer? _queueSaveTimer;
  Timer? _positionSaveTimer;
  Timer? _playCacheTimer;
  DateTime? _listenTimeStartedAt;
  Duration _pendingListenTime = Duration.zero;

  /// 上一次写入本地听歌统计的累计时长（用于增量落盘）。
  Duration _lastStatsFlush = Duration.zero;
  bool _isReportingListenTime = false;
  int _seekSerial = 0;
  bool _isSeeking = false;
  bool _isScrubbing = false;
  bool _isHandlingCompletion = false;
  int _playRequestSerial = 0;
  Future<void> _sourceChangeTail = Future<void>.value();
  bool _isPersonalFmActive = false;
  bool _isLoadingPersonalFm = false;
  int _personalFmRequestSerial = 0;
  String? _completedSongHash;
  bool _isAppForeground = true;
  bool _desktopLyricsPreviewVisible = false;
  /// 用户是否在本次后台运行中主动点击悬浮窗“关闭”按钮临时关闭了桌面歌词。
  /// 当用户再次“点开软件”（应用回到前台）时，会自动重置为 false，
  /// 使得桌面歌词重新“自启动”，而不会因为临时关闭悬浮窗而永久关闭设置开关。
  bool _desktopLyricsUserDismissed = false;

  Song? currentSong;
  List<Song> queue = const [];

  /// 当前队列来自哪个歌单/专辑（用于重启后重建完整队列）。
  QueueOrigin? _queueOrigin;

  QueueOrigin? get queueOrigin => _queueOrigin;

  /// 从磁盘恢复出来、尚未在音频引擎上生效的播放进度。
  ///
  /// 恢复队列时音频源还没加载，此时 seek 无效；由 [prepareRestoredSong]
  /// 在音源加载完成后取走并真正跳转，跳完即置空。
  Duration? _resumePosition;

  /// 是否还有待应用的恢复进度（UI 可据此显示「已恢复」提示）。
  bool get hasPendingResumePosition => _resumePosition != null;

  List<LyricLine> lyrics = const [];
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  Duration position = Duration.zero;

  /// 播放进度的高频通道。position 每 ~200ms 随音频 tick 变化，
  /// 若走 notifyListeners 会让所有订阅者全量 rebuild；改为独立
  /// ValueNotifier 后，只有进度条/时间等真正需要 position 的 UI 订阅它。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  Duration duration = Duration.zero;
  bool isPlaying = false;
  bool isBuffering = false;
  bool isPreparing = false;
  bool _isChangingSource = false;
  bool addListeningTimeEnabled = true;
  bool keepScreenOnEnabled = false;
  bool lyricBlurEnabled = false;
  bool playerGameEnabled = true;
  AudioQuality audioQuality = AudioQuality.standard;

  bool get isPersonalFmActive => _isPersonalFmActive;

  bool get isLoadingPersonalFm => _isLoadingPersonalFm;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;
  bool autoPlayOnStartupEnabled = false;
  bool resumeLastPlaylistOnStartupEnabled = false;
  double playbackSpeed = 1.0;
  bool equalizerEnabled = false;
  List<int> equalizerLevels = List<int>.of(_defaultEqualizerLevels);
  String equalizerPresetName = '平直';
  EqualizerConfig equalizerConfig = EqualizerConfig.fallback(
    _defaultEqualizerLevels,
  );
  bool bassBoostEnabled = false;
  double bassBoostStrength = 0.45;
  bool audioInterruptionEnabled = true;
  bool autoResumeAfterInterruption = true;
  bool autoPlayOnDeviceConnected = false;
  bool volumeNormalizationEnabled = false;
  bool bluetoothLyricsEnabled = false;
  bool bluetoothLyricsTitleSyncEnabled = false;
  bool desktopLyricsEnabled = false;
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();
  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;
  int seekRevision = 0;
  int? _androidAudioSessionId;
  bool get isScrubbing => _isScrubbing;
  bool get isAudioEffectsSupported => _audioEffects.isAudioEffectsSupported;
  bool get isBassBoostSupported => _audioEffects.isBassBoostSupported;
  String get audioEffectsLabel {
    if (!isAudioEffectsSupported) {
      return '当前平台暂不支持';
    }
    if (equalizerEnabled) {
      return '均衡器：$equalizerPresetName';
    }
    if (bassBoostEnabled) {
      return 'Bass ${(bassBoostStrength * 100).round()}%';
    }
    return '关闭';
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

  Duration get smoothPosition {
    final raw = _isScrubbing
        ? position
        : (!isPlaying ? position : position + _positionClock.elapsed);
    var value = raw;
    if (value < Duration.zero) {
      value = Duration.zero;
    } else if (duration > Duration.zero && value > duration) {
      value = duration;
    }
    if (_isScrubbing) {
      // 拖动进度条时位置必须严格跟随手指。
      _lastSmoothPosition = value;
      return value;
    }
    if (value < _lastSmoothPosition) {
      if (_lastSmoothPosition - value > const Duration(milliseconds: 250)) {
        // 明显回退：视为 seek 或切歌，直接重建基线。
        _lastSmoothPosition = value;
      }
    } else {
      _lastSmoothPosition = value;
    }
    return _lastSmoothPosition;
  }

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    final identicalIndex = queue.indexWhere((item) => identical(item, song));
    if (identicalIndex >= 0) {
      return identicalIndex;
    }
    final identity = _songIdentity(song);
    if (identity.isNotEmpty) {
      final idIndex = queue.indexWhere((item) => _songIdentity(item) == identity);
      if (idIndex >= 0) {
        return idIndex;
      }
    }
    if (song.hash.isNotEmpty) {
      final hashIndex = queue.indexWhere((item) => item.hash == song.hash);
      if (hashIndex >= 0) {
        return hashIndex;
      }
    }
    if (song.id.isNotEmpty) {
      final idIndex = queue.indexWhere((item) => item.id == song.id);
      if (idIndex >= 0) {
        return idIndex;
      }
    }
    return -1;
  }

  int get activeLyricIndex {
    if (lyrics.isEmpty) {
      return -1;
    }
    var index = 0;
    for (var i = 0; i < lyrics.length; i++) {
      if (smoothPosition >= lyrics[i].time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  String get playbackModeLabel {
    return switch (playbackMode) {
      PlaybackMode.playlistLoop => '歌单循环',
      PlaybackMode.shuffle => '随机播放',
      PlaybackMode.singleLoop => '单曲循环',
    };
  }

  PlaybackMode cyclePlaybackMode() {
    _shuffleCycle.clear();
    playbackMode = switch (playbackMode) {
      PlaybackMode.playlistLoop => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.singleLoop,
      PlaybackMode.singleLoop => PlaybackMode.playlistLoop,
    };
    if (playbackMode == PlaybackMode.shuffle && queue.isNotEmpty) {
      final currentIdentity = currentSong == null
          ? null
          : _songIdentity(currentSong!);
      _shuffleCycle.reset(
        queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
        current: currentIdentity,
      );
    }
    _saveQueueState();
    notifyListeners();
    return playbackMode;
  }

  Future<void> setAddListeningTimeEnabled(bool enabled) async {
    if (addListeningTimeEnabled == enabled) {
      return;
    }
    addListeningTimeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_listenTimeSettingKey, enabled);
    if (!enabled) {
      _resetListeningTimeTracker();
    } else {
      _syncListeningTimeTracker();
    }
    notifyListeners();
  }

  Future<void> setKeepScreenOnEnabled(bool enabled) async {
    if (keepScreenOnEnabled == enabled) {
      return;
    }
    keepScreenOnEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setLyricBlurEnabled(bool enabled) async {
    if (lyricBlurEnabled == enabled) {
      return;
    }
    lyricBlurEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lyricBlurSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setPlayerGameEnabled(bool enabled) async {
    if (playerGameEnabled == enabled) {
      return;
    }
    playerGameEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_playerGameEnabledSettingKey, enabled);
    notifyListeners();
  }

  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool preservePersonalFmSession = false,
    QueueOrigin? origin,
  }) async {
    final requestSerial = ++_playRequestSerial;
    debugPrint(
      '[KA Music][playback] request=$requestSerial begin '
      'incomingQueue=${queue?.length ?? 0}',
    );
    final isPlayingWithinCurrentQueue =
        _isPersonalFmActive &&
        (queue == null ||
            identical(queue, this.queue) ||
            _isSameQueue(queue, this.queue));
    final shouldPreserveFm =
        preservePersonalFmSession || isPlayingWithinCurrentQueue;
    if (!shouldPreserveFm) {
      _isPersonalFmActive = false;
      _isLoadingPersonalFm = false;
      _personalFmRequestSerial++;
    }
    _climaxEndTime = null;
    climax = null;
    _completionFallbackTimer?.cancel();
    _playCacheTimer?.cancel();
    unawaited(downloadController?.cancelActivePlayCache());
    _completedSongHash = null;
    isPreparing = true;
    _isChangingSource = true;
    errorMessage = null;
    final replacesQueue =
        queue != null && queue.isNotEmpty && !_isSameQueue(queue, this.queue);
    final previousSong = currentSong;
    final wasPlaying = isPlaying &&
        audioPlayer.processingState != ProcessingState.completed &&
        !_isHandlingCompletion;
    if (previousSong != null && previousSong != song) {
      if (wasPlaying) {
        // 用户手动切歌且旧音频正在播放时，仅静音旧音频，
        // 避免网络解析加载期间继续外放，同时保持 Audio Focus 与 WakeLock 不中断；
        // 绝不能在后台切歌或自然播完切歌时调用 pause()，否则会导致系统释放 WakeLock 并撤销 Audio Focus，
        // 造成黑屏切歌卡住不播、必须点亮屏幕才恢复播放。
        unawaited(audioPlayer.setVolume(0.0));
      }
    }
    currentSong = song;
    // 用户主动点歌/切歌后，磁盘上待恢复的进度不再适用
    _resumePosition = null;
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
      // 只有换了一整套队列时才更新来源；在队列内部切歌不能把来源丢掉
      if (replacesQueue) {
        _queueOrigin = origin;
      } else if (origin != null) {
        _queueOrigin = origin;
      }
    } else if (this.queue.isEmpty) {
      this.queue = [song];
      _queueOrigin = origin;
    }
    final songIdentity = _songIdentity(song);
    if (playbackMode == PlaybackMode.shuffle && replacesQueue) {
      _shuffleCycle.reset(
        this.queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
        current: songIdentity,
      );
    } else if (playbackMode == PlaybackMode.shuffle &&
        songIdentity.isNotEmpty) {
      _shuffleCycle.markPlayed(songIdentity);
    }
    lyrics = const [];
    _lastDesktopLyricIndex = -1;
    _lastSuperLyricIndex = -1;
    _lastSuperLyricPlaying = true;
    _lastBluetoothLyricIndex = -1;
    _lastBluetoothPlaying = true;
    _saveQueueState();
    _startPositionSaving();
    notifyListeners();
    // 预缓存封面图，避免打开播放页时出现纯色背景闪烁
    _precacheCover(song);
    unawaited(_syncDesktopLyricsVisibility());
    unawaited(_loadClimax(song));

    try {
      String url;
      String? networkUrl;
      debugPrint(
        '[KA Music][playback] request=$requestSerial local-lookup begin',
      );
      final local = await downloadController?.localPathFor(song, audioQuality);
      if (requestSerial != _playRequestSerial) return;
      debugPrint(
        '[KA Music][playback] request=$requestSerial local-lookup complete '
        'found=${local != null}',
      );
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        debugPrint(
          '[KA Music][playback] request=$requestSerial url-resolve begin',
        );
        final playUrl = await _resolvePlayUrl(song);
        if (requestSerial != _playRequestSerial) return;
        debugPrint(
          '[KA Music][playback] request=$requestSerial url-resolve complete '
          'empty=${playUrl.url.isEmpty}',
        );
        if (playUrl.url.isEmpty) {
          throw Exception(
            song.isCloudDrive
                ? '云盘歌曲暂时没有可播放地址'
                : song.source == SongSource.netease
                ? '网易云歌曲暂时没有可播放地址'
                : '这首歌暂时没有可播放地址',
          );
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      if (requestSerial != _playRequestSerial) return;

      // setUrl/setAudioSource 不能并发执行。快速点击“下一曲”时，让已经开始的
      // 音源切换先安全结束，再由最后一次请求接管，避免旧请求反向覆盖新歌曲。
      debugPrint(
        '[KA Music][playback] request=$requestSerial source-queue enter',
      );
      await _serializeSourceChange(() async {
        if (requestSerial != _playRequestSerial) return;
        debugPrint(
          '[KA Music][playback] request=$requestSerial source-load begin',
        );
        await _audioHandler.loadSong(
          song: song,
          url: url,
          queueSongs: this.queue,
          queueIndex: currentIndex,
        );
        if (requestSerial != _playRequestSerial) return;
        debugPrint(
          '[KA Music][playback] request=$requestSerial source-loaded '
          'local=${networkUrl == null}',
        );

        isPreparing = false;
        notifyListeners();
        unawaited(loadLyrics(song));
        if (wasPlaying) {
          unawaited(audioPlayer.setVolume(1.0));
        }
        await _startPlayback();
        if (requestSerial != _playRequestSerial) return;
        unawaited(_applyVolumeNormalization());
        unawaited(_applyEqualizer());
        unawaited(_applyBassBoost());
        debugPrint(
          '[KA Music][playback] request=$requestSerial started '
          'playing=${audioPlayer.playing} '
          'state=${audioPlayer.processingState.name}',
        );

        // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
        unawaited(_historyService.record(song));
        unawaited(_statsService.recordPlay(song));
        // 稳定播放 15 秒后再后台缓存（避免快速切歌重复消耗大量流量）
        if (networkUrl != null) {
          _schedulePlayCache(song, audioQuality, networkUrl);
        }
      });
    } catch (error) {
      if (requestSerial != _playRequestSerial) return;
      debugPrint('[KA Music][playback] request=$requestSerial failed: $error');
      errorMessage = error.toString();
      unawaited(_audioHandler.pause());
      if (wasPlaying) {
        unawaited(audioPlayer.setVolume(1.0));
      }
      isPreparing = false;
      notifyListeners();
    } finally {
      if (requestSerial == _playRequestSerial) {
        _isChangingSource = false;
        if (isPreparing) {
          isPreparing = false;
          notifyListeners();
        }
      }
    }
  }

  Future<void> _serializeSourceChange(Future<void> Function() operation) async {
    final previous = _sourceChangeTail;
    final turnCompleted = Completer<void>();
    _sourceChangeTail = turnCompleted.future;
    try {
      await previous;
      await operation();
    } finally {
      turnCompleted.complete();
    }
  }

  Future<void> _startPlayback() async {
    await _audioSessionReady;
    await _audioHandler.play();
  }

  /// 启动固定为“红心 Radio + 根据口味”的私人 FM 会话。
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async {
    if (_isLoadingPersonalFm) {
      return false;
    }

    _isLoadingPersonalFm = true;
    final requestSerial = ++_personalFmRequestSerial;
    errorMessage = null;
    notifyListeners();
    try {
      final songs = initialSongs?.isNotEmpty == true
          ? List<Song>.of(initialSongs!)
          : await _api.personalFm();
      if (requestSerial != _personalFmRequestSerial) {
        return false;
      }
      if (songs.isEmpty) {
        errorMessage = '暂时没有新的私人 FM 推荐';
        return false;
      }

      _isPersonalFmActive = true;
      await playSong(
        songs.first,
        queue: songs,
        preservePersonalFmSession: true,
      );
      return errorMessage == null;
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
      }
      return false;
    } finally {
      if (requestSerial == _personalFmRequestSerial) {
        _isLoadingPersonalFm = false;
        notifyListeners();
      }
    }
  }

  /// 预缓存歌曲封面到 Flutter ImageCache，打开播放页时可立即显示。
  ///
  /// 地址按显示尺寸规格化：网易云封面原图 1~2MB，取 `?param=480y480` 只有
  /// 300KB 左右（见 [CoverService.sized]）。歌曲完全没有封面时再按来源补取。
  void _precacheCover(Song song) {
    final coverUrl = CoverService.sized(song.coverUrl, 240);
    if (coverUrl != null && coverUrl.isNotEmpty) {
      _resolveCoverProvider(coverUrl);
      return;
    }
    unawaited(
      CoverService.instance.resolve(song).then((url) {
        if (url == null || url.isEmpty) return;
        _resolveCoverProvider(CoverService.sized(url, 240) ?? url);
      }),
    );
  }

  /// 按来源选择合适的 ImageProvider 预热。
  ///
  /// 网易云必须走 [NeteaseImageProvider]：它在 HttpClient 层用 `set` 覆盖
  /// User-Agent；用 `NetworkImage(headers:)` 会变成两个 User-Agent 而被 403。
  void _resolveCoverProvider(String url) {
    if (url.startsWith('content://')) return; // 本地封面走原生加载，不预缓存
    final ImageProvider provider = CoverService.isNeteaseImage(url)
        ? NeteaseImageProvider(url)
        : NetworkImage(url);
    provider.resolve(ImageConfiguration.empty);
  }

  /// 解析播放地址。
  ///
  /// - 云盘歌曲走 [MusicApi.cloudSongUrl]
  /// - 网易云歌曲使用外链地址
  /// - 其它歌曲走 [MusicApi.songUrl]，开启智能音质时在网络请求失败
  ///   或返回空地址时自动降级重试（lossless -> high -> standard）。
  Future<PlayUrl> _resolvePlayUrl(Song song) async {
    if (song.source == SongSource.local) {
      return PlayUrl(url: song.id, hash: song.hash);
    }
    if (song.isCloudDrive) {
      return _api.cloudSongUrl(song);
    }
    if (song.source == SongSource.netease) {
      // 网易云歌曲使用外链播放地址
      return PlayUrl(
        url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
        hash: song.hash,
      );
    }

    try {
      final playUrl = await _api.songUrl(
        song,
        quality: audioQuality,
        hashOnly: _isPersonalFmActive,
      );
      if (playUrl.url.isNotEmpty || !smartQualityEnabled) {
        return playUrl;
      }
      // 返回空地址：按智能音质策略降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) return playUrl;
      return await _api.songUrl(
        song,
        quality: fallback,
        hashOnly: _isPersonalFmActive,
      );
    } catch (error) {
      if (!smartQualityEnabled) rethrow;
      // 网络请求失败：尝试降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) rethrow;
      try {
        final retryUrl = await _api.songUrl(
          song,
          quality: fallback,
          hashOnly: _isPersonalFmActive,
        );
        if (retryUrl.url.isNotEmpty) {
          debugPrint(
            '[KA Music][smart-quality] ${audioQuality.badge} 失败，'
            '已降级为 ${fallback.badge}',
          );
          return retryUrl;
        }
      } catch (_) {
        // 降级也失败，抛出原始错误
      }
      rethrow;
    }
  }

  /// 返回更低一档的音质；已是最低档时返回 null。
  AudioQuality? _nextLowerQuality(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.lossless:
        return AudioQuality.high;
      case AudioQuality.high:
        return AudioQuality.standard;
      case AudioQuality.standard:
        return null;
    }
  }

  Future<bool> addToQueue(Song song) async {
    final songKey = song.hash.isNotEmpty ? song.hash : song.id;
    final currentSongKey = currentSong == null
        ? ''
        : (currentSong!.hash.isNotEmpty ? currentSong!.hash : currentSong!.id);
    if (songKey.isNotEmpty && songKey == currentSongKey) {
      return false;
    }

    final nextQueue = List<Song>.of(queue);
    final existingIndex = nextQueue.indexWhere((item) {
      final itemKey = item.hash.isNotEmpty ? item.hash : item.id;
      return itemKey.isNotEmpty && itemKey == songKey;
    });
    if (existingIndex >= 0) {
      nextQueue.removeAt(existingIndex);
    }

    if (nextQueue.isEmpty) {
      nextQueue.add(song);
    } else {
      final index = currentIndex;
      final insertIndex = index < 0
          ? 0
          : (index + 1).clamp(0, nextQueue.length);
      nextQueue.insert(insertIndex, song);
    }

    queue = nextQueue;
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: currentSong,
    );
    _saveQueueState();
    notifyListeners();
    return true;
  }

  /// 当当前队列仍是 [expectedQueue] 时，用 [newQueue] 补齐播放队列。
  ///
  /// 歌单页会先用已经展示的歌曲立即开始播放，再在后台拉取完整歌单。
  /// 只有用户期间没有切换到其他队列时才应用刷新结果，避免后台请求覆盖
  /// 用户随后主动选择的新歌单。
  Future<bool> replaceQueueIfMatches({
    required List<Song> expectedQueue,
    required List<Song> newQueue,
  }) async {
    final song = currentSong;
    if (song == null ||
        newQueue.isEmpty ||
        !_isSameQueue(queue, expectedQueue)) {
      return false;
    }

    final currentIdentity = _songIdentity(song);
    if (!newQueue.any((item) => _songIdentity(item) == currentIdentity)) {
      return false;
    }

    queue = List<Song>.of(newQueue);
    if (playbackMode == PlaybackMode.shuffle) {
      _shuffleCycle.reset(
        queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
        current: currentIdentity,
      );
    }
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: song,
    );
    _saveQueueState();
    notifyListeners();
    return true;
  }

  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    final sameQuality = audioQuality == quality;
    if (sameQuality && !reloadCurrent) {
      return;
    }

    audioQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioQualitySettingKey, quality.apiValue);
    notifyListeners();

    if (reloadCurrent && currentSong != null && !sameQuality) {
      await _reloadCurrentSongForQuality();
    }
  }

  /// 开关音质智能切换（播放失败时自动降级重试）。
  Future<void> setSmartQualityEnabled(bool enabled) async {
    if (smartQualityEnabled == enabled) return;
    smartQualityEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartQualitySettingKey, enabled);
    notifyListeners();
  }

  /// 开机自启播放开关当前是否已开启（从持久化存储读取）。
  ///
  /// 供启动流程判断是否需要预加载上次播放：开启时由首页自动播放逻辑
  /// 接管，避免两套加载流程竞争覆盖同一播放源。
  static Future<bool> isAutoPlayOnStartup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoPlayOnStartupSettingKey) ?? false;
  }

  /// “恢复上次播放列表”开关当前是否已开启（从持久化存储读取）。
  static Future<bool> isResumeLastPlaylistOnStartup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_resumeLastPlaylistOnStartupSettingKey) ?? false;
  }

  /// 开关开机自启播放（推荐歌单）。
  ///
  /// 与“恢复上次播放列表”互斥：开启时自动关闭另一项，两项只能启用其一。
  Future<void> setAutoPlayOnStartupEnabled(bool enabled) async {
    if (autoPlayOnStartupEnabled == enabled) return;
    autoPlayOnStartupEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnStartupSettingKey, enabled);
    if (enabled && resumeLastPlaylistOnStartupEnabled) {
      resumeLastPlaylistOnStartupEnabled = false;
      await prefs.setBool(_resumeLastPlaylistOnStartupSettingKey, false);
    }
    notifyListeners();
  }

  /// 开关“打开应用时自动加载并播放上一次播放的列表”。
  ///
  /// 与“开机自启播放（推荐歌单）”互斥：开启时自动关闭另一项，保持只启用其一。
  Future<void> setResumeLastPlaylistOnStartupEnabled(bool enabled) async {
    if (resumeLastPlaylistOnStartupEnabled == enabled) return;
    resumeLastPlaylistOnStartupEnabled = enabled;
    if (enabled && autoPlayOnStartupEnabled) {
      autoPlayOnStartupEnabled = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoPlayOnStartupSettingKey, false);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_resumeLastPlaylistOnStartupSettingKey, enabled);
    notifyListeners();
  }

  /// 开关连接新音频设备自动播放功能。
  Future<void> setAutoPlayOnDeviceConnected(bool enabled) async {
    if (autoPlayOnDeviceConnected == enabled) return;
    autoPlayOnDeviceConnected = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnDeviceConnectedSettingKey, enabled);
    notifyListeners();
  }

  /// 开关音量均衡功能。
  Future<void> setVolumeNormalizationEnabled(bool enabled) async {
    if (volumeNormalizationEnabled == enabled) return;
    volumeNormalizationEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_volumeNormalizationEnabledSettingKey, enabled);
    await _applyVolumeNormalization();
    notifyListeners();
  }

  /// 车载蓝牙歌词功能是否受支持（仅 Android）。
  bool get isBluetoothLyricsSupported =>
      BluetoothLyricsService.isSupportedPlatform;

  /// 开关车载蓝牙歌词功能。
  Future<void> setBluetoothLyricsTitleSyncEnabled(bool enabled) async {
    if (bluetoothLyricsTitleSyncEnabled == enabled) return;
    bluetoothLyricsTitleSyncEnabled = enabled;
    _audioHandler.setBluetoothLyricsTitleSync(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bluetoothLyricsTitleSyncSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setBluetoothLyricsEnabled(bool enabled) async {
    if (bluetoothLyricsEnabled == enabled) return;
    bluetoothLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bluetoothLyricsEnabledSettingKey, enabled);
    // 关闭时，清理残留广播
    if (!enabled && currentSong != null) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: currentSong!.title,
          artist: currentSong!.artist,
          album: currentSong!.albumName,
          lyric: '',
          position: position,
          duration: currentSong!.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
      _audioHandler.updateLyricMetadata(lyricText: null);
    } else if (enabled) {
      // 打开时立即推送一次当前状态
      _pushBluetoothLyricForCurrentLine(force: true);
    }
    notifyListeners();
  }

  /// 读取本地播放统计。
  Future<PlaybackStats> getPlaybackStats() => _statsService.getStats();

  /// 清空本地播放统计。
  Future<void> clearPlaybackStats() => _statsService.clear();

  /// 读取播放历史。
  Future<List<Song>> getPlaybackHistory({int limit = 100}) =>
      _historyService.getHistory(limit: limit);

  /// 读取播放历史总数（轻量计数，不反序列化 Song 对象）。
  Future<int> getPlaybackHistoryCount() => _historyService.count();

  /// 清空播放历史。
  Future<void> clearPlaybackHistory() => _historyService.clear();

  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 3.0);
    if ((playbackSpeed - clamped).abs() < 0.001) {
      return;
    }
    playbackSpeed = clamped;
    await audioPlayer.setSpeed(clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_playbackSpeedSettingKey, clamped);
    notifyListeners();
  }

  Future<void> setBassBoostEnabled(bool enabled) async {
    if (bassBoostEnabled == enabled) {
      return;
    }
    bassBoostEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, enabled);
    await _applyBassBoost();
    notifyListeners();
  }

  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((bassBoostStrength - nextStrength).abs() < 0.001) {
      return;
    }
    bassBoostStrength = nextStrength;
    if (bassBoostEnabled) {
      unawaited(_applyBassBoost());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bassBoostStrengthSettingKey, nextStrength);
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    if (equalizerEnabled == enabled) {
      return;
    }
    equalizerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, enabled);
    await _applyEqualizer();
    notifyListeners();
  }

  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {
    if (index < 0 || index >= equalizerLevels.length) {
      return;
    }
    final clamped = levelMillibels.clamp(
      equalizerConfig.minMillibels,
      equalizerConfig.maxMillibels,
    );
    if (equalizerLevels[index] == clamped) {
      return;
    }
    equalizerLevels = List<int>.of(equalizerLevels)..[index] = clamped;
    equalizerPresetName = '自定义';
    if (equalizerEnabled) {
      unawaited(_applyEqualizer());
    }
    notifyListeners();

    if (persist) {
      await _persistEqualizer();
    }
  }

  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    equalizerPresetName = preset.name;
    equalizerLevels = _levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    if (equalizerEnabled) {
      await _applyEqualizer();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    await applyEqualizerPreset(equalizerPresets.first);
  }

  Future<void> loadLyrics(Song song) async {
    final cache = cacheService;
    final cacheKey = 'cache_lyric_${song.hash}';

    if (song.source == SongSource.local) {
      final lines = await LocalLyricsService(
        api: _api,
        cache: cache,
        embeddedLyricsReader: localMusic?.getEmbeddedLyrics,
      ).load(song);
      if (currentSong?.hash == song.hash) {
        lyrics = lines;
        notifyListeners();
        _syncDesktopLyrics();
      }
      return;
    }

    // 1. 先读缓存，命中则立即显示（无感）
    if (cache != null) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          cacheKey,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: const Duration(days: 30),
        );
        if (cached != null &&
            !listEquals(lyrics, cached.data) &&
            currentSong?.hash == song.hash) {
          lyrics = cached.data;
          notifyListeners();
          _syncDesktopLyrics();
        }
      } catch (_) {}
    }

    // 2. 后台静默刷新
    try {
      final fresh = await _api.lyrics(song);
      if (currentSong?.hash != song.hash) return; // 已切歌，丢弃
      if (!listEquals(lyrics, fresh)) {
        lyrics = fresh;
        notifyListeners();
      }
      // 写缓存（空歌词也缓存，避免重复请求）
      if (cache != null) {
        unawaited(
          cache.write(cacheKey, {
            'lines': fresh.map((l) => l.toCache()).toList(),
          }),
        );
      }
    } catch (_) {
      if (currentSong?.hash == song.hash && lyrics.isEmpty) {
        lyrics = const [];
        notifyListeners();
      }
    }
    if (currentSong?.hash == song.hash) {
      _syncDesktopLyrics();
    }
  }

  Future<void> togglePlay() async {
    if (audioPlayer.playing) {
      await _audioHandler.pause();
      // 暂停瞬间落盘一次进度：用户经常暂停后直接退出，5 秒定时器
      // 可能还没触发，位置会停留在上一次保存点。
      _saveCurrentPosition();
    } else {
      if (audioPlayer.processingState == ProcessingState.completed) {
        await _audioHandler.seek(Duration.zero);
      }
      await _startPlayback();
    }
  }

  /// 当前歌曲是否支持高潮片段。
  ///
  /// 只有酷狗提供 `/song/climax`；网易云的 hash 是 `ne_<id>`，接口只返回
  /// 空对象 `{}`，本地歌曲同理，所以直接判定不支持，避免点了才报错。
  bool get isClimaxSupported {
    final song = currentSong;
    if (song == null) return false;
    if (song.source != SongSource.kugou) return false;
    return song.hash.isNotEmpty && !song.hash.startsWith('ne_');
  }

  /// 试听当前歌曲的高潮片段：定位到高潮开始并播放，到高潮结束自动暂停。
  /// 返回是否成功（无高潮片段或失败时返回 false）。
  Future<bool> playClimaxPreview() async {
    final song = currentSong;
    if (song == null || !isClimaxSupported) return false;
    try {
      // 切歌时已经预取过就直接用，避免每次点击都多打一次接口
      final cached = climax;
      final data = cached != null && cached.isValid
          ? cached
          : await _api.songClimax(song.hash);
      if (data == null) return false;
      climax = data;
      _climaxEndTime = data.endTime;
      await seek(data.startTime);
      await play();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 高潮试听播放到结束时间时自动暂停。
  void _maybeStopClimaxPreview(Duration value) {
    final end = _climaxEndTime;
    if (end == null || value < end) return;
    _climaxEndTime = null;
    unawaited(pause());
  }

  /// 异步获取当前歌曲高潮时间，用于进度条标记（失败静默）。
  Future<void> _loadClimax(Song song) async {
    // 网易云 / 本地歌曲没有高潮数据，不发无效请求
    if (song.source != SongSource.kugou ||
        song.hash.isEmpty ||
        song.hash.startsWith('ne_')) {
      if (currentSong?.hash == song.hash && climax != null) {
        climax = null;
        notifyListeners();
      }
      return;
    }
    try {
      final result = await _api.songClimax(song.hash);
      if (currentSong?.hash != song.hash) return;
      climax = result;
      notifyListeners();
    } catch (_) {
      if (currentSong?.hash == song.hash) {
        climax = null;
      }
    }
  }

  Future<void> play() async {
    if (!audioPlayer.playing) {
      await togglePlay();
    }
  }

  Future<void> pause() async {
    if (audioPlayer.playing) {
      await togglePlay();
    }
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    _setPositionBase(position, playing: false);
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    seekRevision++;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    notifyListeners();

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      notifyListeners();
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  Future<void> next() async {
    if (_isPersonalFmActive && _isAtQueueEnd) {
      await _loadNextPersonalFmBatch(isOverplay: false);
      return;
    }
    final nextSong = _nextSong();
    if (nextSong == null) return;
    await playSong(
      nextSong,
      queue: queue,
      preservePersonalFmSession: _isPersonalFmActive,
    );
  }

  Future<void> previous() async {
    final prevSong = _previousSong();
    if (prevSong != null) {
      await playSong(
        prevSong,
        queue: queue,
        preservePersonalFmSession: _isPersonalFmActive,
      );
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> _handleCompleted() async {
    if (_isHandlingCompletion || currentSong == null) return;
    if (_completedSongHash == currentSong!.hash) return;
    _isHandlingCompletion = true;
    _completionFallbackTimer?.cancel();
    _completedSongHash = currentSong!.hash;

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        return;
      }

      // Windows 上 just_audio_windows 的 WinRT MediaPlayer 在触发 completed
      // 事件时，native 回调仍在后台线程执行。若立即调用 setUrl() 加载新音源，
      // 会与 COM 平台线程产生竞态，导致 "Lost connection to device" 进程崩溃。
      // 延迟 100ms 让 native 层完成 completed 状态的清理，再切换到下一首。
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 延迟后重新检查状态，避免在延迟期间用户手动切歌
        if (_completedSongHash != currentSong?.hash) return;
      }

      if (_isPersonalFmActive && _isAtQueueEnd) {
        await _loadNextPersonalFmBatch(isOverplay: true);
        return;
      }

      if (!_isPersonalFmActive && playbackMode == PlaybackMode.singleLoop) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
        await _startPlayback();
        return;
      }

      final nextSong = _nextSong();
      if (nextSong == null) {
        await _audioHandler.seek(Duration.zero);
        return;
      }
      await playSong(
        nextSong,
        queue: queue,
        preservePersonalFmSession: _isPersonalFmActive,
      );
    } finally {
      _isHandlingCompletion = false;
    }
  }

  void _maybeCompleteFromPosition(Duration value) {
    if (_isSeeking || _isScrubbing || !isPlaying || duration <= Duration.zero) {
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      return;
    }

    final remaining = duration - value;
    if (remaining.inMilliseconds <= 750 &&
        (_completionFallbackTimer?.isActive != true)) {
      final delay =
          (remaining > Duration.zero ? remaining : Duration.zero) +
          const Duration(milliseconds: 180);
      _completionFallbackTimer = Timer(delay, () {
        if (!isPlaying || _isSeeking || _isScrubbing) return;
        final currentPosition = audioPlayer.position;
        if (duration > Duration.zero &&
            duration - currentPosition <= const Duration(milliseconds: 220)) {
          unawaited(_handleCompleted());
        }
      });
    }
  }

  Future<void> _reloadCurrentSongForQuality() async {
    final song = currentSong;
    if (song == null) {
      return;
    }

    final resumePlayback = isPlaying;
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    notifyListeners();

    try {
      String url;
      String? networkUrl;
      final local = await downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final PlayUrl playUrl;
        if (song.isCloudDrive) {
          playUrl = await _api.cloudSongUrl(song);
        } else if (song.source == SongSource.netease) {
          playUrl = PlayUrl(
            url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
            hash: song.hash,
          );
        } else {
          playUrl = await _api.songUrl(
            song,
            quality: audioQuality,
            hashOnly: _isPersonalFmActive,
          );
        }
        if (playUrl.url.isEmpty) {
          throw Exception('当前音质暂时没有可播放地址');
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      if (targetPosition > Duration.zero) {
        await _audioHandler.seek(_clampPosition(targetPosition));
      }
      if (resumePlayback) {
        await _startPlayback();
      }
      // 切音质稳定播放后再后台缓存
      if (networkUrl != null) {
        _schedulePlayCache(song, audioQuality, networkUrl);
      }
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isPreparing = false;
      notifyListeners();
    }
  }

  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // 打断开始：系统可能已自动暂停播放器。
          // 若开启了"阻止打断"，立即恢复播放以对抗暂停。
          if (!audioInterruptionEnabled && isPlaying && currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 300), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_startPlayback());
              }
            });
          }
        } else {
          // 打断结束：若开启了"自动恢复"或"阻止打断"，恢复播放。
          if ((autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
              currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_startPlayback());
              }
            });
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (!audioInterruptionEnabled) {
          // 阻止打断模式下忽略耳机拔出
          return;
        }
        if (autoResumeAfterInterruption && currentSong != null) {
          _autoResumeTimer?.cancel();
          _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
            if (!isPlaying && currentSong != null) {
              unawaited(_startPlayback());
            }
          });
        }
      });
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen((devices) {
        if (_previousDevices != null) {
          final addedDevices = devices.difference(_previousDevices!);
          if (addedDevices.isNotEmpty) {
            // ignore: experimental_member_use
            final hasNewAudioDevice = addedDevices.any(
              (d) =>
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothA2dp ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothLe ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothSco ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadset ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadphones ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.carAudio,
            );

            if (hasNewAudioDevice &&
                autoPlayOnDeviceConnected &&
                currentSong != null &&
                !isPlaying) {
              _autoResumeTimer?.cancel();
              _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
                if (!isPlaying && currentSong != null) {
                  unawaited(_startPlayback());
                }
              });
            }
          }
        }
        _previousDevices = devices;
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 阻止打断时使用 [AndroidAudioFocusGainType.gain] 并禁用 androidWillPauseWhenDucked，
  /// 向系统声明不希望被其他 App 打断。同时配合 interruptionEventStream 中的
  /// 主动恢复播放作为双保险。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻止打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    _desktopLyricsUserDismissed = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await _desktopLyrics.checkPermission();
      if (!hasPermission) {
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await _desktopLyrics.requestPermission();
        return;
      }
      final song = currentSong;
      if (song != null) {
        await _syncDesktopLyricsVisibility();
      }
    } else {
      await _desktopLyrics.hide();
    }
  }

  bool get _shouldShowDesktopLyrics {
    return desktopLyricsEnabled &&
        (_desktopLyricsPreviewVisible ||
            (!_desktopLyricsUserDismissed &&
                currentSong != null &&
                !_isAppForeground));
  }

  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      await _desktopLyrics.hide();
      return;
    }

    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (shown) {
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  void _syncDesktopLyrics() {
    if (!_shouldShowDesktopLyrics) return;
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(current: '', next: '');
      return;
    }
    final current = lyrics[index.clamp(0, lyrics.length - 1)].text;
    final nextIndex = index + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    _desktopLyrics.updateLyrics(current: current, next: next);
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  int _lastDesktopLyricIndex = -1;
  int _lastSuperLyricIndex = -1;
  // 初始为 false：App 启动时通常处于暂停态，若初始为 true，
  // 首个 position tick 就会向系统发送一次无意义的 stop/playstate 广播。
  bool _lastSuperLyricPlaying = false;
  int _lastBluetoothLyricIndex = -1;
  bool _lastBluetoothPlaying = false;

  void _maybeSyncDesktopLyricFromPosition() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    _syncDesktopKaraokeProgress();
  }

  void _syncSuperLyricFromPosition() {
    if (currentSong == null) return;
    if (lyrics.isEmpty) {
      // 无歌词时仅处理播放状态变化
      if (!isPlaying && _lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = false;
        _lastSuperLyricIndex = -1;
        unawaited(_superLyric.sendStop());
      } else if (isPlaying && !_lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = true;
      }
      return;
    }
    final index = activeLyricIndex;
    // 行变化且正在播放 → 发歌词
    final lineChanged = isPlaying && (index != _lastSuperLyricIndex);
    // 从暂停切到播放 → 重新发送当前行
    final resumed = isPlaying && !_lastSuperLyricPlaying;
    if (lineChanged || resumed) {
      _lastSuperLyricIndex = index;
      _lastSuperLyricPlaying = true;
      final clampedIndex = index.clamp(0, lyrics.length - 1);
      final line = lyrics[clampedIndex];
      final lineEndTime =
          line.time +
          (line.duration ??
              _estimatedLineDuration(clampedIndex) ??
              Duration.zero);
      unawaited(
        _superLyric.sendLyric(
          song: currentSong!,
          line: line,
          lineEndTime: lineEndTime,
        ),
      );
    } else if (!isPlaying && _lastSuperLyricPlaying) {
      // 切到暂停：发送 stop
      _lastSuperLyricPlaying = false;
      unawaited(_superLyric.sendStop());
    }
  }

  /// 位置流中的车载蓝牙歌词同步入口。
  void _syncBluetoothLyricsFromPosition() {
    if (!bluetoothLyricsEnabled) return;
    if (currentSong == null) return;
    final index = lyrics.isEmpty ? -1 : activeLyricIndex;
    final lineChanged = index != _lastBluetoothLyricIndex;
    final playingChanged = isPlaying != _lastBluetoothPlaying;
    // 状态或行变化时推送
    if (lineChanged || playingChanged) {
      _pushBluetoothLyricForCurrentLine(
        index: index,
        forcePlayState: playingChanged,
      );
    }
  }

  /// 推送当前行歌词到车载蓝牙（MediaSession extras + 系统广播）。
  ///
  /// - [force]：忽略行/状态缓存直接发送一次（用于用户刚打开开关时）
  /// - [index]：当前歌词行索引，-1 表示无歌词；默认取 activeLyricIndex
  /// - [forcePlayState]：即使行未变也发送 playStateChanged 广播
  void _pushBluetoothLyricForCurrentLine({
    bool force = false,
    int? index,
    bool forcePlayState = false,
  }) {
    if (!bluetoothLyricsEnabled || currentSong == null) return;
    final song = currentSong!;
    final resolvedIndex = index ?? (lyrics.isEmpty ? -1 : activeLyricIndex);
    // 行变化判定基准快照（下方 if/else 会更新 _lastBluetoothLyricIndex）
    final prevIndex = _lastBluetoothLyricIndex;

    final String lyricText;
    final String? translationText;
    final String? romanizationText;
    if (lyrics.isEmpty || resolvedIndex < 0) {
      lyricText = '';
      translationText = null;
      romanizationText = null;
      _lastBluetoothLyricIndex = -1;
    } else {
      final clampedIndex = resolvedIndex.clamp(0, lyrics.length - 1);
      final line = lyrics[clampedIndex];
      lyricText = line.text;
      translationText = line.translation;
      romanizationText = line.romanization;
      _lastBluetoothLyricIndex = clampedIndex;
    }

    _lastBluetoothPlaying = isPlaying;

    // 1. MediaSession extras 歌词字段（部分 App/Xposed 读取 MediaSession）
    _audioHandler.updateLyricMetadata(
      lyricText: lyricText.isEmpty ? null : lyricText,
      translationText: translationText,
      romanizationText: romanizationText,
    );

    // 2. 系统广播 + 各 App 自定义广播
    // 行变化判定必须用快照对比：不能用恒真的 lyricText.isNotEmpty，
    // 否则 lineChanged 恒真、forcePlayState 分支永远无法执行，
    // 播放/暂停状态广播会被静默吞掉。
    final lineChanged = force || prevIndex != _lastBluetoothLyricIndex;
    if (lineChanged) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          lyric: lyricText,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
    }
    // 播放/暂停状态变化独立发送，不依赖行是否变化。
    if (forcePlayState) {
      unawaited(
        _bluetoothLyrics.broadcastPlayStateChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
        ),
      );
    }
  }

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);

    if (line.words.isEmpty) {
      // No word-level data: estimate progress from line duration
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      } else {
        _desktopLyrics.updateKaraokeProgress(
          progress: 1.0,
          lineDuration: null,
          isPlaying: isPlaying,
        );
      }
    } else {
      // Word-level: find active word and compute progress
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      }
    }
  }

  Duration? _estimatedLineDuration(int index) {
    if (index < 0 || index >= lyrics.length) {
      return null;
    }
    final explicit = lyrics[index].duration;
    if (explicit != null && explicit > Duration.zero) {
      return explicit;
    }
    if (index + 1 < lyrics.length) {
      final nextDuration = lyrics[index + 1].time - lyrics[index].time;
      if (nextDuration > Duration.zero) {
        return nextDuration;
      }
    }
    if (duration > lyrics[index].time) {
      final tailDuration = duration - lyrics[index].time;
      if (tailDuration > Duration.zero) {
        return tailDuration;
      }
    }
    return null;
  }

  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported => DesktopLyricsService.isSupportedPlatform;

  void setAppForeground(bool isForeground) {
    if (isForeground) {
      // 点开软件或切回前台时，重置用户本次临时关闭悬浮窗的标记，恢复自启动
      _desktopLyricsUserDismissed = false;
    } else {
      // 退到后台时立刻落盘一次完整队列。系统可能在任意时刻回收进程，
      // 只依赖 500ms 防抖 + dispose 会导致「歌曲存了、队列丢了」，
      // 重启后队列退化成单曲，无法在歌单内切歌。
      _queueSaveTimer?.cancel();
      unawaited(_persistQueueState());
    }
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
    if (_desktopLyricsPreviewVisible == visible) return;
    _desktopLyricsPreviewVisible = visible;
    if (visible) {
      _desktopLyricsUserDismissed = false;
    }
    await _syncDesktopLyricsVisibility();
  }

  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed) {
      return;
    }
    // 用户在桌面歌词悬浮窗点击“关闭”按钮：仅临时隐藏本次后台悬浮窗，
    // 不修改持久化设置开关 desktopLyricsEnabled，保证下次“点开软件自启动”。
    _desktopLyricsUserDismissed = true;
    _desktopLyricsPreviewVisible = false;
    notifyListeners();
  }

  /// 获取用户是否在当前后台会话中临时关闭了桌面歌词
  bool get isDesktopLyricsUserDismissed => _desktopLyricsUserDismissed;

  Future<bool> checkDesktopLyricsPermission() =>
      _desktopLyrics.checkPermission();

  Future<void> requestDesktopLyricsPermission() =>
      _desktopLyrics.requestPermission();

  bool get isSleepTimerActive =>
      sleepTimerRemaining != null && sleepTimerRemaining! > Duration.zero;

  bool get isSleepFinishCurrentSong => _sleepFinishCurrentSong;
  bool get sleepFinishCurrentSongOption => _sleepFinishCurrentSongOption;

  /// Set a sleep timer that pauses playback immediately or after current song finishes when it expires.
  void setSleepTimer(Duration duration, {bool finishCurrentSong = false}) {
    _sleepFinishCurrentSongOption = finishCurrentSong;
    _sleepFinishCurrentSong = false;
    _sleepTimer?.cancel();
    _sleepTimerEnd = DateTime.now().add(duration);
    sleepTimerRemaining = duration;
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _sleepTimerEnd;
      if (end == null) return;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        if (_sleepFinishCurrentSongOption) {
          _sleepTimer?.cancel();
          _sleepTimer = null;
          _sleepTimerEnd = null;
          _sleepFinishCurrentSong = true;
          notifyListeners();
        } else {
          _executeSleepTimer();
        }
      } else {
        sleepTimerRemaining = remaining;
        notifyListeners();
      }
    });
  }

  /// Set a sleep timer that finishes the current song, then stops.
  void setSleepTimerFinishSong(Duration duration) {
    setSleepTimer(duration, finishCurrentSong: true);
  }

  /// Update the sleep timer finish song option dynamically.
  void updateSleepTimerOption(bool finishCurrentSong) {
    if (_sleepTimer != null || _sleepFinishCurrentSong) {
      _sleepFinishCurrentSongOption = finishCurrentSong;
      // If the timer has already expired and is waiting for song to finish,
      // and they turn it OFF, we should stop immediately.
      if (!finishCurrentSong && _sleepFinishCurrentSong) {
        _executeSleepTimer();
      } else {
        notifyListeners();
      }
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
  }

  void _executeSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
    unawaited(_audioHandler.pause());
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    addListeningTimeEnabled =
        prefs.getBool(_listenTimeSettingKey) ?? addListeningTimeEnabled;
    keepScreenOnEnabled =
        prefs.getBool(_keepScreenOnSettingKey) ?? keepScreenOnEnabled;
    lyricBlurEnabled = prefs.getBool(_lyricBlurSettingKey) ?? lyricBlurEnabled;
    playerGameEnabled =
        prefs.getBool(_playerGameEnabledSettingKey) ?? playerGameEnabled;
    audioQuality = AudioQuality.fromApiValue(
      prefs.getString(_audioQualitySettingKey),
    );
    smartQualityEnabled =
        prefs.getBool(_smartQualitySettingKey) ?? smartQualityEnabled;
    autoPlayOnStartupEnabled =
        prefs.getBool(_autoPlayOnStartupSettingKey) ?? autoPlayOnStartupEnabled;
    resumeLastPlaylistOnStartupEnabled =
        prefs.getBool(_resumeLastPlaylistOnStartupSettingKey) ??
        resumeLastPlaylistOnStartupEnabled;
    equalizerEnabled =
        prefs.getBool(_equalizerEnabledSettingKey) ?? equalizerEnabled;
    equalizerPresetName =
        prefs.getString(_equalizerPresetSettingKey) ?? equalizerPresetName;
    equalizerLevels = _restoreEqualizerLevels(
      prefs.getString(_equalizerLevelsSettingKey),
    );
    equalizerConfig = EqualizerConfig.fallback(equalizerLevels);
    bassBoostEnabled =
        prefs.getBool(_bassBoostEnabledSettingKey) ?? bassBoostEnabled;
    bassBoostStrength =
        prefs.getDouble(_bassBoostStrengthSettingKey) ?? bassBoostStrength;
    audioInterruptionEnabled =
        prefs.getBool(_audioInterruptionEnabledSettingKey) ??
        audioInterruptionEnabled;
    autoResumeAfterInterruption =
        prefs.getBool(_autoResumeAfterInterruptionSettingKey) ??
        autoResumeAfterInterruption;
    autoPlayOnDeviceConnected =
        prefs.getBool(_autoPlayOnDeviceConnectedSettingKey) ??
        autoPlayOnDeviceConnected;
    volumeNormalizationEnabled =
        prefs.getBool(_volumeNormalizationEnabledSettingKey) ??
        volumeNormalizationEnabled;
    bluetoothLyricsEnabled =
        prefs.getBool(_bluetoothLyricsEnabledSettingKey) ??
            bluetoothLyricsEnabled;
    final savedPendingMs = prefs.getInt(_pendingListenTimeKey) ?? 0;
    if (savedPendingMs > 0) {
      _pendingListenTime = Duration(milliseconds: savedPendingMs);
      // 这部分时长在上次运行中已经计入本地统计，水位对齐避免重复累加。
      _lastStatsFlush = _pendingListenTime;
    }
    bluetoothLyricsTitleSyncEnabled =
        prefs.getBool(_bluetoothLyricsTitleSyncSettingKey) ?? false;
    _audioHandler.setBluetoothLyricsTitleSync(bluetoothLyricsTitleSyncEnabled);
    playbackSpeed = prefs.getDouble(_playbackSpeedSettingKey) ?? playbackSpeed;
    desktopLyricsEnabled =
        prefs.getBool(_desktopLyricsEnabledSettingKey) ?? desktopLyricsEnabled;
    final dlSettingsRaw = prefs.getString(_desktopLyricsSettingsKey);
    if (dlSettingsRaw != null && dlSettingsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(dlSettingsRaw);
        if (map is Map<String, dynamic>) {
          desktopLyricsSettings = DesktopLyricsSettings.fromMap(map);
        }
      } catch (_) {}
    }
    unawaited(audioPlayer.setSpeed(playbackSpeed));
    if (desktopLyricsEnabled) {
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
      unawaited(_syncDesktopLyricsVisibility());
    }
    _syncListeningTimeTracker();
    unawaited(_refreshEqualizerConfig());
    unawaited(_applyEqualizer());
    unawaited(_applyBassBoost());
    unawaited(_applyVolumeNormalization());
    notifyListeners();
    if (!_settingsRestored.isCompleted) {
      _settingsRestored.complete();
    }
  }

  List<int> _restoreEqualizerLevels(String? raw) {
    if (raw == null || raw.isEmpty) {
      return List<int>.of(_defaultEqualizerLevels);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final levels = decoded
            .whereType<num>()
            .map((value) => value.round())
            .toList();
        if (levels.isNotEmpty) {
          return _levelsForBandCount(levels, _defaultEqualizerLevels.length);
        }
      }
    } catch (_) {}
    return List<int>.of(_defaultEqualizerLevels);
  }

  Future<void> _persistEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, equalizerEnabled);
    await prefs.setString(_equalizerPresetSettingKey, equalizerPresetName);
    await prefs.setString(
      _equalizerLevelsSettingKey,
      jsonEncode(equalizerLevels),
    );
  }

  Future<void> _refreshEqualizerConfig() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    final config = await _audioEffects.equalizerConfig(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
    );
    if (config == null || config.bands.isEmpty) {
      return;
    }
    equalizerConfig = config;
    if (equalizerLevels.length != config.bands.length) {
      equalizerLevels = _levelsForBandCount(
        equalizerLevels,
        config.bands.length,
      );
      unawaited(_persistEqualizer());
    }
    notifyListeners();
  }

  Future<void> _applyEqualizer() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    await _audioEffects.configureEqualizer(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: equalizerEnabled,
      levels: equalizerLevels,
    );
  }

  Future<void> _applyBassBoost() async {
    if (!isBassBoostSupported) {
      return;
    }

    await _audioEffects.configureBassBoost(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: bassBoostEnabled,
      strength: bassBoostStrength,
    );
  }

  Future<void> _applyVolumeNormalization() async {
    if (!isAudioEffectsSupported) {
      return;
    }

    await _audioEffects.configureVolumeNormalization(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: volumeNormalizationEnabled,
    );
  }

  void _syncListeningTimeTracker() {
    final shouldTrack =
        addListeningTimeEnabled && isPlaying && currentSong != null;
    if (shouldTrack) {
      _listenTimeStartedAt ??= DateTime.now();
      _listenTimeTimer ??= Timer.periodic(
        _listenTimeCheckInterval,
        (_) => unawaited(_onListenTimeTick()),
      );
      return;
    }

    _pauseListeningTimeTracker();
  }

  /// 每 15 秒一次：独立累计本地统计，并按 5 分钟周期向服务端上报。
  Future<void> _onListenTimeTick() async {
    // 本地统计与本地上报互不影响：先落盘，再尝试上报。
    await _flushListenStats();
    await _maybeReportListeningTime();
  }

  void _pauseListeningTimeTracker() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      _pendingListenTime += DateTime.now().difference(startedAt);
      _listenTimeStartedAt = null;
      SharedPreferences.getInstance().then((prefs) {
        prefs.setInt(_pendingListenTimeKey, _pendingListenTime.inMilliseconds);
      }).catchError((_) {});
      // 暂停/切歌时立刻把已听时长结进本地统计，避免只听了十几秒就退出
      // 导致这段时间完全没有被记录。
      unawaited(_flushListenStats());
    }
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  /// 把尚未计入本地统计的听歌时长增量写入统计。
  ///
  /// 与服务端上报完全解耦：接口失败、未登录、离线播放都不影响本地统计。
  Future<void> _flushListenStats() async {
    final tracked = _trackedListeningTime();
    final delta = tracked - _lastStatsFlush;
    if (delta < const Duration(seconds: 1)) return;
    _lastStatsFlush = tracked;
    try {
      await _statsService.addListenTime(delta);
    } catch (_) {
      // 写盘失败时回退基准，下次继续尝试
      _lastStatsFlush -= delta;
    }
  }

  void _resetListeningTimeTracker() {
    _listenTimeStartedAt = null;
    _pendingListenTime = Duration.zero;
    _lastStatsFlush = Duration.zero;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove(_pendingListenTimeKey);
    }).catchError((_) {});
  }

  Duration _trackedListeningTime() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt == null) {
      return _pendingListenTime;
    }
    return _pendingListenTime + DateTime.now().difference(startedAt);
  }

  Future<void> _maybeReportListeningTime() async {
    if (_isReportingListenTime || !addListeningTimeEnabled) {
      return;
    }
    if (_trackedListeningTime() < _listenTimeReportInterval) {
      return;
    }

    _isReportingListenTime = true;
    try {
      // 先把服务端上报前已累积的本地时长结清，避免上报成功后水位跳变
      // 让后续增量算成负数而丢失。
      await _flushListenStats();
      await _api.addListeningTime();
      // 本地统计已由 _flushListenStats 独立累计，这里只清算上报水位。
      final stillPlaying = isPlaying && currentSong != null;
      final remainder = _trackedListeningTime() - _listenTimeReportInterval;
      _pendingListenTime = remainder > Duration.zero
          ? remainder
          : Duration.zero;
      _listenTimeStartedAt = stillPlaying ? DateTime.now() : null;
      // 上报水位与本地统计水位一起归零对齐
      _lastStatsFlush = _pendingListenTime;
      if (!stillPlaying) {
        _listenTimeTimer?.cancel();
        _listenTimeTimer = null;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingListenTimeKey);
    } catch (error) {
      // 服务端失败不影响本地统计，只记录日志
      debugPrint('[KA Music][listen-time] report failed: $error');
    } finally {
      _isReportingListenTime = false;
    }
  }

  void _schedulePlayCache(Song song, AudioQuality quality, String networkUrl) {
    _playCacheTimer?.cancel();
    _playCacheTimer = Timer(const Duration(seconds: 15), () {
      if (currentSong?.hash != song.hash || !isPlaying) {
        return;
      }
      unawaited(
        downloadController?.cacheForPlayback(song, quality, networkUrl),
      );
    });
  }

  Song? _previousSong() {
    if (queue.isEmpty) {
      return null;
    }

    final index = currentIndex;
    if (_isPersonalFmActive) {
      if (index > 0) {
        return queue[index - 1];
      }
      return null;
    }
    if (playbackMode == PlaybackMode.shuffle) {
      final currentIdentity = currentSong == null
          ? null
          : _songIdentity(currentSong!);
      final prevIdentity = _shuffleCycle.previous(
        queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
        current: currentIdentity,
      );
      if (prevIdentity == null) return null;
      return queue.firstWhere(
        (song) => _songIdentity(song) == prevIdentity,
        orElse: () => currentSong ?? queue.first,
      );
    }

    if (index > 0) {
      return queue[index - 1];
    }

    if (queue.length > 1) {
      return queue.last;
    }
    return null;
  }

  Song? _nextSong() {
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (_isPersonalFmActive) {
      if (index >= 0 && index < queue.length - 1) {
        return queue[index + 1];
      }
      return null;
    }
    if (playbackMode == PlaybackMode.shuffle) {
      final currentIdentity = currentSong == null
          ? null
          : _songIdentity(currentSong!);
      final nextIdentity = _shuffleCycle.next(
        queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
        current: currentIdentity,
      );
      if (nextIdentity == null) return currentSong;
      return queue.firstWhere(
        (song) => _songIdentity(song) == nextIdentity,
        orElse: () => currentSong ?? queue.first,
      );
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    // index == -1 说明当前歌曲不在队列里（重启后快照残缺、外部入口切歌等）。
    // 此时不能直接返回 queue.first：若它正好就是当前歌曲，「下一首」会永远
    // 原地重播同一首，表现为完全无法切歌。改为挑一首不同的歌。
    if (index < 0 && queue.length > 1) {
      final currentIdentity = currentSong == null
          ? ''
          : _songIdentity(currentSong!);
      final different = queue.firstWhere(
        (song) => _songIdentity(song) != currentIdentity,
        orElse: () => queue.first,
      );
      return different;
    }

    return queue.first;
  }

  bool get _isAtQueueEnd {
    final index = currentIndex;
    return index >= 0 && index == queue.length - 1;
  }

  Future<void> _loadNextPersonalFmBatch({required bool isOverplay}) async {
    final song = currentSong;
    if (!_isPersonalFmActive || song == null || !_isAtQueueEnd) {
      return;
    }
    if (_isLoadingPersonalFm) {
      return;
    }

    _isLoadingPersonalFm = true;
    final requestSerial = ++_personalFmRequestSerial;
    errorMessage = null;
    notifyListeners();
    try {
      var incoming = await _api.personalFm(
        hash: song.hash.isEmpty ? null : song.hash,
        songId: song.id.isEmpty ? null : song.id,
        playtime: smoothPosition.inSeconds,
        isOverplay: isOverplay,
      );
      if (requestSerial != _personalFmRequestSerial) {
        return;
      }
      if (!_isPersonalFmActive || currentSong != song || !_isAtQueueEnd) {
        return;
      }

      var additions = _personalFmAdditions(incoming, song);
      if (additions.isEmpty) {
        incoming = await _api.personalFm();
        if (requestSerial != _personalFmRequestSerial ||
            !_isPersonalFmActive ||
            currentSong != song ||
            !_isAtQueueEnd) {
          return;
        }
        additions = _personalFmAdditions(incoming, song);
      }
      if (additions.isEmpty) {
        errorMessage = '私人 FM 暂时没有新的推荐歌曲';
        return;
      }

      queue = [...queue, ...additions];
      await playSong(
        additions.first,
        queue: queue,
        preservePersonalFmSession: true,
      );
    } catch (error) {
      if (requestSerial == _personalFmRequestSerial) {
        errorMessage = error.toString();
      }
    } finally {
      if (requestSerial == _personalFmRequestSerial) {
        _isLoadingPersonalFm = false;
        notifyListeners();
      }
    }
  }

  String _songIdentity(Song song) {
    if (song.hash.isNotEmpty) {
      return 'hash:${song.hash}';
    }
    if (song.albumAudioId?.isNotEmpty == true) {
      return 'audio:${song.albumAudioId}';
    }
    return song.id.isEmpty ? '' : 'id:${song.id}';
  }

  bool _isSameQueue(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_songIdentity(a[i]) != _songIdentity(b[i])) return false;
    }
    return true;
  }

  List<Song> _personalFmAdditions(List<Song> incoming, Song current) {
    final currentIdentity = _songIdentity(current);
    return incoming
        .where((song) {
          final identity = _songIdentity(song);
          return identity.isNotEmpty && identity != currentIdentity;
        })
        .take(5)
        .toList();
  }

  @override
  void dispose() {
    // 让仍在解析播放地址或等待切换音源的请求立即失效，避免销毁后继续更新状态。
    _playRequestSerial++;
    _pauseListeningTimeTracker();
    _stopPositionSaving();
    _queueSaveTimer?.cancel();
    _playCacheTimer?.cancel();
    _autoResumeTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _stateSub.cancel();
    _processingStateSub.cancel();
    _androidAudioSessionSub.cancel();
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesSub?.cancel();
    _completionFallbackTimer?.cancel();
    unawaited(
      _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        levels: equalizerLevels,
      ),
    );
    unawaited(
      _audioEffects.configureBassBoost(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: bassBoostStrength,
      ),
    );
    unawaited(
      _audioEffects.configureVolumeNormalization(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
      ),
    );
    _audioHandler.detachTransportControls();
    _desktopLyrics.setVisibilityChangedHandler(null);
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    positionNotifier.dispose();
    super.dispose();
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    final clamped = _clampPosition(value);
    position = clamped;
    positionNotifier.value = clamped;
    _positionClock
      ..stop()
      ..reset();
    if (playing) {
      _positionClock.start();
    }
  }

  Duration _clampPosition(Duration value) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }

  List<int> _levelsForBandCount(List<int> source, int count) {
    if (count <= 0) {
      return const [];
    }
    if (source.length == count) {
      return List<int>.of(source);
    }
    if (source.length == 1) {
      return List<int>.filled(count, source.first);
    }

    return [
      for (var index = 0; index < count; index++)
        source[((index / math.max(1, count - 1)) * (source.length - 1))
            .round()],
    ];
  }

  // ===== 播放队列持久化 =====

  /// 保存播放队列状态到本地存储（防抖 500ms）。
  void _saveQueueState() {
    _queueSaveTimer?.cancel();
    _queueSaveTimer = Timer(
      const Duration(milliseconds: _queueSaveDebounceMs),
      () => _persistQueueState(),
    );
  }

  /// 立即持久化播放队列、当前歌曲和播放模式。
  ///
  /// 队列、当前歌曲、播放模式必须作为**同一个 JSON 快照**写入：
  /// SharedPreferences 的多次写入不是原子的，一旦进程在中间被杀，
  /// 重启后就会出现「当前歌曲存在但队列丢了」的残缺状态，表现为
  /// 无法在歌单内切歌（下一首永远是它自己），必须重新进歌单点播。
  Future<void> _persistQueueState() async {
    final prefs = await SharedPreferences.getInstance();
    final song = currentSong;
    final snapshot = jsonEncode({
      'mode': playbackMode.name,
      'currentSong': song?.toCache(),
      'queue': queue.map((s) => s.toCache()).toList(),
      if (_queueOrigin != null) 'origin': _queueOrigin!.toJson(),
    });
    // 先写快照（单次原子写入），再更新进度。
    await prefs.setString(_stateKey, snapshot);
    if (song != null) {
      // 进度单独保存：高频更新时无需重写整个队列。
      // 与歌曲 hash 绑定，避免位置被错配到别的歌上。
      final currentPos = audioPlayer.position;
      await prefs.setString(
        _currentPositionKey,
        jsonEncode({
          'hash': song.hash,
          'ms': currentPos.inMilliseconds,
        }),
      );
    } else {
      await prefs.remove(_currentPositionKey);
    }
    // 旧版本的分散字段不再写入：歌单动辄上千首，写多份副本会显著拖慢
    // 主线程外的序列化，也更容易在写入中途被杀导致状态残缺。
  }

  /// 启动定时保存播放进度（每 5 秒）。
  void _startPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(_positionSaveInterval, (_) {
      _saveCurrentPosition();
    });
  }

  /// 保存当前播放进度。
  ///
  /// 进度必须与歌曲绑定（hash + 毫秒）一起存：只存毫秒的话，切歌与写盘
  /// 交错时会把这个位置错配到下一首歌上，重进软件就跳到错误位置。
  void _saveCurrentPosition() {
    final song = currentSong;
    if (song == null) return;
    // 直接读取播放器的实时位置，避免使用可能过时的 position 变量
    final currentPos = audioPlayer.position;
    final payload = jsonEncode({
      'hash': song.hash,
      'ms': currentPos.inMilliseconds,
    });
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString(_currentPositionKey, payload);
    });
  }

  /// 读取磁盘上保存的播放进度，返回 null 表示没有可用进度。
  Duration? _readSavedPosition(SharedPreferences prefs, String? songHash) {
    return parseSavedPosition(prefs.get(_currentPositionKey), songHash);
  }

  /// 停止定时保存播放进度。
  void _stopPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
  }

  /// 同步保存当前播放状态（用于 dispose 时紧急保存）。
  void persistCurrentStateSync() {
    _persistQueueState();
    _saveCurrentPosition();
  }

  /// 用服务端「继续播放」列表填充队列并定位到第一首（不自动播放）。
  void restoreFromServerQueue(List<Song> songs) {
    if (songs.isEmpty || currentSong != null) return;
    queue = List<Song>.of(songs);
    currentSong = songs.first;
    position = Duration.zero;
    positionNotifier.value = Duration.zero;
    // 服务端「继续播放」不提供精确到毫秒的进度，清掉本地待恢复值，
    // 避免把上一次本地记录的进度套到这首歌上。
    _resumePosition = null;
    notifyListeners();
  }

  /// 从本地存储恢复播放队列、当前歌曲和播放进度。
  Future<bool> restoreQueueState() async {
    final requestSerial = _playRequestSerial;
    final prefs = await SharedPreferences.getInstance();
    if (requestSerial != _playRequestSerial) return false;

    String? modeName;
    List<Song> restoredQueue = const [];
    Song? restoredSong;
    QueueOrigin? restoredOrigin;

    // 优先读快照：队列/当前歌曲/模式是同一次写入，不会出现残缺组合。
    final snapshotJson = prefs.getString(_stateKey);
    if (snapshotJson != null && snapshotJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(snapshotJson);
        if (decoded is Map<String, dynamic>) {
          modeName = asString(decoded['mode']);
          restoredQueue = asList(decoded['queue'])
              .whereType<Map<String, dynamic>>()
              .map(Song.fromCache)
              .where((s) => s.hash.isNotEmpty)
              .toList();
          restoredOrigin = QueueOrigin.fromJson(decoded['origin']);
          final songJson = decoded['currentSong'];
          if (songJson is Map<String, dynamic>) {
            restoredSong = Song.fromCache(songJson);
          }
        }
      } catch (_) {}
    }

    // 兼容旧版本的分散字段（升级后首次启动）。
    if (modeName == null) {
      modeName = prefs.getString(_playbackModeKey);
    }
    if (restoredQueue.isEmpty) {
      final queueJson = prefs.getString(_queueKey);
      if (queueJson != null && queueJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(queueJson);
          if (decoded is List) {
            restoredQueue = decoded
                .whereType<Map<String, dynamic>>()
                .map(Song.fromCache)
                .where((s) => s.hash.isNotEmpty)
                .toList();
          }
        } catch (_) {}
      }
    }
    if (restoredSong == null) {
      final songJson = prefs.getString(_currentSongKey);
      if (songJson != null && songJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(songJson);
          if (decoded is Map<String, dynamic>) {
            restoredSong = Song.fromCache(decoded);
          }
        } catch (_) {}
      }
    }

    // 恢复播放模式
    if (modeName != null) {
      for (final mode in PlaybackMode.values) {
        if (mode.name == modeName) {
          playbackMode = mode;
          break;
        }
      }
    }

    // 恢复当前歌曲：队列里找不到时补进去，否则 currentIndex 为 -1，
    // 「下一首」会一直返回同一首，看起来就是无法切歌。
    if (restoredSong != null && restoredSong.hash.isNotEmpty) {
      final identity = _songIdentity(restoredSong);
      if (restoredQueue.isNotEmpty &&
          !restoredQueue.any((item) => _songIdentity(item) == identity)) {
        restoredQueue = List<Song>.of(restoredQueue)..add(restoredSong);
      }
      queue = restoredQueue.isEmpty
          ? [restoredSong]
          : List<Song>.of(restoredQueue);
      currentSong = restoredSong;
    } else if (restoredQueue.isNotEmpty) {
      queue = List<Song>.of(restoredQueue);
      currentSong = restoredQueue.first;
    }

    // 恢复播放进度：只接受与当前歌曲 hash 匹配的记录。
    // 旧版本只存毫秒值（int），升级后仍兼容读取。
    final savedPosition = _readSavedPosition(prefs, currentSong?.hash);
    if (savedPosition != null && savedPosition > Duration.zero) {
      position = savedPosition;
      positionNotifier.value = position;
      _resumePosition = savedPosition;
    } else {
      position = Duration.zero;
      positionNotifier.value = Duration.zero;
      _resumePosition = null;
    }

    _queueOrigin = restoredOrigin;
    notifyListeners();

    // 队列残缺（只剩一首或为空）时按来源补全，保证能继续切歌。
    // 放在 notifyListeners 之后：界面先用已恢复内容渲染，补全后台完成。
    if (restoredOrigin != null && queue.length <= 1) {
      unawaited(_rebuildQueueFromOrigin());
    }
    return true;
  }

  /// 按记忆的队列来源重新拉取完整歌单/专辑，并用它替换当前队列。
  ///
  /// 只在队列明显残缺时触发；当前歌曲不在新队列里就补到队尾，
  /// 避免 currentIndex 变成 -1 导致「下一首」原地不动。
  Future<void> _rebuildQueueFromOrigin() async {
    final origin = _queueOrigin;
    final song = currentSong;
    if (origin == null || song == null) return;
    final requestSerial = _playRequestSerial;
    try {
      final songs = origin.isAlbum
          ? await _api.albumSongs(origin.id, pageSize: 5000)
          : await _api.playlistSongs(origin.id, fetchAll: true);
      if (requestSerial != _playRequestSerial ||
          _queueOrigin != origin ||
          songs.isEmpty) {
        return;
      }
      final identity = _songIdentity(song);
      final rebuilt = List<Song>.of(songs);
      if (!rebuilt.any((item) => _songIdentity(item) == identity)) {
        rebuilt.add(song);
      }
      queue = rebuilt;
      if (playbackMode == PlaybackMode.shuffle) {
        _shuffleCycle.reset(
          queue.map(_songIdentity).where((identity) => identity.isNotEmpty),
          current: identity,
        );
      }
      await _audioHandler.setSongQueue(
        queueSongs: queue,
        queueIndex: currentIndex,
        currentSong: song,
      );
      _saveQueueState();
      notifyListeners();
    } catch (_) {
      // 重建失败保持已恢复的队列，用户重新点歌单也能恢复
    }
  }

  /// 在恢复队列后加载并准备播放当前歌曲（默认不自动播放，仅预加载）。
  ///
  /// [autoPlay] 为 true 时（“恢复上次播放列表”开机模式）加载完成后立即播放。
  Future<void> prepareRestoredSong({
    bool autoPlay = false,
    Song? expectedSong,
  }) async {
    final song = expectedSong ?? currentSong;
    if (song == null ||
        (expectedSong != null && !identical(currentSong, expectedSong))) {
      return;
    }
    final requestSerial = ++_playRequestSerial;
    debugPrint(
      '[KA Music][playback] restore-request=$requestSerial begin '
      'autoPlay=$autoPlay',
    );
    climax = null;
    unawaited(_loadClimax(song));

    // 在加载前保存恢复的进度（loadSong 会重置 position 为 0）。
    // 优先用磁盘上待应用的进度，其次才是内存中的 position。
    final restoredPosition = _resumePosition ?? position;

    isPreparing = true;
    notifyListeners();

    try {
      String url;
      final local = await downloadController?.localPathFor(song, audioQuality);
      if (requestSerial != _playRequestSerial) return;
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        if (requestSerial != _playRequestSerial) return;
        if (playUrl.url.isEmpty) return;
        url = playUrl.url;
      }

      // 恢复音源与用户主动点歌共用同一串行队列。覆盖安装后，
      // 此预加载可能与“播放全部”同时发生；旧恢复请求一旦失效，
      // 不得再覆盖用户新选择的音源或播放状态。
      await _serializeSourceChange(() async {
        if (requestSerial != _playRequestSerial) return;
        await _audioHandler.loadSong(
          song: song,
          url: url,
          queueSongs: queue,
          queueIndex: currentIndex,
        );
        if (requestSerial != _playRequestSerial) return;

        // 跳转到保存的进度
        if (restoredPosition > Duration.zero) {
          await _audioHandler.seek(_clampPosition(restoredPosition));
          if (requestSerial != _playRequestSerial) return;
          _setPositionBase(_clampPosition(restoredPosition), playing: false);
        }
        // 进度已应用到音频引擎，清掉待恢复标记，避免后续再次跳转
        _resumePosition = null;

        unawaited(loadLyrics(song));
        _startPositionSaving();
        if (autoPlay) {
          await _startPlayback();
          if (requestSerial != _playRequestSerial) return;
          // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
          unawaited(_historyService.record(song));
          unawaited(_statsService.recordPlay(song));
        }
      });
    } catch (e) {
      if (requestSerial == _playRequestSerial) {
        debugPrint('[KA Music] Failed to prepare restored song: $e');
      }
    } finally {
      if (requestSerial == _playRequestSerial) {
        isPreparing = false;
        notifyListeners();
      }
    }
  }
}
