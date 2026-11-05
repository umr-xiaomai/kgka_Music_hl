import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 可折叠的介绍卡片（歌手介绍 / 专辑介绍）。
///
/// 默认收起为几行摘要，点「详细」展开全文，再点「收起」还原。
/// 介绍文本里自带换行分段（`long_intro` 的标题与正文），
/// 因此用 [Text] 原样渲染，不做二次排版。
class ExpandableIntroCard extends StatefulWidget {
  const ExpandableIntroCard({
    super.key,
    required this.title,
    required this.text,
    this.collapsedLines = 3,
  });

  final String title;
  final String text;
  final int collapsedLines;

  @override
  State<ExpandableIntroCard> createState() => _ExpandableIntroCardState();
}

class _ExpandableIntroCardState extends State<ExpandableIntroCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Text(
                    text,
                    maxLines: _expanded ? null : widget.collapsedLines,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: colorScheme.primary,
                    ),
                    child: Text(_expanded ? '收起' : '详细'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
