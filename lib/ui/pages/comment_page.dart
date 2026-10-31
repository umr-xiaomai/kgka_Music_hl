import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/music_models.dart';
import '../../services/comment_models.dart';
import '../../services/kugou_comment_service.dart';
import '../../services/netease_comment_service.dart';
import '../widgets/retryable_network_image.dart';
import '../widgets/toast.dart';

/// 打开评论页的统一入口（播放页封面区、歌词页、更多菜单都走这里）。
///
/// 目前支持酷狗与网易云两个来源，其它来源直接提示。
void openCommentPage(BuildContext context, Song song) {
  if (!supportsComments(song)) {
    Toast.error('目前只支持查看酷狗 / 网易云评论');
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => CommentPage(song: song)),
  );
}

/// 当前歌曲是否支持查看评论（酷狗 / 网易云）。
bool supportsComments(Song song) {
  return switch (song.source) {
    SongSource.kugou => song.hash.isNotEmpty,
    SongSource.netease => (song.albumAudioId ?? song.id).isNotEmpty,
    SongSource.local => false,
  };
}

/// 歌曲评论页。
///
/// 酷狗与网易云共用同一套 UI，差异由 [MusicCommentService] 实现吸收：
/// - 顶部页签（酷狗：热门 / 最新；网易云：热门 / 全部），各自独立分页、各自显示总数
/// - 每条评论：头像、昵称、等级、时间、地区、点赞数、正文、配图
/// - 列表自带的第一条楼层回复 / 被引用评论，可展开查看全部回复（酷狗）
/// - 底部按页翻页（上一页 / 下一页），刷新按钮重新拉取
class CommentPage extends StatefulWidget {
  const CommentPage({super.key, required this.song});

  final Song song;

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  late final MusicCommentService _service;
  final _tabKeys = <GlobalKey<_CommentTabState>>[];

  var _tabIndex = 0;
  final _totals = <int?>[];

  @override
  void initState() {
    super.initState();
    _service = _createService(widget.song);
    for (var i = 0; i < _service.tabs.length; i++) {
      _tabKeys.add(GlobalKey<_CommentTabState>());
      _totals.add(null);
    }
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  MusicCommentService _createService(Song song) {
    return switch (song.source) {
      SongSource.netease => NeteaseCommentService(),
      _ => KugouCommentService(),
    };
  }

  bool get _supported => supportsComments(widget.song);

  void _refresh() {
    for (final key in _tabKeys) {
      key.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          title: Text(
            '${widget.song.title} 的评论',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _supported ? _refresh : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _supported ? _buildBody() : _buildUnavailable(),
      ),
    );
  }

  Widget _buildUnavailable() {
    final label = widget.song.source == SongSource.local
        ? '本地歌曲没有评论'
        : '这首歌暂时没有评论';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final tabs = _service.tabs;
    return Column(
      children: [
        _buildTabBar(tabs),
        const Divider(height: 1),
        Expanded(
          // 只构建当前页签：网易云图片 CDN 并发稍高就会限流拒掉部分请求，
          // 两个页签同时构建会在开页瞬间打出去几十个图片请求，
          // 后发的那些直接失败并永久停在占位图。
          child: _CommentTab(
            key: _tabKeys[_tabIndex],
            service: _service,
            song: widget.song,
            kind: tabs[_tabIndex].kind,
            errorLabel: '${tabs[_tabIndex].label}评论加载失败，点击重试',
            onTotalChanged: (total) {
              if (_totals[_tabIndex] == total) return;
              setState(() => _totals[_tabIndex] = total);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(List<CommentTab> tabs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            _tabButton(label: tabs[i].label, total: _totals[i], index: i),
        ],
      ),
    );
  }

  Widget _tabButton({
    required String label,
    required int? total,
    required int index,
  }) {
    final theme = Theme.of(context);
    final active = _tabIndex == index;
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (_tabIndex == index) return;
        setState(() => _tabIndex = index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              total == null ? label : '$label ($total)',
              style: theme.textTheme.titleSmall?.copyWith(
                color: color,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 3,
              width: active ? 22 : 0,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个页签的评论列表。
class _CommentTab extends StatefulWidget {
  const _CommentTab({
    super.key,
    required this.service,
    required this.song,
    required this.kind,
    required this.errorLabel,
    required this.onTotalChanged,
  });

  final MusicCommentService service;
  final Song song;
  final CommentKind kind;
  final String errorLabel;
  final ValueChanged<int> onTotalChanged;

  @override
  State<_CommentTab> createState() => _CommentTabState();
}

class _CommentTabState extends State<_CommentTab> {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  List<CommentItem> _comments = const [];
  var _page = 1;
  var _maxPage = 1;
  var _total = 0;
  var _isLoading = true;
  String? _errorMessage;

  /// 最近一次失败的那一页，重试时直接回到这一页。
  int? _failedPage;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 重新拉取当前页（顶部刷新按钮用）。
  void reload() => _load(_page);

  Future<void> _load(int page) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await widget.service.fetchComments(
        song: widget.song,
        kind: widget.kind,
        page: page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _comments = data.comments;
        _page = data.page < 1
            ? 1
            : (data.page > data.maxPage ? data.maxPage : data.page);
        _maxPage = data.maxPage;
        _total = data.total;
        _isLoading = false;
        _failedPage = null;
      });
      widget.onTotalChanged(_total);
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error is CommentException
            ? error.message
            : error.toString();
        _failedPage = page;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_comments.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_comments.isEmpty && _errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.errorLabel,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _load(_page),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.comment_outlined,
              size: 48,
              color: Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant
                  .withValues(alpha: .42),
            ),
            const SizedBox(height: 12),
            Text(
              '还没有评论',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _comments.length + 1,
      itemBuilder: (context, index) {
        if (index == _comments.length) {
          return _buildPager();
        }
        final comment = _comments[index];
        return Column(
          children: [
            _CommentTile(
              comment: comment,
              service: widget.service,
              song: widget.song,
            ),
            const Divider(height: 1, thickness: .4, indent: 14, endIndent: 14),
          ],
        );
      },
    );
  }

  Widget _buildPager() {
    final theme = Theme.of(context);
    final canPrev = _page > 1 && !_isLoading;
    final canNext = _page < _maxPage && !_isLoading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          if (_maxPage > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: canPrev ? () => _load(_page - 1) : null,
                  child: const Text('上一页'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '第 $_page / $_maxPage 页',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: canNext ? () => _load(_page + 1) : null,
                  child: const Text('下一页'),
                ),
              ],
            ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_errorMessage != null)
            // 翻页失败时列表里还有旧内容，不能整页换成错误页，
            // 这里给一条可重试的提示，否则用户只会觉得“点了没反应”。
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    '加载失败：$_errorMessage',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _load(_failedPage ?? _page),
                  child: const Text('重试'),
                ),
              ],
            )
          else
            Text(
              '共 $_total 条评论',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 楼层：一条评论 + 头像 + 首条回复 / 被引用内容。
class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.service,
    required this.song,
  });

  final CommentItem comment;
  final MusicCommentService service;
  final Song song;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final liked = comment.likedCount;
    final time = _formatCommentTime(comment.time);
    final location = comment.location ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UserAvatar(url: comment.avatar, size: 40, radius: 6),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              comment.userName ?? '匿名用户',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface.withValues(alpha: .88),
                              ),
                            ),
                          ),
                          if (comment.levelLabel case final level?) ...[
                            const SizedBox(width: 4),
                            _LevelChip(label: level),
                          ],
                        ],
                      ),
                    ),
                    if (liked != null && liked > 0) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.thumb_up_alt_outlined,
                        size: 12,
                        color: scheme.primary.withValues(alpha: .72),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$liked',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          color: scheme.primary.withValues(alpha: .72),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (time.isNotEmpty)
                      Text(
                        time,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (location.isNotEmpty) ...[
                      if (time.isNotEmpty) const SizedBox(width: 8),
                      Text(
                        location,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  comment.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    height: 1.5,
                    color: scheme.onSurface.withValues(alpha: .92),
                  ),
                ),
                if (comment.images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _CommentImages(urls: comment.images),
                  ),
                if (comment.firstReply != null ||
                    (comment.replyCount ?? 0) > 0 ||
                    comment.canLoadMoreReplies)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ReplyBlock(
                      comment: comment,
                      service: service,
                      song: song,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 评论配图，点击放大。
class _CommentImages extends StatelessWidget {
  const _CommentImages({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    final shown = urls.take(6).toList(growable: false);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final url in shown)
          GestureDetector(
            onTap: () => _showImage(context, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: RetryableNetworkImage(
                url: url,
                width: 96,
                height: 96,
                cacheWidth: 192,
                cacheHeight: 192,
                placeholderBuilder: (context) => Container(
                  width: 96,
                  height: 96,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

void _showImage(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogContext) {
      final viewSize = MediaQuery.sizeOf(dialogContext);
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(dialogContext);
      // 放大到 4 倍仍要清晰：按屏幕像素宽度取图，别固定成 1024 再被拉伸发糊。
      final cacheWidth = (viewSize.width * devicePixelRatio)
          .round()
          .clamp(720, 2048)
          .toInt();

      return GestureDetector(
        onTap: () => Navigator.of(dialogContext).pop(),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: _ZoomableCommentImage(url: url, cacheWidth: cacheWidth),
          ),
        ),
      );
    },
  );
}

/// 可缩放平移的评论配图。
///
/// `InteractiveViewer` 本身铺满视口，缩放锚点才落在手指位置；
/// 图片用 `BoxFit.contain` 居中绘制在视口内。若把没有尺寸约束的图片直接
/// 塞进 `InteractiveViewer`，它会撑成图片原始尺寸（如 1024x1024），
/// 缩放中心落在可视区之外，看起来就是「视角卡在原图没跟着放大」。
class _ZoomableCommentImage extends StatefulWidget {
  const _ZoomableCommentImage({required this.url, required this.cacheWidth});

  final String url;
  final int cacheWidth;

  @override
  State<_ZoomableCommentImage> createState() => _ZoomableCommentImageState();
}

class _ZoomableCommentImageState extends State<_ZoomableCommentImage> {
  final _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  /// 双击在「原始比例」和「2.5 倍」之间切换，和常见看图工具一致。
  void _toggleZoom(TapDownDetails details) {
    final current = _transformController.value.getMaxScaleOnAxis();
    if (current > 1.05) {
      _transformController.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    final position = details.localPosition;
    _transformController.value = Matrix4.identity()
      ..translate(-position.dx * (scale - 1), -position.dy * (scale - 1))
      ..scale(scale);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: _toggleZoom,
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: _transformController,
        minScale: 1,
        maxScale: 4,
        child: SizedBox.expand(
          child: RetryableNetworkImage(
            url: widget.url,
            fit: BoxFit.contain,
            cacheWidth: widget.cacheWidth,
            placeholderBuilder: (context) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 楼层回复区：展示首条回复 / 被引用内容，可展开全部回复。
class _ReplyBlock extends StatelessWidget {
  const _ReplyBlock({
    required this.comment,
    required this.service,
    required this.song,
  });

  final CommentItem comment;
  final MusicCommentService service;
  final Song song;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final firstReply = comment.firstReply;
    final replyCount = comment.replyCount ?? 0;
    // 已经展示的条数：列表自带的首条回复 / 引用算一条。
    final shownCount = firstReply == null ? 0 : 1;
    final remaining = replyCount - shownCount;
    final canOpen = comment.canLoadMoreReplies;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (firstReply != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _UserAvatar(url: firstReply.avatar, size: 22, radius: 4),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        firstReply.userName ?? '匿名用户',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface.withValues(alpha: .82),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        firstReply.content,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          height: 1.45,
                          color: scheme.onSurface.withValues(alpha: .82),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (remaining > 0 || canOpen)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  top: firstReply == null ? 0 : 6,
                  left: firstReply == null ? 0 : 30,
                ),
                child: canOpen
                    ? InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () =>
                            _openReplies(context, service, song, comment),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          child: Text(
                            '查看全部 $replyCount 条回复 ›',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      )
                    // 网易云的楼层回复接口需要登录 + weapi 加密，这里只做条数提示。
                    : Text(
                        '共 $replyCount 条回复',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _openReplies(
  BuildContext context,
  MusicCommentService service,
  Song song,
  CommentItem comment,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return _RepliesSheet(service: service, song: song, comment: comment);
    },
  );
}

/// 全部回复（楼层回复分页加载）。
class _RepliesSheet extends StatefulWidget {
  const _RepliesSheet({
    required this.service,
    required this.song,
    required this.comment,
  });

  final MusicCommentService service;
  final Song song;
  final CommentItem comment;

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  final _replies = <CommentItem>[];
  var _page = 1;
  var _isLoading = false;
  var _hasMore = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    // 上一页刚失败时不要因为滚动自动重试，交给用户点“重试”。
    if (_errorMessage != null) return;
    if (!_scrollController.hasClients || _isLoading || !_hasMore) return;
    if (_scrollController.position.extentAfter < 240) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final page = await widget.service.fetchReplies(
        song: widget.song,
        comment: widget.comment,
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _replies.addAll(page);
        _page++;
        _hasMore = page.length == _pageSize;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error is CommentException
            ? error.message
            : error.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height * .7;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '全部回复（${widget.comment.replyCount ?? _replies.length}）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    final theme = Theme.of(context);
    if (_replies.isEmpty) {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_errorMessage != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('回复加载失败', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        );
      }
      return Center(
        child: Text(
          '暂无回复',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _replies.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _replies.length) {
          if (_errorMessage != null) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('加载失败，点击重试'),
                ),
              ),
            );
          }
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final reply = _replies[index];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _UserAvatar(url: reply.avatar, size: 28, radius: 4),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            reply.userName ?? '匿名用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if ((reply.likedCount ?? 0) > 0) ...[
                          Icon(
                            Icons.thumb_up_alt_outlined,
                            size: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${reply.likedCount}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      reply.content,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 用户头像（加载失败退回占位图）。
class _UserAvatar extends StatelessWidget {
  const _UserAvatar({this.url, this.size = 40, this.radius = 6});

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_rounded,
        size: size * .55,
        color: scheme.onSurfaceVariant,
      ),
    );

    final avatarUrl = url;
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: placeholder,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: RetryableNetworkImage(
        // 网易云头像原图 2000px、且是 http，统一降尺寸 + 升 https。
        url: avatarUrl,
        width: size,
        height: size,
        cacheWidth: (size * 2).round(),
        cacheHeight: (size * 2).round(),
        placeholderBuilder: (context) => placeholder,
      ),
    );
  }
}

/// 用户等级标签（酷狗的 LV.x）。
class _LevelChip extends StatelessWidget {
  const _LevelChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 把一个 `yyyy-MM-dd HH:mm:ss` 的时间压成移动端好读的形式。
String _formatCommentTime(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (parsed == null) return raw;
  final now = DateTime.now();
  if (parsed.year == now.year) {
    return '${_two(parsed.month)}-${_two(parsed.day)} '
        '${_two(parsed.hour)}:${_two(parsed.minute)}';
  }
  return '${parsed.year}-${_two(parsed.month)}-${_two(parsed.day)}';
}
