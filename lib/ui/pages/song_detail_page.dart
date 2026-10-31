import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../design_tokens.dart';

/// 打开歌曲详细信息页（与「查看评论」同层级，从歌曲操作弹层进入）。
void openSongDetailPage(
  BuildContext context,
  Song song, {
  MusicApi? api,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SongDetailPage(song: song, api: api),
    ),
  );
}

/// 歌曲详细信息页。
///
/// 版式沿用项目里列表页那一套：分组卡片 + [ListTile]（左图标、右文字），
/// 与歌曲操作弹层里的条目视觉一致。信息分三组，各自独立成卡。
///
/// 各入口解析出的 [Song] 完整度不同（私人 FM / 排行榜 / 云盘等入口不带
/// 专辑与发行信息），所以进入页面后会按 hash 再补取一次详情，拿到就替换，
/// 拿不到就继续用列表里的字段兜底，保证任何入口点进来都能看到信息。
class SongDetailPage extends StatefulWidget {
  const SongDetailPage({super.key, required this.song, this.api});

  final Song song;
  final MusicApi? api;

  @override
  State<SongDetailPage> createState() => _SongDetailPageState();
}

class _SongDetailPageState extends State<SongDetailPage> {
  late Song _song;

  @override
  void initState() {
    super.initState();
    _song = widget.song;
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final api = widget.api;
    final original = widget.song;
    if (api == null) return;
    // 网易云 / 本地歌曲的字段在入口处已经齐全，接口也补不了，直接展示
    if (original.source != SongSource.kugou) return;
    // 字段齐了就不用再请求
    if (_isComplete(original)) return;
    try {
      final detail = await api.songDetail(original);
      if (!mounted || detail == null) return;
      setState(() => _song = _merge(original, detail));
    } catch (_) {
      // 补取失败保持列表字段，页面照常展示
    }
  }

  bool _isComplete(Song song) =>
      (song.albumName ?? '').isNotEmpty &&
      song.releaseDate != null &&
      (song.duration ?? Duration.zero) > Duration.zero;

  /// 接口字段优先，接口没给的保留列表里的值。
  Song _merge(Song from, Song detail) {
    return Song(
      id: detail.id.isNotEmpty ? detail.id : from.id,
      title: detail.title.isNotEmpty ? detail.title : from.title,
      artist: detail.artist.isNotEmpty ? detail.artist : from.artist,
      hash: detail.hash.isNotEmpty ? detail.hash : from.hash,
      albumId: detail.albumId ?? from.albumId,
      albumAudioId: detail.albumAudioId ?? from.albumAudioId,
      albumName: (detail.albumName ?? '').isNotEmpty
          ? detail.albumName
          : from.albumName,
      coverUrl: detail.coverUrl ?? from.coverUrl,
      duration: (detail.duration ?? Duration.zero) > Duration.zero
          ? detail.duration
          : from.duration,
      releaseDate: detail.releaseDate ?? from.releaseDate,
      artists: from.artists,
      isCloudDrive: from.isCloudDrive,
      source: from.source,
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: const Text('歌曲信息')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        children: [
          _InfoGroup(
            title: '基本信息',
            tiles: [
              _InfoTile(
                icon: Icons.music_note_rounded,
                label: '歌名',
                value: song.title,
              ),
              _InfoTile(
                icon: Icons.person_rounded,
                label: '歌手',
                value: song.artist,
              ),
              _InfoTile(
                icon: Icons.album_rounded,
                label: '专辑',
                value: _orUnknown(song.albumName),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _InfoGroup(
            title: '发行信息',
            tiles: [
              _InfoTile(
                icon: Icons.event_rounded,
                label: '发行日期',
                value: _releaseDateText,
              ),
              _InfoTile(
                icon: Icons.schedule_rounded,
                label: '时长',
                value: _durationText,
              ),
              _InfoTile(
                icon: Icons.source_rounded,
                label: '音源',
                value: _sourceText,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _InfoGroup(
            title: '音源标识',
            tiles: [
              _InfoTile(
                icon: Icons.tag_rounded,
                label: '歌曲 ID',
                value: song.id,
                copyable: true,
              ),
              _InfoTile(
                icon: Icons.fingerprint_rounded,
                label: 'Hash',
                value: song.hash,
                copyable: true,
              ),
              if ((song.albumId ?? '').isNotEmpty)
                _InfoTile(
                  icon: Icons.album_outlined,
                  label: '专辑 ID',
                  value: song.albumId!,
                  copyable: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _orUnknown(String? value) =>
      value == null || value.isEmpty ? '未知' : value;

  String get _releaseDateText {
    final date = _song.releaseDate;
    if (date == null) return '未知';
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String get _durationText {
    final duration = _song.duration;
    if (duration == null || duration <= Duration.zero) return '未知';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get _sourceText => switch (_song.source) {
    SongSource.kugou => '酷狗音乐',
    SongSource.netease => '网易云音乐',
    SongSource.local => '本地文件',
  };
}

/// 一组信息卡片：分组标题 + 若干 [ListTile]。
class _InfoGroup extends StatelessWidget {
  const _InfoGroup({required this.title, required this.tiles});

  final String title;
  final List<_InfoTile> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm, bottom: AppSpacing.sm),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                tiles[i],
                if (i != tiles.length - 1)
                  const Divider(height: 1, indent: 56),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 单条信息：左图标、右文字，与弹层里的操作条目同款。
class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(label),
      subtitle: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w600),
      ),
      trailing: copyable
          ? Icon(
              Icons.copy_rounded,
              size: 18,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .7),
            )
          : null,
      onTap: copyable
          ? () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text('已复制$label'),
                    duration: const Duration(milliseconds: 1200),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
            }
          : null,
    );
  }
}
