import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/models_new/msg/msg_at/data.dart';
import 'package:PiliPlus/models_new/msg/msg_at/item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class AtMeController extends CommonListController<MsgAtData, MsgAtItem> {
  int? cursor;
  int? cursorTime;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<MsgAtItem>? getDataList(MsgAtData response) {
    if (response.cursor?.isEnd == true) {
      isEnd = true;
    }
    cursor = response.cursor?.id;
    cursorTime = response.cursor?.time;
    return response.items;
  }

  @override
  Future<void> onRefresh() {
    cursor = null;
    cursorTime = null;
    return super.onRefresh();
  }

  @override
  Future<LoadingState<MsgAtData>> customGetData() =>
      MsgHttp.msgFeedAtMe(cursor: cursor, cursorTime: cursorTime);

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onRemove(Object id, int index) async {
    try {
      final res = await MsgHttp.delMsgfeed(2, id);
      if (res.isSuccess) {
        // 请求期间列表可能已刷新/删除过其它项：按稳定 id 重新定位。
        final list = loadingState.value.dataOrNull;
        final target = list == null
            ? -1
            : indexWhereStable(list, (e) => e.id == id);
        if (target < 0) {
          loadingState.refresh();
          return;
        }
        list!.removeAt(target);
        loadingState.refresh();
        SmartDialog.showToast('删除成功');
      } else {
        res.toast();
      }
    } catch (_) {}
  }
}
