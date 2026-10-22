# 应用流程剖析与原型图（flows）

状态：持续生效（基于 v1.1.0+5 代码静态盘点，2026-09）
相关文档：[ARCHITECTURE.md](../../ARCHITECTURE.md)、[CODEBASE_MAP.md](../codebase/CODEBASE_MAP.md)、[DESIGN_SYSTEM.md](../design/DESIGN_SYSTEM.md)、[doc/README.md](../README.md)

## 1. 定位

本主题目录回答一个问题：**应用现在长什么样、用户与数据是怎么流转的**。它是后续改版 / 重构规划的现状盘点底稿——先如实记录「现状是什么」，再在各文档末尾附「改版观察」小节罗列可讨论的摩擦点；观察只陈述代码事实，不做决策。

与其他文档的分工：

| 文档 | 回答的问题 | 与本主题的关系 |
| --- | --- | --- |
| `ARCHITECTURE.md`（根目录） | 为什么这样分层设计 | 本主题引用其分层结论，不重复论述 |
| `codebase/CODEBASE_MAP.md` | 每个文件在哪里、干什么 | 流程图中标注的入口文件可在其中反查 |
| `design/DESIGN_SYSTEM.md` | 视觉应该长什么样（Token/规范） | 原型图的配色、圆角、字号以它为准 |
| `flows/*`（本目录） | 现在实际长什么样、怎么流转 | — |

## 2. 文档清单与阅读顺序

```text
doc/flows/
├── README.md                 # 本索引
├── NAVIGATION_MAP.md         # ① 启动链路、AppShell 骨架、全局导航地图
├── USER_FLOWS.md             # ② 面向用户的流程：浏览/搜索/详情换源/续播/追更/设置
├── PLAYBACK_PIPELINE.md      # ③ 播放全链路：点击到出画面的十步流水线
├── PLAYBACK_STARTUP_OPTIMIZATION_PLAN.md # 点击到首帧的计时边界、瓶颈与待实施优化
├── CACHE_DOWNLOAD_FLOWS.md   # ④ 缓存体系与下载任务生命周期
└── PROTOTYPES.md             # ⑤ 全部页面 ASCII 原型图（线框 + 区块注解）
```

推荐阅读顺序：① 了解骨架 → ② 用户视角的流程 → ③④ 技术视角的深水区 → ⑤ 对照页面。

## 3. 约定

- 所有流程图与原型图均使用 ```text 代码块内的 ASCII 图（沿用仓库惯例，不使用 Mermaid/图片）。
- 原型图为**低保真线框**，标注区块名与交互点；具体颜色、字号、间距 Token 见 `DESIGN_SYSTEM.md`，本文不重复。
- 流程图中代码入口只标「文件 + 关键类/方法」粒度，逐文件说明见 `CODEBASE_MAP.md`。
- 应用迭代后若流程或页面结构变化，须同步更新对应文档（含版本基线行）。

## 4. 快速导航

- 「应用有几个页面、怎么跳」→ [NAVIGATION_MAP.md](NAVIGATION_MAP.md) 第 3 节全景导航地图
- 「点一个视频到出画面发生了什么」→ [PLAYBACK_PIPELINE.md](PLAYBACK_PIPELINE.md) 第 1 节全链路总览
- 「从点击到首帧还能如何提速」→ [PLAYBACK_STARTUP_OPTIMIZATION_PLAN.md](PLAYBACK_STARTUP_OPTIMIZATION_PLAN.md)
- 「边下边播和离线下载是什么关系」→ [CACHE_DOWNLOAD_FLOWS.md](CACHE_DOWNLOAD_FLOWS.md) 第 1 节
- 「某页面有哪些区块和交互」→ [PROTOTYPES.md](PROTOTYPES.md) 对应小节
