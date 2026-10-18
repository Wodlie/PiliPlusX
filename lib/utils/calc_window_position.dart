import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/rendering.dart' show Offset, Rect, Size;
import 'package:screen_retriever/screen_retriever.dart';

Future<Offset> calcWindowPosition(Size windowSize) async {
  final allDisplays = screenRetriever.getAllDisplays();
  final cursorScreenPoint = await screenRetriever.getCursorScreenPoint();

  final currentDisplay =
      (await allDisplays).firstWhereOrNull(
        (display) => (display.visiblePosition! & display.size).contains(
          cursorScreenPoint,
        ),
      ) ??
      await screenRetriever.getPrimaryDisplay();

  final double visibleWidth;
  final double visibleHeight;
  if (currentDisplay.visibleSize case final size?) {
    visibleWidth = size.width;
    visibleHeight = size.height;
  } else {
    visibleWidth = currentDisplay.size.width;
    visibleHeight = currentDisplay.size.height;
  }

  final double visibleStartX;
  final double visibleStartY;
  if (currentDisplay.visiblePosition case final offset?) {
    visibleStartX = offset.dx;
    visibleStartY = offset.dy;
  } else {
    visibleStartX = visibleStartY = 0;
  }

  // 完整工作区矩形：含显示器原点（右侧副屏为正、左侧/上方副屏可能为负），
  // 不能只拿宽高当边界（F39）。
  final workspace = Rect.fromLTWH(
    visibleStartX,
    visibleStartY,
    visibleWidth,
    visibleHeight,
  );

  final windowPosition = Pref.windowPosition;
  if (windowPosition != null) {
    try {
      final dx = windowPosition[0];
      final dy = windowPosition[1];
      // 窗口左上角须落在工作区内，且至少留 30×30 的区域在界内
      if (workspace.contains(Offset(dx, dy)) &&
          workspace.contains(Offset(dx + 30, dy + 30))) {
        return Offset(dx, dy);
      }
    } catch (_) {}
  }

  return Offset(
    visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
    visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
  );
}
