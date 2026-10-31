import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/playback_stats_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PlaybackStats 时长格式化', () {
    test('不足一分钟显示秒数，不再统一显示「不足1分钟」', () {
      expect(
        const PlaybackStats(
          totalListenTime: Duration(seconds: 35),
        ).formattedListenTime,
        '35秒',
      );
      expect(
        const PlaybackStats(totalListenTime: Duration.zero).formattedListenTime,
        '0秒',
      );
    });

    test('分钟与小时正常显示', () {
      expect(
        const PlaybackStats(
          totalListenTime: Duration(minutes: 3, seconds: 20),
        ).formattedListenTime,
        '3分钟',
      );
      expect(
        const PlaybackStats(
          totalListenTime: Duration(hours: 2, minutes: 5),
        ).formattedListenTime,
        '2小时5分钟',
      );
    });
  });

  group('PlaybackStatsService 累计', () {
    test('多次累加短时长会真实增长，不受服务端上报影响', () async {
      final service = PlaybackStatsService();

      await service.addListenTime(const Duration(seconds: 15));
      await service.addListenTime(const Duration(seconds: 15));
      await service.addListenTime(const Duration(seconds: 15));

      final stats = await service.getStats();
      expect(stats.totalListenTime, const Duration(seconds: 45));
      expect(stats.formattedListenTime, '45秒');
    });

    test('零或负时长不写入，也不影响已有统计', () async {
      final service = PlaybackStatsService();
      await service.addListenTime(const Duration(seconds: 10));

      await service.addListenTime(Duration.zero);
      await service.addListenTime(const Duration(seconds: -5));

      final stats = await service.getStats();
      expect(stats.totalListenTime, const Duration(seconds: 10));
    });

    test('统计可持久化并在下次读取时恢复', () async {
      final service = PlaybackStatsService();
      await service.addListenTime(const Duration(minutes: 12));

      // 新实例走同一条 SharedPreferences 读取路径
      final restored = await PlaybackStatsService().getStats();
      expect(restored.totalListenTime, const Duration(minutes: 12));
      expect(restored.formattedListenTime, '12分钟');
    });
  });
}
