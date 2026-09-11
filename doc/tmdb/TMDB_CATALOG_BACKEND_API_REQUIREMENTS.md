# Jive TMDB Catalog 后端需求与接口文档

> 文档状态：待后端评审  
> 目标版本：V1  
> 客户端：Jive Flutter Android / iOS  
> 关联文档：[`TMDB_CURATED_FEEDS_REQUIREMENTS.md`](TMDB_CURATED_FEEDS_REQUIREMENTS.md)  
> 当前客户端数据版本：`schemaVersion = 1`

## 1. 文档目的

本文供后端开发、部署和联调使用，定义 Jive 的 TMDB Catalog 服务需求、数据口径、HTTP 接口、缓存与降级策略、安全约束和验收标准。

服务的核心目标不是开放一个通用 TMDB 反向代理，而是向 Jive 提供稳定、可缓存、参数受控的策展榜单。服务端持有 TMDB Token，Jive 不直接请求 TMDB。

本文中的关键词含义：

- **必须（MUST）**：上线前必须满足。
- **建议（SHOULD）**：没有明确原因时应满足。
- **可选（MAY）**：可在后续版本实现。

## 2. 背景与业务边界

Jive 首页包含四个 Feed：

```text
默认 | 最新 | 最热 | 高分
```

- “默认”来自当前 VOD 源，不属于本服务。
- “最新 / 最热 / 高分”由本服务根据 TMDB 数据生成。
- 本服务只负责发现、排序和展示元数据，不返回播放地址。
- Jive 收到榜单后，继续在当前选中的 VOD 源中实时搜索并严格匹配。
- 只有匹配成功的条目才在客户端展示并进入现有详情、播放、缓存和下载链路。

最终链路：

```text
TMDB API
  ↓
Jive TMDB Catalog 服务
  ├─ 缓存
  ├─ 最新成功快照
  └─ 海报对象存储/CDN（推荐）
  ↓
Jive 客户端
  ↓
当前 VOD 源实时匹配
  ↓
可播放卡片
```

## 3. 项目范围

### 3.1 V1 必须实现

1. 服务端安全保存 TMDB API Read Access Token。
2. 生成“最新 / 最热 / 高分”三个 Feed。
3. 每个 Feed 包含：全部、电影、电视剧、动漫、综艺五个分组。
4. 提供与 Jive 当前 `TmdbCatalogSnapshot` 兼容的 JSON。
5. 提供 `manifest.json` 和三个 Feed JSON 静态入口。
6. 提供受控的 Catalog 查询接口。
7. 使用缓存、请求合并和定时预热，避免按用户请求重复扫描 TMDB。
8. TMDB 不可用时返回最近一次成功快照。
9. 正确处理上游超时、`429` 和 `5xx`。
10. 提供健康检查、结构化日志和基本监控指标。
11. 所有外部接口只允许 HTTPS。
12. 对请求参数、并发、频率和响应大小设置硬限制。

### 3.2 V1 不包含

- VOD 搜索、匹配、详情或播放地址代理。
- TMDB 用户登录、收藏、评分和 Session。
- 任意 TMDB path/query 的透传代理。
- 豆瓣、猫眼、灯塔等非官方数据抓取。
- 个性化推荐。
- 真正的月度热门榜。
- 向客户端暴露 TMDB Token。

### 3.3 后续可选能力

- 获取 TMDB alternative titles，提升 VOD 搜索命中率。
- 单个电影或电视剧详情接口。
- 按 TMDB ID 增量刷新。
- Bangumi 动漫别名补充。
- 自建月榜热度采样。
- 多语言榜单。

## 4. 部署要求

### 4.1 推荐地域

源站建议部署在香港、日本或新加坡，并在部署前验证该出口可以稳定访问：

```text
https://api.themoviedb.org
https://image.tmdb.org
```

不建议默认部署在中国大陆后再直接访问 TMDB，因为其上游连接可能与国内客户端遇到相同的网络问题。

如使用中国大陆服务器、自定义域名、API 网关或境内 CDN，部署方必须自行完成适用的 ICP/APP 备案及其他合规手续。

### 4.2 推荐组件

V1 可以采用单机轻量实现：

```text
Nginx/Caddy
  ↓
Catalog API 进程
  ├─ 进程内缓存
  ├─ 本地快照目录
  └─ 定时刷新任务
```

生产规模扩大后可升级为：

```text
CDN/WAF
  ↓
负载均衡
  ↓
Catalog API 多实例
  ├─ Redis
  └─ 对象存储
```

实现语言不限。Go、Node.js、Dart 均可，但生成规则和 DTO 必须与本文一致。

## 5. 配置与 Secret

建议环境变量：

| 名称 | 必填 | 示例 | 说明 |
| --- | --- | --- | --- |
| `TMDB_READ_ACCESS_TOKEN` | 是 | `***` | TMDB API Read Access Token |
| `TMDB_API_BASE_URL` | 否 | `https://api.themoviedb.org/3` | 默认使用官方地址 |
| `CATALOG_PUBLIC_BASE_URL` | 是 | `https://api.hey-rickytse.com` | 对外 API 根地址 |
| `CATALOG_SNAPSHOT_DIR` | 是 | `/var/lib/jive/tmdb/v1` | 最新成功快照目录 |
| `CATALOG_REFRESH_ENABLED` | 否 | `true` | 是否启用定时预热 |
| `CATALOG_LOG_LEVEL` | 否 | `info` | 日志级别 |
| `POSTER_PUBLIC_BASE_URL` | 否 | `https://cdn.hey-rickytse.com/tmdb` | 自有海报 CDN 根地址 |

安全要求：

- Token 必须通过 Secret 管理或环境变量注入。
- Token 不得写入 Git、镜像、响应、异常消息或访问日志。
- 不要求同时配置 TMDB v3 API Key。
- 日志必须对 `Authorization`、Cookie 和查询中的敏感字段脱敏。

## 6. 榜单业务规则

### 6.1 公共规则

- TMDB `language` 固定为 `zh-CN`。
- 支持参数的端点固定传 `include_adult=false`。
- 返回条目必须二次过滤 `adult == true`。
- 无有效 TMDB ID，或本地标题与原始标题均为空的条目必须丢弃。
- 使用 `mediaType + tmdbId` 去重。
- 每个 Feed 的每个分组最多返回 200 条。
- 条目全局 ID 格式：`tmdb:{mediaType}:{tmdbId}`。
- `mediaType` 仅允许 `movie` 或 `tv`。
- 排名从 1 开始，必须在每个分组内独立计算。

### 6.2 分类映射

分类按以下优先级互斥判定：

1. 包含 TMDB Genre `16 Animation`：`animation`。
2. TV 包含 `10763 News`、`10764 Reality`、`10767 Talk` 任一项：`variety`。
3. 其余电影：`movie`。
4. 其余电视剧：`tv`。

分组固定为：

```text
all | movie | tv | animation | variety
```

`all` 包含上述四个业务分类的合并结果。同一条目不得同时出现在 `movie/tv` 和 `animation/variety` 中。

### 6.3 最新 `latest`

#### 电影

调用 TMDB Discover Movie：

```text
sort_by=popularity.desc
primary_release_date.gte=当前 UTC 日期 - 180 天
primary_release_date.lte=当前 UTC 日期
include_adult=false
include_video=false
language=zh-CN
```

#### 电视剧

调用 TMDB Discover TV：

```text
sort_by=popularity.desc
first_air_date.gte=当前 UTC 日期 - 180 天
first_air_date.lte=当前 UTC 日期
include_adult=false
language=zh-CN
```

同时调用 `tv/on_the_air`，补充首播较早但近期推出新一季的电视剧。

对 `on_the_air` 候选补查 TV Detail，并读取：

```text
last_episode_to_air.air_date    → sortDate
last_episode_to_air.season_number → latestSeasonNumber
```

最终规则：

- `popularity >= 10`。
- 不包含未来上映/首播日期。
- 按 `sortDate` 降序。
- 电影使用 `release_date`。
- 新电视剧使用 `first_air_date`。
- 老剧新季使用 `last_episode_to_air.air_date`。

### 6.4 最热 `popular`

调用：

```text
/trending/movie/week
/trending/tv/week
```

合并后按 `popularity` 降序。V1 使用周榜，不声明为月榜。

### 6.5 高分 `top_rated`

电影和电视剧分别调用 Discover：

```text
sort_by=vote_average.desc
vote_average.gte=7.0
vote_count.gte=200
include_adult=false
language=zh-CN
```

合并排序：

1. `vote_average` 降序。
2. 评分相同按 `vote_count` 降序。
3. 仍相同时保持 TMDB 原始顺序。

## 7. 数据模型

### 7.1 CatalogItem

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `tmdbId` | integer | 是 | 正整数 TMDB ID |
| `mediaType` | string | 是 | `movie` 或 `tv` |
| `category` | string | 是 | `movie/tv/animation/variety` |
| `localizedTitle` | string | 是 | `zh-CN` 标题；缺失时回退原始标题 |
| `originalTitle` | string | 是 | 原始标题；允许空字符串 |
| `aliases` | string[] | 是 | V1 可为空数组 |
| `releaseDate` | string | 是 | `YYYY-MM-DD` 或空字符串 |
| `sortDate` | string | 是 | 榜单排序日期，格式同上 |
| `latestSeasonNumber` | integer | 否 | 最新季度，正整数 |
| `rating` | number | 是 | TMDB `vote_average` |
| `voteCount` | integer | 是 | TMDB `vote_count` |
| `popularity` | number | 是 | TMDB `popularity` |
| `posterPath` | string | 是 | TMDB path、完整 HTTPS 地址或空字符串 |
| `rank` | integer | 否 | 动态分页接口返回时建议包含；静态快照由客户端按分组顺序计算 |

### 7.2 Snapshot

为兼容当前 Flutter 客户端，静态文件和 V1 Catalog API 的 `data` 必须保留以下核心结构：

```json
{
  "schemaVersion": 1,
  "revision": "20260908T120000Z",
  "feed": "latest",
  "generatedAt": "2026-09-08T12:00:00Z",
  "expiresAt": "2026-09-08T18:00:00Z",
  "stale": false,
  "groups": {
    "all": ["tmdb:movie:123"],
    "movie": ["tmdb:movie:123"],
    "tv": [],
    "animation": [],
    "variety": []
  },
  "items": {
    "tmdb:movie:123": {
      "tmdbId": 123,
      "mediaType": "movie",
      "category": "movie",
      "localizedTitle": "示例电影",
      "originalTitle": "Example Movie",
      "aliases": [],
      "releaseDate": "2026-09-01",
      "sortDate": "2026-09-01",
      "rating": 7.8,
      "voteCount": 1200,
      "popularity": 93.5,
      "posterPath": "/example.jpg"
    }
  }
}
```

兼容约束：

- `feed` 只允许 `latest/popular/top_rated`；文件名仍使用 `top-rated.json`。
- `groups` 内存放全局 ID，不重复嵌入条目。
- `items` 的 key 必须等于条目的全局 ID。
- `revision` 使用 UTC 时间：`yyyyMMddTHHmmssZ`。
- 新增字段必须保持向后兼容；客户端会忽略未知字段。
- 不得静默改变既有字段类型或语义；破坏性变更必须升级 `schemaVersion` 和 URL 版本。

## 8. HTTP API

API Base URL 示例：

```text
https://api.hey-rickytse.com/api/tmdb/v1
```

### 8.1 查询 Catalog

```http
GET /api/tmdb/v1/catalog?feed={feed}
```

#### Query 参数

| 参数 | 必填 | 允许值 | 说明 |
| --- | --- | --- | --- |
| `feed` | 是 | `latest/popular/top_rated` | 榜单类型 |

V1 一次返回该 Feed 的五个完整分组，客户端继续在本地切换分类并扫描最多 24 个候选。服务端暂不提供 `scope/page/pageSize`，避免改变客户端排名和自动补位语义。

#### 请求示例

```http
GET /api/tmdb/v1/catalog?feed=popular HTTP/1.1
Host: api.hey-rickytse.com
Accept: application/json
Accept-Encoding: gzip, br
If-None-Match: "20260908T120000Z-popular"
```

#### 成功响应

```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Cache-Control: public, max-age=300, stale-while-revalidate=3600
ETag: "20260908T120000Z-popular"
X-Catalog-Revision: 20260908T120000Z
X-Catalog-Stale: false
```

响应 Body 为第 7.2 节的完整 Snapshot，不额外包裹 `data`，以便客户端直接复用当前解析逻辑。

#### 未变化响应

```http
HTTP/1.1 304 Not Modified
ETag: "20260908T120000Z-popular"
```

#### 参数错误

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json; charset=utf-8

{
  "error": {
    "code": "INVALID_ARGUMENT",
    "message": "feed 仅支持 latest、popular、top_rated",
    "requestId": "01J..."
  }
}
```

### 8.2 获取 Manifest

```http
GET /api/tmdb/v1/manifest
```

响应：

```json
{
  "schemaVersion": 1,
  "language": "zh-CN",
  "feeds": {
    "latest": {
      "revision": "20260908T120000Z",
      "generatedAt": "2026-09-08T12:00:00Z",
      "expiresAt": "2026-09-08T18:00:00Z",
      "path": "latest.json"
    },
    "popular": {
      "revision": "20260908T120000Z",
      "generatedAt": "2026-09-08T12:00:00Z",
      "expiresAt": "2026-09-08T18:00:00Z",
      "path": "popular.json"
    },
    "top_rated": {
      "revision": "20260908T120000Z",
      "generatedAt": "2026-09-08T12:00:00Z",
      "expiresAt": "2026-09-09T12:00:00Z",
      "path": "top-rated.json"
    }
  }
}
```

### 8.3 静态兼容入口

必须继续发布：

```text
GET /data/tmdb/v1/manifest.json
GET /data/tmdb/v1/latest.json
GET /data/tmdb/v1/popular.json
GET /data/tmdb/v1/top-rated.json
```

静态文件与 Catalog API 必须来自同一份已验证快照，不能使用两套独立生成逻辑。

静态发布顺序必须是：

1. 生成到临时 revision 目录。
2. 完成 JSON Schema 和业务校验。
3. 上传三个 Feed 文件。
4. 最后原子替换 `manifest.json`。

发布失败时保留上一 revision。

### 8.4 健康检查

```http
GET /health/live
GET /health/ready
```

- `/health/live`：进程存活即返回 200，不查询 TMDB。
- `/health/ready`：服务可读取三个最近成功快照时返回 200。
- TMDB 临时不可访问但仍有有效旧快照时，`ready` 应保持 200，并在响应中标记 degraded。

示例：

```json
{
  "status": "degraded",
  "tmdbReachable": false,
  "snapshotAvailable": true,
  "latestRevision": "20260908T120000Z"
}
```

健康检查响应不得包含 Token、内部异常堆栈或服务器绝对路径。

## 9. 错误规范

| HTTP 状态 | `code` | 场景 |
| --- | --- | --- |
| 400 | `INVALID_ARGUMENT` | 参数缺失或不在白名单 |
| 404 | `NOT_FOUND` | 不存在的受控资源 |
| 429 | `RATE_LIMITED` | 客户端触发服务限流 |
| 500 | `INTERNAL_ERROR` | 未分类内部错误 |
| 502 | `UPSTREAM_ERROR` | TMDB 返回不可恢复错误且无快照 |
| 503 | `CATALOG_UNAVAILABLE` | 无可用快照且暂时无法生成 |
| 504 | `UPSTREAM_TIMEOUT` | TMDB 超时且无快照 |

统一结构：

```json
{
  "error": {
    "code": "CATALOG_UNAVAILABLE",
    "message": "榜单暂时不可用，请稍后重试",
    "requestId": "01J..."
  }
}
```

生产环境不得把 TMDB 原始响应、内部域名、调用栈或 Secret 返回给客户端。

## 10. 缓存、预热与降级

### 10.1 建议时间

| 数据 | 新鲜期 | 最大旧快照使用期 | 定时预热建议 |
| --- | --- | --- | --- |
| `latest` | 6 小时 | 48 小时 | 每 4 小时 |
| `popular` | 2 小时 | 24 小时 | 每 1 小时 |
| `top_rated` | 24 小时 | 7 天 | 每 12 小时 |
| TV Detail | 24 小时 | 7 天 | 按需 |
| 上游失败/空结果 | 3～5 分钟 | 不适用 | 负缓存 |

### 10.2 请求处理顺序

```text
收到请求
  ↓
内存/Redis 中有新鲜快照？── 是 → 返回
  ↓ 否
有可接受的旧快照？──────── 是 → 返回 stale=true，并异步刷新
  ↓ 否
同步生成（同一 cache key 只允许一个任务）
  ├─ 成功 → 校验、持久化、返回
  └─ 失败 → 返回标准错误
```

必须实现 single-flight/request coalescing：相同 Feed 并发失效时，只允许一个任务访问 TMDB，其余请求等待或获得旧快照。

普通客户端请求不得提供“绕过所有服务端缓存”的参数。客户端下拉刷新最多绕过本地缓存，不能强制对 TMDB 发起完整重建。

### 10.3 上游重试

- 单次 TMDB 请求超时建议 10 秒，上限不超过 30 秒。
- 仅对网络错误、`429` 和 `5xx` 重试。
- 总尝试次数不超过 3 次。
- `429` 优先遵循 `Retry-After`。
- 退避建议加入随机抖动。
- `400/401/403/404` 默认不自动重试。
- 全局 TMDB 并发建议限制为 4～8。

## 11. 海报方案

仅代理 JSON 不足以保证国内海报可用，因为当前客户端会访问 `image.tmdb.org`。

### 11.1 推荐方案：入榜海报预取

生成榜单时只同步实际入榜的 `w500` 海报至对象存储/CDN：

```text
https://cdn.hey-rickytse.com/tmdb/w500/{poster-file}
```

服务端在 `posterPath` 中直接返回完整 HTTPS URL。当前 Jive 模型已兼容完整 HTTPS 地址。

要求：

- 只接受由 TMDB 返回的合法 `poster_path`。
- 不允许客户端传任意远程 URL让服务端下载。
- 校验 MIME、文件大小和下载超时。
- 下载失败时保留原 TMDB path，客户端仍可回退 VOD 海报。
- 缓存必须设置刷新和淘汰策略，不得永久保存。

### 11.2 可选方案：受限图片代理

若使用动态代理，接口只能接受固定尺寸和安全文件名：

```http
GET /media/tmdb/{size}/{fileName}
```

其中：

- `size` 白名单：`w342/w500/original`。
- `fileName` 只允许安全字符及 `.jpg/.png/.webp` 后缀。
- 上游域名固定为 `image.tmdb.org`。
- 必须防止路径穿越、开放代理和 SSRF。

## 12. 安全与滥用防护

- 禁止实现 `/proxy?url=` 或 `/proxy?path=` 一类任意透传接口。
- 所有枚举、日期、页数和字符串长度必须在服务端校验。
- 公共查询接口建议按 IP 每分钟限制 60～120 次，并设置全局限流。
- 对单次响应设置大小上限，建议未压缩不超过 1 MiB。
- 启用 gzip 或 Brotli。
- 应设置合理的 CORS；原生 App 不依赖 CORS，但 Web 管理端不得使用 `*` 携带凭据。
- App 内嵌固定 Secret 不能作为主要安全措施，因为安装包可被逆向。
- 如需识别客户端，可使用版本号、设备证明或签名请求，但不能替代限流和参数白名单。
- 管理刷新接口不得公开；如必须提供，应放在内网或使用独立的强认证。

## 13. TMDB 授权与署名

上线前必须由产品/运营确认 TMDB 使用性质和授权范围：

- 非商业用途仍需按 TMDB 要求署名。
- 商业用途需与 TMDB 确认商业许可。
- Jive 的 About/Credits 页面应使用 TMDB 批准的 Logo。
- 页面应展示 TMDB 要求的非背书声明。
- TMDB 数据和图片缓存应设置刷新与删除策略，最长保存时间不得违反其现行条款。
- 服务终止使用 TMDB 或授权失效时，应支持清理相关缓存和对象存储文件。

后端应记录每个快照的生成时间和来源版本，以便处理内容更新、删除和合规清理。

参考：

- TMDB API 文档：https://developer.themoviedb.org/docs/getting-started
- TMDB Rate Limiting：https://developer.themoviedb.org/docs/rate-limiting
- TMDB FAQ/Attribution：https://developer.themoviedb.org/docs/faq
- TMDB API Terms：https://www.themoviedb.org/api-terms-of-use

## 14. 日志、指标与告警

### 14.1 结构化日志字段

建议至少包含：

```text
timestamp
level
requestId
route
feed
statusCode
durationMs
cacheStatus      HIT | MISS | STALE | REVALIDATED
revision
upstreamStatus
upstreamDurationMs
retryCount
itemCount
errorCode
```

不得记录 Token 和完整授权请求头。

### 14.2 指标

- Catalog 请求数、成功率、P50/P95/P99。
- 缓存命中率和 stale 返回比例。
- TMDB 请求数、错误率、`429` 次数和延迟。
- 每次生成各分组条目数量。
- 海报同步成功率。
- 最近成功 revision 及距当前时间。

### 14.3 建议告警

- 任一 Feed 连续两次生成失败。
- 任一核心分组为空。
- 某分组数量较上次下降超过 50%。
- 最近成功快照超过最大旧快照使用期。
- TMDB `401/403` 出现，可能代表 Token 失效。
- 5 分钟内 TMDB `429` 超过阈值。

## 15. 快照生成与校验

写入或发布前必须校验：

1. `schemaVersion == 1`。
2. `feed` 合法且与目标文件一致。
3. `revision` 非空。
4. 五个分组全部存在。
5. 每个分组不超过 200 条且内部 ID 不重复。
6. 每个分组引用的 ID 都存在于 `items`。
7. `items` 非空，`all` 非空。
8. `items` 的 key 等于条目的全局 ID。
9. `tmdbId > 0`。
10. 标题至少有一个非空值。
11. 日期字段格式合法或为空。
12. 分类、媒体类型和全局 ID 相互一致。

禁止用空榜单覆盖上一份正常快照。

## 16. 性能与可用性目标

V1 建议目标：

| 项目 | 目标 |
| --- | --- |
| 缓存命中响应 P95 | 小于 300 ms（不含客户端跨境网络） |
| 静态 JSON 可用性 | 不低于 99.9% |
| Catalog API 可用性 | 不低于 99.5% |
| 正常快照响应 | 100% 可 gzip/Brotli |
| 单 Feed 未压缩大小 | 不超过 1 MiB |
| 上游并发 | 默认不超过 8 |
| 空榜单发布 | 0 次 |

这些是工程目标，不代表 TMDB 自身 SLA。

## 17. 与 Jive 的联调约定

当前客户端文件：

- `lib/domain/tmdb_catalog.dart`
- `lib/data/catalog/tmdb_catalog_repository.dart`
- `lib/features/home/curated_feed_controller.dart`

联调时应验证：

1. Flutter 能直接解析三个 API Snapshot。
2. 未知新增字段不会导致解析失败。
3. revision 与 manifest 一致。
4. 中文、日文、韩文和 emoji 标题 UTF-8 正常。
5. TMDB 海报失败时能回退 VOD 海报。
6. 服务器断网时客户端能使用本地缓存。
7. 服务端和客户端缓存均为空时能降级至 App 内置资产。
8. 切换 VOD 源不会触发服务端重建 TMDB 榜单，只会触发客户端重新匹配。
9. 客户端单批仍遵守：首轮 12 条、最多扫描 24 条、VOD 搜索最多 30 次、并发最多 3。

## 18. 测试要求

### 18.1 单元测试

- 三种 Feed 的过滤和排序。
- 分类互斥映射。
- 去重。
- 老剧新季 `sortDate/latestSeasonNumber`。
- 高分阈值。
- `popularity >= 10`。
- Snapshot 序列化和校验。
- 错误码映射。
- ETag/304。
- 缓存新鲜、过期、stale 和 single-flight。
- `429/5xx/timeout` 重试。

### 18.2 集成测试

- 使用 TMDB Mock Server，禁止测试依赖真实 TMDB 稳定性。
- 验证生成任务原子发布。
- 验证旧快照降级。
- 验证 Token 不出现在日志和响应中。
- 验证恶意 path、超长参数和非法枚举被拒绝。
- 验证海报路径穿越与 SSRF 防护。

### 18.3 线上验收

- 在中国大陆至少使用移动、联通、电信网络各抽测一次。
- 抽测 API JSON 和海报首屏成功率、DNS、TLS、P95 延迟。
- 连续运行至少 48 小时，确认定时刷新和降级正常。
- 人工抽查四类内容及最新季度准确性。

## 19. 发布阶段

### 阶段 A：静态 JSON 上线

- 将现有生成器迁移到服务器或 CI。
- 定时生成并原子上传四个 JSON。
- 配置 HTTPS、缓存头、压缩和监控。
- Jive 启用 `RemoteTmdbCatalogRepository`。

### 阶段 B：Catalog API

- 抽取生成器的榜单规则为共享 Catalog Engine。
- 实现 `/api/tmdb/v1/catalog`、manifest 和健康检查。
- 加入缓存、single-flight、stale 降级和限流。
- 静态文件与 API 共用同一快照。

### 阶段 C：海报国内链路

- 接入对象存储/CDN。
- 预取实际入榜海报。
- 返回自有 HTTPS 海报 URL。
- 建立刷新、淘汰和合规删除机制。

### 阶段 D：增强匹配数据

- alternative titles。
- 详情增量更新。
- 命中率统计和质量监控。

## 20. V1 验收清单

- [ ] Token 仅存在服务端 Secret。
- [ ] 三种 Feed、五种分组均能生成。
- [ ] 榜单规则与第 6 节一致。
- [ ] API Snapshot 可被当前 Flutter 模型直接解析。
- [ ] 四个静态 JSON 可通过正式 HTTPS 域名访问。
- [ ] manifest 最后原子发布。
- [ ] ETag、304、压缩和缓存头生效。
- [ ] 同 Feed 并发失效只产生一次上游刷新。
- [ ] TMDB 超时、429 和 5xx 能重试并降级。
- [ ] 空榜单不会覆盖正常快照。
- [ ] 海报具有国内可用方案或明确保留 VOD 海报降级。
- [ ] 有健康检查、结构化日志、指标和告警。
- [ ] 已完成 TMDB About/Credits 署名。
- [ ] 已完成适用的部署、备案、授权和内容合规评估。
- [ ] 已通过大陆多运营商真实网络抽测。

## 21. 后端待确认项

后端评审时需要确认：

1. 首发地域和云厂商。
2. 正式 API 与静态数据域名。
3. 单机文件快照还是对象存储。
4. 进程内缓存还是 Redis。
5. 海报预取是否纳入 V1。
6. 三个 Feed 的实际刷新周期。
7. 是否沿用当前每个上游端点最多 10 页。
8. Catalog API 是否与现有 V1 静态快照同时上线。
9. 监控和告警接收渠道。
10. TMDB 商业/非商业授权结论和数据清理负责人。
