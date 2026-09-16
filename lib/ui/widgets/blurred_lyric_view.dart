import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart' hide LineMetrics;
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/core/lyric_styles.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';
import 'package:flutter_lyric/render/lyric_painter.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_layout_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_highlight.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_switch_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_mask_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_scroll_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_touch_mixin.dart';

/// 在 flutter_lyric 的基础上给非当前行增加随距离递增的高斯模糊。
class BlurredLyricView extends StatefulWidget {
  const BlurredLyricView({
    super.key,
    required this.controller,
    this.width,
    this.height,
    this.style,
    this.maxBlurSigma = 6.0,
    this.blurStep = 1.4,
  });

  final LyricController controller;
  final double? width;
  final double? height;
  final LyricStyle? style;

  /// 距离当前行最远时的最大模糊强度。
  final double maxBlurSigma;

  /// 每远离当前行一行时增加的模糊强度。
  final double blurStep;

  @override
  State<BlurredLyricView> createState() => _BlurredLyricViewState();
}

class _BlurredLyricViewState extends State<BlurredLyricView>
    with
        TickerProviderStateMixin,
        LyricLayoutMixin,
        LyricScrollMixin,
        LyricMaskMixin,
        LyricTouchMixin,
        LyricLineHightlightMixin,
        LyricLineSwitchMixin {
  @override
  LyricController get controller => widget.controller;

  @override
  LyricStyle get style => widget.style ?? LyricStyles.default1;

  @override
  LyricLayout? layout;

  @override
  Size lyricSize = Size.zero;

  @override
  final scrollYNotifier = ValueNotifier<double>(0.0);

  @override
  void onLayoutChange(LyricLayout layout) {
    super.onLayoutChange(layout);
    updateHighlightWidth();
    updateScrollY(animate: false);
  }

  @override
  void didUpdateWidget(covariant BlurredLyricView oldWidget) {
    if (widget.style != oldWidget.style ||
        widget.maxBlurSigma != oldWidget.maxBlurSigma ||
        widget.blurStep != oldWidget.blurStep) {
      onStyleChange();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return wrapTouchWidget(
      context,
      SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height ?? double.infinity,
        child: Padding(
          padding: style.contentPadding.copyWith(top: 0, bottom: 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              if (size.width != lyricSize.width ||
                  size.height != lyricSize.height) {
                lyricSize = size;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  computeLyricLayout();
                });
              }
              if (layout == null) return const SizedBox.shrink();
              Widget result = buildLineSwitch((context, switchState) {
                return buildActiveHighlightWidth((double value) {
                  return ValueListenableBuilder(
                    valueListenable: scrollYNotifier,
                    builder: (context, double scrollY, child) {
                      return CustomPaint(
                        painter: _BlurredLyricPainter(
                          layout: layout!,
                          onShowLineRectsChange: (rects) {
                            showLineRects = rects;
                          },
                          style: style,
                          playIndex: controller.activeIndexNotifiter.value,
                          activeHighlightWidth: value,
                          isSelecting: controller.isSelectingNotifier.value,
                          scrollY: scrollY,
                          onAnchorIndexChange: (index) {
                            scheduleMicrotask(() {
                              controller.selectedIndexNotifier.value = index;
                            });
                          },
                          switchState: switchState,
                          maxBlurSigma: widget.maxBlurSigma,
                          blurStep: widget.blurStep,
                        ),
                        size: lyricSize,
                      );
                    },
                  );
                });
              });
              result = wrapMaskIfNeed(result);
              return result;
            },
          ),
        ),
      ),
    );
  }
}

class _BlurredLyricPainter extends LyricPainter {
  _BlurredLyricPainter({
    required super.layout,
    required super.playIndex,
    required super.scrollY,
    required super.onAnchorIndexChange,
    required super.activeHighlightWidth,
    required super.switchState,
    required super.isSelecting,
    required super.onShowLineRectsChange,
    required super.style,
    required this.maxBlurSigma,
    required this.blurStep,
  });

  final double maxBlurSigma;
  final double blurStep;

  @override
  void drawLine(
    Canvas canvas,
    LineMetrics metric,
    Size size,
    int index,
    bool isInAnchorArea,
  ) {
    final distance = (index - playIndex).abs();
    final shouldStaySharp =
        maxBlurSigma <= 0 ||
        distance == 0 ||
        (isSelecting && isInAnchorArea);
    if (shouldStaySharp) {
      super.drawLine(canvas, metric, size, index, isInAnchorArea);
      return;
    }

    final sigma = math.min(maxBlurSigma, blurStep * distance).toDouble();
    final blurPaint = Paint()
      ..imageFilter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.saveLayer(null, blurPaint);
    super.drawLine(canvas, metric, size, index, isInAnchorArea);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlurredLyricPainter oldDelegate) {
    return super.shouldRepaint(oldDelegate) ||
        oldDelegate.maxBlurSigma != maxBlurSigma ||
        oldDelegate.blurStep != blurStep;
  }
}
