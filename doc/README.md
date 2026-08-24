# 文档索引

仓库入口文档在根目录：`README.md`（使用与现状）、`ARCHITECTURE.md`（架构）、`AGENTS.md`（贡献约定）。产品、设计与方案文档集中在本目录。

## 目录结构

```text
doc/
├── README.md                                 # 本索引
├── codebase/
│   └── CODEBASE_MAP.md                       # 代码文件地图（逐文件索引）
├── design/
│   └── DESIGN_SYSTEM.md                      # 夜幕影院设计规范
├── backend/
│   └── BACKEND_TECHNICAL_REQUIREMENTS.md     # V1.1 后端技术需求
├── cast/
│   └── CAST_PLAN.md                          # 投屏功能方案（待确认电视型号后启动）
├── tv/
│   └── TV_ADAPTATION_PLAN.md                 # 最小 TV 适配需求方案（feature/tv-adaptation 分支）
├── vod-source/
│   └── SYNCNEXT_SOURCE_INTEGRATION_PLAN.md   # Syncnext / AGE 接入方案
└── archive/
    ├── mvp/                                  # 第一版需求与排期
    ├── cache/                                # 缓存与下载
    └── vod-source/                           # 已完成的多源切换方案
```

## 约定

- 当前有效文档按主题放在 `doc/<topic>/`，不要直接堆在 `doc/` 根下（本 README 除外）。
- 功能完成后整份文档移入 `doc/archive/<topic>/`，并同步更新本索引的状态。
- 新主题先建同名目录，归档沿用同一主题名（例如有效文档在 `vod-source/`，完成后进 `archive/vod-source/`）。
- 仓库根目录只保留 `README.md`、`ARCHITECTURE.md`、`AGENTS.md`。

## 当前有效

| 文档 | 状态 | 说明 |
| --- | --- | --- |
| [`codebase/CODEBASE_MAP.md`](codebase/CODEBASE_MAP.md) | 持续生效 | 代码文件地图：`lib/` 逐文件作用索引，新增/移动/删除文件时须同步 |
| [`design/DESIGN_SYSTEM.md`](design/DESIGN_SYSTEM.md) | 持续生效 | 「夜幕影院」深色主题设计规范（颜色/字号/组件 Token），UI 改动须遵守 |
| [`backend/BACKEND_TECHNICAL_REQUIREMENTS.md`](backend/BACKEND_TECHNICAL_REQUIREMENTS.md) | 进行中 | V1.1 后端（VOD 源目录与远程配置服务）技术需求 |
| [`vod-source/SYNCNEXT_SOURCE_INTEGRATION_PLAN.md`](vod-source/SYNCNEXT_SOURCE_INTEGRATION_PLAN.md) | 第二期进行中 | 接入 SyncnextPlugin 源；AGE Dart Adapter + 通用 JS 插件运行时 |
| [`cast/CAST_PLAN.md`](cast/CAST_PLAN.md) | 待启动 | 投屏功能方案：Cast/DLNA/AirPlay 路线对比与分期计划；待确认电视型号与广告过滤取舍后进入 P0 验证 |
| [`tv/TV_ADAPTATION_PLAN.md`](tv/TV_ADAPTATION_PLAN.md) | 开发中 | 最小 TV 适配需求方案：FR-1~FR-4 已实现（`feature/tv-adaptation` 分支），待真机实测 |

## 归档（`archive/`，功能已实现，仅作历史记录与验收依据）

### [`archive/mvp/`](archive/mvp/) — MVP 需求与排期

- [`APP_REQUIREMENTS_V1.md`](archive/mvp/APP_REQUIREMENTS_V1.md) — 最初的总需求（列表/搜索/详情/播放/最近观看）
- [`DEVELOPMENT_PLAN.md`](archive/mvp/DEVELOPMENT_PLAN.md) — 6 周开发排期（阶段 0–6，已全部完成）
- [`PHASE1_FEATURE_PRD.md`](archive/mvp/PHASE1_FEATURE_PRD.md) — 收藏、播放列表、可拖动预览进度条

### [`archive/cache/`](archive/cache/) — 缓存与下载体系

- [`CACHE_MANAGEMENT_PLAN.md`](archive/cache/CACHE_MANAGEMENT_PLAN.md) — 缓存体系权威总纲（本地代理、ContentKey、配额/LRU、广告过滤）
- [`CACHE_TTL_EVICTION_PRD.md`](archive/cache/CACHE_TTL_EVICTION_PRD.md) — TTL 自动过期清理（总纲第 6 节的时间维度补丁）
- [`DOWNLOAD_REQUIREMENTS_AND_TEST_PLAN.md`](archive/cache/DOWNLOAD_REQUIREMENTS_AND_TEST_PLAN.md) — 显式下载与离线播放需求及验收清单
- [`边播边下与广告过滤技术解析.md`](archive/cache/边播边下与广告过滤技术解析.md) — HLS/边播边下原理科普；其中 302 跳转等早期架构细节已废弃，方案以 PLAN 为准

### [`archive/vod-source/`](archive/vod-source/) — 多源切换（客户端侧已完成）

- [`VOD_SOURCE_SWITCH_PRD_AND_PLAN.md`](archive/vod-source/VOD_SOURCE_SWITCH_PRD_AND_PLAN.md) — 全局浏览源、搜索备用源探测、详情页切源、Adapter 抽象；后端演进由 [`backend/BACKEND_TECHNICAL_REQUIREMENTS.md`](backend/BACKEND_TECHNICAL_REQUIREMENTS.md) 接管
