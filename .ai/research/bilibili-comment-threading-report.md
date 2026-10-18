# Bilibili 评论楼中楼（nested replies）：rcount / DetailList / dialog 事实核查报告

> 纯网络与源码调研，未调用 B 站接口。所有结论附来源；无法证实的内容集中在最后的
> **Uncertain / not found**，正文中推测性内容均已显式标注为 *(speculative)*。

## Q1. 顶层评论上报的 N（`rcount` / gRPC `ReplyInfo.count`）到底统计什么？

**直接答案：** `rcount` 是评论条目对象上的「回复评论条数」，与 `count`（二级评论条数）并列；
`reply_control.sub_reply_entry_text` 就是 UI 上那句「共 xx 条回复」。它是**服务端算好的总计**，
而不是某个列表数组的长度；`replies` 只是「评论回复条目预览」，官方文档明确写着**仅嵌套一层、最多 3 项**
（`2` 为最后一项）。因此 N ≠ 你在某一页看到的条数。

- 字段定义（评论条目对象表）：「`count` | num | 二级评论条数」「`rcount` | num | 回复评论条数」，
  以及 `replies` 备注「**仅嵌套一层** 否则为 null」、数组项备注「最后一项」为第 3 项：
  [bilibili-API-collect 评论区](https://goooler.github.io/bilibili-API-collect/docs/comment/)
- 「共 xx 条回复」的来源：`reply_control` 中 `sub_reply_entry_text` 备注 `共 xx 条回复`，
  `sub_reply_title_text` 为 `相关回复共有 xx 条`：同上表。

**是否含被删除/隐藏/待审核 / 折叠 / 回复的回复：**

| 子问题 | 结论 | 依据 |
|---|---|---|
| 回复的回复（`parent != root`） | **计入**。`/x/v2/reply/reply` 的 `page.count` 被文档定义为「二级评论数」，而同一页的 `replies`（上限 20）里**混合**了 `parent == root` 与 `parent != root` 的条目 | [评论区明细（含 `reply/reply` 一节）](https://janson20.github.io/bilibili-api-collect-mirror/docs/comment/list.html) |
| 被阿瓦隆隐藏（`state = 17`） | 服务端仍**保留计数**：条目本身会被返回，只是「无法被别人看到，只能自己看到」 | 同上表 `state` 说明 |
| 评论折叠 | 折叠是**评论区级/楼层级**的展示状态（`folder.has_folded` / `is_folded`），被折叠内容「集中展示在该内容评论区的**最末页**」，并未声明会从计数中扣除 | [评论折叠规则（官方公告）](https://www.bilibili.com/blackboard/foldingreply.html)；`folder` 定义见 BAC 评论条目表 |
| 已删除 / 待审核 | **未能证实**（见 Uncertain） | — |

**实测偏差的直接证据：** 有用户报告「评论显示"共1条回复"，实际点击进入不显示」「（显示"共7条回复"，实际进入只显示4条）」，
说明 N 与实际列表长度确实可以不一致（该 issue 至今 open）：
[Richasy/Bili.Copilot issue #1054](https://github.com/Richasy/Bili.Copilot/issues/1054)。用户侧对「共X条回复 与实际不符」
的抱怨在贴吧亦有：[B站评论折叠原因及如何完整展示](https://tieba.baidu.com/p/9518656964)。
一个相关（但方法不同）的旁证是评论分析工具用「楼层号缺口」反推被举报/删除的评论，并注明
「无法得知评论消失的原因（相关API已被B站取消）」：[Chaosinism/BilibiliCommentAnalyzer](https://github.com/Chaosinism/BilibiliCommentAnalyzer)。

## Q2. 楼中楼接口返回的是「全部拍平」还是「仅直接回复 root」？会不会少于 N？

**直接答案：返回整条楼中楼对话树的拍平列表（含 `parent != root` 的回复），按回复顺序、每页最多 20 条。**
所以「少于 N」在这个接口上是**正常且必然的**——因为它是分页的，而 `page.count` / gRPC `root.count`
是**整条楼中楼的总数**，不是本页条数。

- 官方文档：`data.replies` = 「评论对话树列表 | **最大内容数为20**」；`data.page.count` = 「二级评论数」；
  `ps` 备注「默认为20 定义域：1-49 **但 data_replies 的最大内容数为20**」：
  [评论区明细](https://janson20.github.io/bilibili-api-collect-mirror/docs/comment/list.html)
- 「含回复的回复」由同一篇的响应示例坐实：示例里 `rpid=3030790837 = root`，而返回项中
  `rpid=3030810089` 的 `parent=3030802207`、`dialog=3030802207`，即**祖父母不是 root 的子回复也在这一个数组里**：同上。
- gRPC 侧结构完全对应：`DetailListReply.root` = 「根评论信息(**带二级评论**)」，
  而 `DetailListReq` 是「二级评论明细接口」： [protodoc: bilibili.main.community.reply.v1](https://protodoc.io/SocialSisterYi/bilibili-API-collect/bilibili.main.community.reply.v1)
- **文档化「数组短于 count」的实例**：同页示例 `page.count = 230`、`page.size = 5`，返回数组只有 5 项。这是分页语义；
  另外还有一个后端行为上的坑：`/x/v2/reply/detail` 的抓取封装需要循环请求直到 `cursor.is_end` 为真才拿全楼中楼
  （`next` 为下次起始楼号，到末尾则为 0），也说明单次响应并不等于全量：
  [eggry/BiliReplyDetailCrawler](https://github.com/eggry/BiliReplyDetailCrawler)（README：`.data.cursor.is_end` 是否到达楼中楼末尾）。

## Q3. `DetailList` 的 `rpid` 字段；`DialogList` 的 `dialog` 语义

**`DetailList.rpid`** 定义为「目标评论rpid」（`int64 rpid = 4`）：
[protodoc](https://protodoc.io/SocialSisterYi/bilibili-API-collect/bilibili.main.community.reply.v1)。
PiliPlus 的调用方式是关键旁证——**平时传 0，只有「要跳到某条子回复」时才传该子回复 rpid**：

```dart
: ReplyGrpc.detailList(
    type: replyType, oid: oid, root: rpid,
    rpid: id ?? 0,                 // id = 目标子回复，跳转后立刻置空
    mode: mode, offset: paginationReply?.nextOffset);

// onInit/refresh 后：
if (id != null) { setIndexById(Int64(id!), data.root.replies); id = null; }
```
来源：工作区源码 `lib/pages/video/reply_reply/controller.dart`（L124-139、L82-85），属本仓库自有证据而非外部文档。
**结论：** `rpid=0` ⇒ 整个 root 的楼中楼首屏；`rpid=<sub rpid>` ⇒ 服务端以该子回复为锚点定位/聚焦（对话线程视图）。
具体响应差异（是否过滤 `root.replies` 只留该对话链）**无官方文档证实**（见 Uncertain）。

**`DialogList.dialog`** 在 proto 里名为 `rpid`，注释「对话评论rpid」；REST 侧 `dialog` 字段定义最清楚：
「回复对方 rpid —— 若为一级评论则为 0；**若为二级评论则为该评论 rpid**；大于二级评论为上一级评论 rpid」
（[BAC 评论条目表](https://goooler.github.io/bilibili-API-collect/docs/comment/)）。
即 `dialog` 是「这条回复所属对话的发起者 rpid」，**子回复点自己、深链指向被回复者**。PiliPlus 用它作 DialogList 的入参，
并且**只有 `id != dialog` 才显示「查看对话」按钮**（`id == dialog` 说明该子回复是对话根、其下没有分支）：
`lib/pages/video/reply_reply/view.dart` L382、`lib/pages/video/reply/reply_item_grpc.dart` L679-689。
第三方脚本同样围绕这个「回复的回复」断层做补全（悬停时展示主评论 → 被回复子回复 → 当前回复的最小链路）：
[B站楼中楼上下文](https://greasyfork.org/zh-CN/scripts/572814)、[ScriptCat 镜像](https://scriptcat.org/zh-CN/script-show-page/7095)。

## Q4. 主列表内联预览里的子回复，是否会不出现在楼中楼详情里？分页坑

**直接答案（分两部分）：**

1. **数据同源**：内联预览 `replies`（≤3 条，按热度排序）是「回复条目预览，仅嵌套一层」，
   与楼中楼详情同属一条对话树；因此预览里的条目在详情列表里**应当也存在**（可能落在后续分页，而非第一页）。
2. **没有找到「某条预览回复永远只在自己页面/对话视图里才可见」的文档化证据。** 客户端真正可复现的
   「可见却拉不到」有两类：
   - **分页游标坑（后端）**：楼中楼单次响应上限 20 条（BAC 明写 `ps` 设 49 也只返回 20 条）；
     `/x/v2/reply/detail` 必须沿 `cursor.next` 循环到 `cursor.is_end` 才是全量（
     [BAC](https://janson20.github.io/bilibili-api-collect-mirror/docs/comment/list.html)、
     [BiliReplyDetailCrawler](https://github.com/eggry/BiliReplyDetailCrawler)）。
   - **客户端本地过滤把分页判死（本项目已修）**：当筛选把某一页全部移除后，
     `CommonListController` 收到空数组即 `isEnd = true` 并显示"无评论"，用户再也无法加载后续页——
     PiliPlusX 为此加了「空页自动续拉、`autoLoadDepth` 上限 5」的修复：
     [Wodlie/PiliPlusX PR #5](https://github.com/Wodlie/PiliPlusX/pull/5)
     （正文引用上游 issue：「设置评论筛选条件后…程序认为无评论，用户无法加载下一页」）。
   - 排序/游标口径差异（内联预览按热度、楼中楼默认按回复顺序 `pn`，或 `pagination_str` 的
     `type/direction/cursor` 与旧 `next`/`pn` 不一致）会导致**第一页看不到预览里的条目**：
     `pagination_str.offset` 备注「不推荐, 已弃用, 优先级比 `pagination_str` 高」见
     [BAC 懒加载一节](https://janson20.github.io/bilibili-api-collect-mirror/docs/comment/list.html)；
     第三方脚本显式提供「更多 / 分页（B站原生分页）」两种加载方式、并对
     「**父回复不在当前分页**」显示标注「不在本页」，说明分页导致链路断裂是常见现象：
     [Mixlining/BilibiliCommentTree](https://github.com/Mixlining/BilibiliCommentTree)。

## Uncertain / not found

- **`rcount` 是否包含已删除评论**：无权威来源确认。可确认的只有「阿瓦隆隐藏（state 17）条目仍会被返回」。
- **待审核（待审核评论）是否计入**：未找到任何来源。
- **折叠评论是否从 N 中扣除**：官方公告只说被折叠内容「集中展示在最末页」，未说明计数口径；未能证实。
- **`DetailList` 传具体 `rpid` 时响应数组语义的变化**：无文档；PiliPlus 的用法只能证明它是「定位/聚焦目标子回复」的锚点，
  是否改走过滤逻辑属推测 *(speculative)*。
- **`DialogList` 是否返回完整子树还是仅回复链**：proto 仅写「子评论列表」，未找到行为说明。
- **「预览可见、详情永远不可见」的确证案例**：未找到；仅有分页/过滤/排序造成的「当前页看不到」。
- **PiliPlus 上游 issue 检索**：`api.github.com/search` 对本会话可用的仓库名返回 422（无法检索上游仓库名），
  因此**未能**给出上游 PiliPlus issue 的关于回复数/缺回复的条目；仅在 fork `Wodlie/PiliPlusX` 找到 PR #2/#5。
- **BiliRoamingX** 评论区补丁：未检索到针对回复计数/折叠的 patch 说明（未证实存在）。
- 抓取受限：`raw.githubusercontent.com`、`github.com/<repo>` 正文页在本会话多次 `fetch failed`，
  相关证据改用 GitHub REST API 与文档镜像取得。
