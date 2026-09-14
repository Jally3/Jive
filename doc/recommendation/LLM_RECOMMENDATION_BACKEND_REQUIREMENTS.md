# Jive「猜你喜欢」后端实现需求

> 文档状态：V1 后端已部署，客户端迁移待完成
>
> 适用范围：首页「猜你喜欢」Feed
>
> 目标方案：LLM 唯一推荐 + 服务端严格校验 + 有状态 Cursor 分页 + 客户端 VOD 最终验证
>
> 当前状态：后端已上线；客户端直连方舟仅用于本地开发验证，生产包必须迁移到本接口

> 本文档是唯一现行推荐需求，取代已删除的
> `PERSONALIZED_RECOMMENDATION_REQUIREMENTS.md`。与本文档冲突的 TMDB 候选召回、公共榜单降级、
> 规则推荐和模型仅重排方案均已废止。

## 1. 总体方案

```text
Jive App
  ├─ 首次启动申请服务端匿名主体标识，本地持久保存
  └─ 提交最小化观看历史和个人内容库
       ↓
推荐服务
  ├─ 验证主体、输入、频率和预算
  ├─ 调用 LLM 生成候选（唯一来源）
  ├─ 逐条校验、稳定去重和顺序保持
  └─ 会话内 Cursor 分页和幂等响应
       ↓
Jive App
  └─ 当前 VOD 源搜索并严格匹配，匹配成功才进入可播主列表
```

核心原则：

1. LLM 决定候选和顺序，服务端不插入 LLM 未返回的影片。
2. V1 推荐链路不调用 TMDB。同进程现有 TMDB Catalog 可独立运行，但不得进入推荐请求链路。
3. 服务端保证结构、去重、顺序和分页，不声称已确认候选真实存在或可播。
4. 客户端 VOD 严格匹配是 V1 唯一的可播身份验证。
5. 会话和推荐缓存仅存在于当前 Node.js 进程内；服务重启后不恢复。每日预算账本例外，必须独立持久化，避免通过重启绕过成本上限。

## 2. 范围

目标：个性化候选、强类型校验、跨页去重、幂等、缓存降级、服务端密钥、分层限流和成本保护。

非目标：

- 登录账号、跨设备画像、协同过滤或向量库。
- 服务端搜索 VOD、返回播放地址或选择播放线路。
- TMDB/热门榜单降级、补位或重排。
- 保证每个模型候选真实存在；该风险由 VOD 匹配拦截和匹配率监控。
- Cursor、会话或缓存的跨进程重启恢复。

## 3. 匿名主体

### 3.1 签发接口

```http
POST /api/v1/recommendations/anonymous-subject
Content-Type: application/json

{}
```

HTTP 201：

```json
{
  "anonymousSubjectId": "opaque-server-signed-value",
  "issuedAt": "2026-09-13T17:00:00Z"
}
```

- 服务端使用至少 128 bit 随机性生成标识，并使用服务端密钥签名。
- 标识不包含硬件 ID、偏好、IP 或可读个人信息；它是应用级随机 ID，不是设备指纹。
- 服务端无状态验证签名，不为签发本身建立持久化账号。
- App 使用 Keychain/Keystore 等持久存储；丢失、重装或密钥轮换后重新申请。
- 推荐和事件请求通过 `X-Jive-Anonymous-Subject` 携带该值。
- 缺失、签名无效或超长时返回 401 `INVALID_ANONYMOUS_SUBJECT`。
- 签发接口不产生 LLM 费用，但仍需连接来源和全局限流。

### 3.2 安全边界

匿名主体只用于 Cursor 绑定、频率和预算统计，不用于广告或跨应用跟踪。
公开 App 无法用静态 Secret 阻止恶意人批量申请新主体，因此每主体限额只是第一层防线；
全局并发、全局每日 Token/成本上限和功能开关是不可绕过的最后保护。

## 4. 推荐请求

### 4.1 首页

```http
POST /api/v1/recommendations/personalized
Content-Type: application/json
X-Jive-Anonymous-Subject: opaque-server-signed-value
```

```json
{
  "clientRequestId": "client-generated-uuid",
  "locale": "zh-CN",
  "pageSize": 24,
  "history": [{
    "title": "降临", "year": "2016", "category": "电影片",
    "episodeName": "正片", "progress": 0.92, "completed": true,
    "watchedAt": "2026-09-13T16:20:00+08:00"
  }],
  "library": [{
    "title": "流人", "year": "2022", "category": "欧美剧",
    "favorite": true, "following": true,
    "updatedAt": "2026-09-12T12:00:00+08:00"
  }]
}
```

### 4.2 续页

```json
{
  "clientRequestId": "new-client-generated-uuid",
  "cursor": "opaque-server-cursor"
}
```

- 首页不携带 `cursor`；续页只携带 `clientRequestId` 和 `cursor`。
- `pageSize` 默认 24，允许 12～24，首页创建会话时固定。续页携带该字段返回 400。
- 续页携带 `history`、`library` 或 `locale` 返回 400。
- `clientRequestId` 最大 64 字符，只允许 UUID 字符集；它用于追踪，不是幂等键。
- 服务端独立生成 `req_*` 格式 `requestId`，同时返回 `X-Request-ID`。

### 4.3 输入限制

- 请求体最大 64 KiB，只接受 `application/json`。
- `history` 最多 20 条，服务端按 `watchedAt` 从新到旧重排。
- `library` 最多 10 条，服务端按 `updatedAt` 从新到旧重排。
- 未完播且进度低于 5% 的历史、`favorite=false` 且 `following=false` 的内容库项不作为偏好。
- 标题最大 100 字符，分类和剧集名最大 50；去首尾空白和不可见控制字符。
- 客户端和服务端都裁剪；服务端不信任客户端校验。
- 裁剪后两组同时为空时进入冷启动，不调用 LLM。
- 不上传播放 URL、VOD 源、Cookie、Authorization、API Key 或硬件标识。
- 用户文本均为不可信数据，不允许覆盖 System Prompt。

## 5. LLM 输出契约

规则：收藏、追更和完播为强偏好；排除输入和会话已返回作品；以高相关为主、少量探索；
标题优先中文 VOD 常见名；未知字符串返回 `""`；理由最多 30 个 Unicode 字符且不做敏感属性推断。

```json
{
  "items": [{
    "title": "银翼杀手2049",
    "originalTitle": "Blade Runner 2049",
    "aliases": ["银翼杀手 2049"],
    "year": "2017",
    "mediaType": "movie",
    "category": "movie",
    "latestSeasonNumber": null,
    "modelConfidence": 0.91,
    "reason": "偏好科幻悬疑题材"
  }]
}
```

| 字段 | 契约 |
| --- | --- |
| `title` | 必填字符串，1～100 字符 |
| `originalTitle` | 字符串，未知为 `""`，最大 100 |
| `aliases` | 数组，未知为 `[]`，最多 3 项，每项 1～100 |
| `year` | `""` 或 `1900`～当前年份加 2 的四位字符串 |
| `mediaType` | `movie` 或 `tv` |
| `category` | `movie`、`tv`、`animation` 或 `variety` |
| `latestSeasonNumber` | `null` 或 1～100 整数；电影必须 `null` |
| `modelConfidence` | 0～1 数字；仅为模型自评，不是真实性概率 |
| `reason` | 字符串，未知为 `""`；校验上限 50，输出上限 30 |

## 6. 解析、校验与去重

1. 确认上游 HTTP 成功并限制响应体大小。
2. 提取模型文本，最多剥离一层 Markdown JSON 围栏。
3. 使用标准 JSON Parser，不用正则拼装 JSON。
4. 宽松校验 envelope：外层为对象且 `items` 为数组。
5. `items` 逐条强类型校验，单条非法不影响其他条目。
6. 记录丢弃原因和数量，不记录原始内容；有效数为零则整体失败。
7. 按 `mediaType + normalizedTitle + year` 当页和跨页稳定去重，保留首次项。
8. 最多保留 `pageSize` 条，不改变 LLM 顺序。

处理：`title` 非法、`mediaType` 非枚举则丢弃；`originalTitle/reason` 非字符串置 `""`；
`aliases` 非数组置 `[]` 并过滤无效项；`year` 非法置 `""`；非法季号置 `null`；
非法置信度置 `0.5`；理由过滤敏感推断和 HTML/Markdown 注入。

`movie` 只允许 `movie|animation`，`tv` 只允许 `tv|animation|variety`；冲突时修正为 `movie` 或 `tv`。
`normalizedTitle` 做 NFKC、小写化、移除空白和常见标点，不做简繁、翻译或别名推断。

## 7. 分页会话与 Cursor

首页创建 30 分钟会话，保存主体不可逆摘要、偏好快照/指纹、locale、pageSize、
Schema/Prompt/模型/参数版本、已返回身份集、已生成页、Cursor 响应缓存和时间。

- Cursor 是签名不透明随机令牌，绑定会话、主体、目标页和过期时间，不含可读偏好。
- `nextCursor` 表示获取下一页。首次成功后，后续重放返回完全相同响应，不再调用 LLM。
- 签名、页或主体绑定无效返回 400；签名有效但会话不存在/过期返回 410。
- 进程重启后旧 Cursor 统一返回 410。

### 7.1 同 Cursor 并发

1. 先以 `hash(cursor)` 查找已缓存响应。
2. 未命中时查找该 Cursor 的 in-flight Promise。
3. 已有 in-flight 时，后续请求等待同一 Promise，不占用新 LLM 并发名额。
4. 成功后在同一临界区原子更新页、身份集、页索引和下一 Cursor，再解析等待者。
5. 失败时等待者获得同类错误，清除 in-flight；后续重试可新发起一次调用。

### 7.2 页数与 `hasMore`

- 每会话最多 3 页，每页 12～24 个候选；已返回页不改写、不重排。
- 不得仅因有效数少于 `pageSize` 就结束分页。
- 已到第 3 页、本页零新候选，或新候选少于 `RECOMMENDATION_MIN_ITEMS_FOR_NEXT_PAGE` 时 `hasMore=false`。
- 上述阈值启动建议为 4，上线后按有效数和 Token 成本调整。

## 8. 进程内存储、容量与估算

- 会话、幂等响应、新鲜/陈旧缓存、短窗口限流和冷却状态均只存在于当前进程。
- 不复用 TMDB Catalog `state-store`，不把高频推荐状态写入 Catalog 快照。
- 重启后状态清空；客户端收到 410 后保留已展示页，以最新偏好创建新会话。
- 24 小时陈旧缓存不承诺跨重启。
- 每日主体/全局 LLM 次数、Token 和成本账本不属于推荐缓存，保存到独立 `RECOMMENDATION_BUDGET_STATE_FILE`；预算预留先原子落盘再调用上游，结算后再次原子更新。
- 启动时恢复当日账本并清理过期日期。账本缺失可创建空状态；账本存在但损坏、版本不兼容或无法写入时必须 fail-closed：停止新 LLM 调用并返回预算状态不可用错误，不得按零用量继续。

| 项目 | 启动建议 | 满载行为 |
| --- | ---: | --- |
| 有效会话 | 1,000 | 先清过期项；仍满时不驱逐未过期会话，新首页返回 503 |
| 偏好缓存项 | 500 | 先清过期项，再按 LRU 驱逐；只造成 cache miss |
| 全局 LLM in-flight | 4 | 超出后进入有界队列 |
| LLM 等待队列 | 16 | 队列满返回 503，不创建无界 Promise |
| 每日主体预算项 | 20,000 | 独立账本持久化；日界线后清除；满时新主体返回 503 |
| 清理周期 | 60 秒 | 清会话、缓存、窗口和已完成 in-flight；定时器 `unref()` |

保守估算：

- 单会话约 24～48 KiB；1,000 会话约 24～48 MiB。
- 24 条候选缓存约 8～16 KiB；500 项约 4～8 MiB。
- 限额 Map、Cursor、in-flight 缓冲和临时 JSON 预留 8～20 MiB。
- 推荐子系统典型满载 40～64 MiB，容量验收按最坏 80 MiB 预留。

现有 V8 堆上限 256 MiB、systemd `MemoryMax` 320 MiB。上线后监控 RSS、heap used、会话/缓存数和容量拒绝。
推荐稳定超过 80 MiB 时先降低容量或拆进程，不盲目提高内存上限。

## 9. 缓存

- 偏好指纹基于服务端排序裁剪后快照，使用 HMAC-SHA-256，不返回客户端或写入日志。
- 缓存键包含偏好指纹、locale、Schema/Prompt/模型/参数版本。
- 模板最多 24 条，新会话按 `pageSize` 截取，因此 `pageSize` 不必进入模板键。
- 首页成功候选 30 分钟内为新鲜缓存，24 小时内可作上游失败陈旧降级。
- 命中模板仍为当前主体创建新会话和 Cursor。
- 只缓存校验后候选，不缓存 VOD 结果。
- 陈旧响应保留原 `generatedAt`，另返回 `servedAt` 和 `meta.cache="stale"`。
- 续页不用跨会话陈旧缓存；失败保留已展示页，允许重试原 Cursor。

## 10. 限流、并发、预算与 429 冷却

| 保护 | 保守启动值 | 口径 |
| --- | ---: | --- |
| 每主体 HTTP 限流 | 2 次/分钟 | 首页、续页、缓存命中和重放 |
| 每连接来源 HTTP 限流 | 30 次/分钟 | 辅助防护，不假设总能取得真实 IP |
| 每主体 LLM 生成 | 12 次/日 | 缓存命中、陈旧降级和幂等重放不计入 |
| 每主体 Token | 100,000/日 | prompt + completion |
| 全局 LLM 生成 | 500 次/日 | 全部主体 |
| 全局 Token | 5,000,000/日 | 全部主体 |
| 全局估算成本 | 50 元/日 | 部署时按套餐、合同价和运营预算确认 |
| 全局 LLM 并发 | 4 | 首页和续页共用 |
| 全局等待队列 | 16 | 超出快速失败 |

日界线默认 `Asia/Shanghai`，所有阈值必须可配置。

- 调用前按 Prompt 估算输入 Token，以最大输出 Token 预留最坏用量/成本；不能预留则不调用。
- 预算检查与预留必须串行化，并在上游调用前原子写入独立预算账本；进程崩溃时允许保守多计，不允许少计。
- 有 usage 时按实际 prompt/completion 和配置单价结算；无 usage 时保留最坏预留。
- 输入/输出 Token 单价分开配置。Token Plan 仍配置等价成本用于保护。
- 主体或全局次数、Token、成本触顶后停止新 LLM 调用；缓存和已生成页仍可返回。
- `RECOMMENDATION_ENABLED=false` 时返回 503 `RECOMMENDATION_DISABLED`，不影响 Catalog。

上游 429：

- 记录全局冷却；优先采用合法 `Retry-After`，限制 1～60 秒。
- 无有效 `Retry-After` 时，连续 429 按 5、15、30、60 秒退避，成功一次后重置。
- 冷却期不进 LLM 队列；首页先试陈旧缓存，无缓存或续页返回 503 `RECOMMENDATION_UPSTREAM_RATE_LIMITED` 和 `Retry-After`。
- 不对已收到 HTTP 响应的生成自动重试；客户端重试原 Cursor。

## 11. 方舟调用边界

- API Key 只通过服务端 Secret/受控环境文件注入。
- Base URL、模型 ID、Prompt 版本、temperature、最大输出 Token、超时和响应字节必须显式配置。
- 启动只验证配置完整性，不因方舟短时不可用阻止 Catalog 启动。
- 使用当前模型实际支持的 JSON 输出模式；无论 `json_object` 还是 JSON Schema，服务端都重新校验。
- LLM 硬超时建议 18 秒，用 `AbortSignal` 取消。
- 客户端中断后，若当前 Cursor 无其他等待者则取消上游；否则继续共享 Promise。
- 不把自由文本、思考过程、工具调用或原始响应返回客户端或写入常规日志。

## 12. 响应与冷启动

```json
{
  "requestId": "req_server-generated-uuid",
  "clientRequestId": "client-generated-uuid",
  "generatedAt": "2026-09-13T17:30:00Z",
  "servedAt": "2026-09-13T17:30:00Z",
  "expiresAt": "2026-09-13T18:00:00Z",
  "sessionId": "opaque-session-logical-id",
  "source": "llm",
  "mode": "personalized",
  "items": [],
  "page": {"index": 1, "pageSize": 24, "hasMore": true, "nextCursor": "opaque-server-cursor"},
  "meta": {
    "requested": 24, "llmReturned": 24, "validAfterSchema": 22,
    "duplicatesRemovedInPage": 1, "duplicatesRemovedInSession": 1,
    "returned": 20, "cache": "miss"
  }
}
```

- `source` 个性化响应固定 `llm`；`meta.cache` 为 `miss|fresh|stale|cursor_replay`。
- `sessionId` 仅用于事件关联，不可枚举、不是 Cursor、不含主体信息。
- `expiresAt` 是会话过期时间。推荐响应统一 `Cache-Control: private, no-store`。

裁剪后无偏好时不调用 LLM，HTTP 200 返回：

```json
{
  "requestId": "req_server-generated-uuid",
  "clientRequestId": "client-generated-uuid",
  "servedAt": "2026-09-13T17:30:00Z",
  "source": "none",
  "mode": "cold_start",
  "items": [],
  "page": {"index": 1, "pageSize": 24, "hasMore": false, "nextCursor": null},
  "meta": {"reason": "insufficient_preference_signals", "llmCalled": false, "cache": "miss"}
}
```

冷启动不返回热门内容。客户端展示：「看过或收藏几部影片后，这里会出现更懂你的推荐。」

## 13. 错误契约

```json
{
  "error": {
    "code": "RECOMMENDATION_UPSTREAM_TIMEOUT",
    "message": "推荐服务暂时不可用",
    "requestId": "req_server-generated-uuid",
    "clientRequestId": "client-generated-uuid",
    "retryable": true,
    "retryAfterSeconds": 10
  }
}
```

| HTTP | code | 场景 |
| ---: | --- | --- |
| 400 | `INVALID_RECOMMENDATION_INPUT` | 请求字段、数量、类型或续页字段非法 |
| 400 | `INVALID_RECOMMENDATION_CURSOR` | Cursor 签名、主体绑定或页参数非法 |
| 401 | `INVALID_ANONYMOUS_SUBJECT` | 主体缺失或签名无效 |
| 410 | `RECOMMENDATION_CURSOR_EXPIRED` | 会话过期、被清理或进程重启 |
| 413 | `RECOMMENDATION_PAYLOAD_TOO_LARGE` | 请求体超限 |
| 429 | `RECOMMENDATION_RATE_LIMITED` | 主体或连接来源短时超频 |
| 429 | `RECOMMENDATION_SUBJECT_BUDGET_EXHAUSTED` | 主体当日次数或 Token 用尽 |
| 502 | `RECOMMENDATION_INVALID_RESPONSE` | LLM 无任何有效候选 |
| 503 | `RECOMMENDATION_DISABLED` | 功能开关关闭 |
| 503 | `RECOMMENDATION_CAPACITY_EXCEEDED` | 会话、计数 Map、并发或队列用尽 |
| 503 | `RECOMMENDATION_GLOBAL_BUDGET_EXHAUSTED` | 全局次数、Token 或成本触顶 |
| 503 | `RECOMMENDATION_BUDGET_STATE_UNAVAILABLE` | 每日预算账本损坏、版本不兼容或无法安全写入 |
| 503 | `RECOMMENDATION_UPSTREAM_RATE_LIMITED` | 方舟 429 冷却中 |
| 503 | `RECOMMENDATION_UPSTREAM_UNAVAILABLE` | 方舟不可用 |
| 504 | `RECOMMENDATION_UPSTREAM_TIMEOUT` | 方舟超时 |

`requestId` 永远是服务端 ID。`retryAfterSeconds` 仅在有明确时间时返回，并设置 `Retry-After`。
每日预算用尽时重试时间指向下一日界线，客户端不立即重试。

## 14. 客户端 VOD 验证与迁移

- 按 `title → originalTitle → aliases` 生成去重搜索词，单候选最多 2 个。
- 用标题、年份、媒体类型和季号严格匹配；多结果接近判定歧义。
- 匹配成功后使用 VOD `Video` 身份和播放信息；未匹配/歧义/失败项不进可播主列表。
- 保持服务端顺序，不按 VOD 完成顺序重排。
- 每页预算：24 候选、并发 3、单候选 2 个词、30 次 VOD 请求、最多新增 12 个可播项。
- 首页找到 12 个可播项后仍保留 Cursor。未找到候选进入手动查找区，可查原结果、换源或主动查最多 3 个备用源。

迁移要求：

- 新增 `BackendRecommendationClient`；`RecommendationBatch` 增加 mode/session/page/meta/request-id/结构化错误。
- `RecommendedFeedController` 增加冷启动、Cursor、`loadMore`、续页重试、页追加和每页预算。
- 客户端可保留 30 分钟 UI 缓存，但不伪造新 Cursor；410 后创建新会话。
- 删除输出方舟原始响应的调试日志。公开发布前从 APK/IPA、Dart Define、Asset 和远程配置删除生产 Key。
- 直连能力如保留，只用于本地开发验证，由不进发布包的开关隔离。
- 客户端总超时建议 25～30 秒，不再使用直连验证的 300 秒默认值。

## 15. 事件回传

```http
POST /api/v1/recommendations/events
Content-Type: application/json
X-Jive-Anonymous-Subject: opaque-server-signed-value
```

```json
{
  "clientRequestId": "client-generated-uuid",
  "sessionId": "opaque-session-logical-id",
  "pageIndex": 1,
  "candidatePosition": 3,
  "event": "vod_matched",
  "occurredAt": "2026-09-13T17:31:00Z"
}
```

允许事件：`candidate_exposed`、`vod_matched`、`vod_not_found`、`vod_ambiguous`、`vod_search_failed`、
`manual_search_opened`、`source_switch_opened`、`manual_playable_found`。

- 不上传标题、VOD URL、来源凭据或播放地址。
- 验证 `sessionId` 属于当前主体，页码和位置在会话范围内。
- 事件接口单独限流，不调用 LLM。
- 若未实现该接口，VOD 匹配率等不得列为后端验收项。

## 16. 日志、监控与隐私

记录 Server/Client/方舟 request-id、模型/Prompt 版本、页索引、总/排队/LLM 耗时、输入条数、
候选返回/有效/丢弃/去重/最终数、缓存、限额、冷却、Token 和估算成本。
会话和主体只记录带密钥不可逆摘要。

指标包括成功率、P50/P95/P99、超时、429/冷却、JSON 无效率、Token/成本/预算拒绝、
并发/队列、会话/缓存/内存/LRU、Cursor 过期/重放/并发合并/跨页重复、冷启动，
以及实现事件回传后的 VOD 匹配和手动查找转化。

现有 count/sum/max 无法得到分位数；必须增加直方图桶或受限分位数摘要，不用平均值代替 P50/P95/P99。

禁止记录 Authorization、完整主体 ID、Cursor、完整历史、Prompt 和 LLM 原始响应。
标题默认不入常规日志；临时明文采样必须有权限、采样率和时效。
偏好快照最长保留 30 分钟；缓存只保留校验后候选和 HMAC 指纹。

## 17. 配置、部署与模块

建议配置：

```text
RECOMMENDATION_ENABLED
ARK_API_KEY
ARK_BASE_URL
ARK_MODEL
ARK_REQUEST_TIMEOUT_MS
ARK_MAX_OUTPUT_TOKENS
ARK_MAX_RESPONSE_BYTES
ARK_TEMPERATURE
ARK_INPUT_YUAN_PER_MILLION_TOKENS
ARK_OUTPUT_YUAN_PER_MILLION_TOKENS
RECOMMENDATION_PROMPT_VERSION
RECOMMENDATION_CURSOR_SECRET
RECOMMENDATION_SUBJECT_SECRET
RECOMMENDATION_FINGERPRINT_SECRET
RECOMMENDATION_SESSION_TTL_MS
RECOMMENDATION_MAX_SESSIONS
RECOMMENDATION_MAX_CACHE_ENTRIES
RECOMMENDATION_CACHE_FRESH_TTL_MS
RECOMMENDATION_CACHE_STALE_TTL_MS
RECOMMENDATION_CLEANUP_INTERVAL_MS
RECOMMENDATION_MAX_CONCURRENCY
RECOMMENDATION_MAX_QUEUE
RECOMMENDATION_SUBJECT_RATE_LIMIT_PER_MINUTE
RECOMMENDATION_SOURCE_RATE_LIMIT_PER_MINUTE
RECOMMENDATION_SUBJECT_DAILY_CALLS
RECOMMENDATION_SUBJECT_DAILY_TOKENS
RECOMMENDATION_GLOBAL_DAILY_CALLS
RECOMMENDATION_GLOBAL_DAILY_TOKENS
RECOMMENDATION_GLOBAL_DAILY_COST_YUAN
RECOMMENDATION_BUDGET_TIMEZONE
RECOMMENDATION_BUDGET_STATE_FILE
RECOMMENDATION_MIN_ITEMS_FOR_NEXT_PAGE
```

Nginx 新增 `/api/v1/recommendations/`；代理超时建议 30 秒、客户端 25～30 秒；
推荐响应不用 Catalog 公共缓存头、ETag 或 CDN；密钥由 systemd `EnvironmentFile` 注入。
预算账本文件应位于 systemd 已授权的可写目录（建议 `/var/lib/jive-catalog/recommendation-budget.json`），采用临时文件加原子重命名保存。
推荐故障不改变现有 `/health/ready` 对 Catalog 的判断，推荐状态进入独立诊断。

建议模块：

```text
src/recommendation/
  types.ts       validator.ts   prompt.ts      ark-client.ts
  subject.ts     cursor.ts      store.ts       limiter.ts
  service.ts     monitoring.ts
```

不把推荐加入 TMDB `CatalogSnapshot` 或复用 `state-store`。拆出可组合 Catalog/Recommendation 异步路由，
增加安全 Body Parser 和统一异步异常边界。每日预算使用独立原子文件 Store，不复用 Catalog 状态文件。
同步更新 `PROJECT_MAP.md`、README、OpenAPI、
`.env.example`、部署手册和版本号。

## 18. 验收与测试

- [ ] App 可申请并持久保存服务端匿名主体；Cursor 不能跨主体使用。
- [ ] 候选只来自 LLM 或同偏好 LLM 缓存，推荐链路不调用 TMDB。
- [ ] 非法 JSON 不崩溃，单条非法不影响其他条目。
- [ ] 续页只追加、稳定去重；同 Cursor 串行或并发请求只调用一次 LLM。
- [ ] 重启后旧 Cursor 返回 410，不承诺恢复缓存。
- [ ] 裁剪后无偏好时不调用 LLM，返回 `cold_start`。
- [ ] 可播主列表只展示 VOD 严格匹配成功项。
- [ ] 会话、缓存、计数 Map、并发和队列均有硬上限，每 60 秒清理。
- [ ] 主体限流/每日次数/Token，以及全局并发/队列/次数/Token/成本均生效；预算调用前预留并先原子持久化，重启不能重置当日已用预算。
- [ ] 429 进入有界冷却；推荐可独立关闭，不影响 Catalog。
- [ ] 压测 1,000 会话、500 缓存项和 4+16 并发/队列，推荐子系统最坏内存不超过 80 MiB 目标。
- [ ] APK/IPA 不含生产方舟 Key；服务端和客户端均不输出 LLM 原始响应。
- [ ] 可查询成功率、P50/P95/P99、超时、429、JSON 有效率、Token/成本、容量、缓存和 Cursor 指标。

必测场景包括：主体签名篡改/轮换/跨主体 Cursor；Body 大小与输入裁剪；围栏/非法/混合 JSON；
顺序与跨页去重；至少 20 个同 Cursor 并发重放；超时、429、5xx、过大响应、usage 缺失；
限额预留竞态、预算账本重启恢复/损坏 fail-closed；会话满载、LRU、清理、重启后 410 和内存压测；日志脱敏、OpenAPI 和客户端契约。

## 19. 实施顺序

1. 固化 OpenAPI、DTO、空值、错误码、request-id 和匿名主体契约。
2. 拆分异步 HTTP 路由，实现 JSON Body Parser、64 KiB 上限和断开取消。
3. 实现主体签发/验证、输入裁剪、逐条校验和稳定去重。
4. 封装方舟调用，实现超时、响应上限、usage、错误映射和安全日志。
5. 实现分层限流、并发/队列、独立预算账本、调用前原子预留/结算、开关和 429 冷却。
6. 实现有界内存 Store、LRU、定时清理、Cursor、页事务和同 Cursor single-flight。
7. 实现冷启动、新鲜/陈旧缓存、续页和重启后 410。
8. 增加监控直方图、预算/容量/冷却诊断、事件回传和告警。
9. 完成单元、并发、契约、压测、隐私和异常测试。
10. 更新 OpenAPI、README、`.env.example`、项目地图、Nginx/systemd 文档和版本号。
11. 客户端迁移到后端，增加主体持久化、冷启动、续页、410 恢复和事件回传。
12. 删除生产包方舟密钥和原始响应日志，再切换生产流量。

## 20. 最终原则

```text
LLM 决定推荐什么
服务端保证匿名身份、结构、去重、顺序、分页、幂等和成本可控
冷启动不用热门内容伪装个性化
客户端最终确认当前 VOD 源是否真的能播
V1 进程内状态可丢失，但容量、费用和失败行为必须明确且可监控
```

后续优化只要改变候选来源、排序、主体数据用途或跨重启存储承诺，必须重新评审。
TMDB 规范化若在 V2 引入，不得未经评审演变为第二套推荐系统。
