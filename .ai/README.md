# `.ai/` — AI 智能体产物

本目录汇总仓库里由 AI 智能体产出的全部文档、证据、逆向工作区与调查草稿。
原先它们散落在仓库根目录（`reverse-output/`、`.sisyphus/`、`.probe/`、`.tmp/`、
`tmp-investigation-reply2/`）与 `docs/` 下（`docs/research/`、`docs/code-review-2026-10-13/`）。

迁移日期：**2026-10-14**。移动采用同卷 rename，内容未被复制或重新编码。

## 目录索引

| 目录 | 内容 | 文件数 | 体积 |
|---|---|---:|---:|
| [`reverse-output/`](reverse-output/) | 针对官方 B 站 APK 的 IDA/JADX 逆向报告与证据（appkey/appsec、签名、gRPC metadata、设备身份、BUVID、评论折叠等） | 202 | 1.7 MB |
| [`probe/`](probe/) | 逆向与在线探针工作区：APK/APKM 样本、dex、repo 脚本（`.py`/`.sh`/`.ps1`）、抓包与日志 | 268 | 410 MB |
| [`sisyphus/`](sisyphus/) | sisyphus 智能体工作区：`boulder.json` 状态、`plans/`、`notepads/`、`evidence/` | 196 | 4.8 MB |
| [`code-review-2026-10-13/`](code-review-2026-10-13/) | 全仓代码审查报告（scope/inventory/report/verification + 复现测试） | 7 | 0.2 MB |
| [`tmp-investigation-reply2/`](tmp-investigation-reply2/) | 评论楼中楼旧路由调查（报告 + 11 轮探针） | 24 | 0.12 MB |
| [`tmp/`](tmp/) | 平台层独立只读审查报告与评论探针诊断 | 5 | 0.05 MB |
| [`research/`](research/) | 已提交的调研报告：B 站楼中楼 `rcount`/DetailList/dialog 事实核查 | 1 | 0.01 MB |
| [`migration-2026-10-14/`](migration-2026-10-14/) | 本次迁移的校验物：迁移前文件数/体积快照、改写前后语法一致性检查脚本 | 2 | 0.002 MB |

仓库根因此只剩 `.ai/` 一个 AI 产物目录；`docs/` 回到纯人工文档（TODO、快捷键、上游配置）。

## 旧路径 → 新路径映射

前缀式映射，其余层级原样保留：

| 迁移前 | 迁移后 |
|---|---|
| `reverse-output/` | `.ai/reverse-output/` |
| `.probe/` | `.ai/probe/` |
| `.sisyphus/` | `.ai/sisyphus/` |
| `.tmp/` | `.ai/tmp/` |
| `tmp-investigation-reply2/` | `.ai/tmp-investigation-reply2/` |
| `docs/code-review-2026-10-13/` | `.ai/code-review-2026-10-13/` |
| `docs/research/` | `.ai/research/` |

## 版本控制

`.gitignore` 忽略 `.ai/*`，只有两项例外：

- `.ai/README.md`（本索引）
- `.ai/research/`（`bilibili-comment-threading-report.md` 原先已被 git 跟踪，随楼中楼功能一起提交）

## 注意事项

1. **冻结证据**：`.ai/reverse-output/**`（含 `evidence/*.java`、`evidence/*.txt` 等）为已发布结论的证据快照，
   迁移时保持逐字节不变，因此其中出现的 `reverse-output/...`、`.probe/...` 仍是迁移前路径。
   需要定位时按上表加 `.ai/` 前缀即可。`.ai/code-review-2026-10-13/`、`.ai/tmp*/` 等报告类文本同理。
2. **脚本已修路径**：`.ai/probe/**` 下的可执行脚本（`.py`/`.sh`/`.js`/`.mjs`/`.ps1`/`.json`）里硬编码的
   `.probe` 路径已批量更新为 `.ai/probe`，可直接运行；报告类 `.md`/`.txt` 保持原文。
3. **含真实凭据**：`.ai/probe/` 内有 cookie、票据、keystore 等敏感文件（如 `rev/real_cookie.txt`、
   `cphone/official_ticket.txt`）。它们被 gitignore 覆盖，请勿提交、勿外传。
4. **sisyphus 工作区**：本目录是 sisyphus 智能体的状态根。若该工具在仓库根重新创建 `.sisyphus/`，
   请把新内容并入 `.ai/sisyphus/`，并同步 `boulder.json` 里的绝对路径。
5. 本目录只放产物，不放业务源码；业务文档仍在 `docs/`。

## 迁移校验

- **守恒**：7 处产物的文件数与总体积与迁移前逐一比对，文件数 703 全部一致。
  体积仅因路径改写而变，且每一处增量都能与其改写量精确对上：
  `probe` +387 B = 115 处 `.probe`→`.ai/probe`（+3 B/处） + 14 处 `".probe",`→`".ai", "probe",`（额外 +3 B/处）；
  `sisyphus` +4 B = `boulder.json` 里 JSON 转义后的 `.ai\` 前缀；`code-review` −11 B = 排除列表改写。
  明细见 [`migration-2026-10-14/before-snapshot.json`](migration-2026-10-14/before-snapshot.json)。
- **引用**：改动后 `git grep` 已无指向旧路径的活引用；4 处源码注释、`AGENTS.md`、`.gitignore` 全部指向 `.ai/`。
- **脚本**：`.ai/probe/**` 内 166 个 Python 文件全部 `ast.parse` 通过 160 个；6 个失败文件
  （`cphone/make_account_store.py`、`cphone/make_account_store2.py`、`cphone/v2parse.py`、
  `rev/geetest_login.py`、`rev/replay_captured.py`、`rev/test_account2.py`）经"改写回退后重新解析"证明
  **改写前后报错集合完全一致**，即迁移前就已损坏（部分文件磁盘上仍是凭据脱敏占位符 `{{Redact:…}}`）。
  复现：`python .ai/migration-2026-10-14/before-after-syntax-parity.py`（需在仓库根执行）。
- **索引**：`.ai/research/` 的改名已 `git mv` 暂存；`.ai/README.md` 待提交。
