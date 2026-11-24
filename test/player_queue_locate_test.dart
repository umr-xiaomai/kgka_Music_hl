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
import 'package:kgka_music_hl/ui/app_theme.dart';
import 'package:kgka_music_hl/ui/pages/player_page.dart';
import 'package:kgka_music_hl/ui/pages/playlist_detail_page.dart';
import 'package:kgka_music_hl/ui/widgets/player_queue_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestPlayer extends PlayerController {
  _TestPlayer(MusicApi api) : super(api, MusicAudioHandler());

  void changeTrack(Song song) {
    currentSong = song;
    notifyListeners();
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
  final songs = List.generate(550, (index) {
    final label = index.toString().padLeft(3, '0');
    return Song(
      id: 'song-$index',
      hash: 'hash-$index',
      title: 'Track $label',
      artist: 'Artist',
    );
  });

  late MusicApi api;
  late AuthController auth;
  late _TestPlayer player;

  Future<void> initializePlayer() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'com.ryanheise.just_audio.methods') {
          return call.method == 'init' ? {'id': 'locate-test'} : {};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
      );
    }
    final theme = ThemeController();
    final client = ApiClient();
    api = MusicApi(client);
    auth = AuthController(api, CacheService());
    player = _TestPlayer(api);
    addTearDown(() {
      player.dispose();
      auth.dispose();
      client.close();
      theme.dispose();
    });
    await player.settingsRestored;
  }

  void setScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('one swipe opens the queue and locate jumps to a distant track', (
    tester,
  ) async {
    setScreen(tester);
    await initializePlayer();
    player.queue = List<Song>.of(songs);
    // An earlier copy of the track must not hide the actual queue position.
    player.queue[0] = Song(
      id: songs[480].id,
      hash: songs[480].hash,
      title: 'Earlier copy',
      artist: songs[480].artist,
    );
    player.changeTrack(songs[480]);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(player: player, auth: auth),
      ),
    );
    await tester.pumpAndSettle();

    final pages = find.byType(PageView);
    await tester.drag(pages, const Offset(-365, 0));
    await tester.pumpAndSettle();
    final queue = find.byType(PlayerQueueView);
    final locateButton = find.descendant(
      of: queue,
      matching: find.byTooltip('定位到当前歌曲'),
    );
    final activeTitle = find.descendant(
      of: queue,
      matching: find.text(songs[480].title),
    );
    expect(locateButton.hitTestable(), findsOneWidget);
    expect(activeTitle, findsNothing);
    await tester.tap(locateButton);
    await tester.pumpAndSettle();
    expect(activeTitle.hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(of: activeTitle, matching: find.byType(ListTile)),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('暂无歌词').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('播放封面'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放列表').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'playlist locate uses the sorted list and clears a hiding search',
    (tester) async {
      setScreen(tester);
      await initializePlayer();
      player.changeTrack(songs.last);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.45,
            child: child!,
          ),
          home: PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: const PlaylistSummary(id: 'static', title: '测试歌单'),
            initialSongs: songs.reversed.toList(),
            readOnly: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('默认排序').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('按歌名').last);
      await tester.pumpAndSettle();

      player.changeTrack(songs[480]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), songs.first.title);
      await tester.pumpAndSettle();
      expect(find.text(songs[480].title), findsNothing);

      await tester.tap(find.byTooltip('定位到当前歌曲'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text(songs[480].title).hitTestable(), findsOneWidget);
      expect(find.text('481').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
