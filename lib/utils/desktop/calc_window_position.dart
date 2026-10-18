import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/rendering.dart' show Offset, Rect, Size;
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:screen_retriever/screen_retriever.dart';

const _displayManager = nativeapi.DisplayManager.instance;

nativeapi.Rectangle calcWindowBounds() {
  final windowSize = Pref.windowSize;
  final offset = calcWindowPosition(windowSize);
  return nativeapi.Rectangle(
    x: offset.dx,
    y: offset.dy,
    width: windowSize.width,
    height: windowSize.height,
  );
}

Offset calcWindowPosition(Size windowSize) {
  final displays = _displayManager.getAll();
  final cursorPosition = _displayManager.getCursorPosition().toOffset();

  final currentDisplay =
      displays.firstWhereOrNull(
        (display) => (display.position.toOffset() & display.size.toSize())
            .contains(cursorPosition),
      ) ??
      _displayManager.getPrimary();

  if (currentDisplay == null) return .zero;

  final workArea = currentDisplay.workArea.toRect();

  final double visibleWidth = workArea.width;
  final double visibleHeight = workArea.height;

  final double visibleStartX = workArea.left;
  final double visibleStartY = workArea.top;

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
