# Domain Docs

工程技能在探索本仓库代码时，如何消费本仓库的域文档。

## 布局：**single-context**

**本仓库是 single-context**：整个仓库共用**一份**根目录的 `GLOSSARY.md`，架构决策放在**根目录**的
`docs/adr/`。因此**不要**创建 `GLOSSARY-MAP.md`，也不要建各子项目的 `GLOSSARY.md`。

（初始化时已检查：仓库内既没有旧名的 `CONTEXT.md` / `CONTEXT-MAP.md`，也没有 `GLOSSARY.md` /
`GLOSSARY-MAP.md` / `docs/adr/` —— 这些都是**按需惰性创建**的，见下。）

## 探索代码之前要读什么

- **`GLOSSARY.md`**（仓库根）—— 术语与一致语言。
- **`docs/adr/`** —— 与你要改的区域相关的架构决策。

这些文件**不存在就静默跳过**：不要报"缺失"，不要主动建议先建。
`/domain-modeling`（通过 `/grill-with-docs`、`/improve-codebase-architecture` 触达）会在术语或决策
真正定下来时**惰性创建**它们。

## 文件结构

```
/
├── GLOSSARY.md          ← 全仓库唯一的术语表（惰性创建）
├── docs/
│   ├── adr/             ← 全仓库的架构决策记录（惰性创建）
│   ├── agents/          ← 本目录：技能配置
│   ├── 当前状态.md        ← 现状唯一出口
│   └── 审查整改执行记录.md  ← R01–R20 台账
└── BpRecorder/          ← HarmonyOS 应用源码（不是独立子项目上下文）
```

## 与既有文档的关系

- 术语以 `GLOSSARY.md` 为准；**现状**以 [`../当前状态.md`](../当前状态.md) 为准；两者不互相替代。
- 本仓库的"领域"边界由应用本身决定：血压记录、用药计划/打卡、提醒协调、导入导出与完整备份；
  这些词一旦出现分歧，写进 `GLOSSARY.md` 而不是散落在各处注释里。
