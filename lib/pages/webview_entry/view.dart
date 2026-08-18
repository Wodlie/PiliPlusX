import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 「网页浏览」二级页：输入网址或扫码调用内置 webview 浏览网站。
class WebviewEntryPage extends StatefulWidget {
  const WebviewEntryPage({super.key});

  @override
  State<WebviewEntryPage> createState() => _WebviewEntryPageState();
}

class _WebviewEntryPageState extends State<WebviewEntryPage> {
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  /// 规范化输入：无协议时自动补 https://，其它 scheme（如 ftp://）原样保留。
  String _normalizeUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) {
      return '';
    }
    if (!url.startsWith(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'))) {
      url = 'https://$url';
    }
    return url;
  }

  void _openWebview(String url) {
    Get.toNamed('/webview', parameters: {'url': url});
  }

  Future<void> _onSubmit() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      SmartDialog.showToast('请输入网址');
      return;
    }
    if (input.startsWith('bilibili://')) {
      // bilibili:// 深链交给 PiliScheme 路由（视频/空间/直播/番剧等）
      if (!await PiliScheme.routePush(Uri.parse(input))) {
        SmartDialog.showToast('无法打开该链接');
      }
      return;
    }
    _openWebview(_normalizeUrl(input));
  }

  Future<void> _onScan() async {
    if (!PlatformUtils.isMobile) {
      SmartDialog.showToast('当前平台不支持扫码');
      return;
    }
    await Get.toNamed('/qrScanner');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网页浏览')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _onSubmit(),
              decoration: InputDecoration(
                hintText: '输入网址或 bilibili:// 链接',
                prefixIcon: const Icon(Icons.link),
                border: const OutlineInputBorder(
                  borderRadius: Style.mdRadius,
                ),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _urlController,
                  builder: (context, value, child) {
                    if (value.text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: '清除',
                      onPressed: () {
                        _urlController.clear();
                        FocusScope.of(context).requestFocus(_urlFocusNode);
                      },
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _onSubmit,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('打开网页'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _onScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫一扫'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.star_outline_rounded),
                ),
                title: const Text('常用功能'),
                subtitle: const Text('客服中心、装扮商城等常用网页'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Get.toNamed('/commonFuncs'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '提示：支持 https/http 网址与 bilibili:// 深链（如 bilibili://video/123）；'
              '扫描二维码后若内容为网址将直接调用内置浏览器打开，'
              '右上角菜单可刷新、复制链接或换用系统浏览器。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
