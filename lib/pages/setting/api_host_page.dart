import 'package:PiliPlus/http/api_hosts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class ApiHostPage extends StatefulWidget {
  const ApiHostPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<ApiHostPage> createState() => _ApiHostPageState();
}

class _ApiHostPageState extends State<ApiHostPage> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = apiHostEntries
        .map((e) => TextEditingController(
              text: GStorage.setting.get(e.settingKey, defaultValue: '') as String? ?? '',
            ))
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showAppBar = widget.showAppBar;
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: showAppBar ? AppBar(title: const Text('自定义 API 主机')) : null,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          ListView.separated(
            padding: padding.copyWith(
              top: 20,
              left: 20 + (showAppBar ? padding.left : 0),
              right: 20 + (showAppBar ? padding.right : 0),
              bottom: padding.bottom + 100,
            ),
            itemCount: apiHostEntries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 20),
            itemBuilder: (context, i) {
              final entry = apiHostEntries[i];
              return TextField(
                controller: _controllers[i],
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: '${entry.label}（默认：${entry.defaultHost}）',
                  border: const OutlineInputBorder(),
                ),
              );
            },
          ),
          Positioned(
            right:
                kFloatingActionButtonMargin + (showAppBar ? padding.right : 0),
            bottom: kFloatingActionButtonMargin + padding.bottom,
            child: FloatingActionButton(
              child: const Icon(Icons.save),
              onPressed: () async {
                for (var i = 0; i < apiHostEntries.length; i++) {
                  final entry = apiHostEntries[i];
                  final raw = _controllers[i].text;
                  final value = raw.trim();
                  _controllers[i].text = value;
                  if (value.isNotEmpty) {
                    if (!value.startsWith('http')) {
                      SmartDialog.showToast('${entry.label}：需以 http 或 https 开头');
                      return;
                    }
                    if (value.endsWith('/')) {
                      SmartDialog.showToast('${entry.label}：不能以 / 结尾');
                      return;
                    }
                  }
                }
                final map = <String, String>{};
                for (var i = 0; i < apiHostEntries.length; i++) {
                  map[apiHostEntries[i].settingKey] = _controllers[i].text;
                }
                await GStorage.setting.putAll(map);
                SmartDialog.showToast('已保存');
              },
            ),
          ),
        ],
      ),
    );
  }
}
