import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/common/widgets/radio_widget.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/common/widgets/dialog/report_v2.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

typedef ReasonCheck = bool Function(int? reasonType);

bool _kReportCheck(int? reasonType) => reasonType == 0;

typedef OnReport =
    Future<LoadingState> Function(
      int reasonType,
      String? reasonDesc,
      bool banUid,
      bool deleteComment,
    );

Future<void> autoWrapReportDialog(
  BuildContext context,
  Map<String, Map<int, String>> options,
  OnReport onReport, {
  bool ban = true,
  bool showImageBlock = false,
  List<String>? imageUrls,
  Future<void> Function(List<String> imageUrls)? onBlockImages,
  Object? targetMid,
  int? scene,
  String? reportUrl,
  ReasonCheck withContent = _kReportCheck,
  ReasonCheck contentRequired = _kReportCheck,
  Object? oid,
  Object? replyType,
}) {
  int? reasonType;
  String? reasonDesc;
  bool banUid = false;
  bool deleteComment = false;
  bool blockImages = true;
  late final key = GlobalKey<FormFieldState<String>>();

  // H5-ported dynamic state
  Map<String, Map<int, String>> effectiveOptions = options;
  Map<int, bool> dynamicContentRequired = {};
  bool canDelete = false;
  bool metadataInited = false;
  Future<LoadingState<Map<String, dynamic>>>? metadataFuture;
  if (oid != null && replyType != null) {
    metadataFuture = ReplyHttp.getReportMetadata(oid: oid, type: replyType);
  }

  bool isWithContent(int? rt) {
    if (dynamicContentRequired.containsKey(rt)) {
      return true;
    }
    return withContent(rt);
  }

  bool isContentRequired(int? rt) {
    if (dynamicContentRequired.containsKey(rt)) {
      return dynamicContentRequired[rt]!;
    }
    return contentRequired(rt);
  }

  Widget title = const Text('举报');
  if (reportUrl != null) {
    title = Row(
      mainAxisAlignment: .spaceBetween,
      children: [
        title,
        iconButton(
          iconSize: 21,
          tooltip: '网页举报',
          onPressed: () => Get.toNamed('/webview', parameters: {'url': reportUrl}),
          icon: const Icon(MdiIcons.web, size: 22),
        ),
      ],
    );
  }

  return showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        bool isWithContentNow = isWithContent(reasonType);
        bool isContentRequiredNow = isContentRequired(reasonType);

        void updateReasonType(int? value) {
          reasonType = value;
          if (isWithContent(value)) {
            key.currentState?.clearError();
          }
          setState(() {});
        }

        Widget buildReasonList() {
          if (metadataFuture == null) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: .only(left: 22, right: 22, bottom: 5),
                  child: Text('请选择举报的理由：'),
                ),
                RadioGroup(
                  onChanged: updateReasonType,
                  groupValue: reasonType,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: effectiveOptions.entries.map((entry) {
                      return WrapRadioOptionsGroup<int>(
                        groupTitle: entry.key,
                        options: entry.value,
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          }
          return FutureBuilder<LoadingState<Map<String, dynamic>>>(
            future: metadataFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting && !metadataInited) {
                return const Padding(
                  padding: EdgeInsets.all(22),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snapshot.hasData && snapshot.data is Success) {
                final data = (snapshot.data as Success<Map<String, dynamic>>).data;
                if (!metadataInited) {
                  // parse only once
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    bool newCanDelete = data['can_delete'] == true;
                    Map<String, Map<int, String>> newOptions = Map.from(options);
                    Map<int, bool> newRequired = {};
                    final reasonList = data['reason_list'] as List?;
                    final reportGroups = data['report_groups'] as List?;
                    if (reasonList != null && reasonList.isNotEmpty) {
                      // H5 new structure: reason_list -> tag_id/tag_name/content_required
                      final map = <int, String>{};
                      for (final e in reasonList) {
                        if (e is Map) {
                          final id = e['tag_id'] ?? e['reason'] ?? e['id'];
                          final name = e['tag_name'] ?? e['reason_text'] ?? e['name'];
                          final req = e['content_required'] == true || e['is_required'] == true;
                          if (id is int && name is String) {
                            map[id] = name;
                            newRequired[id] = req;
                          } else if (id is num && name is String) {
                            map[id.toInt()] = name;
                            newRequired[id.toInt()] = req;
                          }
                        }
                      }
                      if (map.isNotEmpty) {
                        newOptions = {'': map};
                      }
                    } else if (reportGroups != null && reportGroups.isNotEmpty) {
                      final parsed = <String, Map<int, String>>{};
                      for (final g in reportGroups) {
                        if (g is Map) {
                          final gName = g['name'] as String? ?? '';
                          final opts = g['report_options'] as List?;
                          if (opts != null) {
                            final m = <int, String>{};
                            for (final o in opts) {
                              if (o is Map) {
                                final v = o['value'] ?? o['reason'];
                                final l = o['label'] ?? o['reason_text'];
                                if (v is int && l is String) m[v] = l;
                                if (v is num && l is String) {
                                  m[v.toInt()] = l;
                                }
                              }
                            }
                            if (m.isNotEmpty) parsed[gName] = m;
                          }
                        }
                      }
                      if (parsed.isNotEmpty) newOptions = parsed;
                    }
                    if (newOptions != effectiveOptions ||
                        newRequired.isNotEmpty ||
                        newCanDelete != canDelete) {
                      setState(() {
                        effectiveOptions = newOptions;
                        dynamicContentRequired = newRequired;
                        canDelete = newCanDelete;
                        metadataInited = true;
                      });
                    } else {
                      metadataInited = true;
                    }
                  });
                }
              } else if (snapshot.hasError || (snapshot.hasData && snapshot.data is Error)) {
                metadataInited = true;
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: .only(left: 22, right: 22, bottom: 5),
                    child: Text('请选择举报的理由：'),
                  ),
                  RadioGroup(
                    onChanged: updateReasonType,
                    groupValue: reasonType,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: effectiveOptions.entries.map((entry) {
                        return WrapRadioOptionsGroup<int>(
                          groupTitle: entry.key,
                          options: entry.value,
                        );
                      }).toList(),
                    ),
                  ),
                ],
              );
            },
          );
        }

        return AlertDialog(
          title: title,
          titlePadding: const .only(left: 22, top: 16, right: 22),
          contentPadding: const .symmetric(vertical: 5),
          actionsPadding: const .only(left: 16, right: 16, bottom: 10),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildReasonList(),
                        if (isWithContentNow)
                          Padding(
                            padding: const .only(left: 22, top: 5, right: 22),
                            child: TextFormField(
                              key: key,
                              minLines: 2,
                              maxLines: 4,
                              initialValue: reasonDesc,
                              autofocus: isContentRequiredNow,
                              decoration: const InputDecoration(
                                labelText: '为帮助审核人员更快处理，请补充问题类型和出现位置等详细信息',
                                border: OutlineInputBorder(),
                                contentPadding: .all(10),
                                labelStyle: TextStyle(fontSize: 14),
                                floatingLabelStyle: TextStyle(fontSize: 14),
                              ),
                              onChanged: (value) => reasonDesc = value,
                              validator: (value) =>
                                  isContentRequiredNow && value.isNullOrEmpty ? '理由不能为空' : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (ban)
                Padding(
                  padding: const EdgeInsets.only(left: 14, top: 6),
                  child: CheckBoxText(
                    text: '拉黑该用户',
                    onChanged: (value) => banUid = value,
                  ),
                ),
              if (canDelete)
                Padding(
                  padding: const EdgeInsets.only(left: 14, top: 4),
                  child: CheckBoxText(
                    text: '同时删除该评论',
                    selected: false,
                    onChanged: (value) => deleteComment = value,
                  ),
                ),
              if (showImageBlock)
                Padding(
                  padding: const EdgeInsets.only(left: 14, top: 4),
                  child: CheckBoxText(
                    text: '同时屏蔽图片',
                    selected: true,
                    onChanged: (value) => blockImages = value,
                  ),
                ),
            ],
          ),
          actions: [
            if (targetMid != null && scene != null)
              TextButton(
                onPressed: () {
                  final ctx = context;
                  Get.back();
                  if (!Accounts.report.isLogin) {
                    SmartDialog.showToast('举报账号未登录');
                    return;
                  }
                  showNewReportDialog(
                    ctx,
                    targetMid: targetMid,
                    scene: scene,
                  );
                },
                child: const Text('使用新版举报方式'),
              ),
            TextButton(
              onPressed: Get.back,
              child: Text(
                '取消',
                style: TextStyle(color: ColorScheme.of(context).outline),
              ),
            ),
            TextButton(
              onPressed: () async {
                final curWithContent = isWithContent(reasonType);
                final curRequired = isContentRequired(reasonType);
                if (reasonType == null || (curRequired && key.currentState?.validate() != true)) {
                  return;
                }
                SmartDialog.showLoading();
                try {
                  final res = await onReport(
                    reasonType!,
                    curWithContent ? reasonDesc : null,
                    banUid,
                    deleteComment,
                  );
                  SmartDialog.dismiss();
                  if (res.isSuccess) {
                    Get.back();
                    SmartDialog.showToast('举报成功');
                  } else {
                    res.toast();
                  }
                  if (showImageBlock && blockImages && onBlockImages != null && imageUrls != null) {
                    await onBlockImages(imageUrls);
                  }
                } catch (e, s) {
                  SmartDialog.dismiss();
                  SmartDialog.showToast('提交失败：$e');
                  Utils.reportError(e, s);
                }
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    ),
  );
}

class CheckBoxText extends StatefulWidget {
  final String text;
  final ValueChanged<bool> onChanged;
  final bool selected;

  const CheckBoxText({
    super.key,
    required this.text,
    required this.onChanged,
    this.selected = false,
  });

  @override
  State<CheckBoxText> createState() => _CheckBoxTextState();
}

class _CheckBoxTextState extends State<CheckBoxText> {
  late bool _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return InkWell(
      onTap: () {
        setState(() {
          _selected = !_selected;
          widget.onChanged(_selected);
        });
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              size: 22,
              _selected ? Icons.check_box_outlined : Icons.check_box_outline_blank,
              color: _selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            Text(
              ' ${widget.text}',
              style: TextStyle(color: _selected ? colorScheme.primary : null),
            ),
          ],
        ),
      ),
    );
  }
}

abstract final class ReportOptions {
  // from https://s1.hdslb.com/bfs/seed/jinkela/comment-h5/static/js/605.chunks.js
  static Map<String, Map<int, String>> get commentReport => const {
    '违反法律法规': {9: '违法违规', 2: '色情', 10: '低俗', 12: '赌博诈骗', 23: '违法信息外链'},
    '谣言类不实信息': {19: '涉政谣言', 22: '虚假不实信息*', 20: '涉社会事件谣言'},
    '侵犯个人权益': {7: '人身攻击', 15: '侵犯隐私'},
    '有害社区环境': {
      1: '垃圾广告',
      4: '引战',
      5: '剧透',
      3: '刷屏',
      8: '视频不相关',
      18: '违规抽奖',
      17: '青少年不良信息',
    },
    '其他': {0: '其他*'},
  };
  static ReasonCheck withContentReply = (reasonType) => reasonType != null;
  static ReasonCheck contentRequiredReply = (reasonType) => reasonType == 0 || reasonType == 22;

  static Map<String, Map<int, String>> get dynamicReport => const {
    '': {
      4: '垃圾广告',
      8: '引战',
      1: '色情',
      5: '人身攻击',
      3: '违法信息',
      9: '涉政谣言',
      10: '涉社会事件谣言',
      12: '虚假不实信息',
      13: '违法信息外链',
      0: '其他*',
    },
  };

  static Map<String, Map<int, String>> get danmakuReport => const {
    '': {
      1: '违法违禁',
      2: '色情低俗',
      3: '赌博诈骗',
      4: '人身攻击',
      5: '侵犯隐私',
      6: '垃圾广告',
      7: '引战',
      8: '剧透',
      9: '恶意刷屏',
      10: '视频无关',
      12: '青少年不良信息',
      13: '违法信息外链',
      11: '其它*',
    },
  };
  static ReasonCheck danmakuReportCheck = (reasonType) => reasonType == 11;

  static Map<String, Map<int, String>> get liveDanmakuReport => const {
    '': {
      1: '违法违规',
      2: '低俗色情',
      3: '垃圾广告',
      4: '辱骂引战',
      5: '政治敏感',
      6: '青少年不良信息',
      0: '其他',
    },
  };
  static ReasonCheck liveDanmakuReportCheck = (_) => false;

  static Map<String, Map<int, String>> get imMsgReport => const {
    '': {
      1: '色情低俗',
      2: '政治敏感',
      3: '违法有害',
      4: '广告骚扰',
      5: '人身攻击',
      6: '诈骗',
      0: '其他问题*',
    },
  };
}
