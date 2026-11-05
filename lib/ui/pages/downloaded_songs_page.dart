import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../adaptive_layout.dart';
import '../widgets/liquid_glass_ui.dart';
import '../widgets/mini_player.dart';
import '../widgets/status_bar_overlay.dart';
import 'song_detail_page.dart';

/// 已下载歌曲与播放缓存管理页。
class DownloadedSongsPage extends StatefulWidget {
  const DownloadedSongsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  State<DownloadedSongsPage> createState() => _DownloadedSongsPageState();
}

class _DownloadedSongsPageState extends State<DownloadedSongsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StatusBarOverlay(
      brightness: Theme.of(context).brightness,
      child: LiquidGlassBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('已下载'),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '已下载'),
              Tab(text: '播放缓存'),
            ],
          ),
        ),
        extendBody: true,
        body: AdaptiveContentPadding(
          child: TabBarView(
            controller: _tabController,
            children: [
              _DownloadedList(
                api: widget.api,
                auth: widget.auth,
                player: widget.player,
                downloads: widget.downloads,
              ),
              _PlayCacheList(downloads: widget.downloads),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MiniPlayer(
              player: widget.player,
              auth: widget.auth,
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// 已下载列表。
class _DownloadedList extends StatelessWidget {
  const _DownloadedList({
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        final entries = downloads.downloadEntries;
        final completed =
            entries.where((e) => e.status == DownloadStatus.downloaded).toList();
        final downloading =
            entries.where((e) => e.status == DownloadStatus.downloading).toList();
        final failed =
            entries.where((e) => e.status == DownloadStatus.failed).toList();

        if (entries.isEmpty) {
          return _emptyState(context, '还没有已下载歌曲', '下载歌曲后可离线播放');
        }

        return ListView(
          children: [
            if (completed.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                child: Row(
                  children: [
                    Text(
                      '已下载 ${completed.length} 首',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _confirmClearAll(context),
                      child: const Text('清空全部'),
                    ),
                  ],
                ),
              ),
              ...completed.map((entry) => _DownloadedSongRow(
                    entry: entry,
                    api: api,
                    auth: auth,
                    player: player,
                    downloads: downloads,
                  )),
            ],
            if (downloading.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Text(
                  '下载中 ${downloading.length} 首',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              ...downloading.map((entry) => _DownloadingRow(entry: entry)),
            ],
            if (failed.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Text(
                  '下载失败 ${failed.length} 首',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ),
              ...failed.map(
                (entry) => _FailedRow(entry: entry, downloads: downloads),
              ),
            ],
          ],
        );
      },
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部下载'),
        content: const Text('确定要删除所有已下载的歌曲吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              downloads.clearAllDownloads();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

/// 已下载歌曲行。
class _DownloadedSongRow extends StatelessWidget {
  const _DownloadedSongRow({
    required this.entry,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final DownloadEntry entry;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    final isCurrent = player.currentSong?.hash == song.hash;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Artwork(
        url: song.coverUrl,
        size: 48,
        borderRadius: 8,
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent
            ? TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w600)
            : null,
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_circle_fill_rounded),
            color: colorScheme.primary,
            onPressed: () {
              player.playSong(song);
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => _showActions(context, song),
          ),
        ],
      ),
      onTap: () => player.playSong(song),
    );
  }

  void _showActions(BuildContext context, Song song) {
    final filePath = entry.filePath;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('歌曲信息'),
              onTap: () {
                Navigator.pop(ctx);
                openSongDetailPage(context, song, api: api);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除下载'),
              onTap: () {
                Navigator.pop(ctx);
                downloads.deleteDownload(song);
              },
            ),
            if (filePath != null && filePath.isNotEmpty) ...[
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('打开文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openContainingFolder(filePath);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('查看文件路径'),
                subtitle: Text(
                  filePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: filePath));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('路径已复制到剪贴板'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openContainingFolder(String filePath) async {
    final file = File(filePath);
    final dir = file.parent.path;

    if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dir]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir]);
    } else if (Platform.isAndroid) {
      // Android 无法直接打开文件管理器到指定目录，尝试用 file:// URI
      final uri = Uri.parse('file://$dir');
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        // 回退：尝试 content URI 方式
        final contentUri = Uri.parse('content://com.android.externalstorage.documents/document/primary:${dir.replaceFirst('/storage/emulated/0/', '')}');
        await launchUrl(contentUri, mode: LaunchMode.externalApplication);
      }
    }
  }
}

/// 下载中行（显示进度）。
class _DownloadingRow extends StatelessWidget {
  const _DownloadingRow({required this.entry});

  final DownloadEntry entry;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    return ListTile(
      leading: Artwork(url: song.coverUrl, size: 48, borderRadius: 8),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: SizedBox(
        width: 28,
        height: 28,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: entry.progress > 0 ? entry.progress : null,
              strokeWidth: 2.5,
            ),
            if (entry.progress > 0)
              Text(
                '${(entry.progress * 100).round()}',
                style: const TextStyle(fontSize: 9),
              ),
          ],
        ),
      ),
    );
  }
}

/// 下载失败行（可重试或移除）。
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.entry, required this.downloads});

  final DownloadEntry entry;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Artwork(url: song.coverUrl, size: 48, borderRadius: 8),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        entry.error ?? '下载失败',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colorScheme.error.withValues(alpha: .85),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '重新下载',
            icon: const Icon(Icons.refresh_rounded),
            color: colorScheme.primary,
            onPressed: () => downloads.download(song, entry.quality),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => downloads.removeFailed(song),
          ),
        ],
      ),
    );
  }
}

/// 播放缓存列表。
class _PlayCacheList extends StatelessWidget {
  const _PlayCacheList({required this.downloads});

  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        final entries = downloads.playCacheEntries;
        if (entries.isEmpty) {
          return _emptyState(context, '还没有播放缓存', '播放歌曲后会自动缓存');
        }

        final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.size);

        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
              child: Row(
                children: [
                  Text(
                    '缓存 ${entries.length} 首 · ${_formatBytes(totalBytes)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _confirmClearCache(context),
                    child: const Text('清空缓存'),
                  ),
                ],
              ),
            ),
            ...entries.map((entry) => ListTile(
                  leading: Artwork(url: entry.song.coverUrl, size: 48, borderRadius: 8),
                  title: Text(
                    entry.song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${entry.song.artist} · ${_formatBytes(entry.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () =>
                        downloads.deletePlayCache(entry.song, entry.quality),
                  ),
                )),
          ],
        );
      },
    );
  }

  void _confirmClearCache(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空播放缓存'),
        content: const Text('确定要清空所有播放缓存吗？下次播放需要重新加载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              downloads.clearPlayCache();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

Widget _emptyState(BuildContext context, String title, String subtitle) {
  final colorScheme = Theme.of(context).colorScheme;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_done_rounded,
            size: 64,
            color: colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
