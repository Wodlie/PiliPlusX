import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/black.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/blacklist/data.dart';
import 'package:PiliPlus/models_new/blacklist/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class BlackListController
    extends CommonListController<BlackListData, BlackListItem> {
  RxInt total = (-1).obs;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<BlackListItem>? getDataList(BlackListData response) {
    total.value = response.total ?? 0;
    return response.list;
  }

  @override
  void checkIsEnd(int length) {
    if (length >= total.value) {
      isEnd = true;
    }
  }

  void onRemove(BuildContext context, int index, name, mid) {
    showConfirmDialog(
      context: context,
      title: Text('确定将 $name 移出黑名单？'),
      onConfirm: () async {
        final result = await VideoHttp.relationMod(mid: mid, act: 6, reSrc: 11);
        if (result.isSuccess) {
          // 请求期间列表可能已翻页/重排：按稳定 mid 重新定位。
          final list = loadingState.value.dataOrNull;
          final target = list == null
              ? -1
              : indexWhereStable(list, (e) => e.mid == mid);
          if (target < 0) {
            loadingState.refresh();
            return;
          }
          list!.removeAt(target);
          loadingState.refresh();
          total.value -= 1;
          // 增量维护本地过滤缓存：页面数据可能只是分页的一部分，
          // 全网替换留给「确认已拿到全集」的退出路径。
          if (mid is int) Pref.removeBlackMid(mid);
          SmartDialog.showToast('移除成功');
        }
      },
    );
  }

  @override
  Future<LoadingState<BlackListData>> customGetData() =>
      BlackHttp.blackList(pn: page);
}
