import 'package:PiliPlus/common/widgets/radio_widget.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/report/report_options_v2.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

Future<void> showNewReportDialog(
  BuildContext context, {
  required Object? targetMid,
  required int scene,
  bool allowSceneSelection = false,
}) async {
  int? reason;
  String? specificReason;
  int selectedScene = scene;
  final key = GlobalKey<FormFieldState<String>>();

  // Check account login first
  if (!Accounts.report.isLogin) {
    SmartDialog.showToast('举报账号未登录');
    return;
  }

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('举报（新版）'),
            const SizedBox(height: 6),
            Wrap(
              children: [
                Text(
                  '此举报方式是BiliBili正在灰度测试的举报方式，'
                  '使用该方式可能导致封禁。'
                  '请确认您是否有使用此方式举报的资格！',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
        titlePadding: const EdgeInsets.only(left: 22, top: 16, right: 22),
        contentPadding: const EdgeInsets.symmetric(vertical: 5),
        actionsPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 10),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Scene selector (only when allowSceneSelection)
                    if (allowSceneSelection) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 22,
                          right: 22,
                          bottom: 8,
                        ),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: '举报目标',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            isDense: true,
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: selectedScene,
                              isDense: true,
                              items: ReportOptionsV2Hardcoded.kAllScenes.entries
                                  .map(
                                    (e) => DropdownMenuItem<int>(
                                      value: e.key,
                                      child: Text(
                                        e.value,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    selectedScene = value;
                                    reason =
                                        null; // Reset reason when scene changes
                                  });
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                    // Reason list from API
                    FutureBuilder<LoadingState<List<ReportReasonV2>>>(
                      future: MemberHttp.getReportOptions(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(22),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        List<ReportReasonV2> allReasons = [];
                        if (snapshot.hasData && snapshot.data is Success) {
                          allReasons =
                              (snapshot.data as Success<List<ReportReasonV2>>)
                                  .data;
                        }
                        // Always have fallback ready
                        if (allReasons.isEmpty) {
                          allReasons =
                              ReportOptionsV2Hardcoded.kFallbackReasons;
                        }
                        // Filter by current scene
                        final filteredReasons =
                            ReportOptionsV2Hardcoded.filterByScene(
                              allReasons,
                              selectedScene,
                            );

                        if (filteredReasons.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.all(22),
                            child: Text('当前场景暂不支持新版举报方式'),
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(
                                left: 22,
                                right: 22,
                                bottom: 5,
                              ),
                              child: Text('请选择举报的理由：'),
                            ),
                            RadioGroup(
                              onChanged: (value) {
                                setState(() {
                                  reason = value;
                                });
                              },
                              groupValue: reason,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: filteredReasons.map((r) {
                                  return RadioWidget<int>(
                                    value: r.reason,
                                    title: r.reasonText,
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    // Specific reason text field
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 22,
                        top: 5,
                        right: 22,
                      ),
                      child: TextFormField(
                        key: key,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '补充说明（可选）',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(10),
                          labelStyle: TextStyle(fontSize: 14),
                          floatingLabelStyle: TextStyle(fontSize: 14),
                        ),
                        onChanged: (value) => specificReason = value,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: reason == null
                ? null
                : () async {
                    SmartDialog.showLoading();
                    try {
                      final res = await MemberHttp.reportV2(
                        mid: targetMid,
                        reason: reason!,
                        scene: selectedScene,
                        specificReason: specificReason,
                      );
                      SmartDialog.dismiss();
                      if (res.isSuccess) {
                        Get.back();
                        SmartDialog.showToast('举报成功');
                      } else {
                        res.toast();
                      }
                    } catch (e) {
                      SmartDialog.dismiss();
                      SmartDialog.showToast('提交失败：$e');
                    }
                  },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
