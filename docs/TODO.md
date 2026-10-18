# TODO List

### 构建 & 发布

- [X] 安卓签名密钥(github_secret)
- [X] mac打包dmg免签
- [X] 改release机制
- [X] 软件内更新换源
- [X] 打包版号修正（文件名）
- [x] Linux x64 CI 构建与产物上传（tar.gz / deb / rpm / AppImage）
- [x] 按平台应用 Flutter SDK 补丁脚本
- [ ] 版本名改用tag名
- [ ] '对应上游版本'采用上游最新 Release 对应 Tag
- [ ] 全版本新的检查更新机制，自动比对 latest 时间，手动获取比对第一更新(旧)
- [ ] 设置项 自动检查新的 PreRelease、跳过该版本等等
- [x] Linux 版本支持
- [ ] 应用内更新，参考 Kazumi

### 文档 & 工程维护

- [x] README 补充当前 Flutter / Dart / CI / 测试状态
- [x] README 同步 Linux 发布产物与 gRPC 当前状态
- [x] 分层 AGENTS.md 项目知识库
- [ ] README 徽章与版本号自动化
- [ ] 检查并更新公开代理服务器可用性说明
- [ ] 梳理 ohos / oddo 分支说明与实际维护状态

### 设置项

- [X] 选择鸿蒙黑体/系统字体
- [X] 安卓下载图片和截图路径可选择应用名路径或官版路径
- [X] 设置页添加快捷键指引页
- [X] 切换账号改一键
- [X] 下拉刷新触发距离设置范围扩展
- [X] 双击快快退设置分离
- [x] 阈值 默认打开，无按钮
- [x] 双击快进快退默认关闭
- [x] 默认自动开始播放
- [x] 全局状态栏隐藏，移除安全边距 -Issue12
- [ ] 首页“充电视频”筛除
- [ ] 自定义分享用户界面展示数量
- [ ] 平板/折叠屏 也能旋转进入 全屏
- [ ] 手动点击全屏后自动回退临时全屏
- [ ] 自定义播放窗口顶部按键，可以勾选显示 隐藏
- [ ] 中尺寸布局偏好 (小平板/折叠屏) 布局三选一

### 快捷键

- [X]  回车绑定消息发送
- [X]  刷新快捷键，在动态页就刷新动态页，在首页就刷新首页
- [x] Alt+H / Opt+H 返回主页 (根路由) 
- [x] Ctrl/cmd+',' 打开设置
- [x] 一键粘贴 跳转搜索
- [x] 不将粘贴搜索计入搜索历史
- [ ] 图片全屏时，左右方向键切换上下一张，空格返回
- [ ] cmd/ctrl/shift+enter 发送
- [ ] esc 不退出

### 修复

- [X] 字体（Flutter 3.38 导致）
- [X] 弹幕、字幕、进度条 字体修复
- [X] 手动获取更新
- [X] win端点关闭以后到后台托盘，从桌面打不开，需要从托盘里面才能打开
- [x] mac端不显示字体开关 -Issue1
- [x] 收藏夹/稍后再看中换源视频重新定向
- [x] 选择HDR后弹窗提醒不支持
- [ ] 视频下 推荐区和评论区下滑行为错误联动 -c001
- [ ] 动态评论区正确跳转和动态详情页的评论按钮 -c001
- [ ] 安卓播控中心退出播放页后有概率仍在
- [ ] 换源视频重新定向加一个ping验证
- [ ] 账号选择器分行
- [ ] 1pad error
- [ ] 横平板小横条适配问题 -Air
- [ ] 鸿蒙版全屏返回 加个二次确认
- [ ] 鸿蒙版 "无视旋转锁定"时 不能旋转 (默认全屏方向)
- [ ] Linux 复应用打开
- [ ] Windows 注册表与上游重名

### 稍后再看相关

- [X] 长按展示视频卡片替换为加入稍后再看
- [x] 二次点击'我的'打开的打开账号选择器，可以设置为打开稍后再看页面
- [ ] 稍后再看里新增求差产生的“已看完”板块
- [ ] 稍后再看 ctrl+R 刷新并且通知成功
- [x] 稍后再看搜索结果支持多选加入某个收藏夹

### 听视频相关

- [ ] 支持点击评论区时间戳跳转
- [ ] 分段信息 (设置项 展示在时间轴上)
- [ ] 空降助手

### 动画相关

- [x] 设置页面过渡动画弹窗 中文化
- [ ] 增加对预测性返回的支持（参考Musify）
- [ ] 对 封面卡片-播放详情页增添 Hero 动画（参考收藏）

### 功能请求

- [X] 首页、动态页 刷新提示
- [X] 长按分享就可分享给提前确定的某个用户（设置项）
- [X] 视频外'显示菜单'里加入保存封面
- [x] 安卓版添加权限“忽略电池优化” (如需开启要在系统设置中授权)
- [x] 转发到消息候选用户数量上限从3升至5
- [x] 长按画面比例选项可以在自动与裁剪中切换
- [x] 长按倍速功能在1倍和2倍中切换
- [x] 首页、动态页右下角实体快捷刷新键对标官方客户端（设置项）-hcz -lyy
- [ ] 桌面端多实例（多窗口） -ywt
- [ ] 增加消息通知功能，基于“消息”-点击跳转对应界面，并提高消息刷新频率
- [ ] 直播间竖屏界面下面的弹幕调用弹幕复制组件 -hcz
- [ ] 请求超时后台自动重新选择最快的 CDN -c001
- [ ] 明显处开关打开CDN 弹窗（设置项）-c001
- [ ] 缓存的视频可手动分类 -c001
- [ ] 更换app icon和主题色，优化素材引用导致的内存占用
- [ ] 自定义字体导入.ttf/.otf
- [ ] 这个旋转其他视频平台的逻辑大概是点了之后会有一秒左右的不检测方向（设置项：支持在非临时全屏状态下旋转退出全屏）全屏1s后进入临时全屏状态 -c001 -lxb
- [ ] ip 旁显示性别 -Air
- [ ] 鼠标操作双击控制播放暂停（设置项）-Issue16
- [ ] HDR 和杜比视界播放

### 暂时搁置或暂时无法实现的功能请求

- [ ] 播放页双指双击可以切换弹幕开关
- [ ] 当播放视频时候界面处于长按倍速状态，上下滑动即可动态倍速（设置项）-ywt
- [ ] 鼠标右键事件 -[Issue3](https://github.com/Wodlie/PiliPlusX/issues/3)
- [ ] 看一下api仓库，搜索 图文 接口 -ywt
- [ ] 应用内小窗口，实现参考 [pilipro](https://github.com/naaammme/pilipro) （设置项）-[Issue9](https://github.com/Wodlie/PiliPlusX/issues/9)
- [ ] 弹窗快捷键：y绑定确定，n取消
- [ ] 高画质无限试用 -Air

**欢迎在 [Issues](https://github.com/Wodlie/PiliPlusX/issues) 提交建议和问题反馈**

## 代码审查遗留（2026-10-13 修复后待验证）

以下条目已按 `.ai/code-review-2026-10-13/report.md` 修复，并通过本机静态分析（0 error）+ 相关单测；但需要真机或真实接口才能收口：

- [ ] F03 WebView 桥：原生 fork（`flutter_inappwebview_android` 的 `_callHandler`）仍不传 frame origin。Dart 侧已收口（主 frame 限定 + host 校验 + 导航代次 + 拒绝 net.*），上游 fork 需补 origin 能力。
- [ ] F04 cookie：真机确认平台 CookieManager 里 SESSDATA/bili_jct/DedeUserID 的 `is_httponly` 变为 1；Hive 层 expires(DateTime) 往返抽查一次。
- [ ] F05 换集：慢网连续换集只产生一次有效 playerInit，画面/弹幕/心跳归属新 cid。
- [ ] F08 WBI：断网→恢复后重新取 key；跨日失败不复用旧 key；key 不可用时请求不带 `w_rid`。
- [ ] F09 发布：uploadBfs 返回 Error 时 loading 关闭 + toast 显示服务端文案 + 草稿/已选图保留；清缓存后网图裁剪提示失败。
- [ ] F11 重置所有数据：平台 WebView cookie store 确认已登出。
- [ ] F15 定时关闭：视频/直播设定后进出音频页，倒计时仍在且到点生效。
- [ ] F17 直播：飞行模式断网→恢复，弹幕按 3s→30s 退避恢复；退房/暂停期间不重连；token 晚到不建连接。
- [ ] F18 直播：点击含 "01:23" 的弹幕不再崩且无跳转项。
- [ ] F25 漫画投稿：`/x/v2/space/comic` 是否确为 `pn/ps` 分页（否则改 `next` 游标）。
- [ ] F30 举报缓存：重开 Hive 后缓存命中（`Map<dynamic,dynamic>` 转型）需实测。
- [ ] F35 弹幕：智能云屏蔽权重 >0 时，同 100ms 槽后续高权重弹幕能显示。
- [ ] F36 duck：平台事件序下音量成对恢复。
- [ ] F38 HK 回退：完整 URL 的端点打 -404/-10403 时确实回退且只回退一次。
- [ ] F39 双屏：右副屏/负坐标副屏保存位置后能恢复；屏外值被拒。
- [ ] F40 DLNA：真实设备上刷新后重选同一设备能重新投屏。
- [ ] F42 时间选择：10:56 选 11:00 被拒、11:02 通过。
- [ ] F44 patch.ps1：CI 跑一次 android+ios，用新增的 APPLIED/SKIP 日志当断言。

### 已知未修（超出本次 44 条范围）

- 同类「异步后用旧下标」仍存在于 `fav/topic`、`fav/cheese`、`fav/article`、`fan`、`msg_feed_top/{sys_msg,reply_me,like_me}`、`download/search`；可复用 `common_list_controller.dart` 的 `indexOfIdentity` / `indexWhereStable`。
- 其它评论 footer（`main_reply/view.dart`、`common/dyn/common_dyn_page.dart`）尚未接入 `loadMoreError` 重试入口。
- `lib/pages/common/common_intro_controller.dart:249-251`：快速收藏时 `queryVideoInFolder` 失败会静默 dismiss（与 F41 同类漏提示）。
- `lib/plugin/pl_player/widgets/bottom_control.dart` 的 `videoDetailController` 仍为非空字段；直播若复用默认底栏需一并可空化。
- `BiliCookieJar.toJson()` 以 cookie 名做 key，同名不同 domain/path 的 cookie 持久化会互相覆盖（既有格式边界）。
- SDK 补丁是 CRLF 行尾，`patch.ps1` 只把 material/cupertino 补丁规范化为 LF；CI 靠 Windows runner 的 CRLF 工作树匹配，跨平台需统一。
- 本工具链 SDK 的 `_Cookie(name,value)` 构造器把 `httpOnly` 初始化为 true（`dart-sdk/lib/_http/http_headers.dart`），旧标量 cookie 读入后也会是 HttpOnly；`setBiliDomain` 的显式赋值目前是冗余保险。

### 既有问题（非本次引入，2026-10-13 验收时确认）

- `test/widgets/image_grid_view_test.dart` 在 `tearDownAll` 阶段挂起：全量套件里表现为 runner 的 `TimeoutException after 0:12:00`（唯一失败项）；单独运行 100s 内无任何用例完成。`git log 92815cf..HEAD -- test/widgets/image_grid_view_test.dart` 为空（本次未改动该文件），且原审查 §8 已记录「套件尾部不退出 / 常驻 isolate」同类现象。根因待单独立项（疑为 VisibilityDetector / timer / isolate 未释放）。
