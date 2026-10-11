# 血压助手（bp-recorder）

HarmonyOS / ArkTS 单机血压与服药记录应用，附**策划文档、离线校验链与开发工具**。无网络权限、无账号体系、无第三方 SDK。

> **当前状态以 [`docs/审查整改执行记录.md`](docs/审查整改执行记录.md) 为准**：该文件跟踪《全面审查报告与修改要求-2026-10-11.md》R01–R20 的整改进度、每项证据与未验证项。
> 历史交付与实测数字见 [`docs/自检报告.md`](docs/自检报告.md)；产品与验收口径见 [`血压记录分析App项目策划方案.md`](血压记录分析App项目策划方案.md)。

## 仓库结构（单仓库）

```
BpRecorder/                 # 应用本体（ArkTS 源码、资源、ohosTest）
  entry/src/main/ets/       #   common / model / service / components / pages / entryability
  entry/src/ohosTest/       #   Hypium 端侧测试
docs/                       # 自检报告、决策记录、运行与部署、隔离验收流程、审查整改执行记录…
tools/                      # 离线校验链与开发工具（见下）
血压记录分析App项目策划方案.md  # 产品与验收规格（唯一脊柱）
```

`BpRecorder/build-profile.json5`（含本机签名口令与密钥库路径）**不入库**，仓库内只放脱敏模板 `build-profile.example.json5`。

## 环境要求

- Node.js **≥ 22.5**（`tools/sqlcheck.mjs` 用到内置 `node:sqlite`）
- DevEco Studio（提供 SDK、hvigor 与 JBR）—— 路径通过 `DEVECO_HOME` 指定或写入 `tools/toolchain.local.json`
- 可选：真机调试用 `hdc`（随 DevEco SDK 提供）

## 快速开始（干净目录）

```bash
node tools/init-local-config.mjs   # 生成 build-profile.json5（从模板）与 tools/toolchain.local.json；已存在则拒绝覆盖
npm install                        # 安装 devDependency（typescript，供 parity 类型检查）
node tools/check-all.mjs --skip-review-regression   # 7 组离线检查
```

`tools/check-all.mjs` 不带参数时**还会跑审查反例组** `docs/review-2026-10-11/repro.cjs`：整改期间该组是**红**的（19 个待修缺陷），这是预期状态，不是脚本错误。

## 离线校验链（`tools/`）

| 脚本 | 作用 |
|---|---|
| `parity/run.mjs` | 把 `common`/`model`/`service` 下的**真实 .ets** 拷成 .ts，用 tsc 全量类型检查并跑边界断言（含导出→回导幂等） |
| `sqlcheck.mjs` | 在真实 SQLite 上验证 DDL 与迁移 SQL |
| `check-resources.mjs` | 文案/颜色资源引用与定义一致 |
| `check-project-config.mjs` | 工程配置静态检查 |
| `check-api-usage.mjs` | API 使用扫描（有限规则，不等同编译器结论） |
| `check-encoding-fallback.mjs` | UTF-8 / GB18030 编码回落 |
| `check-tooltip-geometry.mjs` | 图表气泡几何 |
| `check-all.mjs` | 按审查 §5.1 逐条跑并汇总退出码 |

源码覆盖由 `tools/parity/run.mjs` **自动发现**（`common`/`model`/`service` 下所有 `.ets`），不能纳入的文件必须在脚本的 `EXCLUDED` 里逐个写明理由。

## 构建与安装

```bash
# DevEco 的 hvigor（模块化构建）
"$DEVECO_HOME/tools/node/bin/node" "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" \
  --mode module -p module=entry@default -p product=default -p requiredDeviceType=phone \
  clean assembleHap --analyze=normal --parallel --no-daemon

# 测试包：把 module=entry@default 换成 entry@ohosTest
# 安装到真机：node tools/install-to-device.mjs
```

## 环境变量（都可选，用于覆盖自动解析）

| 变量 | 含义 |
|---|---|
| `DEVECO_HOME` | DevEco Studio 的 `Contents` 目录（含 `sdk/`、`tools/`、`jbr/`） |
| `DEVECO_SDK_HOME` | 仅 SDK 目录 |
| `PARITY_NODE` | 跑离线脚本的 Node（默认当前 Node） |
| `PARITY_TSC` | tsc 路径（默认仓库 `node_modules/typescript`） |
| `HDC_BIN` / `HVIGORW` / `HVIGOR_NODE` / `JAVA_HOME` | 设备与构建工具 |

## 数据安全（强制）

用户现用安装（`com.bp.recorder`）里是**真实健康数据**：卸载重装、清空数据、批量导入测试数据、故障注入一律**禁止**在其上执行；现有三份 CSV 已被证明**不能担保完整恢复**。
破坏性验收走 [`docs/隔离验收流程.md`](docs/隔离验收流程.md)（独立设备/模拟器 + 测试包名 + 独立数据库 + 合成数据 + 前后哨兵快照）。
