/// 大会员中心数据（GET /x/vip/web/vip_center/v2）
class VipCenterData {
  VipInfo? vipInfo;
  VipNotice? notice;
  Map? panelInfo;

  VipCenterData({this.vipInfo, this.notice, this.panelInfo});

  factory VipCenterData.fromJson(Map<String, dynamic> json) => VipCenterData(
    vipInfo: json['vip_info'] == null
        ? null
        : VipInfo.fromJson(json['vip_info'] as Map<String, dynamic>),
    notice: json['notice'] == null
        ? null
        : VipNotice.fromJson(json['notice'] as Map<String, dynamic>),
    panelInfo: json['panel_info'] as Map?,
  );
}

/// 大会员状态（vip_status: 0=已过期 1=正常 2=冻结 3=锁定）
class VipInfo {
  int? mid;

  /// 大会员类型 0=无 1=月度 2=年度
  int? vipType;

  /// 大会员状态 0=已过期 1=正常 2=冻结 3=锁定
  int? vipStatus;

  /// 到期时间（秒）
  int? vipDueDate;
  int? vipPayType;
  bool? vipIsNewUser;
  bool? vipIsAnnual;
  bool? vipIsMonth;
  bool? vipIsValid;
  bool? vipIsOverdue;
  int? vipKeepTime;
  int? vipExpireDays;
  int? vipRemainDays;

  /// 电视大会员类型
  int? tvVipType;
  int? tvVipPayType;

  /// 电视大会员状态
  int? tvStatus;
  int? tvDueDate;
  String? nicknameColor;
  int? vipRole;
  Membership? vipMembership;
  Membership? ottMembership;
  Membership? superMembership;

  VipInfo({
    this.mid,
    this.vipType,
    this.vipStatus,
    this.vipDueDate,
    this.vipPayType,
    this.vipIsNewUser,
    this.vipIsAnnual,
    this.vipIsMonth,
    this.vipIsValid,
    this.vipIsOverdue,
    this.vipKeepTime,
    this.vipExpireDays,
    this.vipRemainDays,
    this.tvVipType,
    this.tvVipPayType,
    this.tvStatus,
    this.tvDueDate,
    this.nicknameColor,
    this.vipRole,
    this.vipMembership,
    this.ottMembership,
    this.superMembership,
  });

  factory VipInfo.fromJson(Map<String, dynamic> json) => VipInfo(
    mid: json['mid'] as int?,
    vipType: json['vip_type'] as int?,
    vipStatus: json['vip_status'] as int?,
    vipDueDate: json['vip_due_date'] as int?,
    vipPayType: json['vip_pay_type'] as int?,
    vipIsNewUser: json['vip_is_new_user'] as bool?,
    vipIsAnnual: json['vip_is_annual'] as bool?,
    vipIsMonth: json['vip_is_month'] as bool?,
    vipIsValid: json['vip_is_valid'] as bool?,
    vipIsOverdue: json['vip_is_overdue'] as bool?,
    vipKeepTime: json['vip_keep_time'] as int?,
    vipExpireDays: json['vip_expire_days'] as int?,
    vipRemainDays: json['vip_remain_days'] as int?,
    tvVipType: json['tv_vip_type'] as int?,
    tvVipPayType: json['tv_vip_pay_type'] as int?,
    tvStatus: json['tv_status'] as int?,
    tvDueDate: json['tv_due_date'] as int?,
    nicknameColor: json['nickname_color'] as String?,
    vipRole: json['vip_role'] as int?,
    vipMembership: json['vip_membership'] == null
        ? null
        : Membership.fromJson(json['vip_membership'] as Map<String, dynamic>),
    ottMembership: json['ott_membership'] == null
        ? null
        : Membership.fromJson(json['ott_membership'] as Map<String, dynamic>),
    superMembership: json['super_membership'] == null
        ? null
        : Membership.fromJson(
            json['super_membership'] as Map<String, dynamic>,
          ),
  );
}

class Membership {
  bool? isVip;
  int? status;

  Membership({this.isVip, this.status});

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
    isVip: json['is_vip'] as bool?,
    status: json['status'] as int?,
  );
}

/// 顶部通知条（type: 0=无 1=静态 2=滚动 3=冻结 4=锁定 5=多设备）
class VipNotice {
  String? text;
  String? tvText;
  int? type;
  bool? canClose;
  int? surplusSeconds;
  int? tvSurplusSeconds;
  String? accountExceptionText;
  String? link;
  String? uniqueKey;

  VipNotice({
    this.text,
    this.tvText,
    this.type,
    this.canClose,
    this.surplusSeconds,
    this.tvSurplusSeconds,
    this.accountExceptionText,
    this.link,
    this.uniqueKey,
  });

  factory VipNotice.fromJson(Map<String, dynamic> json) => VipNotice(
    text: json['text'] as String?,
    tvText: json['tv_text'] as String?,
    type: json['type'] as int?,
    canClose: json['can_close'] as bool?,
    surplusSeconds: json['surplus_seconds'] as int?,
    tvSurplusSeconds: json['tv_surplus_seconds'] as int?,
    accountExceptionText: json['account_exception_text'] as String?,
    link: json['link'] as String?,
    uniqueKey: json['unique_key'] as String?,
  );
}
