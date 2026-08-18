import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 默认常用功能（首次进入时写入）
const List<Map<String, String>> kDefaultCommonFuncs = [
  {'title': '客服中心', 'url': 'https://www.bilibili.com/h5/customer-service'},
  {'title': '装扮商城', 'url': 'https://www.bilibili.com/h5/mall/home'},
  {'title': '硬核会员答题', 'url': 'https://www.bilibili.com/h5/senior-newbie'},
  {'title': '大会员页面', 'url': 'https://big.bilibili.com/mobile/index'},
];

/// 「常用功能」二级页：类收藏夹的常用网页列表，预置默认内容，可增删改。
class CommonFuncsPage extends StatefulWidget {
  const CommonFuncsPage({super.key});

  @override
  State<CommonFuncsPage> createState() => _CommonFuncsPageState();
}

class _CommonFuncsPageState extends State<CommonFuncsPage> {
  late List<Map<String, String>> _items;

  @override
  void initState() {
    super.initState();
    _items = Pref.commonFuncs;
    if (!GStorage.setting.containsKey(SettingBoxKey.commonFuncs)) {
      // 首次进入：写入默认内容
      _items = List.of(kDefaultCommonFuncs);
      _save();
    }
  }

  void _save() => Pref.commonFuncs = _items;

  /// 规范化输入：无协议时自动补 https://。
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

  /// 添加/编辑条目（item 非空时为编辑）
  Future<void> _showEditDialog({Map<String, String>? item}) async {
    final isEdit = item != null;
    final titleController = TextEditingController(text: item?['title']);
    final urlController = TextEditingController(text: item?['url']);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isEdit ? '编辑常用功能' : '添加常用功能'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: !isEdit,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '如：客服中心',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '网址',
                hintText: '如：https://www.bilibili.com/h5/customer-service',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (titleController.text.trim().isEmpty) {
                SmartDialog.showToast('请输入名称');
                return;
              }
              if (urlController.text.trim().isEmpty) {
                SmartDialog.showToast('请输入网址');
                return;
              }
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        final entry = {
          'title': titleController.text.trim(),
          'url': _normalizeUrl(urlController.text),
        };
        if (isEdit) {
          final index = _items.indexOf(item);
          if (index != -1) {
            _items[index] = entry;
          }
        } else {
          _items.add(entry);
        }
      });
      _save();
    }
    titleController.dispose();
    urlController.dispose();
  }

  Future<void> _deleteItem(int index) async {
    final item = _items[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除常用功能'),
        content: Text('确定删除「${item['title']}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _items.removeAt(index));
      _save();
      SmartDialog.showToast('已删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('常用功能'),
        actions: [
          IconButton(
            onPressed: _showEditDialog,
            icon: const Icon(Icons.add),
            tooltip: '添加常用功能',
          ),
        ],
      ),
      body: SafeArea(
        child: _items.isEmpty
            ? Center(
                child: Text(
                  '暂无常用功能\n点击右上角 + 添加',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final title = item['title'] ?? '';
                  final url = item['url'] ?? '';
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          title.isEmpty ? '?' : title.characters.first,
                        ),
                      ),
                      title: Text(title),
                      subtitle: Text(
                        url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openWebview(url),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _showEditDialog(item: item);
                          } else if (value == 'delete') {
                            _deleteItem(index);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text('编辑'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
