import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal surface both fold back-ends (fork Rxn and upstream plain field) expose.
abstract interface class ReplyFooterController<R> {
  /// Folded-reply hint text; null when there is no fold entry.
  String? get foldText;
  Future<void> loadFoldList({bool toast});
  void onLoadMore();
  Future<void> onReload();
  bool get isEnd;
}

mixin ReplyFooterMixin<T extends StatefulWidget, R> on State<T> {
  late EdgeInsets padding;
  ColorScheme get colorScheme;
  ReplyFooterController<R> get controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    padding = MediaQuery.viewPaddingOf(context);
  }

  Widget buildFooter() {
    final fold = controller.foldText;
    if (fold != null) return _buildFoldItem(fold);

    controller.onLoadMore();
    return buildEndItem();
  }

  Widget _buildFoldItem(String fold) {
    return Container(
      height: 125,
      alignment: .topCenter,
      margin: .only(bottom: padding.bottom),
      child: Material(
        type: .transparency,
        child: InkWell(
          onTap: () => controller.loadFoldList(toast: true),
          child: SizedBox(
            width: .infinity,
            child: Padding(
              padding: const .symmetric(vertical: 12),
              child: Text(
                fold,
                textAlign: .center,
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildEndItem() {
    return Container(
      height: 125,
      alignment: .center,
      margin: .only(bottom: padding.bottom),
      child: Text(
        controller.isEnd ? '没有更多了' : '加载中...',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: colorScheme.outline),
      ),
    );
  }

  Widget emptyWidget() {
    return HttpError(
      errMsg: '还没有评论',
      onReload: controller.onReload,
    );
  }
}
