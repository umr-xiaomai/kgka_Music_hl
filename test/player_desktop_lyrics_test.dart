import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/ui/pages/player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RouteObserver extends NavigatorObserver {
  final poppedPages = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) poppedPages.add(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    'com.ryanheise.just_audio.methods',
    'com.ryanheise.audio_service.client.methods',
    'com.ryanheise.audio_service.handler.methods',
    'kgka_music_hl/audio_effects',
    'kgka_music_hl/super_lyric',
    'kgka_music_hl/bluetooth_lyrics',
    'kgka_music_hl/desktop_lyrics',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async {
            if (name == 'com.ryanheise.just_audio.methods') {
              return call.method == 'init' ? {'id': 'lyrics-menu-test'} : {};
            }
            if (call.method == 'checkPermission') return true;
            if (name == 'kgka_music_hl/super_lyric') return true;
            return null;
          });
    }
  });

  tearDown(() {
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  for (final carMode in [false, true]) {
    testWidgets('${carMode ? '车机' : '竖屏'}播放页切换桌面歌词只关闭菜单，不移除宿主页面', (
      tester,
    ) async {
      tester.view.physicalSize = carMode
          ? const Size(1280, 800)
          : const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = ThemeController();
      await theme.setCarModeEnabled(carMode);
      final client = ApiClient();
      final api = MusicApi(client);
      final auth = AuthController(api, CacheService());
      final player = PlayerController(api, MusicAudioHandler());
      await player.settingsRestored;
      player.currentSong = Song(
        id: 'test-song',
        title: '测试歌曲',
        artist: '测试歌手',
        hash: 'test-hash',
      );
      final observer = _RouteObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      var closeRequests = 0;

      // AppShell 将播放器叠在根页面上，播放器本身并不是可 pop 的路由。
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          home: PlayerPage(
            player: player,
            auth: auth,
            onClose: () => closeRequests++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final enabled in [true, false]) {
        await tester.tap(find.byTooltip('更多').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('桌面歌词'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(player.desktopLyricsEnabled, enabled);
        expect(observer.poppedPages, isEmpty);
        expect(find.byType(PlayerPage), findsOneWidget);
        expect(navigatorKey.currentState!.canPop(), isFalse);
        expect(closeRequests, 0);
      }

      // 菜单关闭后宿主的返回交互仍可用。
      await tester.tap(find.byTooltip('返回').first);
      expect(closeRequests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      auth.dispose();
      theme.dispose();
      client.close();
      await tester.pump();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
