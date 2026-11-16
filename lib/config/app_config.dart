import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  const AppConfig._();

  static const appName = 'KA Music';
  static const appVersion = '3.3.0';
  static const appVersionCode = '330';

  static const _defaultApiBaseUrl = 'https://music.api.hoilai.cn';
  static const _customBaseUrlKey = 'settings.custom_api_base_url';

  static const apiBaseUrl = String.fromEnvironment(
    'KA_MUSIC_API_BASE_URL',
    defaultValue: _defaultApiBaseUrl,
  );

  static const debugLyrics = bool.fromEnvironment(
    'KA_MUSIC_DEBUG_LYRICS',
    defaultValue: true,
  );

  // ===== 缓存与下载配置 =====
  /// 数据缓存目录名 / 下载目录名 / 播放缓存目录名
  static const cacheDirName = 'ka_music_cache';
  static const downloadDirName = 'KA Music';
  static const playCacheDirName = 'ka_music_play_cache';

  /// 数据缓存 TTL（分级）
  static const homeCacheTtl = Duration(minutes: 30); // 首页推荐
  static const playlistDetailTtl = Duration(hours: 24); // 歌单/专辑详情
  static const userProfileTtl = Duration(hours: 24); // 用户信息+歌单列表

  /// 播放缓存大小上限（超过则按 LRU 清理），下载不设上限（用户主动管理）
  static const playCacheMaxBytes = 300 * 1024 * 1024; // 300MB

  /// 下载并发数
  static const maxConcurrentDownloads = 3;

  /// User-configured API base URL override. When non-null, takes precedence
  /// over the compile-time `apiBaseUrl`.
  static String? _customBaseUrl;

  /// The effective API base URL (custom if set, otherwise the default).
  static String get effectiveBaseUrl => _customBaseUrl ?? apiBaseUrl;

  /// Whether the user has set a custom API base URL.
  static bool get hasCustomBaseUrl => _customBaseUrl != null;

  /// The custom API base URL, or null if using the default.
  static String? get customBaseUrl => _customBaseUrl;

  /// The default (built-in) API base URL.
  static String get defaultApiBaseUrl => apiBaseUrl;

  /// Load the custom API base URL from persistent storage.
  static Future<void> loadCustomBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_customBaseUrlKey);
    if (stored != null && stored.trim().isNotEmpty) {
      _customBaseUrl = stored.trim();
    }
  }

  /// Save a custom API base URL. Pass `null` or empty to reset to default.
  static Future<void> saveCustomBaseUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == apiBaseUrl) {
      _customBaseUrl = null;
      await prefs.remove(_customBaseUrlKey);
    } else {
      _customBaseUrl = trimmed;
      await prefs.setString(_customBaseUrlKey, trimmed);
    }
  }

  static Uri apiUri(String path, [Map<String, Object?> query = const {}]) {
    final base = Uri.parse(effectiveBaseUrl);
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    final normalizedBasePath = base.path.endsWith('/')
        ? base.path
        : '${base.path}/';

    return base.replace(
      path: '$normalizedBasePath$cleanPath',
      queryParameters: {
        for (final entry in query.entries)
          if (entry.value != null && entry.value.toString().isNotEmpty)
            entry.key: entry.value.toString(),
      },
    );
  }
}
