import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/black.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/blacklist/data.dart';
import 'package:PiliPlus/models_new/blacklist/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class BlackListController
    extends CommonListController<BlackListData, BlackListItem> {
  int? _total;
  final blackMids = GlobalData().blackMids;

  @override
  void onInit() {
    super.onInit();
    if (Accounts.main.isLogin) {
      queryData();
    } else {
      loadingState.value = const Error('账号未登录');
    }
  }

  @override
  List<BlackListItem>? getDataList(BlackListData response) {
    _total = response.total;
    return response.list;
  }

  @override
  void checkIsEnd(int length) {
    if (_total != null && length >= _total!) {
      isEnd = true;
    }
  }

  Future<bool> onRemove(BuildContext context, int index, name, mid) async {
    final confirm = await showConfirmDialog(
      context: context,
      title: Text('确定将 $name 移出黑名单？'),
    );
    if (confirm) {
      final result = await VideoHttp.relationMod(mid: mid, act: 6, reSrc: 11);
      if (result.isSuccess) {
        // 请求期间列表可能已翻页/重排：按稳定 mid 重新定位。
        final list = loadingState.value.dataOrNull;
        final target = list == null
            ? -1
            : indexWhereStable(list, (e) => e.mid == mid);
        if (target < 0) {
          loadingState.refresh();
          return false;
        }
        list!.removeAt(target);
        loadingState.refresh();
        _total -= 1;
        // 增量维护本地过滤缓存：页面数据可能只是分页的一部分，
        // 全网替换留给「确认已拿到全集」的退出路径。
        if (mid is int) Pref.removeBlackMid(mid);
        SmartDialog.showToast('移除成功');
        return true;
      }
    }
    return false;
  }

  @override
  Future<LoadingState<BlackListData>> customGetData() =>
      BlackHttp.blackList(pn: page);

  @override
  void onClose() {
    super.onClose();
    if (loadingState.value case Success(:final response?)) {
      blackMids.addAll(response.map((e) => e.mid!));
    }
    Pref.blackMids = blackMids;
  }
}
