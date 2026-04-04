enum AccountType {
  main('主账号', '登录、发表动态、投币、收藏、关注等操作'),
  heartbeat('记录观看', '获取视频/直播信息、上报观看历史与进度等'),
  recommend('推荐', '获取推荐列表、搜索结果、热门榜单等'),
  video('视频取流', '获取视频/直播流地址'),
  reply('评论操作', '发布、删除、点赞、点踩、举报评论，以及置顶、开关评论区等操作')
  ;

  final String title;
  final String desc;
  const AccountType(this.title, this.desc);
}
