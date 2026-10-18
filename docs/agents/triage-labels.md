# Triage 与 Wayfinder 标签词汇

## 一、Triage 五角色（保留默认字符串）

| 角色（技能内的名字） | 本仓库标签 | 含义 |
|---|---|---|
| `needs-triage` | `needs-triage` | 维护者需要先评估这张 issue |
| `needs-info` | `needs-info` | 等报告人补充信息 |
| `ready-for-agent` | `ready-for-agent` | 规格完整，可交给离线 agent 执行 |
| `ready-for-human` | `ready-for-human` | 需要人来实现 |
| `wontfix` | `wontfix` | 不做 |

技能里提到某个角色（例如「打上 AFK-ready 的 triage 标签」）时，用右列对应的标签字符串。

> 说明：`wontfix` 沿用 GitHub 默认标签（仓库里已存在）；其余四个是本仓库新建的。

## 二、Wayfinder 标签（地图式推进）

| 标签 | 用途 |
|---|---|
| `wayfinder:map` | 一张「地图」issue：Notes / Decisions-so-far / Fog |
| `wayfinder:research` | 子票：调研型 |
| `wayfinder:prototype` | 子票：原型型 |
| `wayfinder:grilling` | 子票：追问/拷问型 |
| `wayfinder:task` | 子票：实施型 |

子票类型标签只在 `/wayfinder` 流程里加；普通 issue 不加。
