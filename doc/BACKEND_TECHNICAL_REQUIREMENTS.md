# Jive 多 VOD 源后端技术需求文档

## 1. 文档信息

| 项目 | 内容 |
|---|---|
| 文档用途 | 用于创建独立的 Jive 后端项目，并作为架构、开发、测试和验收依据 |
| 目标客户端 | Jive Flutter Android/iOS App |
| 基础架构 | 模块化单体 + VOD Source Adapter + 独立后台 Worker |
| 核心技术栈 | Node.js 24 LTS、TypeScript、NestJS/Fastify、PostgreSQL、Redis、BullMQ、Docker |
| 关联文档 | `BACKEND_ARCHITECTURE.md`、`APP_REQUIREMENTS_V1.md`、根目录 `ARCHITECTURE.md` |

当本文档与早期架构草案存在冲突时，新后端项目以本文档为准；对外 API 的兼容性要求除外。

## 2. 项目背景

Jive 当前 Flutter MVP 直接调用单一第三方 VOD API，并在客户端解析分类、视频详情、剧集和播放地址。后续需要接入多个合法授权的 VOD 源，因此必须增加自有后端，以实现：

- 对 Flutter 提供稳定、统一、与 VOD 厂商无关的 API。
- 隔离不同源的字段、分页、分类、剧集和播放地址规则。
- 定时同步各源的目录元数据，避免 App 列表请求依赖第三方实时状态。
- 在用户点击播放时解析最新地址，并在失败时自动选择备用源。
- 对各源独立执行限流、重试、健康检查、启停和优先级管理。
- 保留内容审核、下架、投诉处理和来源追溯能力。

后端不代理视频流，不提供转码、切片或 CDN。Flutter 获取播放地址后直接交给播放器。

## 3. 建设目标与范围

### 3.1 第一阶段必须实现

- 独立后端仓库和本地 Docker 开发环境。
- `/api/v1` REST JSON API。
- 分类、视频列表、搜索、详情、播放解析和观看记录接口。
- PostgreSQL 业务数据存储。
- Redis 查询缓存和播放地址短时缓存。
- BullMQ 元数据同步、健康检查和维护任务。
- `StormAdapter`，以及可验证新增第二个源的 Adapter 框架。
- API 进程与 Worker 进程独立运行。
- 源级和线路级的启停、优先级、限流及健康状态。
- 同步断点、幂等 upsert、失败重试、同步运行记录和安全下架判断。
- 播放失败切源、播放事件回传和基础可观测性。
- OpenAPI 文档、数据库迁移、自动测试和部署说明。

### 3.2 第一阶段不实现

- 视频文件上传、代理、转码、截图、切片和自建 CDN。
- DRM 破解或绕过 Referer、Token 等访问控制。
- 自动识别并合并所有同名影视内容。
- 推荐算法、会员、支付和广告系统。
- Kafka、Elasticsearch、Kubernetes 和微服务拆分。
- 多地域部署和跨地域数据库复制。
- 面向第三方开发者的公开开放平台。

## 4. 强制技术栈

### 4.1 运行时与工程

| 类别 | 要求 |
|---|---|
| Runtime | Node.js 24 LTS |
| Language | TypeScript，开启 `strict` |
| Package manager | pnpm workspace |
| Web framework | NestJS 11 |
| HTTP adapter | Fastify 5，不使用 Express adapter |
| API protocol | REST + HTTPS + JSON |
| API contract | OpenAPI 3，由代码生成并在 CI 检查 |
| Build | Nest CLI 或等价 TypeScript build，生产环境输出编译后的 JavaScript |
| Container | Docker，多阶段构建，非 root 用户运行 |

不得在第一阶段引入 GraphQL。API 业务对象不得暴露数据库实体或第三方源原始字段。

### 4.2 数据与基础设施

| 类别 | 要求 |
|---|---|
| 主数据库 | PostgreSQL 17 或更高受支持版本 |
| 数据访问 | Drizzle ORM + SQL migrations；复杂查询允许显式 SQL |
| 缓存 | 独立 Redis Cache 实例，可使用 `allkeys-lru`/`allkeys-lfu` |
| 队列 | BullMQ 5 + 独立 Redis Queue 实例 |
| Queue Redis | 必须启用持久化并设置 `maxmemory-policy=noeviction` |
| 外部 HTTP | `undici`，复用连接池并设置分阶段超时 |
| 外部数据校验 | Zod；每个 Adapter 必须校验不可信响应 |
| ID | 服务端生成带业务前缀的 ULID，如 `vid_`、`ep_`、`pb_`、`sync_` |

缓存 Redis 与队列 Redis 在生产环境必须逻辑或物理隔离，禁止让缓存淘汰策略删除 BullMQ 任务键。

### 4.3 日志、监控与测试

| 类别 | 要求 |
|---|---|
| 日志 | Pino 结构化 JSON 日志 |
| Trace/Metrics | OpenTelemetry；提供 Prometheus 可采集指标 |
| 单元测试 | Vitest |
| 集成测试 | Testcontainers，使用真实 PostgreSQL 和 Redis |
| E2E | Nest 测试应用 + Fastify inject 或真实 HTTP |
| 格式与静态检查 | ESLint、Prettier、TypeScript typecheck |

## 5. 总体架构

```text
Flutter App
    │ HTTPS / JSON
    ▼
API Process
    ├── Catalog Module
    ├── Search Module
    ├── Playback Module
    ├── History Module
    ├── Source Module
    └── Admin Module
           │
           ├──────── PostgreSQL
           ├──────── Redis Cache
           └──────── BullMQ Producer ─── Redis Queue
                                           │
                                           ▼
                                      Worker Process
                                      ├── Source Sync
                                      ├── Health Check
                                      └── Maintenance
                                           │
                                           ▼
                                   VOD Source Adapters
                                   ├── StormAdapter
                                   ├── SourceBAdapter
                                   └── SourceCAdapter
```

### 5.1 架构原则

1. Flutter 只调用 Jive `/api/v1`，不得直接调用第三方 VOD 源。
2. 列表、分类、搜索和详情默认读取本地 PostgreSQL，不实时聚合所有第三方源。
3. 播放地址仅在用户点击播放时按需解析，不出现在列表或详情响应中。
4. 第三方源 ID、播放线路 ID 与 Jive 业务 ID 必须分离。
5. 新增 VOD 源只能增加 Adapter、配置和数据映射，不得要求修改 Flutter 页面。
6. API 和 Worker 共享代码包，但必须可独立部署和扩容。
7. 第一阶段保持模块化单体，不为模块单独建立服务或数据库。
8. 所有任务和同步写入必须幂等，默认接受“至少一次执行”语义。

## 6. 建议仓库结构

```text
jive-backend/
├── apps/
│   ├── api/
│   │   └── src/main.ts
│   └── worker/
│       └── src/main.ts
├── packages/
│   ├── contracts/              # API DTO、错误码和稳定业务类型
│   ├── config/                 # 环境配置及校验
│   ├── database/               # Drizzle schema、migration、repository
│   ├── observability/          # 日志、trace、metrics
│   ├── source-sdk/             # Adapter 接口、统一错误和 HTTP 基础能力
│   └── sources/
│       ├── storm/
│       └── source-b/
├── src/modules/
│   ├── catalog/
│   ├── search/
│   ├── playback/
│   ├── history/
│   ├── sources/
│   ├── sync/
│   ├── health/
│   └── admin/
├── migrations/
├── test/
│   ├── fixtures/sources/
│   ├── integration/
│   └── e2e/
├── docker/
├── compose.yaml
├── Dockerfile
├── pnpm-workspace.yaml
└── README.md
```

业务模块不得直接依赖具体 `StormAdapter`。具体 Adapter 必须通过 `SourceRegistry` 按 `adapter_name` 注册和查找。

## 7. 核心领域模型

### 7.1 统一业务模型

```ts
interface Video {
  id: string;
  title: string;
  posterUrl?: string;
  backdropUrl?: string;
  description?: string;
  categoryId?: string;
  categoryName?: string;
  year?: number;
  status?: string;
  remarks?: string;
}

interface Episode {
  id: string;
  videoId: string;
  name: string;
  episodeNo?: number;
  sortOrder: number;
}

interface PlaybackSource {
  playbackId: string;
  url: string;
  format: 'hls' | 'dash' | 'mp4';
  sourceCode: string;
  lineCode?: string;
  expiresAt?: string;
  headers?: Record<string, string>;
}
```

### 7.2 VOD 厂商与播放线路必须分离

一个 VOD 厂商可能在 `vod_play_from` 中提供多个内部播放线路。后端必须分别建模：

- `vod_sources`：厂商或外部 API，例如 Storm。
- `source_play_lines`：厂商内部线路，例如某个 HLS 线路。
- `source_videos`：厂商视频记录。
- `source_episodes`：某个厂商视频、某条线路下的具体剧集映射。

不得把厂商与厂商内部播放线路混为同一个概念。

## 8. VOD Source Adapter 规范

### 8.1 接口要求

```ts
export interface VodSourceAdapter {
  readonly sourceCode: string;

  listCategories(
    context: SourceRequestContext,
  ): Promise<SourceCategory[]>;

  listVideos(
    input: ListSourceVideosInput,
    context: SourceRequestContext,
  ): Promise<SourceVideoPage>;

  getVideoDetail(
    input: GetSourceVideoDetailInput,
    context: SourceRequestContext,
  ): Promise<SourceVideoDetail>;

  resolvePlayback(
    input: ResolveSourcePlaybackInput,
    context: SourceRequestContext,
  ): Promise<ResolvedSourcePlayback[]>;

  healthCheck(
    context: SourceRequestContext,
  ): Promise<SourceHealthResult>;
}
```

搜索并非所有源都支持，建议以可选 Capability 表达，不得用返回空数组掩盖“不支持搜索”。

```ts
interface SourceCapabilities {
  search: boolean;
  categories: boolean;
  incrementalSync: boolean;
  expiringPlaybackUrl: boolean;
  requiresPlaybackHeaders: boolean;
}
```

### 8.2 Adapter 职责

每个 Adapter 必须负责：

- 第三方字段到统一 Source DTO 的映射。
- 0/1 起始分页、游标和页数差异。
- 分类层级和源分类 ID 解析。
- 多线路、剧集分隔符和播放格式解析。
- 源响应 schema 校验及缺失字段容错。
- 源错误转换为统一错误类型。
- 标明播放地址是否过期、所需 Header 和格式。

Adapter 不得负责：

- 创建或合并 Jive 业务视频。
- 决定全局播放源优先级。
- 直接写业务表或缓存。
- 向普通日志输出完整播放 URL、Token 或源密钥。

### 8.3 Source Client 要求

- 每个源拥有独立连接池、并发数、请求速率和超时配置。
- 默认连接超时 2 秒、响应头超时 3 秒；具体源可在安全范围内配置。
- 仅对 GET、健康检查和幂等同步请求自动重试。
- 重试使用指数退避和 jitter，不得立即连续重试。
- 收到 `429` 时读取合法 `Retry-After`，暂停对应源队列。
- 跟随重定向必须限制次数，并重新执行目标地址安全校验。
- 源地址应由受控配置提供，禁止普通客户端提交任意 URL，避免 SSRF。
- 禁止访问回环、链路本地、私有内网和云元数据地址，除非在部署白名单中明确允许。
- 播放地址及其每次重定向也必须执行协议、host、端口和解析后 IP 校验，阻止私网地址、URL 用户信息和 DNS rebinding。

### 8.4 Adapter 测试要求

每个 Adapter 必须提交脱敏固定响应样本，并覆盖：

- 正常列表、空列表和末页。
- 正常详情、字段缺失、错误 JSON 和错误状态码。
- 单线路、多线路和异常分隔符。
- HLS、MP4 及不支持的播放格式。
- 重复剧集名、重复 URL 和无效 URL。
- 超时、429、5xx 和断网错误映射。
- 源字段变更时的 schema 失败提示。

CI 中的契约测试不得依赖真实第三方源。真实源探测属于独立的受控 smoke test。

## 9. 数据库设计要求

### 9.1 核心表

#### `vod_sources`

```text
id, code, name, adapter_name, base_url, config_jsonb,
priority, enabled, health_status, last_health_at,
created_at, updated_at
```

约束：

- `code` 全局唯一且上线后不可随意修改。
- `config_jsonb` 不得保存明文密钥；密钥使用 Secret 管理或环境变量引用。
- `health_status` 取值：`healthy`、`degraded`、`offline`、`unknown`。

#### `source_play_lines`

```text
id, source_id, line_code, line_name, format_hint,
priority, enabled, health_status, created_at, updated_at
```

唯一键：`(source_id, line_code)`。

#### `videos`

```text
id, title, normalized_title, poster_url, backdrop_url,
description, category_id, year, status, remarks,
enabled, created_at, updated_at
```

#### `source_videos`

```text
id, video_id, source_id, source_video_id,
source_category_id, source_updated_at, content_hash,
raw_payload_jsonb, last_seen_run_id, last_synced_at,
enabled, created_at, updated_at
```

唯一键：`(source_id, source_video_id)`。

`raw_payload_jsonb` 只能保留经过字段白名单和脱敏处理、确实有助于排查源 schema 变化的元数据；必须排除播放 URL、Token、Cookie、签名和源密钥。内容 hash 应基于规范化后的安全字段计算。

#### `episodes`

```text
id, video_id, name, normalized_name, episode_no,
sort_order, enabled, created_at, updated_at
```

#### `source_episodes`

```text
id, episode_id, source_video_id, play_line_id,
source_episode_key, source_episode_name, source_locator_jsonb,
last_seen_run_id, last_synced_at, enabled,
created_at, updated_at
```

唯一键必须为：

```text
(source_video_id, play_line_id, source_episode_key)
```

不得使用 `(source_id, source_episode_id)`，因为很多源的剧集标识只是 `1` 或“第1集”，在不同视频间会重复。

`source_locator_jsonb` 只允许存储再次解析播放地址所需的非敏感定位信息。带签名、Token 或明确会过期的最终播放 URL 不得长期写入 PostgreSQL。

#### 分类相关

```text
categories:
  id, name, parent_id, sort_order, enabled, created_at, updated_at

source_categories:
  source_id, source_category_id, source_category_name,
  category_id, created_at, updated_at
```

`source_categories` 唯一键为 `(source_id, source_category_id)`。

#### `watch_history`

```text
id, owner_type, owner_id, video_id, episode_id,
position_seconds, duration_seconds, completed,
created_at, updated_at
```

唯一键：`(owner_type, owner_id, video_id, episode_id)`。

#### `installations`

```text
id, token_hash, token_version, platform, app_version,
last_seen_at, revoked_at, created_at, updated_at
```

`token_hash` 唯一；安装 Token 必须可轮换和吊销。`watch_history.owner_id` 在匿名阶段指向安装 ID，后续引入账号后通过 `owner_type` 区分。

#### `playback_sessions`

```text
id, owner_id, video_id, episode_id, source_id, play_line_id,
status, resolved_at, expires_at, first_event_at, last_event_at,
created_at, updated_at
```

#### `admin_audit_logs`

```text
id, actor_type, actor_id, action, target_type, target_id,
request_id, before_jsonb, after_jsonb, created_at
```

审计日志禁止保存 Secret 和完整播放 URL，并应设置符合合规要求的保留周期。

不得保存完整播放 URL。必要时只保存 URL 的脱敏 host、格式和不可逆哈希用于排障。

#### `sync_runs`

```text
id, source_id, trigger_type, status, cursor_jsonb,
started_at, finished_at, fetched_count, changed_count,
skipped_count, failed_count, error_summary_jsonb,
created_at, updated_at
```

### 9.2 索引要求

至少建立：

- `videos(normalized_title)` B-tree 索引。
- `videos(normalized_title gin_trgm_ops)` GIN 索引，启用 `pg_trgm`。
- `videos(category_id, enabled, updated_at desc)` 复合索引。
- `episodes(video_id, enabled, sort_order)` 复合索引。
- `source_videos(source_id, last_seen_run_id)` 索引。
- `source_episodes(episode_id, enabled)` 索引。
- `watch_history(owner_type, owner_id, updated_at desc)` 索引。
- `sync_runs(source_id, started_at desc)` 索引。

索引须根据 `EXPLAIN ANALYZE` 验证，禁止仅根据 ORM 默认行为创建。

### 9.3 内容合并原则

- 初始同步不得只根据标题自动合并不同源的视频。
- 新源内容默认可以创建独立 `videos` 记录。
- 只有明确的外部版权 ID、人工审核结果或可靠规则才能把多个 `source_videos` 映射到同一 `video_id`。
- Admin 必须支持后续合并和拆分映射，操作需要审计记录。
- 播放故障切换仅在已确认映射到同一业务视频、同一业务剧集的来源之间执行。

## 10. 元数据同步与队列

### 10.1 队列划分

每个 VOD 源使用独立同步队列，以便独立限流：

```text
vod-sync:storm
vod-sync:{source_code}
vod-health
vod-maintenance
```

任务名称至少包括：

- `source.full-sync`
- `source.incremental-sync`
- `source.sync-page`
- `source.sync-detail`
- `source.health-check`
- `catalog.mark-stale`
- `cache.invalidate`

### 10.2 同步流程

```text
创建 sync_run
    ↓
同步/映射分类
    ↓
按页拉取源视频列表
    ↓
Zod 校验和标准化
    ↓
计算规范化原始数据 hash
    ↓
hash 未变化 → 更新 last_seen_run_id
hash 已变化 → 拉详情并事务 upsert 视频、线路和剧集
    ↓
记录单条成功或失败，不中断整个批次
    ↓
所有页面成功后将 sync_run 标记 completed
    ↓
根据 last_seen_run_id 标记真正失效的源内容
```

### 10.3 同步可靠性

- 同一来源同一类型的全量同步不得并发执行。
- Job ID 必须包含来源、任务类型和游标，避免重复入队。
- 每页任务和每条详情任务必须可安全重跑。
- 数据写入使用唯一键和事务 upsert，不依赖“先查询再插入”。
- 默认重试 5 次，指数退避并带 jitter；错误类型可覆盖默认设置。
- 4xx 数据错误通常不重试；429、超时、连接失败和 5xx 可重试。
- 达到最大次数后进入失败集合，并写入 `sync_runs.error_summary_jsonb`。
- 单条视频失败不得阻止其他视频同步。
- Worker 重启后未完成任务必须继续执行。
- BullMQ 完成和失败任务必须设置保留上限，避免 Redis 无限增长。
- 分页/详情子任务使用 BullMQ Flow 或持久化完成计数进行协调；不得仅凭队列暂时为空就把 `sync_run` 标记为完成。
- 创建 `sync_run`、生成任务和最终状态转换必须有明确的补偿与巡检逻辑，修复“数据库已写入但任务未成功入队”等中间状态。

### 10.4 安全下架规则

只有同时满足以下条件才能因为“源中不存在”而自动禁用源映射：

1. 本次全量同步状态为 `completed`。
2. 已成功遍历源声明的全部页面或游标。
3. 当前记录的 `last_seen_run_id` 不是本次运行 ID。
4. 达到配置的缺失宽限次数或宽限时间。

同步中断、源返回空列表、分页格式突变时，不得批量下架历史内容。

## 11. 播放解析与故障切换

### 11.1 播放流程

```text
接收 video_id + episode_id
    ↓
校验业务视频、剧集和访问频率
    ↓
查询全部已验证的 source_episode 映射
    ↓
过滤 disabled / offline / 熔断中的来源和线路
    ↓
按用户偏好、管理优先级、近期成功率和延迟排序
    ↓
读取 Redis 播放缓存
    ↓ 未命中
调用 Adapter.resolvePlayback()
    ↓ 失败
在总时间预算内尝试下一个候选
    ↓ 成功
校验协议、格式和过期时间，写入短时缓存
    ↓
创建 playback_session 并返回统一 PlaybackSource
```

### 11.2 约束

- 播放解析必须在 API 请求链路直接执行，不通过 BullMQ 等待结果。
- 单次请求最多尝试 3 个候选来源或线路。
- 总响应时间预算默认 5 秒，超过后返回 `PLAYBACK_UNAVAILABLE`。
- 只返回客户端明确支持的 `https` HLS、DASH 或 MP4 地址。
- `headers` 仅返回播放器真正需要的非管理型 Header。
- 不得把源 API 密钥、管理 Token 或可用于访问其他内容的凭据下发给客户端。
- 播放缓存键至少包含 `episode_id`、`source_code` 和 `line_code`。
- 缓存 TTL 不得超过 `expires_at`；无法判断有效期时使用保守短 TTL。
- 过期时间必须预留安全窗口，禁止在最后数秒仍返回即将失效的 URL。
- 列表和详情 API 不得返回实际播放 URL。

### 11.3 健康与熔断

健康状态应同时参考：

- 主动健康检查。
- Adapter 调用的超时和错误率。
- 播放解析成功率。
- Flutter 回传的首帧、播放中断和错误事件。

不得仅凭一次失败将整个源标记为离线。状态变更使用滚动窗口和阈值，并设置半开探测恢复流程。

## 12. 对 Flutter 的 REST API

### 12.1 统一约定

- 前缀：`/api/v1`。
- 请求和响应字段使用 `snake_case`。
- 时间使用 ISO 8601 UTC。
- ID 为不透明字符串，客户端不得解析其结构。
- 分页从 1 开始，`page_size` 默认 20、最大 50。
- 所有响应携带 `request_id`。

身份约定：

- 分类、列表、搜索和详情可以匿名访问，但必须限流。
- App 首次接入后端时调用安装注册接口，获得不透明的匿名安装 Token。
- 观看记录、播放解析和播放事件通过 `Authorization: Bearer <installation_token>` 关联匿名安装身份。
- `device_id` 只能作为兼容迁移字段或观测维度，不能作为身份凭证；服务端不得允许仅凭可猜测的 `device_id` 读取观看记录。
- Flutter 必须将安装 Token 存入平台安全存储，不得提交到日志或分析事件。

成功响应：

```json
{
  "data": {},
  "meta": {},
  "error": null,
  "request_id": "req_01J..."
}
```

失败响应：

```json
{
  "data": null,
  "meta": {},
  "error": {
    "code": "PLAYBACK_UNAVAILABLE",
    "message": "当前暂无可用播放源",
    "retryable": true
  },
  "request_id": "req_01J..."
}
```

### 12.2 必须提供的 App API

```http
POST /api/v1/installations
GET  /api/v1/categories
GET  /api/v1/videos?page=1&page_size=20&sort=latest
GET  /api/v1/videos?category_id={category_id}&page=1&page_size=20
GET  /api/v1/videos/search?q={keyword}&page=1&page_size=20
GET  /api/v1/videos/{video_id}
POST /api/v1/videos/{video_id}/episodes/{episode_id}/playback
GET  /api/v1/watch-history?page=1&page_size=20
PUT  /api/v1/watch-history/{video_id}/{episode_id}
POST /api/v1/playback-events
GET  /health/live
GET  /health/ready
```

安装注册响应返回 `installation_id` 和可轮换的 `installation_token`。Token 只保存哈希或使用可验证的短载荷签名，不在数据库和普通日志中保存可直接使用的明文凭据。

视频列表项至少返回：

```json
{
  "id": "vid_01J...",
  "title": "示例视频",
  "poster_url": "https://cdn.example.com/poster.jpg",
  "category_name": "国产剧",
  "remarks": "更新至第20集"
}
```

视频详情至少返回统一视频字段及按 `sort_order` 排序的剧集：

```json
{
  "id": "vid_01J...",
  "title": "示例视频",
  "poster_url": "https://cdn.example.com/poster.jpg",
  "description": "视频简介",
  "category_name": "国产剧",
  "remarks": "更新至第20集",
  "episodes": [
    {
      "id": "ep_01J...",
      "name": "第1集",
      "episode_no": 1
    }
  ],
  "available_sources": [
    {
      "code": "storm",
      "name": "暴风资源",
      "available": true
    }
  ]
}
```

`available_sources` 只是可用性摘要，不能包含源站 ID、内部定位字段或播放 URL。

### 12.3 播放响应示例

播放请求体中的来源偏好必须是可选提示，后端拥有最终选择权：

```json
{
  "preferred_source": "storm"
}
```

```json
{
  "data": {
    "playback_id": "pb_01J...",
    "url": "https://media.example.com/path/index.m3u8",
    "format": "hls",
    "expires_at": "2026-08-12T10:30:00Z",
    "source_code": "storm",
    "line_code": "line_a",
    "headers": {}
  },
  "meta": {},
  "error": null,
  "request_id": "req_01J..."
}
```

### 12.4 播放事件

支持以下事件：

```text
requested, resolved, initialized, first_frame,
progress, completed, error, abandoned
```

事件接口必须幂等或能容忍重复事件。高频 `progress` 事件应采样或聚合，不能每秒写数据库。

观看记录写入至少接受：

```json
{
  "position_seconds": 318,
  "duration_seconds": 2400,
  "completed": false,
  "client_updated_at": "2026-08-12T10:20:00Z"
}
```

服务端必须校验非负数、合理时长和剧集归属。离线重传产生乱序写入时，使用 `client_updated_at` 和服务端接收时间防止较旧进度覆盖较新进度。

### 12.5 错误码

| 错误码 | HTTP | 可重试 | 含义 |
|---|---:|---:|---|
| `VALIDATION_FAILED` | 400 | 否 | 请求参数错误 |
| `UNAUTHORIZED` | 401 | 否 | 安装凭证或 Admin 凭证无效 |
| `VIDEO_NOT_FOUND` | 404 | 否 | 视频不存在或已下架 |
| `EPISODE_NOT_FOUND` | 404 | 否 | 剧集不存在或已下架 |
| `SOURCE_TIMEOUT` | 502 | 是 | 第三方源超时 |
| `SOURCE_UNAVAILABLE` | 502 | 是 | 第三方源不可用 |
| `PLAY_URL_INVALID` | 502 | 是 | 源返回无效播放地址 |
| `PLAYBACK_UNAVAILABLE` | 503 | 是 | 所有候选来源均不可播放 |
| `RATE_LIMITED` | 429 | 是 | 请求过于频繁 |
| `INTERNAL_ERROR` | 500 | 视情况 | 未归类服务端错误 |

错误响应不得包含堆栈、SQL、第三方完整响应或密钥。

## 13. Admin 能力

第一阶段可以只提供受保护的 Admin API，不要求同时开发完整 Web 管理页面，但必须支持：

- 查看、新增和修改源的非敏感配置。
- 启用/禁用源和播放线路。
- 修改源和线路优先级。
- 手动触发全量或增量同步。
- 查看同步运行状态、游标、计数和错误摘要。
- 查看源健康状态及近期错误率。
- 下架或恢复业务视频。
- 合并或拆分 `source_videos` 与业务视频的映射。
- 清理相关缓存。

Admin API 使用独立鉴权和权限控制，不得依赖 Flutter 的 `device_id`。所有修改操作写入审计日志，包含操作者、时间、动作、对象和变更摘要。

## 14. 缓存与限流

### 14.1 缓存键建议

```text
categories:{catalog_version}                         10 分钟
videos:list:{query_hash}:{catalog_version}           30 秒～5 分钟
videos:search:{query_hash}:{catalog_version}         30 秒～2 分钟
video:detail:{video_id}:{catalog_version}             5 分钟
playback:{episode_id}:{source_code}:{line_code}       小于地址有效期
source:health:{source_code}:{line_code}               30 秒
```

缓存值必须带 schema version。同步写入后优先更新 `catalog_version` 实现批量失效，不使用生产环境全库 `KEYS` 扫描删除。

### 14.2 默认客户端限流

- 分类、列表和详情：按 IP + device ID。
- 搜索：按 IP + device ID，限制突发请求。
- 播放解析：按 device ID + episode ID，并设置最小重试间隔。
- 播放事件：按 playback ID + device ID。
- Admin：按账号和 IP 使用更严格限制。

具体阈值由环境配置，不得硬编码在 Controller。

## 15. 安全与合规

- 仅接入拥有明确授权的内容和 VOD 源。
- 接口可公开访问不代表内容可以商业使用。
- 不绕过 DRM、Referer、签名、Token 或其他源访问控制。
- 所有公开 API 使用 HTTPS；生产环境拒绝明文数据库和 Redis 连接，除非处于受控私网。
- 密钥存入部署平台 Secret，不提交仓库，不写普通日志。
- 日志默认脱敏 URL query、Authorization、Cookie、Token、签名参数和播放地址。
- 数据库使用最小权限账号，API 与 migration 可使用不同角色。
- 源配置必须执行 SSRF 防护和出站访问控制。
- 所有输入执行长度、类型和范围校验。
- 海报、简介等第三方内容在输出前进行必要清洗，禁止把未清洗 HTML 直接返回给 App。
- 保留内容禁用、投诉、来源追踪、人工恢复和审计能力。
- 观看记录按最小化原则保存；后续引入用户账号时必须提供删除能力。

## 16. 可观测性要求

### 16.1 日志字段

所有结构化日志至少包含适用字段：

```text
timestamp, level, service, environment, request_id,
trace_id, source_code, line_code, sync_run_id, job_id,
video_id, episode_id, playback_id, duration_ms,
error_code, retryable
```

不得记录完整播放 URL、源密钥、用户 Authorization 或完整第三方响应正文。

### 16.2 指标

至少提供：

- API 请求数、P50/P95/P99 延迟和各状态码比例。
- PostgreSQL/Redis 连接池使用情况。
- BullMQ waiting、active、delayed、failed 和 stalled 任务数量。
- 各源请求数、延迟、超时、429、5xx 和解析失败率。
- 各源同步最新成功时间、同步耗时和数据变更计数。
- 播放解析成功率、切源次数和总耗时。
- Flutter 回传的初始化、首帧和播放错误率。

### 16.3 告警建议

- 任一启用源连续健康检查失败。
- 某源超过两个计划周期未同步成功。
- 队列积压持续增长或出现 stalled jobs。
- 播放解析成功率在滚动窗口内显著下降。
- PostgreSQL/Redis 连接耗尽或磁盘空间不足。

## 17. 非功能要求

### 17.1 性能目标

在约定的基准环境和正常数据库负载下：

- 缓存命中的列表/详情 API P95 小于 200 ms。
- PostgreSQL 查询命中的列表/详情 API P95 小于 500 ms。
- 搜索 API P95 小于 800 ms。
- 播放解析 API 在成功源正常时 P95 小于 3 秒，总超时不超过 5 秒。
- 观看记录写入 P95 小于 500 ms。

以上时间不包含客户端网络传输，且必须通过可重复的压测脚本验证。

### 17.2 可用性与降级

- 单个 VOD 源离线不得影响目录浏览。
- 缓存不可用时，目录 API 可降级读取 PostgreSQL。
- Queue Redis 不可用时，API 仍可提供目录和已有映射的播放解析，但必须告警。
- PostgreSQL 不可用时 readiness 失败，避免继续接收无法正确处理的流量。
- 所有进程支持优雅关闭，停止接收新任务后等待活跃任务完成或安全释放锁。

### 17.3 数据一致性

- 业务数据库是目录、映射和观看记录的事实来源。
- Redis Cache 只存可重建数据。
- BullMQ Job 可以重复执行，业务写入必须幂等。
- 播放健康状态允许最终一致，不参与需要强事务保证的业务写入。

## 18. 配置要求

所有环境配置在启动时使用 Zod 校验，缺少强制配置必须直接启动失败。至少包括：

```text
NODE_ENV
PORT
DATABASE_URL
CACHE_REDIS_URL
QUEUE_REDIS_URL
LOG_LEVEL
OTEL_EXPORTER_OTLP_ENDPOINT
ADMIN_AUTH_* 或对应 Secret 引用
SOURCE_* 配置或 Source Secret 引用
```

不得通过 `NODE_ENV` 隐式改变危险业务规则。源限流、同步频率、超时、优先级和功能开关应采用有默认值、可审计的显式配置。

## 19. 本地开发与部署

### 19.1 Docker Compose 服务

```text
api
worker
postgres
redis-cache
redis-queue
```

可观测性环境可选增加：

```text
otel-collector
prometheus
grafana
```

### 19.2 容器要求

- API 和 Worker 使用同一镜像、不同启动命令。
- 使用多阶段构建，仅复制生产运行需要的产物。
- 以非 root 用户运行。
- 提供 liveness、readiness 和 graceful shutdown。
- 不在镜像中写入生产 Secret。
- 固定基础镜像主版本，并通过自动化安全扫描更新补丁版本。

### 19.3 数据保护

- PostgreSQL 必须定期备份并验证恢复流程。
- Queue Redis 必须启用 AOF 或托管服务的等价持久化能力。
- Cache Redis 不要求作为恢复来源。
- 数据库 migration 在 API/Worker 扩容前由独立部署步骤执行，禁止所有副本同时自动迁移。

## 20. 测试与质量门禁

### 20.1 必须通过的测试

- Adapter fixture 契约测试。
- Catalog、Playback、Sync 的核心单元测试。
- PostgreSQL schema、唯一键、事务和 upsert 集成测试。
- BullMQ 重试、去重、stalled recovery 和限流测试。
- API 统一响应、校验、错误码和限流 E2E 测试。
- 同一视频多源映射与播放切换测试。
- 同步中断不得错误批量下架的回归测试。
- 播放 URL 过期、安全窗口和缓存 TTL 测试。
- SSRF、日志脱敏和 Admin 鉴权测试。

### 20.2 CI 门禁

每次合并必须通过：

```text
pnpm lint
pnpm format:check
pnpm typecheck
pnpm test
pnpm test:integration
pnpm test:e2e
pnpm build
数据库 migration 校验
OpenAPI 变更校验
依赖及容器安全扫描
```

测试不得依赖公网第三方 VOD 源。真实源 smoke test 使用单独的受控环境、低频执行，并不得阻塞普通代码 CI。

## 21. 实施阶段与验收

### 阶段 A：工程基础

交付：

- 独立后端仓库、pnpm workspace、API/Worker 双入口。
- PostgreSQL、双 Redis、Docker Compose。
- 配置校验、日志、OpenTelemetry、health endpoint。
- 初始 migration 和 CI。

验收：本地一条命令启动全部依赖；API 和 Worker 能独立健康运行；测试和 build 全部通过。

### 阶段 B：单源闭环

交付：

- `StormAdapter` 和固定响应契约测试。
- 分类、视频、剧集、线路及同步模型。
- 全量同步、同步运行记录和安全下架逻辑。
- 分类、列表、搜索、详情 API。
- 播放解析、缓存和播放事件。

验收：Flutter 可完全通过 Jive API 完成首页、分类、搜索、详情和播放，不再访问暴风源或解析 `vod_play_url`。

### 阶段 C：多源与故障切换

交付：

- 第二个合法 VOD Adapter。
- 每源独立队列、限流、健康检查和熔断。
- 业务视频/剧集的经确认多源映射。
- 播放候选排序和自动切换。
- Admin 源管理、手动同步和映射管理 API。

验收：主动关闭优先源后，同一已映射剧集能够在总时间预算内切换到健康备用源；Flutter 无需修改页面或第三方解析逻辑。

### 阶段 D：生产加固

交付：

- 压测、监控仪表盘和告警。
- 备份恢复演练。
- Secret、SSRF、限流和日志脱敏审查。
- 源异常、Queue Redis 重启、Worker 重启和同步中断演练。
- 部署、回滚和运行手册。

验收：达到本文档性能目标；关键故障场景有可验证的降级、恢复和告警行为。

## 22. 完成定义

后端第一版只有同时满足以下条件才算完成：

1. Flutter 所有 VOD 网络访问已切换到 `/api/v1`。
2. Flutter 不再持有第三方源 URL、密钥或 `vod_play_url` 解析规则。
3. 至少一个源完成全量同步并通过契约测试，Adapter 框架能接入第二个源。
4. 列表和详情读取本地目录，第三方单源故障不影响浏览。
5. 播放地址按需解析、不会长期落库或出现在普通日志中。
6. 已验证的多源剧集可以按策略完成播放故障切换。
7. 同步任务具备幂等、断点、限流、重试、失败记录和安全下架机制。
8. Admin 可以禁用源、线路或内容，并审计关键变更。
9. OpenAPI、migration、测试、Docker、部署和运行文档齐全。
10. 内容授权、地区政策和应用商店合规已经由项目方确认。

## 23. 后续演进条件

只有出现明确需求和指标后再考虑升级：

- BullMQ 无法承载任务量或需要多个独立事件消费者时，再评估 Kafka。
- PostgreSQL 搜索无法满足多语言、复杂排序或规模要求时，再评估 OpenSearch。
- 同步成为跨天、跨系统、复杂补偿流程时，再评估 Temporal。
- 确实需要代理高并发媒体流量时，单独建设 Go/Rust 媒体网关。
- 确实需要转码和切片时，单独建设 FFmpeg Worker 与对象存储/CDN 链路。
- 单体出现可测量的独立扩容或团队边界问题时，再拆分微服务。

在上述条件出现前，不得为“未来可能需要”提前增加分布式系统复杂度。
