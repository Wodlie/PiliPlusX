import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/space/space_fav/data.dart';
import 'package:PiliPlus/models_new/space/space_fav/list.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MemberFavoriteCtr
    extends CommonDataController<List<SpaceFavData>?, List<SpaceFavData>?> {
  MemberFavoriteCtr({
    required this.mid,
  });

  final int mid;

  late int favPage = 2;
  bool _favExpand = true;
  final RxBool favEnd = true.obs;
  final Rx<SpaceFavData> favState = SpaceFavData().obs;

  late int subPage = 2;
  bool _subExpand = true;
  final RxBool subEnd = true.obs;
  final Rx<SpaceFavData> subState = SpaceFavData().obs;

  /// 两条「查看更多」各自的在途锁：连点只会发一次请求。
  bool _favLoading = false;
  bool _subLoading = false;

  /// 列表代次：刷新后旧请求的结果不能再落到新列表上。
  int _gen = 0;

  /// 追加时按 id 去重：重复请求同一页或服务端重排都不该出现重复卡片。
  void _appendOnce(
    List<SpaceFavItemModel>? target,
    List<SpaceFavItemModel> added,
  ) {
    if (target == null || added.isEmpty) return;
    final seen = target.map((e) => e.id).toSet();
    target.addAll(added.where((e) => seen.add(e.id)));
  }

  List<SpaceFavItemModel> _parseItems(Object? raw) =>
      (raw as List<dynamic>?)
          ?.map((item) => SpaceFavItemModel.fromJson(item))
          .toList() ??
      const [];

  bool isExpand(bool isFav) {
    return isFav ? _favExpand : _subExpand;
  }

  void setExpand(bool isFav) {
    if (isFav) {
      flag = _favExpand;
      _favExpand = !_favExpand;
    } else {
      _subExpand = !_subExpand;
    }
  }

  bool flag = false;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> onRefresh() {
    favPage = 2;
    subPage = 2;
    _gen++;
    return super.onRefresh();
  }

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<List<SpaceFavData>?> response,
  ) {
    try {
      List<SpaceFavData> res = response.response!;
      favState.value = res.first;
      subState.value = res[1];

      favEnd.value =
          (res.first.mediaListResponse?.count ?? -1) <=
          (res.first.mediaListResponse?.list?.length ?? -1);
      subEnd.value =
          (res[1].mediaListResponse?.count ?? -1) <=
          (res[1].mediaListResponse?.list?.length ?? -1);
    } catch (e) {
      if (kDebugMode) debugPrint(e.toString());
    }
    loadingState.value = response;
    return true;
  }

  Future<void> userFavFolder() async {
    if (_favLoading) return;
    _favLoading = true;
    final gen = _gen;
    final requestedPage = favPage;
    try {
      final res = await Request().get(
        Api.userFavFolder,
        queryParameters: {
          'pn': requestedPage,
          'ps': 20,
          'up_mid': mid,
        },
      );
      // 期间刷新过：这一页属于旧列表，丢弃且不推进页码。
      if (gen != _gen) return;
      if (res.data['code'] == 0) {
        final data = res.data['data'];
        // 只有本次请求页成功落地后才推进页码，避免跳页/重复页。
        favPage = requestedPage + 1;
        if (data != null) {
          favEnd.value = data['has_more'] == false;
          final list = _parseItems(data['list']);
          if (list.isNotEmpty) {
            _appendOnce(favState.value.mediaListResponse?.list, list);
            favState.refresh();
          } else {
            favEnd.value = true;
          }
        } else {
          favEnd.value = true;
        }
      } else {
        SmartDialog.showToast(res.data['message']);
      }
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      _favLoading = false;
    }
  }

  Future<void> userSubFolder() async {
    if (_subLoading) return;
    _subLoading = true;
    final gen = _gen;
    final requestedPage = subPage;
    try {
      final res = await Request().get(
        Api.userSubFolder,
        queryParameters: {
          'up_mid': mid,
          'ps': 20,
          'pn': requestedPage,
          'platform': 'web',
        },
      );
      // 期间刷新过：这一页属于旧列表，丢弃且不推进页码。
      if (gen != _gen) return;
      if (res.data['code'] == 0) {
        final data = res.data['data'];
        // 只有本次请求页成功落地后才推进页码，避免跳页/重复页。
        subPage = requestedPage + 1;
        if (data != null) {
          subEnd.value = data['has_more'] == false;
          final list = _parseItems(data['list']);
          if (list.isNotEmpty) {
            _appendOnce(subState.value.mediaListResponse?.list, list);
            subState.refresh();
          } else {
            subEnd.value = true;
          }
        } else {
          subEnd.value = true;
        }
      } else {
        SmartDialog.showToast(res.data['message']);
      }
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      _subLoading = false;
    }
  }

  @override
  Future<LoadingState<List<SpaceFavData>?>> customGetData() =>
      FavHttp.spaceFav(mid: mid);
}
