# Jive 产品与后端需求

## 1. 文档状态

| 项目         | 内容                              |
| ------------ | --------------------------------- |
| 当前版本     | V1                                |
| 目标客户端   | Jive Flutter Android/iOS App      |
| 后端定位     | VOD 源目录服务                    |
| 数据访问方式 | 客户端获取源列表后直接请求 VOD 源 |
| 后续版本     | V2 引入个人账号及云端个人数据     |

本文件是当前项目需求的权威说明。旧文档中关于后端同步 VOD 元数据、解析播放地址、代理内容目录、播放切源和 Worker 的设计不再适用于 V1。

## 2. 产品目标

V1 的目标是以最小后端完成移动端 VOD MVP：

1. 后端维护并返回当前可用的 VOD 源地址。
2. Flutter 客户端获取源列表。
3. Flutter 客户端直接向选定的 VOD 源请求分类、列表、搜索、详情和播放信息。
4. 收藏、最近观看和播放进度保存在设备本地。
5. V1 不要求注册、登录或多设备同步。

## 3. V1 系统边界

```text
Jive Flutter App
    │
    ├── GET /api/v1/vod-sources ──> Jive Backend
    │
    └── 分类 / 列表 / 搜索 / 详情 / 播放 ──> VOD Source
```

后端只负责 VOD 源目录，不位于视频业务请求链路中。

### 3.1 后端负责

- 保存 VOD 源的公开连接信息。
- 返回全部已启用的 VOD 源。
- 提供稳定的源标识、名称、地址、优先级和能力描述。
- 提供 liveness/readiness 健康检查。
- 对源列表接口执行基础缓存、限流和结构化日志记录。
- 保证响应中不包含密钥、管理凭证或其他 Secret。

### 3.2 Flutter 客户端负责

- 启动时获取 VOD 源列表，并使用本地缓存作为短时降级。
- 根据优先级、用户选择或客户端策略选择 VOD 源。
- 直接调用 VOD 源的分类、列表、搜索和详情接口。
- 解析不同 VOD 源的字段、分页、分类、线路、剧集和播放地址格式。
- 处理超时、限流、无效数据、源切换和播放失败重试。
- 仅接受支持的 HTTPS 播放地址和播放格式。
- 在本地保存收藏、最近观看和播放进度。

### 3.3 V1 后端明确不负责

- 请求或代理 VOD 分类、列表、搜索和详情。
- 解析 `vod_play_url` 或返回播放地址。
- 同步或保存视频、分类、剧集和播放线路。
- 运行 VOD 同步、健康探测或维护 Worker。
- 使用 BullMQ 或 Queue Redis。
- 为不同 VOD 源执行请求限流、重试、熔断或故障切换。
- 代理视频流、转码、切片、截图或 CDN 分发。
- 保存观看记录、收藏和播放事件。
- 用户注册、登录、会员、支付、广告和推荐。

## 4. VOD 源模型

```ts
interface VodSource {
  id: string;
  code: string;
  name: string;
  base_url: string;
  priority: number;
  adapter_type: string;
  capabilities: {
    categories: boolean;
    search: boolean;
    detail: boolean;
    playback: boolean;
  };
  updated_at: string;
}
```

字段约束：

- `id`：服务端生成的不透明 ID。
- `code`：全局唯一且稳定，客户端可用于保存用户的源偏好。
- `name`：客户端展示名称。
- `base_url`：公开的 HTTPS VOD API 根地址。
- `priority`：数字越小优先级越高。
- `adapter_type`：客户端选择解析器使用的稳定标识，例如 `mac_cms_v10`。
- `capabilities`：客户端在调用前判断源支持的操作。
- `updated_at`：ISO 8601 UTC 时间。

不得返回：

- API Secret、管理 Token、Cookie、Authorization Header。
- 私网、回环、链路本地或云元数据地址。
- 最终视频播放 URL。
- 服务端内部配置和数据库字段。

## 5. V1 API

### 5.1 获取全部 VOD 源

```http
GET /api/v1/vod-sources
```

身份验证：不需要。

查询参数：无。

行为：

- 仅返回 `enabled = true` 的源。
- 按 `priority` 升序、`code` 升序排列。
- “全部”是指全部对客户端公开且启用的源，不包括禁用或内部测试源。
- 支持 `ETag` 或短时缓存，建议缓存 5 分钟。
- 无可用源时返回空数组，不返回虚构的默认源。

成功响应：

```json
{
  "data": [
    {
      "id": "src_01K...",
      "code": "storm",
      "name": "暴风资源",
      "base_url": "https://example.com/api.php/provide/vod/",
      "priority": 10,
      "adapter_type": "mac_cms_v10",
      "capabilities": {
        "categories": true,
        "search": true,
        "detail": true,
        "playback": true
      },
      "updated_at": "2026-08-13T00:00:00.000Z"
    }
  ],
  "meta": {
    "count": 1
  },
  "error": null,
  "request_id": "req_01K..."
}
```

失败响应：

```json
{
  "data": null,
  "meta": {},
  "error": {
    "code": "INTERNAL_ERROR",
    "message": "服务暂时不可用",
    "retryable": true
  },
  "request_id": "req_01K..."
}
```

### 5.2 健康检查

```http
GET /health/live
GET /health/ready
```

- `live` 只表示进程存活。
- `ready` 检查源配置存储是否可读取。
- 健康检查不实时探测第三方 VOD 源。

### 5.3 错误码

| 错误码                | HTTP | 可重试 | 含义               |
| --------------------- | ---: | -----: | ------------------ |
| `RATE_LIMITED`        |  429 |     是 | 请求过于频繁       |
| `INTERNAL_ERROR`      |  500 |     是 | 服务端未分类错误   |
| `SERVICE_UNAVAILABLE` |  503 |     是 | 源配置存储暂不可用 |

所有响应使用 `snake_case`，时间使用 ISO 8601 UTC，并携带 `request_id`。错误响应不得包含堆栈、SQL 或 Secret。

## 6. 数据存储

V1 只需要一张 VOD 源表：

```text
vod_sources:
  id
  code
  name
  base_url
  adapter_type
  capabilities_jsonb
  priority
  enabled
  created_at
  updated_at
```

约束：

- `id` 主键。
- `code` 唯一。
- `base_url` 必须为合法 HTTPS URL。
- `(enabled, priority, code)` 建立查询索引。
- `capabilities_jsonb` 必须在写入时校验固定 schema。
- 表中不得保存 VOD 密钥或最终播放 URL。

源数据可以通过数据库 migration、部署配置或受保护的运维脚本维护。V1 不要求管理后台或公开的写接口。

## 7. 技术要求

### 7.1 保留

- Node.js 24 LTS。
- TypeScript strict。
- NestJS 11 + Fastify 5。
- REST JSON 和代码生成的 OpenAPI 3。
- PostgreSQL 17 + Drizzle ORM + SQL migration。
- Pino 结构化日志。
- Prometheus 指标和基础 OpenTelemetry Trace。
- Vitest、Fastify inject E2E 和数据库集成测试。
- Docker 多阶段构建，非 root 用户运行。

### 7.2 删除

- Worker 进程。
- BullMQ。
- Queue Redis。
- VOD Source Adapter 服务端框架。
- 服务端 VOD HTTP Client。
- 视频目录数据库和同步任务。
- 播放解析缓存和播放会话。

### 7.3 可选简化

源列表数据量很小。缓存可以使用进程内缓存或单个 Cache Redis；如果部署规模不需要共享缓存，可不引入 Redis。PostgreSQL 是源配置的事实来源。

## 8. 安全与合规

- 只配置拥有合法授权的 VOD 源。
- 源可公开访问不代表其内容可合法发布。
- `base_url` 必须使用 HTTPS，禁止 URL 用户信息和非标准危险端口。
- 禁止返回任何需要保密的凭据；需要 Secret 才能访问的源不适合 V1 的客户端直连模式。
- 客户端不得绕过 DRM、Referer、Token、地区限制或其他访问控制。
- Flutter 日志和分析事件不得记录完整播放 URL、Token、Cookie 或 Authorization。
- 上线前由项目方确认内容授权、首发地区、隐私政策和应用商店规则。

客户端直连会公开 VOD 源地址，也无法由后端统一实施源级限流、字段兼容和播放安全策略。这是 V1 为缩短交付周期接受的明确取舍。

## 9. 非功能要求

- 源列表缓存命中时 P95 小于 100 ms。
- PostgreSQL 查询命中时 P95 小于 300 ms。
- 响应只返回必要字段，支持 gzip/br 压缩。
- 数据库不可用时 readiness 失败。
- 所有进程支持优雅关闭。
- 日志至少包含 `timestamp`、`level`、`service`、`environment`、`request_id`、`trace_id`、`duration_ms` 和 `error_code`。
- 指标至少包含请求数、状态码、延迟以及 PostgreSQL连接状态。

## 10. 测试与验收

必须覆盖：

- 只返回启用源。
- 排序规则稳定。
- 空列表响应正确。
- 字段使用 `snake_case` 且不泄露内部配置。
- 无效或非 HTTPS 地址无法写入数据库。
- 统一成功/失败响应和 `request_id`。
- 限流行为。
- liveness/readiness。
- migration、唯一键和查询索引。
- OpenAPI 与实现一致。

V1 完成条件：

1. Flutter 能从 Jive 后端获取全部公开 VOD 源。
2. Flutter 能根据 `adapter_type` 直接请求并解析至少一个合法 VOD 源。
3. 后端不请求、解析、同步或保存 VOD 内容数据。
4. 收藏、最近观看和播放进度完全保存在本地。
5. API、migration、测试、Docker 和运行文档齐全。
6. 内容授权和商店合规已经由项目方确认。

## 11. V2 规划

V2 再开始建设个人账号能力，候选范围包括：

- 注册、登录、退出和 Token 刷新。
- 密码找回或第三方登录。
- 用户资料与账号注销。
- 收藏、最近观看和播放进度云同步。
- 多设备数据合并和冲突处理。
- 隐私数据导出与删除。

V2 开始前必须单独编写账号、认证、安全、隐私和数据迁移需求。V1 不预建空的用户表、登录接口或会员模型。

以下能力不因进入 V2 自动纳入范围，仍需单独立项：会员、支付、广告、推荐、评论、内容代理、服务端 VOD 同步和播放解析。

## 12. 实施顺序

### 阶段 A：后端收缩

- 删除旧的 Catalog、Search、Playback、History、Sync、Worker 和 Adapter 服务端能力。
- 将数据库收缩为 `vod_sources`。
- 实现 `GET /api/v1/vod-sources`。
- 更新 OpenAPI、Docker、CI 和测试。

### 阶段 B：客户端多源

- 定义 Flutter 侧 Source Adapter。
- 获取并缓存后端源列表。
- 根据 `adapter_type` 创建客户端 Adapter。
- 完成分类、列表、搜索、详情和播放直连。
- 增加源切换与异常降级。

### 阶段 C：V1 验收

- Android/iOS 真机验证。
- 弱网、空源、源失效和格式异常验证。
- 内容授权和应用商店合规确认。
- 发布与回滚演练。

### 阶段 D：V2 需求设计

- 账号体系方案。
- 本地个人数据迁移方案。
- 隐私与安全评审。
- V2 排期和验收标准。
