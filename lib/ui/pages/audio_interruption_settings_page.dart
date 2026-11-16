import 'package:flutter/material.dart';
import '../design_tokens.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';

class AudioInterruptionSettingsPage extends StatelessWidget {
  const AudioInterruptionSettingsPage({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('后台打断机制')),
        body: AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                // Info banner
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '当你在听歌时，其他 App（如短视频、游戏）可能会抢占音频焦点导致音乐暂停。'
                          '你可以在下方调整打断行为。',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // Settings card
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: !player.audioInterruptionEnabled,
                        onChanged: (value) =>
                            player.setAudioInterruptionEnabled(!value),
                        secondary: Icon(
                          Icons.block_rounded,
                          color: colorScheme.primary,
                        ),
                        title: const Text('阻止后台打断'),
                        subtitle: const Text(
                          '其他 App 播放音频时不会暂停当前音乐',
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                      ),
                      Divider(
                        height: 1,
                        indent: 58,
                        color: colorScheme.outlineVariant.withValues(alpha: .4),
                      ),
                      SwitchListTile(
                        value: player.autoResumeAfterInterruption,
                        onChanged: player.setAutoResumeAfterInterruption,
                        secondary: Icon(
                          Icons.play_circle_outline_rounded,
                          color: colorScheme.primary,
                        ),
                        title: const Text('自动恢复播放'),
                        subtitle: const Text('被打断后自动继续播放'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                      ),
                      Divider(
                        height: 1,
                        indent: 58,
                        color: colorScheme.outlineVariant.withValues(alpha: .4),
                      ),
                      SwitchListTile(
                        value: player.autoPauseOnDeviceDisconnect,
                        onChanged: player.setAutoPauseOnDeviceDisconnect,
                        secondary: Icon(
                          Icons.headset_off_rounded,
                          color: colorScheme.primary,
                        ),
                        title: const Text('蓝牙断开停止播放'),
                        subtitle: const Text(
                          '耳机/蓝牙断开时立即暂停，避免意外外放',
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Compatibility notice
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer.withValues(alpha: .3),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.phonelink_setup_rounded,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '兼容性提示：vivo / iQOO 等 OriginOS 系统对安卓音频框架做了深度定制，'
                          '本功能在这些设备上可能无法正常生效。目前暂无适配方案，'
                          '如遇到问题建议在系统设置中关闭相关后台音频优化。',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
