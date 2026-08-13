class ReasonSceneV2 {
  final int scene;
  final String sceneText;

  const ReasonSceneV2({required this.scene, required this.sceneText});

  factory ReasonSceneV2.fromJson(Map<String, dynamic> json) => ReasonSceneV2(
    scene: json['scene'] as int,
    sceneText: json['scene_text'] as String,
  );

  Map<String, dynamic> toJson() => {
    'scene': scene,
    'scene_text': sceneText,
  };
}

class ReportReasonV2 {
  final int reason;
  final String reasonText;
  final List<ReasonSceneV2> sceneList;

  const ReportReasonV2({
    required this.reason,
    required this.reasonText,
    required this.sceneList,
  });

  factory ReportReasonV2.fromJson(Map<String, dynamic> json) => ReportReasonV2(
    reason: json['reason'] as int,
    reasonText: json['reason_text'] as String,
    sceneList: (json['scene_list'] as List<dynamic>)
        .map((e) => ReasonSceneV2.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'reason': reason,
    'reason_text': reasonText,
    'scene_list': sceneList.map((e) => e.toJson()).toList(),
  };
}

abstract final class ReportOptionsV2Hardcoded {
  static const List<ReportReasonV2> kFallbackReasons = [
    ReportReasonV2(
      reason: 5,
      reasonText: '传播色情/赌博/垃圾广告资源、诱导交易',
      sceneList: [
        ReasonSceneV2(scene: 1, sceneText: '用户资料（头像、签名、昵称）'),
        ReasonSceneV2(scene: 2, sceneText: '稿件'),
        ReasonSceneV2(scene: 3, sceneText: '评论'),
        ReasonSceneV2(scene: 4, sceneText: '动态'),
        ReasonSceneV2(scene: 5, sceneText: '私信'),
        ReasonSceneV2(scene: 6, sceneText: '专栏'),
        ReasonSceneV2(scene: 7, sceneText: '其他（收藏夹、播单等）'),
      ],
    ),
    ReportReasonV2(
      reason: 1,
      reasonText: '色情低俗',
      sceneList: [
        ReasonSceneV2(scene: 1, sceneText: '用户资料（头像、签名、昵称）'),
        ReasonSceneV2(scene: 2, sceneText: '稿件'),
        ReasonSceneV2(scene: 3, sceneText: '评论'),
        ReasonSceneV2(scene: 4, sceneText: '动态'),
        ReasonSceneV2(scene: 5, sceneText: '私信'),
        ReasonSceneV2(scene: 6, sceneText: '专栏'),
        ReasonSceneV2(scene: 7, sceneText: '其他（收藏夹、播单等）'),
      ],
    ),
    ReportReasonV2(
      reason: 4,
      reasonText: '引战、人身攻击',
      sceneList: [
        ReasonSceneV2(scene: 1, sceneText: '用户资料（头像、签名、昵称）'),
        ReasonSceneV2(scene: 2, sceneText: '稿件'),
        ReasonSceneV2(scene: 3, sceneText: '评论'),
        ReasonSceneV2(scene: 4, sceneText: '动态'),
        ReasonSceneV2(scene: 5, sceneText: '私信'),
        ReasonSceneV2(scene: 6, sceneText: '专栏'),
        ReasonSceneV2(scene: 7, sceneText: '其他（收藏夹、播单等）'),
      ],
    ),
    ReportReasonV2(
      reason: 3,
      reasonText: '违法违禁行为',
      sceneList: [
        ReasonSceneV2(scene: 1, sceneText: '用户资料（头像、签名、昵称）'),
      ],
    ),
    ReportReasonV2(
      reason: 2,
      reasonText: '虚假不实信息',
      sceneList: [
        ReasonSceneV2(scene: 1, sceneText: '用户资料（头像、签名、昵称）'),
      ],
    ),
  ];

  /// All 7 scene options with text matching API scene_text.
  static const Map<int, String> kAllScenes = {
    1: '用户资料（头像、签名、昵称）',
    2: '稿件',
    3: '评论',
    4: '动态',
    5: '私信',
    6: '专栏',
    7: '其他（收藏夹、播单等）',
  };

  /// Filter reasons to only those available for [scene].
  static List<ReportReasonV2> filterByScene(
    List<ReportReasonV2> reasons,
    int scene,
  ) {
    return reasons
        .where((r) => r.sceneList.any((s) => s.scene == scene))
        .toList();
  }
}
