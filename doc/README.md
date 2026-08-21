# 文档索引

## 当前活跃文档（根目录）

| 文档 | 状态 | 说明 |
| --- | --- | --- |
| `BACKEND_TECHNICAL_REQUIREMENTS.md` | 进行中 | V1.1 后端（VOD 源目录与远程配置服务）技术需求 |
| `SYNCNEXT_SOURCE_INTEGRATION_PLAN.md` | 第二期进行中 | 接入 SyncnextPlugin 源；AGE Dart Adapter + 通用 JS 插件运行时 |
| `DESIGN_SYSTEM.md` | 持续生效 | "夜幕影院"深色主题设计规范（颜色/字号/组件 Token），UI 改动须遵守 |

## 归档（`archive/`，功能已实现，仅作历史记录与验收依据）

### `archive/mvp/` — MVP 需求与排期

- `APP_REQUIREMENTS_V1.md` — 最初的总需求（列表/搜索/详情/播放/最近观看）
- `DEVELOPMENT_PLAN.md` — 6 周开发排期（阶段 0–6，已全部完成）
- `PHASE1_FEATURE_PRD.md` — 收藏、播放列表、可拖动预览进度条

### `archive/cache/` — 缓存与下载体系

- `CACHE_MANAGEMENT_PLAN.md` — 缓存体系权威总纲（本地代理、ContentKey、配额/LRU、广告过滤）
- `CACHE_TTL_EVICTION_PRD.md` — TTL 自动过期清理（总纲第 6 节的时间维度补丁）
- `DOWNLOAD_REQUIREMENTS_AND_TEST_PLAN.md` — 显式下载与离线播放需求及验收清单
- `边播边下与广告过滤技术解析.md` — HLS/边播边下原理科普；其中 302 跳转等早期架构细节已废弃，方案以 PLAN 为准

### `archive/vod-source/` — 多源切换

- `VOD_SOURCE_SWITCH_PRD_AND_PLAN.md` — 全局浏览源、搜索备用源探测、详情页切源、Adapter 抽象（客户端侧已完成，后端演进由根目录 BACKEND 文档接管）
