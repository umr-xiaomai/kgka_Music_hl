import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/toast.dart';
import 'cloud_drive_page.dart';
import 'downloaded_songs_page.dart';
import 'playback_history_page.dart';
import 'playlist_detail_page.dart';
import 'settings_page.dart';
import 'local_songs_page.dart';
import '../../controllers/local_music_controller.dart';
import '../../core/pinyin_utils.dart';

/// 歌单排序模式。
enum _PlaylistSortMode { defaultOrder, byName, bySongCount, byCreatedTime }

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  // 折叠状态管理（改 tab 为折叠）
  bool _expandedCreated = true;
  bool _expandedCollected = true;
  bool _expandedAlbums = false;
  bool _expandedCloud = true;

  // 歌单排序模式
  _PlaylistSortMode _sortMode = _PlaylistSortMode.defaultOrder;

  // 多选管理状态
  bool _multiSelectMode = false;
  final Set<int> _selectedIndices = {};
  String _selectedSection = 'created'; // 'created' | 'collected' | 'albums'

  void _openPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  bool _isLandscape(BuildContext ctx) {
    final size = MediaQuery.sizeOf(ctx);
    return size.width > size.height;
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          theme: widget.theme,
          downloads: widget.downloads,
          cache: widget.player.cacheService,
          localMusic: widget.localMusic,
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => _CreatePlaylistSheet(),
    );
    if (name == null) return;

    await widget.auth.createPlaylist(name);
    if (!mounted) return;
    if (widget.auth.errorMessage != null) {
      Toast.error('创建失败：${widget.auth.errorMessage}');
    } else {
      Toast.success('歌单已创建');
    }
  }

  List<PlaylistSummary> _sortedPlaylists(List<PlaylistSummary> playlists) {
    switch (_sortMode) {
      case _PlaylistSortMode.byName:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        return sorted;
      case _PlaylistSortMode.bySongCount:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => (b.songCount ?? 0).compareTo(a.songCount ?? 0));
        return sorted;
      case _PlaylistSortMode.byCreatedTime:
      case _PlaylistSortMode.defaultOrder:
        return playlists;
    }
  }

  String get _sortModeLabel {
    return switch (_sortMode) {
      _PlaylistSortMode.defaultOrder => '默认排序',
      _PlaylistSortMode.byName => '按名称',
      _PlaylistSortMode.bySongCount => '按歌曲数',
      _PlaylistSortMode.byCreatedTime => '按创建时间',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_PlaylistSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_PlaylistSortMode.defaultOrder, '默认排序'),
          (_PlaylistSortMode.byName, '按名称'),
          (_PlaylistSortMode.bySongCount, '按歌曲数'),
          (_PlaylistSortMode.byCreatedTime, '按创建时间'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '排序方式',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _SortOptionTile(
                          label: options[i].$2,
                          selected: _sortMode == options[i].$1,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(options[i].$1),
                        ),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 16,
                            color: colorScheme.outlineVariant
                                .withValues(alpha: .3),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && selected != _sortMode) {
      setState(() => _sortMode = selected);
    }
  }

  void _enterMultiSelect(String section, int index) {
    setState(() {
      _selectedSection = section;
      _multiSelectMode = true;
      _selectedIndices
        ..clear()
        ..add(index);
    });
  }

  void _toggleSelected(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) {
          _multiSelectMode = false;
        }
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelectMode = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _deleteSelected(List<PlaylistSummary> currentList) async {
    final targets = _selectedIndices
        .where((i) => i >= 0 && i < currentList.length)
        .map((i) => currentList[i])
        .toList();
    if (targets.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定要删除选中的 ${targets.length} 个歌单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final playlist in targets) {
      try {
        await widget.auth.deleteOrUncollectPlaylist(playlist);
      } catch (_) {}
    }
    if (!mounted) return;
    if (widget.auth.errorMessage != null) {
      Toast.error('删除失败：${widget.auth.errorMessage}');
    } else {
      Toast.success('已删除 ${targets.length} 个歌单');
    }
    _exitMultiSelect();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              widget.auth,
              widget.downloads,
              widget.localMusic,
            ]),
            builder: (context, _) {
              final created = widget.auth.createdPlaylists;
              final collected = widget.auth.collectedPlaylists;
              final albums = widget.auth.collectedAlbums;
              final sortedCreated = _sortedPlaylists(created);
              final sortedCollected = _sortedPlaylists(collected);
              final sortedAlbums = _sortedPlaylists(albums);

              return CustomScrollView(
                slivers: [
                  // 1. 顶部 Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '我的',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                  ),
                            ),
                          ),
                          IconButton(
                            tooltip: '创建歌单',
                            onPressed: _showCreatePlaylistDialog,
                            icon: const Icon(Icons.add_rounded),
                          ),
                          if (!(_isLandscape(context) && widget.theme.carModeEnabled))
                            IconButton(
                              tooltip: '设置',
                              onPressed: _openSettings,
                              icon: const Icon(Icons.settings_rounded),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // 2. 用户资料头部（同款用户区域）
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                      child: _UserProfileHeader(auth: widget.auth),
                    ),
                  ),

                  // 3. 同款 2x2 核心功能卡片网格（我喜欢、最近播放、本地音乐、已下载）
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                      child: _LibraryQuickGrid(
                        auth: widget.auth,
                        downloads: widget.downloads,
                        localMusic: widget.localMusic,
                        onOpenLiked: widget.auth.likedPlaylist == null
                            ? null
                            : () => _openPlaylist(widget.auth.likedPlaylist!),
                        onOpenRecent: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlaybackHistoryPage(
                              api: widget.api,
                              auth: widget.auth,
                              player: widget.player,
                            ),
                          ),
                        ),
                        onOpenLocal: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => LocalSongsPage(
                              player: widget.player,
                              localMusic: widget.localMusic,
                            ),
                          ),
                        ),
                        onOpenDownloads: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DownloadedSongsPage(
                              api: widget.api,
                              auth: widget.auth,
                              player: widget.player,
                              downloads: widget.downloads,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 20)),

                  // 4. 折叠分组 1：我创建的歌单
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我创建的歌单',
                        count: created.length,
                        isExpanded: _expandedCreated,
                        onToggle: () =>
                            setState(() => _expandedCreated = !_expandedCreated),
                        trailingActions: [
                          IconButton(
                            icon: const Icon(Icons.add_rounded, size: 20),
                            visualDensity: VisualDensity.compact,
                            tooltip: '新建歌单',
                            onPressed: _showCreatePlaylistDialog,
                          ),
                          if (created.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.sort_rounded, size: 19),
                              visualDensity: VisualDensity.compact,
                              tooltip: _sortModeLabel,
                              onPressed: () => _showSortSheet(context),
                            ),
                        ],
                        child: _multiSelectMode && _selectedSection == 'created'
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _MultiSelectBar(
                                    selectedCount: _selectedIndices.length,
                                    onCancel: _exitMultiSelect,
                                    onDelete: () => _deleteSelected(sortedCreated),
                                  ),
                                  _PlaylistGroup(
                                    playlists: sortedCreated,
                                    multiSelectMode: true,
                                    selectedIndices: _selectedIndices,
                                    onOpen: _openPlaylist,
                                    onTapInMultiSelect: _toggleSelected,
                                  ),
                                ],
                              )
                            : (sortedCreated.isEmpty
                                ? const _EmptyGroup()
                                : _PlaylistGroup(
                                    playlists: sortedCreated,
                                    onOpen: _openPlaylist,
                                    onLongPress: (i) =>
                                        _enterMultiSelect('created', i),
                                  )),
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // 5. 折叠分组 2：我收藏的歌单
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我收藏的歌单',
                        count: collected.length,
                        isExpanded: _expandedCollected,
                        onToggle: () => setState(
                            () => _expandedCollected = !_expandedCollected),
                        child: sortedCollected.isEmpty
                            ? const _EmptyGroup()
                            : _PlaylistGroup(
                                playlists: sortedCollected,
                                onOpen: _openPlaylist,
                              ),
                      ),
                    ),
                  ),

                  // 6. 折叠分组 3：收藏的专辑（若有或需要展示）
                  if (albums.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: _CollapsibleSection(
                          title: '收藏的专辑',
                          count: albums.length,
                          isExpanded: _expandedAlbums,
                          onToggle: () => setState(
                              () => _expandedAlbums = !_expandedAlbums),
                          child: sortedAlbums.isEmpty
                              ? const _EmptyGroup()
                              : _PlaylistGroup(
                                  playlists: sortedAlbums,
                                  onOpen: _openPlaylist,
                                ),
                        ),
                      ),
                    ),
                  ],

                  const SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // 7. 折叠分组 4：我的云盘（独立放到最下面）
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我的云盘',
                        isExpanded: _expandedCloud,
                        onToggle: () =>
                            setState(() => _expandedCloud = !_expandedCloud),
                        child: _CloudDriveSectionItem(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CloudDrivePage(
                                api: widget.api,
                                auth: widget.auth,
                                player: widget.player,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 底部安全留白，避免内容被悬浮黑胶底栏遮挡
                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
// --- 1. 用户资料头部 (User Profile Header) ---

class _UserProfileHeader extends StatelessWidget {
  const _UserProfileHeader({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final profile = auth.profile;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 54,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? .35 : .08),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                ),
                ClipOval(
                  child: profile?.avatarUrl == null || profile!.avatarUrl!.isEmpty
                      ? Center(
                          child: Icon(
                            Icons.person_rounded,
                            color: colorScheme.primary,
                            size: 30,
                          ),
                        )
                      : Image.network(
                          profile.avatarUrl!,
                          width: 54,
                          height: 54,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              Icons.person_rounded,
                              color: colorScheme.primary,
                              size: 30,
                            ),
                          ),
                        ),
                ),
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: .24)
                            : Colors.white.withValues(alpha: .95),
                        width: 1.8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile?.nickname ?? 'KA Music 用户',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Container(
                      width: 7.5,
                      height: 7.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: auth.isLoggedIn
                            ? const Color(0xFF4CAF50)
                            : colorScheme.onSurfaceVariant.withValues(alpha: .45),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      auth.isLoggedIn ? '已登录' : '未登录',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- 2. 同款 2x2 核心功能卡片网格 (2x2 Quick Grid) ---

class _LibraryQuickGrid extends StatelessWidget {
  const _LibraryQuickGrid({
    required this.auth,
    required this.downloads,
    required this.localMusic,
    required this.onOpenLiked,
    required this.onOpenRecent,
    required this.onOpenLocal,
    required this.onOpenDownloads,
  });

  final AuthController auth;
  final DownloadController downloads;
  final LocalMusicController localMusic;
  final VoidCallback? onOpenLiked;
  final VoidCallback onOpenRecent;
  final VoidCallback onOpenLocal;
  final VoidCallback onOpenDownloads;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _QuickHubTile(
                icon: Icons.favorite_rounded,
                title: '收藏',
                subtitle: '${auth.likedCount} 首',
                gradientColors: const [Color(0xFFFF85A1), Color(0xFFFF3366)],
                onTap: onOpenLiked,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickHubTile(
                icon: Icons.access_time_filled_rounded,
                title: '最近',
                subtitle: '播放历史',
                gradientColors: const [Color(0xFF70B9FE), Color(0xFF2C7BF6)],
                onTap: onOpenRecent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AnimatedBuilder(
                animation: localMusic,
                builder: (context, _) => _QuickHubTile(
                  icon: Icons.computer_rounded,
                  title: '本地',
                  subtitle: '${localMusic.songs.length} 首',
                  gradientColors: const [Color(0xFF67E3C8), Color(0xFF00BFA5)],
                  onTap: onOpenLocal,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedBuilder(
                animation: downloads,
                builder: (context, _) => _QuickHubTile(
                  icon: Icons.download_done_rounded,
                  title: '已下载',
                  subtitle: '${downloads.downloadedSongs.length} 首',
                  gradientColors: const [Color(0xFF81D4FA), Color(0xFF0288D1)],
                  onTap: onOpenDownloads,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickHubTile extends StatefulWidget {
  const _QuickHubTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradientColors,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> gradientColors;
  final VoidCallback? onTap;

  @override
  State<_QuickHubTile> createState() => _QuickHubTileState();
}

class _QuickHubTileState extends State<_QuickHubTile> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final primaryColor = widget.gradientColors.last;
    final cardBgColor = isDark
        ? Colors.white.withValues(alpha: .06)
        : Colors.white.withValues(alpha: .85);
    final cardBorderColor = isDark
        ? Colors.white.withValues(alpha: .12)
        : Colors.white.withValues(alpha: .92);

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: cardBgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cardBorderColor, width: 1.1),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: .20)
                    : const Color(0x0C000000),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.gradientColors,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: isDark ? .40 : .30),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(widget.icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 3. 折叠分组组件 (Collapsible Section) ---

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    this.count,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailingActions,
  });

  final String title;
  final int? count;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final List<Widget>? trailingActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: isExpanded ? 0.0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                ...?trailingActions,
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        AnimatedCrossFade(
          firstChild: child,
          secondChild: const SizedBox.shrink(),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 220),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

// --- 4. 云盘独立列表项组件 (Cloud Drive Section Item) ---

class _CloudDriveSectionItem extends StatelessWidget {
  const _CloudDriveSectionItem({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return LiquidGlassCard(
      borderRadius: AppRadius.lg,
      padding: EdgeInsets.zero,
      enableTouchFlex: false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF68B0FB), Color(0xFF3378FF)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3378FF).withValues(alpha: isDark ? .40 : .30),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '云盘音乐',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '随时随地，同步云端音乐资产',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 5. 排序选项条目 (Sort Option Tile) ---

class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: selected ? colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// --- 6. 多选模式操作栏 (Multi-Select Bar) ---

class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.selectedCount,
    required this.onCancel,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '取消',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: Text(
              '已选中 $selectedCount 项',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: selectedCount > 0 ? onDelete : null,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('删除'),
            style: FilledButton.styleFrom(
              foregroundColor: colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

// --- 7. 空态提示组件 (Empty Group) ---

class _EmptyGroup extends StatelessWidget {
  const _EmptyGroup();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 42,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              '这里还没有内容',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 8. 歌单卡片分组 (Playlist Group) ---

class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({
    required this.playlists,
    required this.onOpen,
    this.multiSelectMode = false,
    this.selectedIndices = const {},
    this.onLongPress,
    this.onTapInMultiSelect,
  });

  final List<PlaylistSummary> playlists;
  final void Function(PlaylistSummary) onOpen;
  final bool multiSelectMode;
  final Set<int> selectedIndices;
  final void Function(int index)? onLongPress;
  final void Function(int index)? onTapInMultiSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 720;
    final isUltraWide = size.width >= 1200;

    if (isWide) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: isUltraWide ? 280 : 340,
          mainAxisExtent: 72,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          return LiquidGlassCard(
            borderRadius: AppRadius.lg,
            padding: EdgeInsets.zero,
            child: _PlaylistRow(
              playlist: playlists[i],
              selected: multiSelectMode && selectedIndices.contains(i),
              multiSelectMode: multiSelectMode,
              onTap: multiSelectMode
                  ? () => onTapInMultiSelect?.call(i)
                  : () => onOpen(playlists[i]),
              onLongPress: () => onLongPress?.call(i),
            ),
          );
        },
      );
    }

    return LiquidGlassCard(
      borderRadius: AppRadius.lg,
      padding: EdgeInsets.zero,
      enableTouchFlex: false,
      child: Column(
        children: [
          for (var i = 0; i < playlists.length; i++) ...[
            _PlaylistRow(
              playlist: playlists[i],
              selected: multiSelectMode && selectedIndices.contains(i),
              multiSelectMode: multiSelectMode,
              onTap: multiSelectMode
                  ? () => onTapInMultiSelect?.call(i)
                  : () => onOpen(playlists[i]),
              onLongPress: () => onLongPress?.call(i),
            ),
            if (i < playlists.length - 1)
              Divider(
                height: 1,
                indent: 62,
                color: colorScheme.outlineVariant.withValues(alpha: .3),
              ),
          ],
        ],
      ),
    );
  }
}

// --- 9. 歌单列表单项 (Playlist Row) ---

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.multiSelectMode = false,
  });

  final PlaylistSummary playlist;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool multiSelectMode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            if (multiSelectMode)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          key: const ValueKey('checked'),
                          size: 26,
                          color: colorScheme.primary,
                        )
                      : Icon(
                          Icons.radio_button_unchecked_rounded,
                          key: const ValueKey('unchecked'),
                          size: 26,
                          color: colorScheme.outline,
                        ),
                ),
              )
            else
              Artwork(url: playlist.coverUrl, size: 44, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    playlist.songCount == null
                        ? (playlist.subtitle ?? '歌单')
                        : '${playlist.songCount} 首歌',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (!multiSelectMode)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}

// --- 10. 创建歌单 BottomSheet ---

class _CreatePlaylistSheet extends StatefulWidget {
  @override
  State<_CreatePlaylistSheet> createState() => _CreatePlaylistSheetState();
}

class _CreatePlaylistSheetState extends State<_CreatePlaylistSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    final trimmed = (value ?? _controller.text).trim();
    Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '创建歌单',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '请输入歌单名称',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            onSubmitted: _submit,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _submit(),
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
