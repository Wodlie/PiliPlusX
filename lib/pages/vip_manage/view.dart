import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/vip.dart';
import 'package:PiliPlus/models_new/vip/play_device.dart';
import 'package:PiliPlus/models_new/vip/vip_center.dart';
import 'package:PiliPlus/pages/vip_manage/controller.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/widget_ext.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

/// 会员状态管理（大会员状态查看 + 播放设备管理）
class VipManagePage extends StatefulWidget {
  const VipManagePage({super.key});

  @override
  State<VipManagePage> createState() => _VipManagePageState();
}

class _VipManagePageState extends State<VipManagePage> {
  final _controller = Get.put(VipManageController());

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('会员状态管理')),
      body: refreshIndicator(
        onRefresh: _controller.loadAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ViewSliverSafeArea(
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const _SectionTitle(title: '大会员状态'),
                  Obx(
                    () => _buildVipBody(
                      Theme.of(context).colorScheme,
                      _controller.vipState.value,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _SectionTitle(title: '播放设备管理'),
                  Obx(
                    () => _buildDeviceBody(
                      Theme.of(context).colorScheme,
                      _controller.deviceState.value,
                    ),
                  ),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
          ],
        ),
      ).constraintWidth(),
    );
  }

  Widget _buildVipBody(
    ColorScheme colorScheme,
    LoadingState<VipCenterData> state,
  ) {
    switch (state) {
      case Loading():
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        );
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: _controller.loadVipCenter,
          isSliver: false,
        );
      case Success(:final response):
        return _buildVipCard(colorScheme, response);
    }
  }

  Widget _buildVipCard(ColorScheme colorScheme, VipCenterData data) {
    final vip = data.vipInfo;
    final notice = data.notice;
    if (vip == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _Card(
          child: Text(
            '未获取到大会员状态',
            style: TextStyle(color: colorScheme.outline),
          ),
        ),
      );
    }
    final isVip = vip.vipStatus == 1;
    final isFrozen = vip.vipStatus == 2;
    final isBanned = vip.vipStatus == 3;
    final isSuperVip = vip.superMembership?.isVip == true;
    final statusText = switch (vip.vipStatus) {
      0 => '已过期',
      1 => '正常',
      2 => '冻结',
      3 => '锁定',
      _ => '未知',
    };
    final typeText = isSuperVip
        ? '超级大会员'
        : switch (vip.vipType) {
            1 => '月度大会员',
            2 => '年度大会员',
            _ => '非大会员',
          };

    final rows = <(String, String)>[
      ('会员类型', typeText),
      ('会员状态', statusText),
      if (vip.vipDueDate != null && vip.vipDueDate! > 0)
        ('到期时间', DateFormatUtils.format(vip.vipDueDate)),
      if (vip.vipRemainDays != null && vip.vipRemainDays! > 0)
        ('剩余天数', '${vip.vipRemainDays} 天'),
      if (vip.vipExpireDays != null && vip.vipExpireDays! >= 0)
        ('距到期', '${vip.vipExpireDays} 天'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...rows.map(
              (row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(
                        row.$1,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row.$2,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 冻结状态可提前解冻
            if (isFrozen)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _controller.unfreeze,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('解除冻结'),
                ),
              ),
            if (isBanned)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '账号风险过高，大会员功能已被锁定',
                  style: TextStyle(fontSize: 12, color: colorScheme.error),
                ),
              ),
            if (!isVip && !isFrozen && !isBanned)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '当前未开通大会员',
                  style: TextStyle(fontSize: 12, color: colorScheme.outline),
                ),
              ),
            // 通知条（type: 3=冻结 4=锁定 5=多设备）
            if (notice != null && notice.text?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _NoticeBar(
                  notice: notice,
                  onAction: () {
                    if (notice.type == 3) {
                      _controller.unfreeze();
                    } else if (notice.link?.isNotEmpty == true) {
                      final link = notice.link;
                      if (link != null && link.isNotEmpty) {
                        Get.toNamed('/webview', parameters: {'url': link});
                      }
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceBody(
    ColorScheme colorScheme,
    LoadingState<VipDeviceData> state,
  ) {
    switch (state) {
      case Loading():
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        );
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: _controller.loadDevices,
          isSliver: false,
        );
      case Success(:final response):
        final devices = response.devices ?? const <PlayDevice>[];
        if (devices.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _Card(
              child: Text(
                '暂无播放设备',
                style: TextStyle(color: colorScheme.outline),
              ),
            ),
          );
        }
        final current = devices
            .where((e) => e.isCurrentDevice == true)
            .toList()
            .firstOrNull;
        return Column(
          children: [
            for (var i = 0; i < devices.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _buildDeviceItem(colorScheme, devices[i], current),
            ],
          ],
        );
    }
  }

  Widget _buildDeviceItem(
    ColorScheme colorScheme,
    PlayDevice device,
    PlayDevice? current,
  ) {
    final isCurrent = device.isCurrentDevice == true;
    // deviceManage JS 常量：status 2=主设备 3=已被限制观看；play_status 1=未播放 2=最近看过 3=播放中
    final isMainDevice = device.status == VipHttp.deviceStatusMain;
    final isDisabled = device.status == VipHttp.deviceStatusDisable;
    final currentIsMain = current?.status == VipHttp.deviceStatusMain;
    final playStatusText = switch (device.playStatus) {
      2 => '最近看过会员内容',
      3 => '播放中',
      _ => null,
    };

    String? buttonText;
    VoidCallback? onPressed;
    if (isCurrent && !isMainDevice) {
      buttonText = '设为主设备';
      onPressed = () => _controller.setMainDevice(device);
    } else if (currentIsMain) {
      if (isDisabled) {
        buttonText = '允许播放';
        onPressed = () => _controller.unFreezeDevice(device);
      } else if (!isMainDevice) {
        buttonText = '移出可播';
        onPressed = () => _controller.playDisabled(device);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _Card(
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                device.mobiApp == 'android_tv_yst'
                    ? Icons.tv_outlined
                    : Icons.devices_outlined,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.name ?? '未知设备',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(本机)',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                      if (isMainDevice) ...[
                        const SizedBox(width: 6),
                        Text(
                          device.mobiApp == 'android_tv_yst' ? 'TV主设备' : '主设备',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (playStatusText != null ||
                      device.location?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          if (isDisabled) '已被限制观看',
                          ?playStatusText,
                          ?device.location,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (buttonText != null && onPressed != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FilledButton.tonal(
                  onPressed: onPressed,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(buttonText, style: const TextStyle(fontSize: 13)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.08),
        ),
      ),
      child: child,
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.notice, required this.onAction});

  final VipNotice notice;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final isFreeze = notice.type == 3;
    final showAction = isFreeze || notice.link?.isNotEmpty == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isFreeze
            ? colorScheme.errorContainer.withValues(alpha: 0.4)
            : colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isFreeze ? Icons.ac_unit_outlined : Icons.notifications_outlined,
            size: 16,
            color: isFreeze ? colorScheme.error : colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              notice.text ?? '',
              style: TextStyle(
                fontSize: 12,
                color: isFreeze
                    ? colorScheme.error
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (showAction)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  isFreeze ? '去解冻' : '去处理',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
