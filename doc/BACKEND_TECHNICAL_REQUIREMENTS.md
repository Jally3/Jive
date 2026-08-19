# Jive V1 产品与后端技术需求

## 1. 文档状态

| 项目 | 内容 |
| --- | --- |
| 当前版本 | V1.1 |
| 目标客户端 | 当前 Jive Flutter Android/iOS App |
| 后端定位 | VOD 源目录与远程配置服务 |
| 数据访问方式 | 客户端获取源列表后直接请求 VOD 源 |
| 客户端基线 | 已实现多源、Mac CMS V10 Adapter、本地收藏/历史/下载 |
| 后续版本 | V2 单独设计账号及云端个人数据 |

本文件是 Jive V1 后端与客户端接入的权威需求。设计以当前 Flutter 客户端的数据模型和运行方式为基线，不要求重做已经完成的多源、搜索、详情、播放和本地缓存能力。

旧文档中关于后端同步 VOD 元数据、解析播放地址、代理内容目录、播放切源和 Worker 的设计不适用于 V1。

## 2. 当前客户端基线

Flutter 客户端当前已经具备：

- `VodSourceRegistry` 与 `VodSourceAdapter`，支持 `mac_cms_v10`。
- 全局源选择、搜索页局部切源和详情页来源探测。
- 使用 `sourceId:sourceVideoId` 作为跨源内容身份。
- 收藏、观看历史、播放进度、下载任务和离线缓存的本地持久化。
- HTTPS 源过滤、异常状态、重试和官方演示视频兜底。
- 从 `config/vod_sources.json` 加载内置源列表。

V1 后端接入是在上述能力之上，将“内置源列表”替换为“远程配置优先、最后有效配置降级”。后端不得改变内容请求仍由客户端直连 VOD 源这一事实。

## 3. 产品目标与系统边界

V1 目标：

1. 后端集中维护经过审核、允许发布的 VOD 源配置。
2. Flutter 客户端启动时获取远程源列表，并安全地缓存最后一次有效配置。
3. Flutter 客户端根据源配置直接请求分类、列表、搜索、详情和播放信息。
4. 后端可以通过禁用源完成紧急下线，不需要发布新 App。
5. 收藏、最近观看、播放进度、下载任务和离线内容继续保存在设备本地。
6. V1 不要求注册、登录或多设备同步。

```text
Jive Flutter App
    |
    |-- GET /api/v1/vod-sources --> Jive Backend
    |
    `-- 分类 / 列表 / 搜索 / 详情 / 播放 --> VOD Source
```

后端只负责源目录和远程配置，不位于视频业务请求链路中。文档中的“已发布源”表示通过配置审核且 `enabled = true`，不代表第三方源实时健康。

### 3.1 后端负责

- 保存并返回已发布 VOD 源的公开连接信息。
- 提供稳定源标识、展示名称、地址、优先级、解析器和客户端能力配置。
- 支持源禁用、地址更新、优先级调整和配置回滚。
- 提供 liveness/readiness 健康检查。
- 对源列表接口提供 HTTP 缓存、限流、结构化日志和基础监控。
- 校验所有发布字段，保证响应不包含密钥、管理凭证或其他 Secret。

### 3.2 Flutter 客户端负责

- 启动时先读取最后一次有效配置，再异步刷新远程配置。
- 将 API `snake_case` DTO 映射到当前 Dart `VodSource` 模型。
- 根据优先级、用户选择和页面策略选择 VOD 源。
- 直接调用 VOD 源，并解析其分类、分页、详情、线路、剧集和播放地址。
- 处理超时、限流、无效数据、源切换、重定向和播放失败重试。
- 忽略当前版本不支持的 `adapter_type`，不能因单条坏数据使整个源列表不可用。
- 仅接受支持的 HTTPS API 和播放地址；重定向后仍需重新校验 HTTPS。
- 保留收藏、历史、进度和下载数据；源下线不能直接删除个人本地数据。

### 3.3 V1 后端明确不负责

- 请求或代理 VOD 分类、列表、搜索和详情。
- 解析 `vod_play_url` 或返回最终播放地址。
- 同步或保存视频、分类、剧集、播放线路和媒体文件。
- 运行 VOD 实时健康探测、同步 Worker 或维护 Worker。
- 为第三方 VOD 源执行请求限流、重试、熔断或故障切换。
- 代理视频流、转码、切片、截图、广告过滤或 CDN 分发。
- 保存收藏、观看记录、播放事件、下载记录或设备标识。
- 用户注册、登录、会员、支付、广告和推荐。

## 4. 客户端身份与兼容性契约

### 4.1 稳定源 ID

公开字段 `id` 是客户端使用的稳定源标识，对应当前 Dart `VodSource.id` 和业务数据中的 `sourceId`。

- `id` 由业务分配，例如 `bfzy`，不是数据库生成 ID。
- `id` 创建后永久不可修改、不可复用，格式为 `^[a-z][a-z0-9_]{1,31}$`。
- 收藏、历史、进度、下载任务和内容缓存继续使用 `id:sourceVideoId`。
- 数据库可使用内部主键，但内部主键不得返回客户端。
- 同一个源只修改名称或地址时必须保留 `id`。
- 将一个 ID 指向无关的新内容源属于破坏性变更，禁止操作。

### 4.2 历史 ID

`legacy_ids` 用于识别客户端历史版本曾经使用过的源 ID。例如旧数据中的 `storm` 可以映射到当前 `bfzy`。

- 历史 ID 同样全局唯一，不得成为另一个源的 `id` 或 `legacy_id`。
- 客户端查找源时先匹配 `id`，再匹配 `legacy_ids`。
- 客户端可以在成功匹配后将用户选择迁移为新 `id`。
- 已持久化内容的 `sourceId` 可保持原值；构造请求时通过别名解析到当前源。

### 4.3 解析器兼容性

- V1 正式支持的 `adapter_type` 为 `mac_cms_v10`。
- 后端只能发布已经进入生产客户端的解析器标识。
- 客户端遇到未知解析器时跳过该源并记录脱敏诊断信息。
- 修改现有源的 `adapter_type` 前必须完成旧客户端兼容评估；不兼容时应创建新源 ID 或等待客户端覆盖率满足发布条件。

## 5. VOD 源公开模型

```ts
interface VodSourceDto {
  id: string;
  legacy_ids: string[];
  name: string;
  base_url: string;
  adapter_type: string;
  priority: number;
  capabilities: {
    categories: boolean;
    search: boolean;
    detail: boolean;
    playback: boolean;
  };
  featured_category_ids: number[];
  updated_at: string;
}
```

字段规则：

- `id`：客户端稳定源 ID，语义见第 4 节。
- `legacy_ids`：历史源 ID；没有时返回空数组。
- `name`：客户端展示名称，去除首尾空白后长度为 1 到 50 个字符。
- `base_url`：公开 HTTPS VOD API 根地址。
- `adapter_type`：客户端选择解析器的稳定标识。
- `priority`：1 到 999，数字越小优先级越高；相同优先级按 `id` 排序。
- `capabilities`：客户端调用前判断源支持的操作；V1 的正式源必须支持分类、详情和播放，搜索可以关闭。
- `featured_category_ids`：当前首页优先展示的根分类 ID；空数组表示由客户端展示源返回的全部根分类。
- `updated_at`：该源公开字段最后变更时间，ISO 8601 UTC。

当前 Dart 模型映射：

| API 字段 | Flutter 字段/行为 |
| --- | --- |
| `id` | `VodSource.id` |
| `legacy_ids` | 远程加载器的历史 ID 索引 |
| `name` | `VodSource.name` |
| `base_url` | `VodSource.baseUri` |
| `adapter_type` | `VodSource.adapterType` |
| `priority` | `VodSource.priority` |
| `capabilities.search` | `VodSource.search` |
| 其他 `capabilities` | 判断该源是否满足当前页面的必要能力 |
| `featured_category_ids` | `VodSource.featuredCategoryIds` |
| 已出现在响应中 | `VodSource.enabled = true` |

不得返回：

- API Secret、管理 Token、Cookie、Authorization Header 或带凭据 URL。
- 私网、回环、链路本地、保留地址或云元数据地址。
- 最终视频播放 URL。
- 数据库内部主键、审核备注、操作者和其他内部配置。

## 6. V1 API

### 6.1 获取已发布 VOD 源

```http
GET /api/v1/vod-sources
```

身份验证：不需要。查询参数：无。

行为：

- 仅返回 `enabled = true` 的源。
- 按 `priority` 升序、`id` 升序稳定排序。
- 返回源的公开快照，不实时探测第三方 VOD 服务。
- 无已发布源时返回成功的空数组，不返回虚构默认源。
- 每次公开配置变化必须产生新的 `config_version` 和 `ETag`。

成功响应：

```json
{
  "data": [
    {
      "id": "bfzy",
      "legacy_ids": ["storm"],
      "name": "暴风资源",
      "base_url": "https://example.com/api.php/provide/vod",
      "adapter_type": "mac_cms_v10",
      "priority": 10,
      "capabilities": {
        "categories": true,
        "search": true,
        "detail": true,
        "playback": true
      },
      "featured_category_ids": [],
      "updated_at": "2026-08-18T00:00:00.000Z"
    }
  ],
  "meta": {
    "count": 1,
    "schema_version": 1,
    "config_version": "cfg_01K...",
    "published_at": "2026-08-18T00:00:00.000Z"
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
    "code": "SERVICE_UNAVAILABLE",
    "message": "服务暂时不可用",
    "retryable": true
  },
  "request_id": "req_01K..."
}
```

### 6.2 HTTP 缓存

- 成功响应返回弱 ETag（例如 `W/"cfg_01K..."`）和 `Cache-Control: public, max-age=300, stale-if-error=604800`。
- 客户端刷新时发送 `If-None-Match`。
- 配置未变化时返回 `304 No Content`，不返回 JSON body；`request_id` 放在响应头 `X-Request-Id`。
- 弱 ETag 由 `schema_version`、`config_version` 和规范化源列表生成，不包含 `request_id` 或内部字段。
- `published_at` 是配置版本的发布时间，同一 `config_version` 下保持不变，不能使用每次请求的当前时间。
- `200` 空数组是权威配置，客户端必须替换旧源列表，以支持紧急下线。
- 网络错误、`429` 或 `5xx` 不得覆盖客户端最后一次有效配置。

### 6.3 健康检查

```http
GET /health/live
GET /health/ready
```

- `live` 只表示进程存活，不访问数据库或第三方源。
- `ready` 检查源配置存储是否可读取。
- 健康检查不实时探测第三方 VOD 源。
- 健康检查响应不使用业务 API envelope，不记录为普通业务请求指标。

### 6.4 错误码

| 错误码 | HTTP | 可重试 | 含义 |
| --- | ---: | ---: | --- |
| `RATE_LIMITED` | 429 | 是 | 请求过于频繁，并返回 `Retry-After` |
| `INTERNAL_ERROR` | 500 | 是 | 服务端未分类错误 |
| `SERVICE_UNAVAILABLE` | 503 | 是 | 源配置存储暂不可用 |

JSON 响应使用 `snake_case`，时间使用 ISO 8601 UTC。业务响应携带 `request_id`，同时返回 `X-Request-Id`；错误响应不得包含堆栈、SQL、主机路径或 Secret。

## 7. 客户端加载、缓存与降级

客户端实现必须遵循以下状态转换：

| 场景 | 客户端行为 |
| --- | --- |
| 本地存在最后有效配置 | 立即构建 Registry，同时后台刷新 |
| 远程返回 `304` | 更新缓存校验时间，继续使用现有配置 |
| 远程返回合法非空 `200` | 过滤不支持项后原子替换缓存和 Registry |
| 远程返回合法空数组 `200` | 清空远程源，不继续使用旧源；保留个人数据 |
| 网络错误、`429` 或 `5xx` | 使用最后有效配置，按退避策略稍后重试 |
| 单条源配置无效 | 跳过该条；其他合法源仍可使用并记录诊断 |
| envelope/schema 无效 | 整份响应拒绝，不覆盖最后有效配置 |
| 无任何可用配置 | 进入“没有可用来源”状态，官方演示视频仍可用于播放器验收 |

缓存要求：

- 只在完整解析和校验成功后写入，使用临时文件加原子替换，防止崩溃产生半份配置。
- 保存 `schema_version`、`config_version`、`ETag`、响应数据和最后成功校验时间。
- 最后有效配置允许在服务异常时降级使用最多 7 天；超过 7 天不得自动访问旧第三方源。
- 手动刷新不得先清空当前 Registry。
- 多个并发刷新只允许最后一个有效请求更新状态，避免旧响应覆盖新配置。
- 日志不得记录完整 `base_url`，只记录源 `id`、主机的脱敏形式和错误类型。

## 8. 源变更与下线规则

### 8.1 可原地修改

- `name`
- `base_url`，前提是仍为同一内容源且通过安全校验
- `priority`
- `capabilities`
- `featured_category_ids`

### 8.2 受限制修改

- `id` 永远不可修改。
- `legacy_ids` 只能追加经过审核的历史标识，不得制造冲突。
- `adapter_type` 修改前必须确认当前生产客户端支持。

### 8.3 禁用源

- 禁用后不再出现在源列表，并生成新的配置版本。
- 客户端若正在使用该源，应切换到下一个支持的已发布源；不得自动删除收藏、历史、下载任务或缓存文件。
- 依赖回源刷新的旧记录应显示“来源当前不可用”，而不是静默绑定到其他源。
- 已完整下载且本地校验通过的内容可继续离线播放，不得因源禁用主动删除。
- 紧急合规下线使用成功空列表或移除对应源，不能依赖短 TTL 自然过期。

### 8.4 回滚

- 每次配置发布必须有唯一 `config_version`、操作者、时间和变更摘要。
- 回滚生成新的配置版本，不复用旧版本号。
- 回滚必须保持源 ID 和历史 ID 约束。

## 9. 数据存储与配置维护

V1 使用三张表：源配置表、历史 ID 别名表和不可变发布版本表。固定能力使用布尔列，不使用难以约束的 JSONB；只有分类 ID 列表和完整发布快照使用结构化字段。

### 9.1 PostgreSQL 17 DDL

```sql
CREATE TABLE vod_sources (
  db_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id varchar(32) NOT NULL UNIQUE,
  name varchar(50) NOT NULL,
  base_url text NOT NULL UNIQUE,
  adapter_type varchar(50) NOT NULL,
  priority smallint NOT NULL DEFAULT 999,
  supports_categories boolean NOT NULL DEFAULT true,
  supports_search boolean NOT NULL DEFAULT true,
  supports_detail boolean NOT NULL DEFAULT true,
  supports_playback boolean NOT NULL DEFAULT true,
  featured_category_ids integer[] NOT NULL DEFAULT '{}',
  enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT vod_sources_source_id_format_ck
    CHECK (source_id ~ '^[a-z][a-z0-9_]{1,31}$'),
  CONSTRAINT vod_sources_name_ck
    CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 50),
  CONSTRAINT vod_sources_base_url_https_ck
    CHECK (base_url ~ '^https://'),
  CONSTRAINT vod_sources_adapter_type_ck
    CHECK (adapter_type ~ '^[a-z][a-z0-9_]{1,49}$'),
  CONSTRAINT vod_sources_priority_ck
    CHECK (priority BETWEEN 1 AND 999),
  CONSTRAINT vod_sources_required_capabilities_ck
    CHECK (
      NOT enabled OR
      (supports_categories AND supports_detail AND supports_playback)
    )
);

CREATE INDEX vod_sources_published_order_idx
  ON vod_sources (priority, source_id)
  WHERE enabled = true;

CREATE TABLE vod_source_aliases (
  alias_id varchar(32) PRIMARY KEY,
  source_db_id bigint NOT NULL
    REFERENCES vod_sources (db_id)
    ON UPDATE RESTRICT
    ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT vod_source_aliases_id_format_ck
    CHECK (alias_id ~ '^[a-z][a-z0-9_]{1,31}$')
);

CREATE INDEX vod_source_aliases_source_idx
  ON vod_source_aliases (source_db_id);

CREATE FUNCTION enforce_vod_source_identifier_uniqueness()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'vod_sources' THEN
    IF EXISTS (
      SELECT 1 FROM vod_source_aliases WHERE alias_id = NEW.source_id
    ) THEN
      RAISE EXCEPTION 'source_id conflicts with an existing alias_id';
    END IF;
  ELSE
    IF EXISTS (
      SELECT 1 FROM vod_sources WHERE source_id = NEW.alias_id
    ) THEN
      RAISE EXCEPTION 'alias_id conflicts with an existing source_id';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER vod_sources_identifier_uniqueness_trg
  BEFORE INSERT OR UPDATE OF source_id ON vod_sources
  FOR EACH ROW
  EXECUTE FUNCTION enforce_vod_source_identifier_uniqueness();

CREATE TRIGGER vod_source_aliases_identifier_uniqueness_trg
  BEFORE INSERT OR UPDATE OF alias_id ON vod_source_aliases
  FOR EACH ROW
  EXECUTE FUNCTION enforce_vod_source_identifier_uniqueness();

CREATE TABLE vod_source_revisions (
  revision_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  config_version varchar(40) NOT NULL UNIQUE,
  schema_version smallint NOT NULL,
  snapshot_jsonb jsonb NOT NULL,
  snapshot_sha256 char(64) NOT NULL,
  change_summary varchar(500) NOT NULL,
  created_by varchar(100) NOT NULL,
  published_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT vod_source_revisions_config_version_ck
    CHECK (config_version ~ '^cfg_[0-9A-Z]+$'),
  CONSTRAINT vod_source_revisions_schema_version_ck
    CHECK (schema_version > 0),
  CONSTRAINT vod_source_revisions_snapshot_type_ck
    CHECK (jsonb_typeof(snapshot_jsonb) = 'object'),
  CONSTRAINT vod_source_revisions_snapshot_sha256_ck
    CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT vod_source_revisions_change_summary_ck
    CHECK (
      change_summary = btrim(change_summary) AND
      char_length(change_summary) BETWEEN 1 AND 500
    ),
  CONSTRAINT vod_source_revisions_created_by_ck
    CHECK (
      created_by = btrim(created_by) AND
      char_length(created_by) BETWEEN 1 AND 100
    )
);

CREATE INDEX vod_source_revisions_latest_idx
  ON vod_source_revisions (published_at DESC, revision_id DESC);

CREATE FUNCTION reject_vod_source_revision_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'vod_source_revisions are immutable';
END;
$$;

CREATE TRIGGER vod_source_revisions_immutable_trg
  BEFORE UPDATE OR DELETE ON vod_source_revisions
  FOR EACH ROW
  EXECUTE FUNCTION reject_vod_source_revision_mutation();
```

### 9.2 表职责

| 表 | 职责 | API 是否直接读取 |
| --- | --- | --- |
| `vod_sources` | 当前可编辑源配置；内部 `db_id` 不下发 | 否 |
| `vod_source_aliases` | 将历史 `alias_id` 映射到当前源 | 否 |
| `vod_source_revisions` | 保存每次正式发布的不可变公开快照 | 是，只读取最新版本 |

`snapshot_jsonb` 保存与成功响应一致的 `data` 及稳定 `meta`，不保存 `request_id`。API 从最新 revision 构建响应，因此源配置编辑到一半时不会被客户端看到。`snapshot_sha256` 根据规范化快照计算，用于发布校验、审计和损坏检测；弱 ETag 使用 `config_version`。

### 9.3 数据约束与应用校验

数据库约束负责字段格式、范围、单表唯一性和外键；以下跨表或网络语义必须由发布事务校验：

- `source_id` 不得与任何 `alias_id` 相同，所有当前 ID 和历史 ID 全局唯一。
- `featured_category_ids` 只能包含大于 0 且不重复的整数，发布前按升序规范化。
- `base_url` 不允许 userinfo、query、fragment、IP literal 和非 443 端口。
- `base_url` 主机解析结果不得为私网、回环、链路本地、保留地址或云元数据地址。
- URL 写入前移除无意义尾部 `/` 并执行规范化，规范化结果必须唯一。
- `adapter_type` 必须存在于当前允许发布的客户端 Adapter 白名单。
- `snapshot_jsonb` 必须通过与 OpenAPI 相同的 schema 校验，且 `count` 与源数量一致。
- `updated_at` 必须在每次公开字段变更时使用数据库时间更新。
- 三张表均不得保存 VOD 密钥、请求 Header、最终播放 URL 或其他客户端不可公开字段。

跨表 ID 冲突校验必须在同一事务中执行，并使用事务级 advisory lock，避免两个并发发布分别通过校验后产生冲突。生产运行角色只允许读取最新 revision，不允许直接修改源表或历史 revision。

### 9.4 发布与回滚事务

配置维护采用单一流程：

```text
受版本管理的源配置
    -> CI/运维脚本校验
    -> 生成差异与人工确认
    -> 开启事务并获取 advisory lock
    -> upsert vod_sources / vod_source_aliases
    -> 校验完整公开快照
    -> 插入不可变 vod_source_revisions
    -> 提交事务
    -> 清理进程缓存并生成新 ETag
```

发布要求：

- `config_version` 推荐使用带 `cfg_` 前缀的 ULID，每次发布和回滚都生成新值。
- revision 插入后不可 `UPDATE` 或 `DELETE`；修正错误只能发布新 revision。
- 回滚读取目标历史快照，重新写入源表并生成一个新 revision，不能把旧 revision 重新标记为最新。
- 最新版本按 `(published_at, revision_id)` 倒序确定；发布时间相同时由 `revision_id` 消除歧义。
- 空源列表也是合法快照，发布脚本必须对空配置进行二次人工确认。
- 发布完成后，各实例通过短轮询或部署平台通知失效进程内缓存；不为此引入 Redis。

V1 不要求管理后台或公开写接口。禁止同时使用手工 SQL、migration seed 和部署环境变量维护不同版本的事实来源。首次 migration 只创建 schema；初始源配置必须通过同一发布脚本生成第一条 revision。

## 10. 技术要求

### 10.1 保留

- Node.js 24 LTS。
- TypeScript strict。
- NestJS 11 + Fastify 5。
- REST JSON 和代码生成的 OpenAPI 3。
- PostgreSQL 17 + Drizzle ORM + SQL migration。
- Pino 结构化日志。
- Prometheus 指标和基础 OpenTelemetry Trace。
- Vitest、Fastify inject E2E 和数据库集成测试。
- Docker 多阶段构建，非 root 用户运行。

保留 NestJS 与 PostgreSQL 是为了复用现有后端基础设施并为 V2 账号能力保留演进路径，不代表 V1 可以预建用户、会员或内容目录模型。

### 10.2 删除或禁止引入

- Worker 进程。
- BullMQ、Queue Redis 和仅为此接口引入的 Cache Redis。
- 服务端 VOD Source Adapter 和 VOD HTTP Client。
- 视频目录数据库、同步任务和实时源探测。
- 播放解析缓存、播放会话和媒体代理。

源列表数据量很小，默认使用短时进程内缓存。PostgreSQL 是配置事实来源，revision 快照用于审计和回滚。

## 11. 安全与合规

- 只配置拥有明确合法授权、允许在目标地区和平台发布的 VOD 源。
- 源可公开访问不代表其内容可以合法发布。
- 需要 Secret、Cookie、Referer、私有 Header 或设备指纹才能访问的源不适合 V1 客户端直连模式。
- 客户端不得绕过 DRM、Token、地区限制或其他访问控制。
- 客户端必须拒绝 HTTPS 降级重定向；播放地址和媒体清单中的资源地址也必须执行现有安全策略。
- Flutter 日志、分析事件和崩溃报告不得记录完整播放 URL、Token、Cookie 或 Authorization。
- 后端日志不得记录完整源配置响应和数据库快照。
- 上线前由项目方书面确认内容授权、首发地区、隐私政策和应用商店规则。

客户端直连会公开 VOD 源地址，也无法由后端统一实施源级限流、字段兼容和播放安全策略。这是 V1 为缩短交付周期接受的明确取舍；如实际源依赖凭据或访问控制，必须重新评估服务端代理方案，不能把凭据下发客户端。

## 12. 非功能要求

- 正常运行时 API 月可用性目标不低于 99.9%。
- 源列表进程缓存命中时 P95 小于 100 ms。
- PostgreSQL 查询命中时 P95 小于 300 ms。
- 单次响应未压缩大小不得超过 128 KiB，支持 gzip/br 压缩。
- 数据库不可读时 readiness 失败，源列表返回 `503`，不能返回未标识的过期服务端缓存。
- 所有进程支持优雅关闭，部署时不丢失正在处理的请求。
- 日志至少包含 `timestamp`、`level`、`service`、`environment`、`request_id`、`trace_id`、`duration_ms`、`status_code` 和 `error_code`。
- 指标至少包含请求数、状态码、延迟、限流次数、缓存命中率和 PostgreSQL 连接状态。
- 指标标签不得包含源 URL、完整 User-Agent、request ID 等高基数字段。
- 对 readiness 失败、持续 `5xx`、异常空配置发布和配置校验失败建立告警。

## 13. 测试与验收

### 13.1 后端必须覆盖

- 只返回启用源，排序稳定，空列表响应正确。
- 公开 `id` 稳定，当前 ID 与历史 ID 全局无冲突。
- DTO 使用 `snake_case`，不泄露内部字段和 Secret。
- 非 HTTPS、userinfo、query、fragment、IP literal、危险端口和私网目标无法发布。
- capabilities 布尔列、分类 ID 数组、优先级和 revision JSON schema 校验。
- ETag、`If-None-Match`、`304`、`Cache-Control` 和配置变更后的缓存失效。
- 统一成功/失败响应、`X-Request-Id`、`Retry-After` 和错误脱敏。
- 限流、liveness/readiness、优雅关闭。
- migration、跨表 ID 冲突触发器、唯一键、check constraint、查询索引、revision 不可变性和回滚。
- OpenAPI 与实现一致，示例响应可被 Flutter 合约测试解析。

### 13.2 Flutter 接入必须覆盖

- API DTO 到当前 `VodSource` 模型的字段映射。
- `legacy_ids` 查找及旧用户选择迁移。
- 先显示缓存、后台刷新、`304`、失败降级和 7 天过期策略。
- 成功空列表清除旧源，但不删除收藏、历史和下载数据。
- 单条坏数据、未知 Adapter 和不支持能力不会破坏其他源。
- 已选源禁用后安全切换，旧记录显示来源不可用。
- 手动刷新、并发请求和旧响应隔离。
- Android/iOS 真机验证 HTTPS、重定向、弱网和离线启动。
- 使用固定 fixture 或测试 VOD 服务完成 Adapter 合约测试，不将实时第三方源作为 CI 唯一依赖。

### 13.3 V1 完成条件

1. Flutter 可以从 Jive 后端获取源列表并映射为当前 Registry。
2. 后端不可用时，客户端可以按规则使用最后有效配置；首次无配置时仍可进入 App。
3. Flutter 可以根据 `adapter_type` 直接请求并解析至少一个已授权测试源。
4. 后端禁用源后客户端能停止新访问，同时保留个人本地数据。
5. 后端不请求、解析、同步或保存 VOD 内容数据。
6. API、migration、发布审计、测试、Docker、监控和运行文档齐全。
7. 内容授权、目标地区和应用商店合规已经由项目方确认。

## 14. 实施顺序

### 阶段 A：后端收缩与源目录

- 删除旧 Catalog、Search、Playback、History、Sync、Worker 和服务端 Adapter 能力。
- 建立 `vod_sources`、`vod_source_aliases` 与 `vod_source_revisions`。
- 使用当前 `config/vod_sources.json` 的 ID 作为初始 `source_id`，不得重新生成客户端 ID。
- 实现源配置校验、发布、回滚和 `GET /api/v1/vod-sources`。
- 完成 OpenAPI、缓存、限流、健康检查、监控、Docker、CI 和测试。

### 阶段 B：客户端远程配置接入

- 保留当前 `VodSourceAdapter`、Repository 和页面多源逻辑。
- 新增后端 DTO、远程加载器、最后有效配置存储和原子更新。
- 将当前 assets 配置保留为开发/测试 fixture，不作为生产源事实来源。
- 增加 `legacy_ids`、未知 Adapter、空列表、源禁用和缓存过期处理。
- 补充 Flutter 与 OpenAPI 的合约测试。

### 阶段 C：联合验收与发布

- Android/iOS 真机验证。
- 弱网、首次离线、后端故障、空配置、源失效和格式异常验证。
- 演练源紧急下线、配置回滚和 App 旧版本兼容。
- 完成内容授权和应用商店合规确认。
- 更新 `README.md` 和 `ARCHITECTURE.md` 中“无需后端/内置源列表”的旧描述。

## 15. V2 规划

V2 再单独设计：

- 注册、登录、退出和 Token 刷新。
- 密码找回或第三方登录。
- 用户资料与账号注销。
- 收藏、最近观看和播放进度云同步。
- 多设备数据合并和冲突处理。
- 隐私数据导出与删除。

V2 开始前必须单独编写账号、认证、安全、隐私和数据迁移需求。V1 不预建空用户表、登录接口或会员模型。

会员、支付、广告、推荐、评论、内容代理、服务端 VOD 同步和播放解析不会因进入 V2 自动纳入范围，仍需单独立项。
