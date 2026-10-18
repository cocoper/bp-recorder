# Issue tracker：GitHub Issues

本仓库的 issue 与规格都放在 **GitHub Issues**（仓库 `cocoper/bp-recorder`）。所有操作走 `gh` CLI。

## 约定

- **新建 issue**：`gh issue create --title "..." --body "..."`；多行正文用 heredoc。
- **读 issue**：`gh issue view <number> --comments`，配合 `jq` 过滤评论并同时取 labels。
- **列表**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，可按 `--label` / `--state` 过滤。
- **评论**：`gh issue comment <number> --body "..."`
- **加/去标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **关闭**：`gh issue close <number> --comment "..."`

仓库由 `git remote -v` 推断；在仓库内运行 `gh` 时自动识别。

## 把 PR 当作请求来源

**PRs as a request surface: no.**（本仓库不把外部 PR 当作功能请求进入 triage 队列；要开启就把本行改成 `yes`。）

GitHub 的 issue 与 PR 共用一个编号空间，因此裸 `#42` 可能是两者之一：先用 `gh pr view 42` 解析，失败再退回 `gh issue view 42`。

## 技能说「发布到 issue tracker」时

新建一个 GitHub issue。

## 技能说「取出相关票据」时

`gh issue view <number> --comments`。

## Wayfinding（地图式推进）操作

用于 `/wayfinder`：**地图**是一张 issue，**子票**是它的子 issue。

- **地图**：一张带 `wayfinder:map` 标签的 issue，正文放 Notes / Decisions-so-far / Fog。
- **子票**：以 GitHub sub-issue 关联到地图（`gh api` 的 sub-issues 端点）；未启用 sub-issues 时，在
  地图正文里放任务清单、并在子票正文顶部写 `Part of #<map>`。子票标签用 `wayfinder:<type>`
  （`research` / `prototype` / `grilling` / `task`）。认领后指派给执行者。
- **阻塞关系**：优先用 GitHub 原生 issue dependencies（UI 可见）；不可用时退回子票正文顶部的
  `Blocked by: #<n>` 行。所有 blocker 关闭即视为解除阻塞。
- **前沿查询**：列出地图下未关闭的子票，去掉有未关闭 blocker 或已有 assignee 的，取地图顺序中的第一张。
- **认领**：`gh issue edit <n> --add-assignee @me`（本会话的第一次写操作）。
- **解决**：`gh issue comment <n> --body "<答案>"` → `gh issue close <n>` → 在地图正文的
  Decisions-so-far 追加一条上下文指针。

## 本仓库的补充约定

- 审查整改类工作（R01–R20）以 `docs/审查整改执行记录.md` 为台账，issue 只作为对外任务入口，
  两者不重复记账；需要引用时把台账条目写进 issue 正文。
- 标签词汇见 [`triage-labels.md`](triage-labels.md)；域文档见 [`domain.md`](domain.md)。
