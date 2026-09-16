import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/device_info_service.dart';
import '../ui/adaptive_layout.dart';

/// 全局个性化设置控制器。
///
/// 管理：
/// - 全局种子色（影响配色方案）
/// - 自定义全局背景图（开关 + 图片路径 + 透明度）
///
/// 通过 SharedPreferences 持久化，通过 ChangeNotifier 驱动 UI 重建。
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _instance = this;
  }

  static ThemeController? _instance;
  static ThemeController get instance => _instance!;

  // ===== SharedPreferences keys =====
  static const _seedColorKey = 'theme.seed_color';
  static const _bgEnabledKey = 'theme.bg_enabled';
  static const _bgImagePathKey = 'theme.bg_image_path';
  static const _bgOpacityKey = 'theme.bg_opacity';
  static const _landscapeEnabledKey = 'theme.landscape_enabled';
  static const _carModeEnabledKey = 'theme.car_mode_enabled';
  static const _fontScaleKey = 'theme.font_scale';
  static const _uiBeautificationKey = 'theme.ui_beautification_enabled';

  /// 全局字体大小档位（1.0 = 标准，1.1 = 大，1.2 = 特大）。
  static const fontScaleOptions = [1.0, 1.1, 1.2];

  /// 车机模式下文字放大倍数（远距离观看更清晰）。
  static const double carModeFontScaleFactor = 1.12;

  /// 预设种子色列表。
  static const presetColors = <_PresetColor>[
    _PresetColor(name: '经典蓝', color: Color(0xFF1478FF)),
    _PresetColor(name: '酷狗红', color: Color(0xFFFF2D55)),
    _PresetColor(name: '清新绿', color: Color(0xFF24C768)),
    _PresetColor(name: '优雅紫', color: Color(0xFF8B5CF6)),
    _PresetColor(name: '暖阳橙', color: Color(0xFFF59E0B)),
    _PresetColor(name: '樱花粉', color: Color(0xFFEC4899)),
    _PresetColor(name: '天际青', color: Color(0xFF06B6D4)),
    _PresetColor(name: '石墨灰', color: Color(0xFF64748B)),
  ];

  Color _seedColor = const Color(0xFF1478FF);
  bool _backgroundEnabled = false;
  String? _backgroundImagePath;
  double _backgroundOpacity = 0.15;
  bool _landscapeEnabled = false;
  bool _carModeEnabled = false;
  double _fontScale = 1.0;
  bool _uiBeautificationEnabled = true;
  // 车机检测结果缓存（设备不变，启动时检测一次）。
  bool _isAutomotiveDevice = false;

  bool? _lastAppliedIsTablet;
  bool? _lastAppliedLandscapeEnabled;
  bool? _lastAppliedCarModeEnabled;

  Color get seedColor => _seedColor;
  bool get backgroundEnabled => _backgroundEnabled;
  String? get backgroundImagePath => _backgroundImagePath;
  double get backgroundOpacity => _backgroundOpacity;
  bool get landscapeEnabled => _landscapeEnabled;
  bool get carModeEnabled => _carModeEnabled;

  /// 是否开启 UI 美化（毛玻璃/模糊特效）。关闭后移除所有
  /// BackdropFilter 与 ImageFilter 模糊，提升低端机流畅度。
  bool get uiBeautificationEnabled => _uiBeautificationEnabled;

  double get fontScale => _fontScale;
  bool get isAutomotiveDevice => _isAutomotiveDevice;

  /// 是否使用了非默认种子色。
  bool get hasCustomSeedColor => _seedColor != const Color(0xFF1478FF);

  /// 检测是否为 Android Automotive 车机并缓存结果。
  /// 设备类型不变，启动时调用一次即可。须在 [load] 之前调用，
  /// 以便首次安装时据检测结果决定车机模式默认值。
  Future<void> detectAutomotive(DeviceInfoService deviceInfo) async {
    _isAutomotiveDevice = await deviceInfo.isAutomotive();
  }

  /// 加载持久化设置。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_seedColorKey);
    if (colorValue != null) {
      _seedColor = Color(colorValue);
    }
    _backgroundEnabled = prefs.getBool(_bgEnabledKey) ?? false;
    _backgroundImagePath = prefs.getString(_bgImagePathKey);
    _landscapeEnabled = prefs.getBool(_landscapeEnabledKey) ?? false;
    _uiBeautificationEnabled = prefs.getBool(_uiBeautificationKey) ?? true;
    // 首次安装（键不存在）：检测到车机则默认开启车机模式；
    // 否则默认关闭。用户手动开关过后键一定存在，永不覆盖用户选择。
    if (prefs.containsKey(_carModeEnabledKey)) {
      _carModeEnabled = prefs.getBool(_carModeEnabledKey) ?? false;
      _fontScale = prefs.getDouble(_fontScaleKey) ?? 1.0;
    } else {
      _carModeEnabled = _isAutomotiveDevice;
    }
    final opacity = prefs.getDouble(_bgOpacityKey);
    if (opacity != null) {
      _backgroundOpacity = opacity.clamp(0.0, 0.8);
    }
    applyOrientations(AdaptiveLayout.isTabletByPlatform());
    notifyListeners();

    // 预缓存自定义背景图，避免页面切换时出现纯色闪烁
    if (_backgroundEnabled && _backgroundImagePath != null) {
      final provider = FileImage(File(_backgroundImagePath!));
      provider.resolve(ImageConfiguration.empty);
    }
  }

  /// 设置全局种子色。
  Future<void> setSeedColor(Color color) async {
    if (_seedColor == color) return;
    _seedColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seedColorKey, color.toARGB32());
    notifyListeners();
  }

  /// 开启/关闭自定义背景图。
  Future<void> setBackgroundEnabled(bool enabled) async {
    if (_backgroundEnabled == enabled) return;
    _backgroundEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgEnabledKey, enabled);
    notifyListeners();
  }

  /// 开启/关闭横屏模式。
  Future<void> setLandscapeEnabled(bool enabled, bool isTablet) async {
    if (_landscapeEnabled == enabled) return;
    _landscapeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_landscapeEnabledKey, enabled);
    applyOrientations(isTablet);
    notifyListeners();
  }

  /// 开启/关闭车机模式：横屏时启用左侧播放面板 + 顶栏布局，并放大文字。
  /// 关闭时回到普通横屏（NavigationRail），竖屏始终不受影响。
  Future<void> setFontScale(double scale) async {
    final clamped = fontScaleOptions.contains(scale) ? scale : 1.0;
    if (_fontScale == clamped) return;
    _fontScale = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontScaleKey, clamped);
    notifyListeners();
  }

  Future<void> setCarModeEnabled(bool enabled) async {
    if (_carModeEnabled == enabled) return;
    _carModeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_carModeEnabledKey, enabled);
    applyOrientations(AdaptiveLayout.isTabletByPlatform());
    notifyListeners();
  }

  /// 开启/关闭 UI 美化特效（关闭后移除毛玻璃等模糊，换取流畅度）。
  Future<void> setUiBeautificationEnabled(bool enabled) async {
    if (_uiBeautificationEnabled == enabled) return;
    _uiBeautificationEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_uiBeautificationKey, enabled);
    notifyListeners();
  }

  /// 动态应用屏幕方向锁定/解锁。
  void applyOrientations(bool isTablet) {
    if (_lastAppliedIsTablet == isTablet &&
        _lastAppliedLandscapeEnabled == _landscapeEnabled &&
        _lastAppliedCarModeEnabled == _carModeEnabled) {
      return;
    }
    _lastAppliedIsTablet = isTablet;
    _lastAppliedLandscapeEnabled = _landscapeEnabled;
    _lastAppliedCarModeEnabled = _carModeEnabled;

    if (isTablet || _landscapeEnabled || _carModeEnabled) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  /// 设置背景图路径（null 表示清除）。
  Future<void> setBackgroundImagePath(String? path) async {
    _backgroundImagePath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_bgImagePathKey, path);
    } else {
      await prefs.remove(_bgImagePathKey);
    }
    notifyListeners();
  }

  /// 设置背景透明度（0.0 ~ 0.8，值越大背景越明显）。
  Future<void> setBackgroundOpacity(double opacity) async {
    _backgroundOpacity = opacity.clamp(0.0, 0.8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgOpacityKey, _backgroundOpacity);
    notifyListeners();
  }

  /// 从相册选择图片并复制到应用永久目录。
  ///
  /// 返回是否成功设置。
  Future<bool> pickAndSetBackgroundImage() async {
    // 延迟导入避免非必要平台初始化
    final ImagePicker picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (xFile == null) return false;

    final sourceFile = File(xFile.path);
    if (!await sourceFile.exists()) return false;

    // 复制到应用文档目录，避免临时文件被系统清理
    final docsDir = await getApplicationDocumentsDirectory();
    final ext = xFile.path.contains('.') 
        ? xFile.path.substring(xFile.path.lastIndexOf('.')) 
        : '.jpg';
    final permanentPath = '${docsDir.path}/bg_custom$ext';
    await sourceFile.copy(permanentPath);

    await setBackgroundImagePath(permanentPath);
    if (!_backgroundEnabled) {
      await setBackgroundEnabled(true);
    }
    return true;
  }

  /// 清除自定义背景图。
  Future<void> clearBackgroundImage() async {
    final path = _backgroundImagePath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    await setBackgroundImagePath(null);
    await setBackgroundEnabled(false);
  }
}

/// 预设颜色项。
class _PresetColor {
  const _PresetColor({required this.name, required this.color});

  final String name;
  final Color color;
}
