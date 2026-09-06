import 'dart:async';
import 'package:flutter/material.dart';

/// 高性能走马灯超长文本往复滚动组件。
///
/// 特性：
/// 1. 自动测量：当文本宽度小于或等于可用空间时，作为普通静态 [Text] 渲染（无 Ticker、无控制器、零开销）；
/// 2. 平滑往复：当文本超出可用宽度时，在起点停留 [pauseDuration]，然后以 [velocity] 像素/秒匀速向右滚动到底，
///    在终点停留 [pauseDuration]，再平滑返回起点循环；
/// 3. 图层隔离：超长滚动部分自带 [RepaintBoundary]，滚动动画仅重绘自身区域，不会引起列表行或父级页面重绘；
/// 4. 生命周期感知：切到后台自动暂停滚动与计时器，返回前台恢复，降低电量与 GPU 开销。
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
    this.velocity = 30.0,
    this.pauseDuration = const Duration(milliseconds: 1800),
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// 滚动速度（像素/秒）。
  final double velocity;

  /// 在起点与终点处的停留缓冲时间。
  final Duration pauseDuration;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with WidgetsBindingObserver {
  late final ScrollController _scrollController;
  Timer? _timer;
  bool _isDisposed = false;
  bool _isAnimating = false;
  double _maxScroll = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_maxScroll > 0 && !_isAnimating) {
        _startAnimation(_maxScroll);
      }
    } else {
      _stopAnimation();
    }
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _stopAnimation();
      _maxScroll = 0.0;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopAnimation();
    _scrollController.dispose();
    super.dispose();
  }

  void _stopAnimation() {
    _timer?.cancel();
    _timer = null;
    _isAnimating = false;
  }

  void _startAnimation(double maxScroll) {
    if (_isDisposed || maxScroll <= 0) return;
    _maxScroll = maxScroll;
    if (_isAnimating) return;
    _isAnimating = true;

    _scheduleScroll(toEnd: true);
  }

  void _scheduleScroll({required bool toEnd}) {
    if (_isDisposed || !mounted) return;

    _timer?.cancel();
    _timer = Timer(widget.pauseDuration, () async {
      if (_isDisposed || !mounted || !_scrollController.hasClients) return;

      final current = _scrollController.offset;
      final target = toEnd ? _maxScroll : 0.0;
      final distance = (target - current).abs();
      if (distance < 1) {
        _scheduleScroll(toEnd: !toEnd);
        return;
      }

      final durationMs =
          ((distance / widget.velocity) * 1000).clamp(300, 30000).toInt();
      try {
        await _scrollController.animateTo(
          target,
          duration: Duration(milliseconds: durationMs),
          curve: Curves.easeInOut,
        );
      } catch (_) {}

      if (_isDisposed || !mounted) return;
      _scheduleScroll(toEnd: !toEnd);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty) {
      return const SizedBox.shrink();
    }

    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle = defaultStyle.merge(widget.style);

    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: widget.text, style: effectiveStyle),
          textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
          maxLines: 1,
        )..layout();

        final textWidth = textPainter.width;
        final maxWidth = constraints.maxWidth;

        // 空间充足或无约束时，作为普通文本静态渲染，不创建滚动与定时器
        if (!maxWidth.isFinite || textWidth <= maxWidth) {
          _stopAnimation();
          return Text(
            widget.text,
            style: widget.style,
            textAlign: widget.textAlign,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        // 空间不足（文本超长），触发平滑走马灯滚动
        final maxScroll = (textWidth - maxWidth).ceilToDouble();
        _maxScroll = maxScroll;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _startAnimation(maxScroll);
          }
        });

        return RepaintBoundary(
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.text,
              style: widget.style,
              textAlign: widget.textAlign,
              maxLines: 1,
            ),
          ),
        );
      },
    );
  }
}
