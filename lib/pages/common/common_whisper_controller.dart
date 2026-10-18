import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show SessionPageType, SessionId, Session;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract class CommonWhisperController<R>
    extends CommonListController<R, Session> {
  SessionPageType get sessionPageType;

  Future<void> onRemove(int index, int talkerId) async {
    final res = await MsgHttp.removeMsg(talkerId);
    if (res.isSuccess) {
      // 会话列表会因新消息/置顶重排：按 talkerId 重新定位，找不到就只刷新。
      final list = loadingState.value.dataOrNull;
      final target = list == null
          ? -1
          : indexWhereStable(
              list,
              (e) => e.id.privateId.talkerUid.toInt() == talkerId,
            );
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
  }

  Future<void> onSetTop(
    Session item,
    int index,
    bool isTop,
    SessionId sessionId,
  ) async {
    final res = isTop
        ? await ImGrpc.unpinSession(sessionId: sessionId)
        : await ImGrpc.pinSession(sessionId: sessionId);

    if (res.isSuccess) {
      item.isPinned = isTop ? false : true;
      final list = loadingState.value.dataOrNull;
      if (list != null && !isTop) {
        // 等待期间列表可能已被新消息重排：按对象身份重新定位。
        final target = indexOfIdentity(list, item);
        if (target > 0) {
          list.insert(0, list.removeAt(target));
        }
      }
      loadingState.refresh();
      SmartDialog.showToast('${isTop ? '移除' : ''}置顶成功');
    } else {
      res.toast();
    }
  }

  Future<void> onSetMute(Session item, bool isMuted, Int64 talkerUid) async {
    final res = await MsgHttp.setMsgDnd(
      uid: Accounts.main.mid,
      setting: isMuted ? 0 : 1,
      dndUid: talkerUid,
    );
    if (res.isSuccess) {
      item.isMuted = !isMuted;
      loadingState.refresh();
      SmartDialog.showToast('设置成功');
    } else {
      res.toast();
    }
  }

  Future<void> onClearUnread() async {
    final res = await ImGrpc.clearUnread(pageType: sessionPageType);
    if (res.isSuccess) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          for (final item in response) {
            if (item.hasUnread()) {
              item.clearUnread();
            }
          }
          loadingState.refresh();
        }
      }
      SmartDialog.showToast('已标记为已读');
    } else {
      res.toast();
    }
  }

  Future<void> onDeleteList() async {
    final res = await ImGrpc.deleteSessionList(pageType: sessionPageType);
    if (res.isSuccess) {
      loadingState.value = const Success(null);
    } else {
      res.toast();
    }
  }
}
