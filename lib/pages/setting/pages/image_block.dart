import 'dart:io';

import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/pages/setting/widgets/normal_item.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/blocked_image_storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class ImageBlockSettingPage extends StatefulWidget {
  const ImageBlockSettingPage({super.key});

  @override
  State<ImageBlockSettingPage> createState() => _ImageBlockSettingPageState();
}

class _ImageBlockSettingPageState extends State<ImageBlockSettingPage> {
  late List<Map<String, dynamic>> _hashList;
  bool _enableMultiSelect = false;
  final Set<int> _selectedIndices = {};
  bool _displayMode = false;

  @override
  void initState() {
    super.initState();
    _hashList = Pref.imageBlockHashList;
    _displayMode = Pref.imageBlockDisplayMode;
  }

  void _refreshList() {
    setState(() {
      _hashList = Pref.imageBlockHashList;
    });
  }

  void _exitSelectMode() {
    setState(() {
      _enableMultiSelect = false;
      _selectedIndices.clear();
    });
  }

  String _formatTimestamp(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  void _selectAll() {
    setState(() {
      if (_selectedIndices.length == _hashList.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices.addAll(List.generate(_hashList.length, (i) => i));
      }
    });
  }

  void _copySelectedPhash() {
    final phashes = _selectedIndices
        .map((i) => _hashList[i]['pHash'] as String)
        .join('\n');
    Utils.copyText(
      phashes,
      toastText: '已复制${_selectedIndices.length}条pHash到剪贴板',
    );
    _exitSelectMode();
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIndices.length;
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('确认删除'),
      content: Text('确定删除选中$count条屏蔽图片？'),
    );
    if (!confirmed) return;

    final toDelete = _selectedIndices
        .map((i) => _hashList[i]['pHash'] as String)
        .toList();
    for (final pHash in toDelete) {
      await BlockedImageStorage.delete(pHash);
    }
    final remaining = <Map<String, dynamic>>[];
    for (int i = 0; i < _hashList.length; i++) {
      if (!_selectedIndices.contains(i)) {
        remaining.add(_hashList[i]);
      }
    }
    Pref.imageBlockHashList = remaining;
    ImageBlockService.invalidateResultCache();
    _refreshList();
    _exitSelectMode();
    SmartDialog.showToast('已删除$count条');
  }

  Future<void> _deleteSingleItem(int index) async {
    final entry = _hashList[index];
    final pHash = entry['pHash'] as String;
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('确认删除'),
      content: Text('确定删除该屏蔽图片？\npHash: $pHash'),
    );
    if (!confirmed) return;

    await BlockedImageStorage.delete(pHash);
    _hashList.removeAt(index);
    Pref.imageBlockHashList = _hashList;
    ImageBlockService.invalidateResultCache();
    _refreshList();
    SmartDialog.showToast('已删除');
  }

  void _showThresholdDialog(BuildContext context, VoidCallback setState) {
    showDialog<double>(
      context: context,
      builder: (context) => SliderDialog(
        title: const Text('图片屏蔽阈值'),
        min: 0,
        max: 64,
        divisions: 64,
        precise: 0,
        value: Pref.imageBlockThreshold.toDouble(),
        suffix: '',
      ),
    ).then((res) {
      if (res != null) {
        Pref.imageBlockThreshold = res.toInt();
        ImageBlockService.invalidateResultCache();
        setState();
      }
    });
  }

  Future<void> _importPhash() async {
    final textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入pHash'),
        content: TextField(
          controller: textController,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '每行一个pHash值，支持粘贴多个',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, textController.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (result == null || result.trim().isEmpty) return;

    final lines = result
        .split('\n')
        .map((l) => l.trim().replaceAll('\r', ''))
        .where((l) => l.isNotEmpty)
        .toList();

    int imported = 0;
    int ignored = 0;
    final existingPhash = _hashList.map((e) => e['pHash'] as String).toSet();

    for (final line in lines) {
      if (RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(line)) {
        if (!existingPhash.contains(line)) {
          existingPhash.add(line);
          _hashList.add({
            'pHash': line,
            'url': '',
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
          imported++;
        } else {
          ignored++;
        }
      } else {
        ignored++;
      }
    }

    if (imported > 0) {
      Pref.imageBlockHashList = _hashList;
      ImageBlockService.invalidateResultCache();
      _refreshList();
    }
    SmartDialog.showToast('导入了$imported条，忽略了$ignored条无效记录');
  }

  void _exportPhash() {
    if (_hashList.isEmpty) {
      SmartDialog.showToast('暂无屏蔽图片');
      return;
    }
    final phashes = _hashList.map((e) => e['pHash'] as String).join('\n');
    Utils.copyText(
      phashes,
      toastText: '已复制${_hashList.length}条pHash到剪贴板',
    );
  }

  Future<void> _clearAll() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('确认清空'),
      content: const Text('确定清空全部屏蔽图片记录？此操作不可撤销'),
    );
    if (!confirmed) return;

    await BlockedImageStorage.deleteAll();
    Pref.imageBlockHashList = [];
    ImageBlockService.invalidateResultCache();
    _refreshList();
    SmartDialog.showToast('已清空全部');
  }

  void _setMode(bool isPreviewMode) {
    if (_displayMode == isPreviewMode) return;
    setState(() {
      _displayMode = isPreviewMode;
      Pref.imageBlockDisplayMode = isPreviewMode;
    });
  }

  Widget _buildOvalToggle() {
    final theme = Theme.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ovalSegment(
            text: '列表',
            isActive: !_displayMode,
            onTap: () => _setMode(false),
          ),
          _ovalSegment(
            text: '预览',
            isActive: _displayMode,
            onTap: () => _setMode(true),
          ),
        ],
      ),
    );
  }

  Widget _ovalSegment({
    required String text,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive ? theme.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w600 : null,
            color: isActive
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _buildMode1Item(ThemeData theme, String pHash, int ts) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                File(BlockedImageStorage.filePathFor(pHash)),
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          Expanded(
            child: Text(
              pHash,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),

          Text(
            _formatTimestamp(ts),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMode2Item(ThemeData theme, String pHash, int ts) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(BlockedImageStorage.filePathFor(pHash)),
              width: double.infinity,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => SizedBox(
                height: 150,
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(
                      Icons.broken_image,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  pHash,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTimestamp(ts),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return popScope(
      canPop: !_enableMultiSelect,
      onPopInvokedWithResult: (didPop, result) {
        if (_enableMultiSelect) {
          _exitSelectMode();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(
            _enableMultiSelect ? '已选择 ${_selectedIndices.length} 项' : '屏蔽图片设置',
          ),
          leading: _enableMultiSelect
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelectMode,
                )
              : null,
          actions: _enableMultiSelect
              ? [
                  TextButton(
                    onPressed: _hashList.isEmpty ? null : _selectAll,
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: _selectedIndices.isEmpty
                        ? null
                        : _copySelectedPhash,
                    child: const Text('复制pHash'),
                  ),
                  TextButton(
                    onPressed: _selectedIndices.isEmpty
                        ? null
                        : _deleteSelected,
                    child: Text(
                      '删除',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  const SizedBox(width: 10),
                ]
              : [
                  _buildOvalToggle(),
                  IconButton(
                    icon: const Icon(Icons.file_download_outlined),
                    tooltip: '导入pHash',
                    onPressed: _importPhash,
                  ),
                  IconButton(
                    icon: const Icon(Icons.file_upload_outlined),
                    tooltip: '导出pHash',
                    onPressed: _exportPhash,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: '清空全部',
                    onPressed: _clearAll,
                  ),
                ],
        ),
        body: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '屏蔽设置',
                style: TextStyle(
                  color: theme.colorScheme.outline,
                  fontSize: 13,
                ),
              ),
            ),
            const Divider(height: 1),
            NormalItem(
              title: '屏蔽阈值',
              getSubtitle: () =>
                  '当前: ${Pref.imageBlockThreshold}；pHash汉明距离超过该值时屏蔽',
              onTap: _showThresholdDialog,
            ),
            const Divider(height: 1),
            SetSwitchItem(
              title: '水平翻转变体',
              subtitle: '将图片水平翻转后计算pHash，加强屏蔽效果',
              setKey: SettingBoxKey.imageBlockFlipEnabled,
              defaultVal: true,
              onChanged: (_) {
                ImageBlockService.invalidateResultCache();
                setState(() {});
              },
            ),
            const Divider(height: 1),
            SetSwitchItem(
              title: '旋转变体',
              subtitle: '将图片旋转后计算pHash，加强屏蔽效果',
              setKey: SettingBoxKey.imageBlockRotateEnabled,
              defaultVal: true,
              onChanged: (_) {
                ImageBlockService.invalidateResultCache();
                setState(() {});
              },
            ),
            const Divider(height: 1),

            if (_hashList.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 80),
                child: Center(
                  child: Text(
                    '暂无被屏蔽的图片',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '已屏蔽图片(${_hashList.length})',
                  style: TextStyle(
                    color: theme.colorScheme.outline,
                    fontSize: 13,
                  ),
                ),
              ),
            if (_hashList.isNotEmpty) const Divider(height: 1),
            ...List.generate(_hashList.length, (index) {
              final entry = _hashList[index];
              final pHash = entry['pHash'] as String;
              final ts = entry['ts'] as int;
              final isSelected = _selectedIndices.contains(index);

              return GestureDetector(
                onLongPress: _enableMultiSelect
                    ? null
                    : () {
                        setState(() {
                          _enableMultiSelect = true;
                          _selectedIndices.add(index);
                        });
                      },
                onTap: _enableMultiSelect
                    ? () {
                        setState(() {
                          if (isSelected) {
                            _selectedIndices.remove(index);
                            if (_selectedIndices.isEmpty) {
                              _enableMultiSelect = false;
                            }
                          } else {
                            _selectedIndices.add(index);
                          }
                        });
                      }
                    : () => _deleteSingleItem(index),
                child: Container(
                  color: isSelected
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.3,
                        )
                      : null,
                  child: _displayMode
                      ? _buildMode2Item(theme, pHash, ts)
                      : _buildMode1Item(theme, pHash, ts),
                ),
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
