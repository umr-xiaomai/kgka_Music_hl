import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 快速跳到等高列表中尚未构建的行，使用实际布局尺寸和粘性栏高度。
bool scrollToListRow({
  required ScrollController controller,
  required GlobalKey listKey,
  required int index,
}) {
  final sliver = listKey.currentContext?.findRenderObject();
  if (index < 0 ||
      !controller.hasClients ||
      sliver is! RenderSliverFixedExtentBoxAdaptor ||
      sliver.geometry == null) {
    return false;
  }
  final extent = sliver.itemExtent;
  final viewport = RenderAbstractViewport.maybeOf(sliver);
  if (extent == null || extent <= 0 || viewport == null) return false;

  final offset = viewport
      .getOffsetToReveal(
        sliver,
        .25,
        rect: Rect.fromLTWH(
          0,
          extent * index,
          sliver.constraints.crossAxisExtent,
          extent,
        ),
      )
      .offset;
  final position = controller.position;
  controller.jumpTo(
    offset.clamp(position.minScrollExtent, position.maxScrollExtent),
  );
  return true;
}
