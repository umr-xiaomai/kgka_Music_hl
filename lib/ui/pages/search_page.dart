import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../../services/search_history_service.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';
import 'dart:math' as math;

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 搜索平台。
enum _SearchPlatform { kugou, netease }

/// 搜索类型。
enum _SearchType { song, album }

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<SearchHotCategory> _hotCategories = const [];
  var _hotLoading = true;
  List<String> _suggestions = const [];
  List<Song> _results = const [];
  List<ArtistAlbum> _albums = const [];
  bool _loading = false;
  bool _searched = false;
  _SearchPlatform _platform = _SearchPlatform.kugou;
  _SearchType _type = _SearchType.song;

  // 搜索历史
  final _historyService = SearchHistoryService();
  List<String> _searchHistory = const [];

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    _loadHotKeywords();
    _loadSearchHistory();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHotKeywords() async {
    try {
      final categories = await widget.api.searchHotKeywords();
      if (mounted) {
        setState(() {
          _hotCategories = categories;
          _hotLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _hotLoading = false);
      }
    }
  }

  /// 加载本地搜索历史。
  Future<void> _loadSearchHistory() async {
    final history = await _historyService.getHistory();
    if (mounted) setState(() => _searchHistory = history);
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() {
        _suggestions = const [];
        _results = const [];
        _albums = const [];
        _searched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(text);
    });
  }

  Future<void> _fetchSuggestions(String keywords) async {
    try {
      final suggestions = await widget.api.searchSuggest(keywords);
      if (mounted && _controller.text.trim() == keywords) {
        setState(() => _suggestions = suggestions);
      }
    } catch (_) {}
  }

  Future<void> _search(String keywords) async {
    if (keywords.isEmpty) return;
    _debounce?.cancel();
    setState(() {
      _loading = true;
      _suggestions = const [];
      _searched = true;
    });
    try {
      if (_type == _SearchType.album) {
        final albums = await widget.api.searchAlbums(keywords);
        if (mounted) {
          setState(() {
            _albums = albums;
            _results = const [];
          });
        }
      } else {
        final songs = _platform == _SearchPlatform.netease
            ? await widget.api.searchNetEaseSongs(keywords)
            : await widget.api.searchSongs(keywords);
        if (mounted) {
          setState(() {
            _results = songs;
            _albums = const [];
          });
        }
      }
      // 搜索成功后记录历史
      await _historyService.add(keywords);
      await _loadSearchHistory();
    } catch (error) {
      if (mounted) {
        setState(() => _results = const []);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) _search(text);
  }

  void _onKeywordTap(String keyword) {
    _controller.text = keyword;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: keyword.length),
    );
    _search(keyword);
  }

  void _switchPlatform(_SearchPlatform platform) {
    if (_platform == platform) return;
    setState(() => _platform = platform);
    // 如果已有搜索关键词，切换平台后自动重新搜索
    final text = _controller.text.trim();
    if (text.isNotEmpty && _searched) {
      _search(text);
    }
  }

  void _switchType(_SearchType type) {
    if (_type == type) return;
    setState(() => _type = type);
    // 已有搜索关键词时切换类型后自动重新搜索
    final text = _controller.text.trim();
    if (text.isNotEmpty && _searched) {
      _search(text);
    }
  }

  /// 打开专辑：复用歌单详情页展示专辑曲目。
  void _openAlbum(ArtistAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: PlaylistSummary(
            id: album.id,
            title: album.name,
            subtitle: album.authorName ?? '',
            coverUrl: album.coverUrl,
          ),
        ),
      ),
    );
  }

  void _playSong(Song song) {
    widget.player.playSong(song, queue: _results);
  }

  void _openArtist(Song song) {
    if (song.source != SongSource.kugou) {
      Toast.info('其他平台歌曲暂不支持查看歌手');
      return;
    }
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  Widget _buildCarSearchHeader(BuildContext context, ColorScheme colorScheme) {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: .54),
              borderRadius: BorderRadius.circular(AppRadius.xxl),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _onSubmit(),
              style: Theme.of(context).textTheme.bodyLarge,
              decoration: InputDecoration(
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _controller.clear();
                          _focusNode.requestFocus();
                        },
                      )
                    : null,
                hintText: '搜索歌曲、歌手、专辑',
                hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton(
          onPressed: _onSubmit,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.xxl),
            ),
          ),
          child: const Text(
            '搜索',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final colorScheme = Theme.of(context).colorScheme;
    // 车机式搜索栏仅在车机模式开启时使用，普通横屏用标准布局。
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    if (isCarMode) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              children: [
                _buildCarSearchHeader(context, colorScheme),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.auth,
                    builder: (context, _) => _buildBody(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LiquidGlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: 64,
          titleSpacing: 4,
          title: LiquidGlassCapsule(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _onSubmit(),
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _controller.clear();
                            _focusNode.requestFocus();
                          },
                        )
                      : null,
                  hintText: '搜索歌曲、歌手、专辑',
                  hintStyle: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '取消',
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      body: AdaptiveContentPadding(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: widget.auth,
                builder: (context, _) => _buildBody(context),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 10,
              child: MiniPlayer(player: widget.player, auth: widget.auth),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final text = _controller.text.trim();

    return Column(
      children: [
        // 类型/平台切换栏（仅搜索状态下显示）
        if (text.isNotEmpty || _searched) ...[
          _TypeSelector(type: _type, onChanged: _switchType),
          // 专辑搜索目前仅酷狗源支持，歌曲搜索才显示平台切换
          if (_type == _SearchType.song)
            _PlatformSelector(platform: _platform, onChanged: _switchPlatform),
        ],
        Expanded(child: _buildContent(context, text)),
      ],
    );
  }

  Widget _buildContent(BuildContext context, String text) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searched && text.isNotEmpty) {
      if (_type == _SearchType.album) {
        return _albums.isEmpty
            ? _EmptyResults(keyword: text)
            : _AlbumResults(albums: _albums, onTap: _openAlbum);
      }
      return _results.isEmpty
          ? _EmptyResults(keyword: text)
          : _SearchResults(
              songs: _results,
              onPlay: _playSong,
              isLiked: (song) => widget.auth.isLiked(song),
              onLikeTap: (song) => widget.auth.toggleLike(song),
              auth: widget.auth,
              player: widget.player,
              onViewArtist: _openArtist,
            );
    }

    if (text.isEmpty) {
      if (_hotLoading) {
        return const _HotSearchSkeleton();
      }

      final size = MediaQuery.sizeOf(context);
      final isLandscape = size.width > size.height;
      // 三列热搜布局是车机专属，普通横屏走下面的标准布局。
      final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

      if (isCarMode) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
          children: [
            if (_searchHistory.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    '搜索历史',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () async {
                      await _historyService.clear();
                      _loadSearchHistory();
                      if (mounted) {
                        Toast.show('已清空搜索历史', type: ToastType.info);
                      }
                    },
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _searchHistory.map((keyword) {
                  return _HistoryChip(
                    keyword: keyword,
                    onTap: () => _onKeywordTap(keyword),
                    onDelete: () async {
                      await _historyService.remove(keyword);
                      _loadSearchHistory();
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
            ],
            if (_hotCategories.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (
                    var i = 0;
                    i < math.min(3, _hotCategories.length);
                    i++
                  ) ...[
                    Expanded(
                      child: _CarHotSearchColumn(
                        category: _hotCategories[i],
                        onTap: _onKeywordTap,
                      ),
                    ),
                    if (i < math.min(3, _hotCategories.length) - 1)
                      const SizedBox(width: 24),
                  ],
                ],
              ),
            ],
          ],
        );
      }

      // 历史记录 + 热搜面板共存于一个可滚动列表
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 160),
        children: [
          if (_searchHistory.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '搜索历史',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    await _historyService.clear();
                    _loadSearchHistory();
                    if (mounted) {
                      Toast.show('已清空搜索历史', type: ToastType.info);
                    }
                  },
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 22,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _searchHistory.map((keyword) {
                return _HistoryChip(
                  keyword: keyword,
                  onTap: () => _onKeywordTap(keyword),
                  onDelete: () async {
                    await _historyService.remove(keyword);
                    _loadSearchHistory();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
          ],
          if (_hotCategories.isEmpty)
            const SizedBox.shrink()
          else
            // 热搜面板内部使用 Column + Expanded 结构，
            // 这里用固定高度 SizedBox 提供布局边界。
            SizedBox(
              height: 550,
              child: _HotSearchPanel(
                categories: _hotCategories,
                onTap: _onKeywordTap,
              ),
            ),
        ],
      );
    }

    if (_suggestions.isNotEmpty) {
      return _SuggestionList(suggestions: _suggestions, onTap: _onKeywordTap);
    }

    return const SizedBox.shrink();
  }
}

/// 类型切换选择器（单曲/专辑）。
class _TypeSelector extends StatelessWidget {
  const _TypeSelector({required this.type, required this.onChanged});

  final _SearchType type;
  final ValueChanged<_SearchType> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Row(
        children: [
          for (final t in _SearchType.values) ...[
            LiquidGlassCapsule(
              isActive: type == t,
              onTap: () => onChanged(t),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 7,
              ),
              child: Text(
                t == _SearchType.song ? '单曲' : '专辑',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: type == t
                      ? (isDark ? Colors.white : colorScheme.primary)
                      : colorScheme.onSurfaceVariant,
                  fontWeight: type == t ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

/// 平台切换选择器。
class _PlatformSelector extends StatelessWidget {
  const _PlatformSelector({required this.platform, required this.onChanged});

  final _SearchPlatform platform;
  final ValueChanged<_SearchPlatform> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Row(
        children: [
          for (final p in _SearchPlatform.values) ...[
            LiquidGlassCapsule(
              isActive: platform == p,
              onTap: () => onChanged(p),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 7,
              ),
              child: Text(
                p == _SearchPlatform.kugou ? '酷狗' : '网易云',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: platform == p
                      ? (Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : colorScheme.primary)
                      : colorScheme.onSurfaceVariant,
                  fontWeight: platform == p
                      ? FontWeight.w800
                      : FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _HotSearchSkeleton extends StatelessWidget {
  const _HotSearchSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 160),
      children: [
        _SkeletonBlock(height: 22, width: 80),
        const SizedBox(height: 14),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 6,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, _) =>
                const _SkeletonBlock(height: 32, width: 72, radius: 16),
          ),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < 10; i++) ...[
          Padding(
            padding: EdgeInsets.only(bottom: i < 9 ? 10 : 0),
            child: Row(
              children: [
                const _SkeletonBlock(height: 16, width: 22),
                const SizedBox(width: 14),
                const Expanded(child: _SkeletonBlock(height: 16)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SkeletonBlock extends StatefulWidget {
  const _SkeletonBlock({this.height = 16, this.width, this.radius = 4});

  final double height;
  final double? width;
  final double radius;

  @override
  State<_SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<_SkeletonBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final alpha = isDark
            ? .06 + _animation.value * .08
            : .08 + _animation.value * .10;
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

class _HotSearchPanel extends StatefulWidget {
  const _HotSearchPanel({required this.categories, required this.onTap});

  final List<SearchHotCategory> categories;
  final ValueChanged<String> onTap;

  @override
  State<_HotSearchPanel> createState() => _HotSearchPanelState();
}

class _HotSearchPanelState extends State<_HotSearchPanel> {
  late final PageController _pageController;
  var _page = 0;
  var _pageScrolling = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories;
    if (categories.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '热搜',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final active = index == _page;
              return _CategoryTab(
                label: categories[index].name,
                active: active,
                onTap: () {
                  _pageScrolling = true;
                  _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                _pageScrolling = true;
              } else if (notification is ScrollEndNotification) {
                final page = (_pageController.page ?? _page.toDouble())
                    .round()
                    .clamp(0, categories.length - 1);
                setState(() {
                  _page = page;
                  _pageScrolling = false;
                });
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (page) {
                if (!_pageScrolling) setState(() => _page = page);
              },
              itemCount: categories.length,
              itemBuilder: (context, index) {
                return _CategoryKeywordList(
                  keywords: categories[index].keywords,
                  onTap: widget.onTap,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LiquidGlassCapsule(
      isActive: active,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: active
              ? (isDark ? Colors.white : colorScheme.primary)
              : colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CategoryKeywordList extends StatelessWidget {
  const _CategoryKeywordList({required this.keywords, required this.onTap});

  final List<SearchHotKeyword> keywords;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LiquidGlassCard(
      borderRadius: AppRadius.lg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      enableTouchFlex: false,
      child: ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: keywords.length,
      itemBuilder: (context, index) {
        final item = keywords[index];
        final rank = index + 1;
        return InkWell(
          onTap: () => onTap(item.keyword),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '$rank',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: _rankWeight(rank),
                      color: _rankColor(rank, colorScheme),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.keyword,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (rank <= 3 && item.reason != null && item.reason!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _rankColor(
                        rank,
                        colorScheme,
                      ).withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(
                      '热',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: _rankColor(rank, colorScheme),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
  }

  FontWeight _rankWeight(int rank) {
    return rank <= 3 ? FontWeight.w900 : FontWeight.w600;
  }

  Color _rankColor(int rank, ColorScheme colorScheme) {
    return switch (rank) {
      1 => const Color(0xFFFF2D55),
      2 => const Color(0xFFFF6B35),
      3 => const Color(0xFFFFB020),
      _ => colorScheme.onSurfaceVariant,
    };
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.suggestions, required this.onTap});

  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 160),
      itemCount: suggestions.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: 62,
        color: colorScheme.outlineVariant.withValues(alpha: .4),
      ),
      itemBuilder: (context, index) {
        final keyword = suggestions[index];
        return ListTile(
          leading: Icon(
            Icons.search_rounded,
            color: colorScheme.onSurfaceVariant,
          ),
          title: Text(
            keyword,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          onTap: () => onTap(keyword),
        );
      },
    );
  }
}

/// 专辑搜索结果列表。
class _AlbumResults extends StatelessWidget {
  const _AlbumResults({required this.albums, required this.onTap});

  final List<ArtistAlbum> albums;
  final ValueChanged<ArtistAlbum> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 160),
      itemCount: albums.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final album = albums[index];
        final subtitle = [
          if (album.authorName != null && album.authorName!.isNotEmpty)
            album.authorName!,
          if (album.publishDate != null && album.publishDate!.isNotEmpty)
            album.publishDate!,
        ].join(' · ');
        return InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => onTap(album),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
            child: Row(
              children: [
                Artwork(url: album.coverUrl, size: 58, borderRadius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colorScheme.outline,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.songs,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
  });

  final List<Song> songs;
  final void Function(Song song) onPlay;
  final bool Function(Song song) isLiked;
  final void Function(Song song) onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final void Function(Song song) onViewArtist;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 160),
          itemCount: songs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 2),
          itemBuilder: (context, index) {
            final song = songs[index];
            final liked = isLiked(song);
            // 其他平台歌曲（如网易云）仅支持播放，不支持收藏等操作
            final isExternal = song.source != SongSource.kugou;
            return AnimatedBuilder(
              animation: player,
              builder: (context, _) {
                final active = player.currentSong?.hash == song.hash;
                final activeColor = colorScheme.primary;
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  onTap: () => onPlay(song),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      vertical: 9,
                      horizontal: 8,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? activeColor.withValues(alpha: .08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            Artwork(
                              url: song.coverUrl,
                              size: 58,
                              borderRadius: 8,
                            ),
                            if (active)
                              Positioned(
                                right: 5,
                                bottom: 5,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surface
                                        .withValues(alpha: .88),
                                    borderRadius: BorderRadius.circular(AppRadius.sm),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: NowPlayingBadge(
                                      active: active,
                                      playing: player.isPlaying,
                                      color: activeColor,
                                      size: 14,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: active ? activeColor : null,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: active
                                          ? activeColor.withValues(alpha: .72)
                                          : colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w500,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (!isExternal)
                          IconButton(
                            onPressed: () => onLikeTap(song),
                            icon: Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: liked
                                  ? Colors.redAccent
                                  : colorScheme.outline,
                              size: 27,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (!isExternal)
                          IconButton(
                            tooltip: '更多',
                            onPressed: () {
                              showSongActionSheet(
                                context: context,
                                song: song,
                                actions: [
                                  SongSheetAction(
                                    icon: Icons.queue_music_rounded,
                                    title: '下一首播放',
                                    onTap: () => addSongToQueueWithFeedback(
                                      context: context,
                                      player: player,
                                      song: song,
                                    ),
                                  ),
                                  SongSheetAction(
                                    icon: Icons.playlist_add_rounded,
                                    title: '添加到歌单',
                                    onTap: () => showAddToPlaylistSheet(
                                      context: context,
                                      auth: auth,
                                      song: song,
                                    ),
                                  ),
                                  SongSheetAction(
                                    icon: Icons.person_rounded,
                                    title: '查看歌手',
                                    onTap: () => onViewArtist(song),
                                  ),
                                  if (player.downloadController != null)
                                    SongSheetAction(
                                      icon:
                                          player.downloadController!
                                              .isDownloaded(song)
                                          ? Icons.download_done_rounded
                                          : Icons.download_rounded,
                                      title:
                                          player.downloadController!
                                              .isDownloaded(song)
                                          ? '已下载'
                                          : '下载',
                                      onTap: () => player.downloadController!
                                          .download(song, player.audioQuality),
                                    ),
                                ],
                              );
                            },
                            icon: const Icon(Icons.more_horiz_rounded),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (isExternal)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.outlineVariant.withValues(
                                  alpha: .5,
                                ),
                                borderRadius: BorderRadius.circular(AppRadius.xs),
                              ),
                              child: Text(
                                song.source == SongSource.netease
                                    ? '网易云'
                                    : '外部',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 60, 28, 160),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: colorScheme.primary.withValues(alpha: .64),
          ),
          const SizedBox(height: 14),
          Text(
            '没有找到「$keyword」相关歌曲',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '换个关键词试试',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索历史标签 Chip。
///
/// 左侧为关键词，右侧带一个删除小图标；整体可点击触发搜索。
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.keyword,
    required this.onTap,
    required this.onDelete,
  });

  final String keyword;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LiquidGlassCapsule(
      onTap: onTap,
      padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            keyword,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDelete,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarHotSearchColumn extends StatelessWidget {
  const _CarHotSearchColumn({required this.category, required this.onTap});

  final SearchHotCategory category;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          category.name,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: math.min(6, category.keywords.length),
          itemBuilder: (context, index) {
            final item = category.keywords[index];
            final rank = index + 1;
            return InkWell(
              onTap: () => onTap(item.keyword),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$rank',
                        style: TextStyle(
                          fontWeight: rank <= 3
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: rank <= 3
                              ? Colors.redAccent
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item.keyword,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
