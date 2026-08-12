# 视频 App 后端架构与接口规范

## 1. 目标

本文档基于 `APP_REQUIREMENTS_V1.md`、`ARCHITECTURE.md` 和当前 VOD 源设计后端。核心目标是：

1. 为 Flutter 提供稳定、统一、与 VOD 厂商无关的 API。
2. 支持暴风资源以及后续更多 VOD 源。
3. 将第三方源的字段、分页、剧集格式和播放地址规则隔离在后端。

## 2. 总体架构

第一版采用“模块化单体 + VOD Source Adapter 适配层”。推荐技术栈为 TypeScript + NestJS/Fastify、PostgreSQL、Redis 和 Docker。

```text
Flutter App
    ↓ HTTPS / JSON
API Server
    ├── Catalog        视频、分类、搜索、详情
    ├── Playback       播放地址解析、重试、故障切换
    ├── History        观看记录和进度
    ├── Source         多 VOD 源适配和健康检查
    ├── Sync           元数据同步任务
    └── Admin          源配置和下架控制
          ↓
    PostgreSQL + Redis
          ↓
    VOD Source Adapters
      ├── StormAdapter
      ├── SourceBAdapter
      └── SourceCAdapter
```

### 2.1 关键原则

- Flutter 只请求自有 `/api/v1`，不直接请求第三方 VOD 源。
- 客户端不解析 `vod_play_url`，由后端适配器完成解析。
- 第三方源 ID 与 App 业务 ID 分离。
- 播放地址在用户点击播放时按需解析，不在列表接口中返回。
- API 返回统一业务模型，不暴露源站字段和内部配置。
- 所有源都实现同一个 Adapter 接口，新增源不修改 Flutter 页面。

## 3. 业务模型

### 3.1 业务视频

```ts
interface Video {
  id: string;                 // App 自有 ID，例如 vid_01J...
  title: string;
  posterUrl?: string;
  backdropUrl?: string;
  description?: string;
  categoryId?: string;
  categoryName?: string;
  year?: number;
  status?: string;
  remarks?: string;
  episodes: Episode[];
}
```

### 3.2 剧集和播放源

```ts
interface Episode {
  id: string;                 // App 自有 ID
  name: string;
  episodeNo?: number;
}

interface PlaybackSource {
  playbackId: string;
  url: string;
  format: 'hls' | 'dash' | 'mp4';
  sourceCode: string;
  expiresAt?: string;
  headers?: Record<string, string>;
}
```

客户端只接收 `PlaybackSource`，不接收 `vod_play_from`、`vod_play_url` 或第三方 `vod_id`。

### 3.3 ID 映射

```text
App video_id        = vid_01J...
source_code         = storm
source_video_id     = 暴风资源的 vod_id
App episode_id      = ep_01J...
source_episode_id   = 源剧集标识
```

这样同一个 App 视频可以有多个来源，也可以在不修改 Flutter 路由的情况下替换播放源。

## 4. VOD Source Adapter

每个源实现统一接口：

```ts
export interface VodSourceAdapter {
  readonly sourceCode: string;
  listVideos(input: ListVideosInput): Promise<SourceVideoPage>;
  searchVideos(input: SearchVideosInput): Promise<SourceVideoPage>;
  listCategories(): Promise<SourceCategory[]>;
  getVideoDetail(input: GetVideoDetailInput): Promise<SourceVideoDetail>;
  resolvePlayback(input: ResolvePlaybackInput): Promise<ResolvedPlayback>;
  healthCheck(): Promise<SourceHealthResult>;
}
```

适配器负责处理：

- 字段映射，如 `vod_name` 转换为 `title`。
- 源 ID 转换。
- 分页从 0 或 1 开始的差异。
- 分类层级和分类 ID 映射。
- `vod_play_url` 的剧集及分隔符解析。
- 多播放源选择。
- 源站超时、重试和错误转换。

### 4.1 暴风资源适配器

```text
StormAdapter
  listVideos      → /api.php/provide/vod/?ac=list&pg={page}
  searchVideos    → /api.php/provide/vod/?ac=list&wd={keyword}&pg={page}
  listCategories  → 列表响应中的 class
  getVideoDetail  → /api.php/provide/vod/?ac=detail&ids={vod_id}
  resolvePlayback → 解析详情中的 vod_play_url
```

适配器内部模型：

```ts
interface SourceVideo {
  sourceVideoId: string;
  title: string;
  posterUrl?: string;
  description?: string;
  sourceCategoryId?: string;
  sourceCategoryName?: string;
  remarks?: string;
  updatedAt?: string;
  episodes: SourceEpisode[];
}

interface SourceEpisode {
  sourceEpisodeId: string;
  name: string;
  rawPlayUrl?: string; // 只允许在 Source Module 内部使用
}
```

## 5. 多源存储和聚合

### 5.1 核心表

```text
sources
  id, code, name, base_url, adapter_name, priority,
  enabled, health_status, created_at, updated_at

videos
  id, title, poster_url, backdrop_url, description,
  category_id, year, status, remarks, normalized_title,
  created_at, updated_at

vod_source_videos
  id, video_id, source_id, source_video_id,
  source_category_id, source_updated_at, last_synced_at

categories
  id, name, parent_id, sort_order, enabled

source_categories
  source_id, source_category_id, category_id

episodes
  id, video_id, name, episode_no, sort_order,
  created_at, updated_at

vod_source_episodes
  episode_id, source_id, source_episode_id,
  raw_play_url, last_synced_at

watch_history
  owner_type, owner_id, video_id, episode_id,
  position_seconds, duration_seconds, completed, updated_at
```

`vod_source_videos` 的唯一键应为 `(source_id, source_video_id)`；`vod_source_episodes` 的唯一键应为 `(source_id, source_episode_id)`。

播放 URL 可能过期，不建议长期写入数据库；可以放在 Redis 中，缓存时间不能超过源地址有效期。

### 5.2 第一版去重策略

第一版先按来源存储和展示，不做复杂影视知识库匹配。后续去重可使用标准化标题、年份、类型、集数和外部版权 ID 生成候选，但不能只依赖标题。

### 5.3 播放源选择

```text
查询视频和剧集的源映射
  ↓
过滤 enabled 且 health_status=healthy 的源
  ↓
按 priority 升序尝试
  ↓
resolvePlayback()
  ↓ 失败
尝试下一个源
  ↓ 全部失败
返回 PLAYBACK_UNAVAILABLE
```

## 6. 元数据同步

第一版可先采用“请求时读取”，但建议尽快改成定时同步：

```text
定时任务
  → 调用源列表接口
  → 标准化字段
  → 按 source + source_video_id upsert
  → 更新视频、分类和剧集
  → 标记下架或失效数据
```

同步任务需要具备：

- 分页断点或可重跑能力。
- 单个视频失败不阻塞整批同步。
- 源站限流和重试。
- 原始数据哈希，内容无变化时跳过更新。
- 同步日志和统计。

## 7. 对 Flutter 的 API 规范

统一前缀：

```text
/api/v1
```

统一响应：

```json
{
  "data": {},
  "meta": {},
  "error": null,
  "request_id": "req_01J..."
}
```

统一错误：

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

### 7.1 分类

```http
GET /api/v1/categories
```

### 7.2 首页和分类视频

```http
GET /api/v1/videos?page=1&page_size=20&sort=latest
GET /api/v1/videos?category_id=cat_31&page=1&page_size=20
```

参数：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `page` | integer | 否 | 从 1 开始，默认 1 |
| `page_size` | integer | 否 | 默认 20，最大 50 |
| `category_id` | string | 否 | 统一分类 ID |
| `sort` | string | 否 | `latest` 或 `updated` |

响应中的视频只返回业务字段：

```json
{
  "data": [
    {
      "id": "vid_01J...",
      "title": "示例视频",
      "poster_url": "https://cdn.example.com/poster.jpg",
      "category_name": "国产剧",
      "remarks": "更新至第20集"
    }
  ],
  "meta": { "page": 1, "page_size": 20, "has_more": true },
  "error": null,
  "request_id": "req_01J..."
}
```

### 7.3 搜索

```http
GET /api/v1/videos/search?q=关键词&page=1&page_size=20
```

约束：

- `q` 去除首尾空格后至少 1 个字符。
- `normalized_title` 建索引。
- 相同关键词短时间内可使用 Redis 缓存。
- 客户端不传入第三方分类 ID 或源 ID。

### 7.4 视频详情

```http
GET /api/v1/videos/{video_id}
```

响应：

```json
{
  "data": {
    "id": "vid_01J...",
    "title": "示例视频",
    "poster_url": "https://cdn.example.com/poster.jpg",
    "description": "视频简介",
    "category_name": "国产剧",
    "remarks": "更新至第20集",
    "episodes": [
      { "id": "ep_01J...", "name": "第1集", "episode_no": 1 }
    ],
    "available_sources": [
      { "code": "storm", "name": "暴风资源", "available": true }
    ]
  },
  "meta": {},
  "error": null,
  "request_id": "req_01J..."
}
```

详情接口只返回播放源摘要，不返回实际播放地址。

### 7.5 获取播放地址

```http
POST /api/v1/videos/{video_id}/episodes/{episode_id}/playback
Content-Type: application/json
```

请求体：

```json
{
  "preferred_source": "storm",
  "device_id": "device_abc123"
}
```

响应：

```json
{
  "data": {
    "playback_id": "pb_01J...",
    "url": "https://example.com/path/index.m3u8",
    "format": "hls",
    "expires_at": "2026-08-11T15:30:00Z",
    "source_code": "storm",
    "headers": {}
  },
  "meta": {},
  "error": null,
  "request_id": "req_01J..."
}
```

说明：

- 第一版至少支持 `hls`，后续可扩展 `dash` 和 `mp4`。
- 如果地址有有效期，必须返回 `expires_at`。
- `headers` 只有播放器确实需要时才返回，不能包含源站管理密钥。
- `preferred_source` 不可用时，后端可以自动尝试其他健康源。
- Flutter 收到 `url` 后直接交给播放器。

### 7.6 观看记录

```http
GET /api/v1/watch-history?device_id=device_abc123&page=1&page_size=20
PUT /api/v1/watch-history/{video_id}/{episode_id}
```

请求体：

```json
{
  "device_id": "device_abc123",
  "position_seconds": 318,
  "duration_seconds": 2400,
  "completed": false
}
```

### 7.7 播放事件

```http
POST /api/v1/playback-events
```

请求体：

```json
{
  "playback_id": "pb_01J...",
  "video_id": "vid_01J...",
  "episode_id": "ep_01J...",
  "event": "error",
  "error_code": "SOURCE_TIMEOUT",
  "position_seconds": 318
}
```

## 8. 错误码

| 错误码 | 含义 | 可重试 |
|---|---|---:|
| `VIDEO_NOT_FOUND` | 视频不存在 | 否 |
| `EPISODE_NOT_FOUND` | 剧集不存在 | 否 |
| `SOURCE_TIMEOUT` | 源站超时 | 是 |
| `SOURCE_UNAVAILABLE` | 源站不可用 | 是 |
| `PLAY_URL_INVALID` | 播放地址格式错误 | 是 |
| `PLAYBACK_UNAVAILABLE` | 所有源均不可播放 | 是 |
| `RATE_LIMITED` | 请求过于频繁 | 稍后重试 |

## 9. 缓存、限流和健康检查

Redis 建议缓存：

```text
categories:{version}                    10 分钟
videos:list:{query_hash}                30 秒～5 分钟
video:detail:{video_id}                 5 分钟
playback:{episode_id}:{source_code}     不超过播放地址有效期
source:health:{source_code}             30 秒
```

限流建议：

- 列表和搜索按 IP 或设备 ID 限流。
- 播放地址按设备 ID + 剧集 ID 限流。
- 播放重试设置最小间隔。
- 对第三方源使用连接池、超时、熔断和退避重试。

定时健康检查至少验证：

- API 是否返回 HTTP 200。
- JSON 是否可解析。
- 列表是否包含基本字段。
- 详情是否包含剧集。
- 播放地址是否为合法 URL。

健康状态：`healthy`、`degraded`、`offline`。

## 10. 安全与合规

- 仅接入拥有合法授权的内容和 VOD 源。
- 不绕过 Referer、Token、DRM 或其他访问控制。
- 不在 Flutter 或普通日志中保存源 API 管理密钥。
- 自有 API 全部使用 HTTPS。
- 播放地址尽量使用短有效期，并避免写入普通日志。
- 保留内容下架、投诉和禁用源的能力。

## 11. 第一版实现边界

第一版实现：

- 一个 API Server。
- PostgreSQL 和 Redis。
- `StormAdapter`。
- 首页、分类、搜索、详情、播放和观看记录接口。
- 手动或定时元数据同步。
- 基础源健康检查和播放失败切换。

暂不实现：

- 复杂推荐系统。
- DRM 服务。
- 视频转码和自建 CDN。
- 用户会员和支付。
- 多地域部署和多服务拆分。
- 复杂影视资料库去重。

## 12. 新增 VOD 源流程

1. 在 `sources` 增加源配置。
2. 新建实现 `VodSourceAdapter` 的适配器。
3. 编写列表、详情、分类和播放地址解析测试。
4. 将源字段映射为统一模型。
5. 执行元数据同步。
6. 运行健康检查。
7. 设置源优先级和启用状态。
8. 不修改 Flutter API 和页面代码。

建议目录：

```text
src/modules/sources/
├── source.interface.ts
├── source.registry.ts
├── storm/
│   ├── storm.adapter.ts
│   ├── storm.client.ts
│   ├── storm.parser.ts
│   └── storm.adapter.spec.ts
└── another-source/
    ├── another-source.adapter.ts
    └── another-source.adapter.spec.ts
```

## 13. 与 Flutter 架构的对应关系

```dart
VideoRepository
  → GET /api/v1/videos
  → GET /api/v1/videos/{id}

PlayerRepository
  → POST /api/v1/videos/{id}/episodes/{episodeId}/playback

WatchHistoryRepository
  → GET /api/v1/watch-history
  → PUT /api/v1/watch-history/{videoId}/{episodeId}
```

未来切换或增加 VOD 源时，只需增加后端 Adapter、同步数据并调整源优先级，Flutter 页面、Provider、播放器和业务模型无需改变。

## 14. 开发前的关键验证

先用一个真实视频 ID 验证：

```text
GET https://bfzyapi.com/api.php/provide/vod/?ac=detail&ids={vod_id}
```

必须确认：

- 是否返回 `vod_play_url`。
- 剧集和多源分隔符是什么。
- 播放地址是否为 `.m3u8`。
- 是否需要额外 Header。
- 是否有过期时间。
- Android 和 iOS 真机是否都能播放。

同时，正式接入前必须确认视频内容和播放源具备合法授权；接口可访问不等于可以商业使用。
