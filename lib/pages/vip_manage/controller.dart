import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/http/vip.dart';
import 'package:PiliPlus/models/login/model.dart';
import 'package:PiliPlus/models_new/vip/play_device.dart';
import 'package:PiliPlus/models_new/vip/vip_center.dart';
import 'package:PiliPlus/pages/login/geetest/geetest_webview_dialog.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 会员状态管理（大会员状态查看 + 播放设备管理）
class VipManageController extends GetxController {
  /// 大会员中心数据
  final Rx<LoadingState<VipCenterData>> vipState =
      LoadingState<VipCenterData>.loading().obs;

  /// 播放设备数据
  final Rx<LoadingState<VipDeviceData>> deviceState =
      LoadingState<VipDeviceData>.loading().obs;

  /// 极验验证码数据（短信验证码必触发）
  final CaptchaDataModel captchaData = CaptchaDataModel();

  @override
  void onInit() {
    super.onInit();
    loadAll();
  }

  Future<void> loadAll() async {
    await Future.wait([loadVipCenter(), loadDevices()]);
  }

  Future<void> loadVipCenter() async {
    vipState.value = await VipHttp.vipCenter();
  }

  Future<void> loadDevices() async {
    deviceState.value = await VipHttp.playDevicesList();
  }

  /// 解冻（大会员冻结状态可提前解除）
  Future<void> unfreeze() async {
    final res = await VipHttp.autoRenewUnfreeze();
    if (res.isSuccess) {
      SmartDialog.showToast('解冻成功');
      loadVipCenter();
    } else {
      res.toast();
    }
  }

  /// 设为主设备：发送短信验证码（必触发极验）→ 校验 → 更新
  Future<void> setMainDevice(PlayDevice device) async {
    final user = deviceState.value.dataOrNull?.user;
    final phone = user?.phone ?? '';
    if (phone.isEmpty) {
      SmartDialog.showToast('请先在哔哩哔哩客户端绑定手机号');
      return;
    }
    await VipSmsDialog.show(
      subtitle: '发送验证码至 $phone',
      onSend: _sendSmsCode,
      onSubmit: (code) async {
        final res = await VipHttp.playDevicesUpdate(
          status: VipHttp.statusSetMainDevice,
          target: device,
          smsCode: code,
        );
        return switch (res) {
          Success() => null,
          Error(:final errMsg) => errMsg,
          Loading() => null,
        };
      },
      onSuccess: () {
        SmartDialog.showToast('已设为主设备');
        loadDevices();
      },
    );
  }

  /// 允许播放（解除限制）
  Future<void> unFreezeDevice(PlayDevice device) async {
    final res = await VipHttp.playDevicesUpdate(
      status: VipHttp.statusUnFreeze,
      target: device,
    );
    if (res.isSuccess) {
      SmartDialog.showToast('已允许播放');
      loadDevices();
    } else {
      res.toast();
    }
  }

  /// 移出可播（踢出设备）
  Future<void> playDisabled(PlayDevice device) async {
    final res = await VipHttp.playDevicesUpdate(
      status: VipHttp.statusPlayDisabled,
      target: device,
    );
    if (res.isSuccess) {
      SmartDialog.showToast('已移出可播设备');
      loadDevices();
    } else {
      res.toast();
    }
  }

  /// 发送短信验证码（触发极验验证码，参考登录流程）
  Future<({bool ok, String? msg})> _sendSmsCode() async {
    var res = await VipHttp.playDevicesSendSms();
    if (res.status) {
      return (ok: true, msg: null);
    }
    // 触发极验验证码：从响应或 preCapture 获取 gee 参数
    String? geeGt;
    String? geeChallenge;
    final data = res.data;
    final captureUrl = data?['recaptcha_url']?.toString() ?? '';
    if (captureUrl.isNotEmpty) {
      final uri = Uri.parse(captureUrl);
      captchaData.token = uri.queryParameters['recaptcha_token'];
      geeGt = uri.queryParameters['gee_gt'];
      geeChallenge = uri.queryParameters['gee_challenge'];
    } else {
      geeGt = data?['gee_gt']?.toString();
      geeChallenge = data?['gee_challenge']?.toString();
      captchaData.token = data?['recaptcha_token']?.toString();
    }
    if (geeGt?.isEmpty != false || geeChallenge?.isEmpty != false) {
      // 兜底：申请极验验证码（与登录一致）
      final pre = await LoginHttp.preCapture();
      if (pre['status'] == true && pre['data'] != null) {
        geeGt = pre['data']['gee_gt']?.toString();
        geeChallenge = pre['data']['gee_challenge']?.toString();
        captchaData.token = pre['data']['recaptcha_token']?.toString();
      }
    }
    if (geeGt?.isEmpty != false || geeChallenge?.isEmpty != false) {
      return (ok: false, msg: res.msg ?? '获取验证码失败');
    }
    final json = await GeetestWebviewDialog.geetest(geeGt!, geeChallenge!);
    if (json == null) {
      return (ok: false, msg: '验证未通过');
    }
    captchaData
      ..validate = json['geetest_validate']?.toString()
      ..seccode = json['geetest_seccode']?.toString()
      ..geetest = GeetestData(
        challenge: json['geetest_challenge']?.toString() ?? '',
        gt: geeGt,
      );
    // 携带极验参数重试
    res = await VipHttp.playDevicesSendSms(
      geeChallenge: captchaData.geetest?.challenge,
      geeSeccode: captchaData.seccode,
      geeValidate: captchaData.validate,
      recaptchaToken: captchaData.token,
    );
    return res.status
        ? (ok: true, msg: null)
        : (ok: false, msg: res.msg ?? '发送失败');
  }
}

/// 短信验证码弹窗（发送验证码 + 输入验证码）
class VipSmsDialog extends StatefulWidget {
  const VipSmsDialog({
    super.key,
    required this.subtitle,
    required this.onSend,
    required this.onSubmit,
    required this.onSuccess,
  });

  final String subtitle;
  final Future<({bool ok, String? msg})> Function() onSend;
  final Future<String?> Function(String code) onSubmit;
  final VoidCallback onSuccess;

  static Future<void> show({
    required String subtitle,
    required Future<({bool ok, String? msg})> Function() onSend,
    required Future<String?> Function(String code) onSubmit,
    required VoidCallback onSuccess,
  }) {
    return showDialog(
      context: Get.context!,
      builder: (context) => VipSmsDialog(
        subtitle: subtitle,
        onSend: onSend,
        onSubmit: onSubmit,
        onSuccess: onSuccess,
      ),
    );
  }

  @override
  State<VipSmsDialog> createState() => _VipSmsDialogState();
}

class _VipSmsDialogState extends State<VipSmsDialog> {
  final TextEditingController _codeCtrl = TextEditingController();
  bool _sending = false;
  bool _submitting = false;
  bool _sent = false;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _cooldown > 0) return;
    setState(() => _sending = true);
    final res = await widget.onSend();
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.ok) {
      setState(() {
        _sent = true;
        _cooldown = 60;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _cooldown--);
        if (_cooldown <= 0) t.cancel();
      });
    } else {
      SmartDialog.showToast(res.msg ?? '发送失败');
    }
  }

  Future<void> _submit() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      SmartDialog.showToast('请输入验证码');
      return;
    }
    if (!_sent) {
      SmartDialog.showToast('请先发送验证码');
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    final errMsg = await widget.onSubmit(code);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (errMsg == null) {
      widget.onSuccess();
      Get.back();
    } else {
      SmartDialog.showToast(errMsg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.only(
        left: 16,
        top: 18,
        right: 16,
        bottom: 12,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      title: const Text('账号身份验证', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.subtitle.isNotEmpty)
            Text(
              widget.subtitle,
              style: TextStyle(fontSize: 14, color: colorScheme.outline),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    hintText: '请输入验证码',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _sending || _cooldown > 0 ? null : _send,
                child: Text(
                  _sending
                      ? '发送中'
                      : _cooldown > 0
                      ? '${_cooldown}s后获取'
                      : '发送验证码',
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('取消')),
        TextButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '提交中' : '确定'),
        ),
      ],
    );
  }
}
