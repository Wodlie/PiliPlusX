import 'package:PiliPlus/pages/setting/widgets/normal_item.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';

class AtFilterPage extends StatefulWidget {
  const AtFilterPage({super.key});

  @override
  State<AtFilterPage> createState() => _AtFilterPageState();
}

class _AtFilterPageState extends State<AtFilterPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('低质量 @ 评论过滤'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '按规则过滤低质量 @ 评论，不会屏蔽被提及用户',
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 14,
              ),
            ),
          ),
          const Divider(height: 1),
          SetSwitchItem(
            title: '启用低质量 @ 评论过滤',
            subtitle: '默认关闭；修改后对后续加载或刷新到的评论生效',
            setKey: SettingBoxKey.enableAtFilter,
            defaultVal: false,
            onChanged: (_) => setState(() {}),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '过滤规则',
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 13,
              ),
            ),
          ),
          SetSwitchItem(
            title: '过滤纯 @ 评论',
            subtitle: '去掉 @ 提及后无有效正文内容',
            setKey: SettingBoxKey.enableAtFilterPureAt,
            defaultVal: false,
          ),
          SetSwitchItem(
            title: '过滤短正文评论',
            subtitle: '去掉 @ 提及和非正文内容后，有效正文长度 ≤ 阈值',
            setKey: SettingBoxKey.enableAtFilterBodyLength,
            defaultVal: false,
          ),
          SetSwitchItem(
            title: '过滤 @ 数量过多',
            subtitle: '结构化 @ 提及数量 ≥ 阈值时过滤',
            setKey: SettingBoxKey.enableAtFilterAtCount,
            defaultVal: false,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '阈值设置',
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 13,
              ),
            ),
          ),
          NormalItem(
            title: '去掉 @ 后正文长度阈值',
            getSubtitle: () =>
                '当前: ${Pref.atFilterBodyLengthThreshold} 字；有效正文长度 ≤ 该值时过滤',
            onTap: _showBodyLengthDialog,
          ),
          const Divider(height: 1),
          NormalItem(
            title: '@ 数量阈值',
            getSubtitle: () =>
                '当前: ${Pref.atFilterAtCountThreshold} 个；@ 提及数量 ≥ 该值时过滤',
            onTap: _showAtCountThresholdDialog,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '豁免规则',
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 13,
              ),
            ),
          ),
          SetSwitchItem(
            title: '点赞豁免',
            subtitle: '点赞数超过阈值时直接放行，不再套用 @ 过滤规则',
            setKey: SettingBoxKey.enableAtFilterLikeExempt,
            defaultVal: false,
          ),
          NormalItem(
            title: '点赞豁免阈值',
            getSubtitle: () =>
                '当前: ${Pref.atFilterLikeExemptThreshold} 赞；点赞数 > 该值时放行',
            onTap: _showLikeExemptThresholdDialog,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _showBodyLengthDialog(BuildContext context, VoidCallback setState) {
    showDialog<double>(
      context: context,
      builder: (context) => SliderDialog(
        title: const Text('去掉 @ 后正文长度阈值'),
        min: 0,
        max: 100,
        divisions: 20,
        precise: 0,
        value: Pref.atFilterBodyLengthThreshold.toDouble(),
        suffix: ' 字',
      ),
    ).then((res) {
      if (res != null) {
        GStorage.setting.put(
          SettingBoxKey.atFilterBodyLengthThreshold,
          res.toInt(),
        );
        setState();
      }
    });
  }

  void _showAtCountThresholdDialog(BuildContext context, VoidCallback setState) {
    showDialog<double>(
      context: context,
      builder: (context) => SliderDialog(
        title: const Text('@ 数量阈值'),
        min: 1,
        max: 50,
        divisions: 49,
        precise: 0,
        value: Pref.atFilterAtCountThreshold.toDouble(),
        suffix: ' 个',
      ),
    ).then((res) {
      if (res != null) {
        GStorage.setting.put(
          SettingBoxKey.atFilterAtCountThreshold,
          res.toInt(),
        );
        setState();
      }
    });
  }

  void _showLikeExemptThresholdDialog(BuildContext context, VoidCallback setState) {
    showDialog<double>(
      context: context,
      builder: (context) => SliderDialog(
        title: const Text('点赞豁免阈值'),
        min: 0,
        max: 5000,
        divisions: 100,
        precise: 0,
        value: Pref.atFilterLikeExemptThreshold.toDouble(),
        suffix: ' 赞',
      ),
    ).then((res) {
      if (res != null) {
        GStorage.setting.put(
          SettingBoxKey.atFilterLikeExemptThreshold,
          res.toInt(),
        );
        setState();
      }
    });
  }
}
