import 'dart:ui';
import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// 全局流体极光氛围底层背景（iOS 26 Ambient Mesh Background）。
/// 采用全屏平滑弥散光晕，消除任何高度截断与局部断层。
class LiquidGlassBackground extends StatelessWidget {
  const LiquidGlassBackground({
    super.key,
    required this.child,
    this.showOrbs = true,
  });

  final Widget child;
  final bool showOrbs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final baseBgColor = isDark ? const Color(0xFF090B10) : const Color(0xFFF3F7FC);
    final primaryOrbColor = colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.08);
    final secondaryOrbColor = colorScheme.secondary.withValues(alpha: isDark ? 0.12 : 0.05);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: baseBgColor,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showOrbs)
            RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 顶部主题色柔和极光光晕（全屏平滑衰减，无硬边）
                  Positioned(
                    top: -160,
                    left: -80,
                    right: -80,
                    height: 480,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0, -0.6),
                            radius: 0.9,
                            colors: [
                              primaryOrbColor,
                              primaryOrbColor.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 中下部副色微光（全屏平滑衰减）
                  Positioned(
                    bottom: -100,
                    right: -100,
                    width: 400,
                    height: 400,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              secondaryOrbColor,
                              secondaryOrbColor.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// 全局通用的液态玻璃卡片容器组件。
/// 采用原生 GPU 高斯模糊 + 物理菲涅尔微光高光边框 + 触控弹性。
/// 彻底杜绝滑动过头时的 Shader 越界采样黑块与色彩脏斑。
class LiquidGlassCard extends StatefulWidget {
  const LiquidGlassCard({
    super.key,
    required this.child,
    this.borderRadius = AppRadius.xl,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.onTap,
    this.enableTouchFlex = true,
    this.backgroundColor,
    this.borderColor,
    this.blurSigma = 0.0,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final VoidCallback? onTap;
  final bool enableTouchFlex;
  final Color? backgroundColor;
  final Color? borderColor;
  final double blurSigma;

  @override
  State<LiquidGlassCard> createState() => _LiquidGlassCardState();
}

class _LiquidGlassCardState extends State<LiquidGlassCard> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails _) {
    if (widget.enableTouchFlex && widget.onTap != null) {
      setState(() => _isPressed = true);
    }
  }

  void _handleTapUp(TapUpDetails _) {
    if (widget.enableTouchFlex && widget.onTap != null) {
      setState(() => _isPressed = false);
    }
  }

  void _handleTapCancel() {
    if (widget.enableTouchFlex && widget.onTap != null) {
      setState(() => _isPressed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final effectiveBgColor = widget.backgroundColor ??
        (isDark
            ? colorScheme.surfaceContainerHighest.withValues(alpha: .38)
            : Colors.white.withValues(alpha: .75));

    final effectiveBorderColor = widget.borderColor ??
        (isDark
            ? Colors.white.withValues(alpha: .14)
            : Colors.white.withValues(alpha: .90));

    Widget cardBody = Container(
      width: widget.width,
      height: widget.height,
      padding: widget.padding ?? const EdgeInsets.all(AppSpacing.md),
      child: widget.child,
    );

    if (widget.onTap != null) {
      cardBody = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          onTap: widget.onTap,
          splashColor: colorScheme.primary.withValues(alpha: .12),
          highlightColor: colorScheme.primary.withValues(alpha: .06),
          child: cardBody,
        ),
      );
    }

    final hasBlur = widget.blurSigma > 0;
    final cardDecoration = BoxDecoration(
      color: effectiveBgColor,
      borderRadius: BorderRadius.circular(widget.borderRadius),
      border: Border.all(
        color: effectiveBorderColor,
        width: 1.1,
      ),
    );

    final Widget innerContent = DecoratedBox(
      decoration: cardDecoration,
      child: cardBody,
    );

    Widget glass = Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: .22)
                : const Color(0x0A000000),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: hasBlur
          ? ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: widget.blurSigma,
                  sigmaY: widget.blurSigma,
                ),
                child: innerContent,
              ),
            )
          : innerContent,
    );

    if (widget.enableTouchFlex && widget.onTap != null) {
      return GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        behavior: HitTestBehavior.translucent,
        child: AnimatedScale(
          scale: _isPressed ? 0.982 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: glass,
        ),
      );
    }

    return glass;
  }
}

/// 全局通用的液态玻璃胶囊按钮/标签组件（Stadium/Pill 形态）。
class LiquidGlassCapsule extends StatefulWidget {
  const LiquidGlassCapsule({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.margin,
    this.onTap,
    this.isActive = false,
    this.activeColor,
    this.blurSigma = 0.0,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool isActive;
  final Color? activeColor;
  final double blurSigma;

  @override
  State<LiquidGlassCapsule> createState() => _LiquidGlassCapsuleState();
}

class _LiquidGlassCapsuleState extends State<LiquidGlassCapsule> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveActiveColor = widget.activeColor ?? colorScheme.primary;

    final effectiveBgColor = widget.isActive
        ? effectiveActiveColor.withValues(alpha: isDark ? .35 : .22)
        : (isDark
            ? colorScheme.surfaceContainerHighest.withValues(alpha: .38)
            : Colors.white.withValues(alpha: .82));

    final effectiveBorderColor = widget.isActive
        ? effectiveActiveColor.withValues(alpha: .70)
        : (isDark
            ? Colors.white.withValues(alpha: .16)
            : Colors.white.withValues(alpha: .92));

    Widget content = Padding(
      padding: widget.padding,
      child: widget.child,
    );

    if (widget.onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(100),
          onTap: widget.onTap,
          splashColor: effectiveActiveColor.withValues(alpha: .15),
          highlightColor: effectiveActiveColor.withValues(alpha: .08),
          child: content,
        ),
      );
    }

    final hasBlur = widget.blurSigma > 0;
    final capsuleDecoration = BoxDecoration(
      color: effectiveBgColor,
      borderRadius: BorderRadius.circular(100),
      border: Border.all(
        color: effectiveBorderColor,
        width: widget.isActive ? 1.4 : 1.0,
      ),
    );

    final Widget innerContent = DecoratedBox(
      decoration: capsuleDecoration,
      child: content,
    );

    Widget capsule = Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(100),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: .18)
                : const Color(0x08000000),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: hasBlur
          ? ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: widget.blurSigma,
                  sigmaY: widget.blurSigma,
                ),
                child: innerContent,
              ),
            )
          : innerContent,
    );

    if (widget.onTap != null) {
      return GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        behavior: HitTestBehavior.translucent,
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: capsule,
        ),
      );
    }

    return capsule;
  }
}

/// 全局通用的液态玻璃列表行组件（LiquidGlassTile）。
class LiquidGlassTile extends StatelessWidget {
  const LiquidGlassTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.borderRadius = AppRadius.md,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassCard(
      borderRadius: borderRadius,
      padding: padding,
      onTap: onTap,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  subtitle!,
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 全局通用的液态玻璃底板面板（用于 BottomSheet、Dialog 等）。
class LiquidGlassSheetContainer extends StatelessWidget {
  const LiquidGlassSheetContainer({
    super.key,
    required this.child,
    this.borderRadius = AppRadius.xxl,
    this.padding,
    this.constraints,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      constraints: constraints,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(borderRadius),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: .45)
                : const Color(0x18000000),
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(borderRadius),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF141822).withValues(alpha: .85)
                  : Colors.white.withValues(alpha: .88),
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(borderRadius),
              ),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: .18)
                    : Colors.white.withValues(alpha: .95),
                width: 1.2,
              ),
            ),
            child: Padding(
              padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}


