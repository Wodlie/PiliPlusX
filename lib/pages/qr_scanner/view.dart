import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码页：识别二维码内容——bilibili TV 登录码直接走原生确认登录（官方客户端
/// 角色，使 firstLogin.py 等外部轮询方成功）；网址则调用内置 webview 打开。
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) {
      return;
    }
    final value = capture.barcodes
        .map((e) => e.rawValue)
        .whereType<String>()
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (value.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(value);
    // bilibili TV 登录二维码（firstLogin.py 等外部工具生成的 auth_code 链接）：
    // 以当前账号确认登录（appkey 签名），使外部轮询方成功，不交给内置 webview
    final tvAuthCode = _tvLoginAuthCode(value);
    if (tvAuthCode != null) {
      _handled = true;
      await _controller.stop();
      await _confirmTvLogin(tvAuthCode);
      return;
    }
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      _handled = true;
      await _controller.stop();
      // 替换当前扫码页，返回时直接回到「网页浏览」入口页
      Get.offNamed('/webview', parameters: {'url': value});
    } else if (value.startsWith('bilibili://')) {
      // bilibili:// 深链（视频/空间/直播等）交给 PiliScheme 路由
      _handled = true;
      await _controller.stop();
      Get.back();
      if (!await PiliScheme.routePush(Uri.parse(value))) {
        SmartDialog.showToast('无法打开该链接');
      }
    } else {
      SmartDialog.showToast('未识别到网址：$value');
    }
  }

  /// 识别 bilibili TV 登录确认页二维码（`/x/passport-tv-login/h5/qrcode/auth`），
  /// 返回其中的 auth_code；非 TV 登录码返回 null。
  static String? _tvLoginAuthCode(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'passport.bilibili.com' ||
        uri.path != '/x/passport-tv-login/h5/qrcode/auth') {
      return null;
    }
    final code = uri.queryParameters['auth_code'];
    return (code == null || code.isEmpty) ? null : code;
  }

  /// 以当前账号确认 TV 端扫码登录（官方客户端角色）：firstLogin.py 等外部
  /// 工具生成 TV 登录二维码后由其自身轮询，本方法确认后其即可换取 token。
  Future<void> _confirmTvLogin(String authCode) async {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('请先登录后再扫码确认');
      Get.toNamed('/loginPage');
      return;
    }
    SmartDialog.showLoading(msg: '正在确认登录');
    final res = await LoginHttp.confirmTvLogin(authCode);
    SmartDialog.dismiss();
    if (res['status'] == true) {
      SmartDialog.showToast('已确认登录，等待 TV 端完成');
    } else {
      SmartDialog.showToast('确认失败：(${res['code']}) ${res['msg']}');
    }
    Get.back();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('扫码')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // 扫描框遮罩
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 80,
                      spreadRadius: 60,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Column(
              children: [
                Text(
                  '将二维码对准扫描框',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                ),
                const SizedBox(height: 12),
                IconButton.filledTonal(
                  tooltip: '切换手电筒',
                  onPressed: _controller.toggleTorch,
                  icon: const Icon(Icons.flashlight_on_outlined),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
