import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

/// 在列表里按稳定身份重新定位，而不是沿用操作发起时的渲染下标。
///
/// 优先取对象同一性（同一个实例），再退化为 ==（模型/PB 消息可能重写）；
/// 返回 -1 表示目标已经不在当前列表里：此时调用方只应刷新，不落旧操作。
int indexOfIdentity<T>(List<T> list, T item) {
  for (var i = 0; i < list.length; i++) {
    if (identical(list[i], item)) return i;
  }
  return list.indexOf(item);
}

/// 按稳定 id/条件重新定位（例如删除请求只回传了 id 的场景）。
/// 返回 -1 表示目标已不在当前列表里。
int indexWhereStable<T>(List<T> list, bool Function(T item) test) {
  for (var i = 0; i < list.length; i++) {
    if (test(list[i])) return i;
  }
  return -1;
}

abstract class CommonListController<R, T> extends CommonController<R, T> {
  int page = 1;
  bool isEnd = false;
  bool get endIfNullOrEmpty => true;
  bool get hasFooter => false;

  /// 续页（isRefresh=false）失败时的可操作错误。
  ///
  /// 与 loadingState 分开保存：续页失败既不能替换已有列表，也不能让 footer
  /// 一直停在「加载中」，视图据此展示重试入口。
  final Rx<String?> loadMoreError = Rx<String?>(null);

  @override
  Rx<LoadingState<List<T>?>> loadingState =
      LoadingState<List<T>?>.loading().obs;

  void handleListResponse(List<T> dataList) {}

  /// 翻页追加前的回调：仅在加载更多（非刷新）时调用，
  /// 可用于过滤即将追加的数据（如按 id 去重）。
  void handleLoadMore(List<T> dataList) {}

  List<T>? getDataList(R response) {
    return response as List<T>?;
  }

  void checkIsEnd(int length) {}

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading || (!isRefresh && isEnd)) return;
    isLoading = true;
    loadMoreError.value = null;
    final LoadingState<R> res = await customGetData();
    if (res case Success(:final response)) {
      if (!customHandleResponse(isRefresh, res)) {
        final dataList = getDataList(response);
        if (dataList == null || dataList.isEmpty) {
          if (endIfNullOrEmpty) isEnd = true;
          if (isRefresh) {
            loadingState.value = Success(dataList);
          } else if (hasFooter) {
            loadingState.refresh();
          }
          isLoading = false;
          return;
        }
        handleListResponse(dataList);
        if (isRefresh) {
          checkIsEnd(dataList.length);
          loadingState.value = Success(dataList);
        } else if (loadingState.value case Success(:final response)) {
          handleLoadMore(dataList);
          response!.addAll(dataList);
          checkIsEnd(response.length);
          loadingState.refresh();
        }
      }
      page++;
    } else {
      final errMsg = res is Error ? res.errMsg : null;
      if (isRefresh) {
        if (!handleError(errMsg)) loadingState.value = res as Error;
      } else {
        // 续页错误不能被吞：列表与游标保持不变，由 footer 提供可操作重试。
        // 只写这个 Rx（订阅它的 footer 会自行重建），不 refresh loadingState：
        // 某些视图在 build 里调用 onLoadMore，凭空重建会变成失败重试死循环。
        loadMoreError.value = errMsg ?? '加载失败，点击重试';
      }
    }
    isLoading = false;
  }

  /// 重试上一次失败的续页：保留已加载列表与游标，只清除错误后重发。
  Future<void> onLoadMoreRetry() {
    if (isEnd) return Future<void>.value();
    loadMoreError.value = null;
    return queryData(false);
  }

  @override
  Future<void> onRefresh() {
    page = 1;
    isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<List<T>?>.loading();
    return super.onReload();
  }
}
