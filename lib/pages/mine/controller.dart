import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/theme/theme_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/models/user/stat.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/data.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class MineController extends CommonDataController<FavFolderData, FavFolderData>
    with AccountMixin {
  @override
  AccountService accountService = Get.find<AccountService>();

  int? favFolderCount;

  // 用户信息 头像、昵称、lv
  final Rx<UserInfoData> userInfo = UserInfoData().obs;
  // 用户状态 动态、关注、粉丝
  final Rx<UserStat> userStat = const UserStat().obs;

  final Rx<ThemeType> themeType = Pref.themeType.obs;

  ThemeType get nextThemeType =>
      ThemeType.values[(themeType.value.index + 1) % ThemeType.values.length];

  static RxBool anonymity =
      (Accounts.account.isNotEmpty && !Accounts.heartbeat.isLogin).obs;

  late final list = <({IconData icon, String title, VoidCallback onTap})>[
    (
      icon: CustomIcons.folderDownloadOutline,
      title: '离线缓存',
      onTap: () => Get.toNamed('/download'),
    ),
    (
      icon: CustomIcons.history,
      title: '观看记录',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/history');
        }
      },
    ),
    (
      icon: CustomIcons.subscriptions_outlined,
      title: '我的订阅',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/subscription');
        }
      },
    ),
    (
      icon: CustomIcons.watch_later_outlined,
      title: '稍后再看',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/later');
        }
      },
    ),
  ];

  @override
  void onInit() {
    super.onInit();
    UserInfoData? userInfoCache = Pref.userInfoCache;
    if (userInfoCache != null) {
      userInfo.value = userInfoCache;
      queryData();
      queryUserInfo();
    }
  }

  bool get isLogin {
    if (!accountService.isLogin.value) {
      // SmartDialog.showToast('账号未登录');
      return false;
    }
    return true;
  }

  /// 账号资料。
  ///
  /// cookie 校验统一由 `AccountService` 在生命周期节点完成（启动/切换/重登），
  /// 这里只消费那份结果：避免「我的」页面再发一次 nav，也避免用 cookie 结果
  /// 覆盖 access token 的判定。cookie 明确失效只更新未登录展示，不在这里删除
  /// 账号；网络异常保留已有资料。
  Future<void> queryUserInfo() async {
    final selected = Accounts.main;
    if (selected is! LoginAccount) {
      accountService.isLogin.value = false;
      return;
    }
    final service = accountService;
    final pending = service.pendingFor(selected);
    if (pending != null) await pending;
    final health = service.healthFor(selected);
    if (!health.identity.matches(Accounts.main)) return;
    final res = health.cookieResult;
    // 展示资料只在 cookie **明确有效**时采用：`cookieResult` 只是「有资料」，
    // 非空资料配 isLogin=false（畸形/截断响应）绝不能把账号显示成已登录。
    // 登录态的发布由 AccountService 按凭证投影负责，这里不反向覆盖它。
    if (res case Success(:final response)
        when health.cookie == CookieHealth.valid) {
      userInfo.value = response;
      if (response != Pref.userInfoCache) {
        GStorage.userInfo.put('userInfoCache', response);
      }
      if (response.mid != null && response.uname != null) {
        Pref.setAccountUname(response.mid!, response.uname!);
      }
      service.face.value = response.face ?? service.face.value;
    } else if (health.cookie == CookieHealth.invalid) {
      // cookie 明确失效：只改展示态，不删除存储账号（token 失效是另一回事）。
      service.isLogin.value = false;
      userInfo.value = UserInfoData();
    }
    // 明确失效时不发统计请求（必然 401，且没有意义）；其余情况等待完成，
    // 让 `queryUserInfo()` 的 async 语义完整（调用方 await 后状态已就绪）。
    if (health.cookie != CookieHealth.invalid) {
      await queryUserStatOwner();
    }
  }

  /// 账号统计。
  ///
  /// 绑定发起时的账号与凭证指纹：账号在中途被切换（或同 mid 换 key）时，
  /// 响应不会被写回，避免上一个账号的统计覆盖新账号的展示。
  Future<void> queryUserStatOwner() async {
    final selected = Accounts.main;
    if (selected is! LoginAccount) return;
    final identity = AccountHealthIdentity.capture(selected);
    final res = await UserHttp.userStatOwner(
      account: selected,
      expectedIdentity: identity,
    );
    if (!identity.matches(Accounts.main)) return;
    if (res case Success(:final response)) {
      userStat.value = response;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FavFolderData> response) {
    favFolderCount = response.response.count;
    loadingState.value = response;
    return true;
  }

  @override
  Future<LoadingState<FavFolderData>> customGetData() {
    return FavHttp.userfavFolder(
      pn: 1,
      ps: 20,
      mid: Accounts.main.mid,
    );
  }

  static void onChangeAnonymity() {
    if (Accounts.account.isEmpty) {
      SmartDialog.showToast('请先登录');
      return;
    }
    final newVal = !anonymity.value;
    anonymity.value = newVal;
    if (newVal) {
      SmartDialog.dismiss();
      SmartDialog.show<bool>(
        clickMaskDismiss: false,
        usePenetrate: true,
        displayTime: const Duration(seconds: 2),
        alignment: Alignment.bottomCenter,
        builder: (context) {
          final theme = Theme.of(context);
          final style = TextStyle(
            color: theme.colorScheme.onSecondaryContainer,
          );
          return ColoredBox(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: EdgeInsets.only(
                top: 15,
                left: 20,
                right: 20,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 15,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(MdiIcons.incognito, size: 20),
                      const SizedBox(width: 10),
                      Text('已进入无痕模式', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '搜索不携带身份信息\n'
                    '不产生查询或播放记录\n'
                    '点赞等其它操作不受影响\n'
                    '播放进度信息跟随视频取流\n'
                    '上次观看分p信息跟随主账号\n'
                    '(前往隐私设置了解详情)',
                    style: theme.textTheme.bodySmall,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () {
                          SmartDialog.dismiss(result: true);
                          SmartDialog.showToast('已设为永久无痕模式');
                        },
                        child: Text('保存为永久', style: style),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: () {
                          SmartDialog.dismiss();
                          SmartDialog.showToast('已设为临时无痕模式');
                        },
                        child: Text('仅本次（默认）', style: style),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ).then((res) {
        if (res == false) {
          return;
        }
        res == true
            ? Accounts.set(AccountType.heartbeat, AnonymousAccount())
            : Accounts.accountMode[AccountType.heartbeat.index] =
                  AnonymousAccount();
      });
    } else {
      Accounts.set(AccountType.heartbeat, Accounts.main);
      SmartDialog.dismiss(result: false);
      SmartDialog.show(
        clickMaskDismiss: false,
        usePenetrate: true,
        displayTime: const Duration(seconds: 1),
        alignment: Alignment.bottomCenter,
        builder: (context) {
          final theme = Theme.of(context);
          return ColoredBox(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: EdgeInsets.only(
                top: 15,
                left: 20,
                right: 20,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 15,
              ),
              child: Row(
                children: [
                  const Icon(MdiIcons.incognitoOff, size: 20),
                  const SizedBox(width: 10),
                  Text('已退出无痕模式', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
          );
        },
      );
    }
  }

  void onChangeTheme() {
    final newVal = nextThemeType;
    themeType.value = newVal;
    GStorage.setting.put(SettingBoxKey.themeMode, newVal.index);
    Get.changeThemeMode(ThemeUtils.themeMode = newVal.toThemeMode);
  }

  void push(String name) {
    late final mid = userInfo.value.mid;
    if (isLogin && mid != null) {
      Get.toNamed('/$name?mid=$mid');
    }
  }

  void onLogin([bool longPress = false]) {
    if (!accountService.isLogin.value || longPress) {
      Get.toNamed('/loginPage');
    } else {
      Get.toNamed('/member?mid=${userInfo.value.mid}');
    }
  }

  @override
  Future<void> onRefresh({bool isManual = true}) {
    if (!accountService.isLogin.value) {
      return Future.syncValue(null);
    }
    queryUserInfo();
    return super.onRefresh().whenComplete(() {
      if (isManual) {
        scrollController.jumpToTop();
      }
    });
  }

  @override
  void onChangeAccount(bool isLogin) {
    if (isLogin) {
      onRefresh();
    } else {
      userInfo.value = UserInfoData();
      userStat.value = const UserStat();
      loadingState.value = LoadingState.loading();
    }
  }
}
