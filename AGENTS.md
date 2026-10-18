# AGENTS.md — 本仓库的 agent 约定

本文件是**仓库级**约定；用户级全局规则（工具参数引号、长文本落文件等）在 `~/.dsh/AGENTS.md`，
两者不冲突时都生效。

## 先看哪里

- **现状**（版本/已验证能力/未验证项/已知问题）：[`docs/当前状态.md`](docs/当前状态.md)
- **审查整改 R01–R20 台账**：[`docs/审查整改执行记录.md`](docs/审查整改执行记录.md)
- **交接总结**：[`docs/审查整改总结-2026-10-11.md`](docs/审查整改总结-2026-10-11.md)
- **隔离与数据安全**：[`docs/隔离验收流程.md`](docs/隔离验收流程.md)（生产安装 `com.bp.recorder`
  里是真实健康数据：禁止卸载/清空/批量导入）

## Agent skills

### Issue tracker

GitHub Issues（`cocoper/bp-recorder`），用 `gh` CLI 读写；不把外部 PR 当作请求来源。See `docs/agents/issue-tracker.md`.

### Triage labels

保留默认五角色（`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`），另有 wayfinder 的 5 个 `wayfinder:*` 标签。See `docs/agents/triage-labels.md`.

### Domain docs

single-context：全局一份根目录 `GLOSSARY.md` + `docs/adr/`。See `docs/agents/domain.md`.
