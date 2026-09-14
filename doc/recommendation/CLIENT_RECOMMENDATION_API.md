# 「猜你喜欢」客户端接口文档

> API 版本：V1
> 生产 Base URL：`https://hey-rickytse.com`
> 机器契约：Jive-Backend `docs/openapi.yaml`

所有存在消息体的请求和响应均为 UTF-8 JSON。推荐响应使用 `Cache-Control: private, no-store`。客户端应记录响应头 `X-Request-ID` 以便排障，但不得记录匿名主体或 Cursor。

## 1. 签发匿名主体

```http
POST /api/v1/recommendations/anonymous-subject
Content-Type: application/json

{}
```

成功：HTTP 201。

```json
{
  "anonymousSubjectId": "v1.opaque-signed-value",
  "issuedAt": "2026-09-14T02:28:00.000Z"
}
```

客户端在首次使用推荐能力前申请一次，并持久化保存 `anonymousSubjectId`。后续推荐和事件请求添加：

```http
X-Jive-Anonymous-Subject: v1.opaque-signed-value
```

不得用 IDFA、Android ID、设备序列号等硬件标识代替。收到 401 `INVALID_ANONYMOUS_SUBJECT` 时，删除旧值、重新签发一次，并仅重放一次原操作；再次失败则展示错误，不循环重签。

## 2. 获取推荐首页

```http
POST /api/v1/recommendations/personalized
Content-Type: application/json
X-Jive-Anonymous-Subject: v1.opaque-signed-value
```

```json
{
  "clientRequestId": "0aa95bdf-3454-4e40-8209-e423293e5858",
  "locale": "zh-CN",
  "pageSize": 24,
  "history": [
    {
      "title": "降临",
      "year": "2016",
      "category": "电影片",
      "episodeName": "正片",
      "progress": 0.92,
      "completed": true,
      "watchedAt": "2026-09-13T16:20:00+08:00"
    }
  ],
  "library": [
    {
      "title": "流人",
      "year": "2022",
      "category": "欧美剧",
      "favorite": true,
      "following": true,
      "updatedAt": "2026-09-12T12:00:00+08:00"
    }
  ]
}
```

约束：

- `clientRequestId`：每次 HTTP 操作新建 UUID；最大 64 字符，它不是幂等键。
- `locale`：可省略，默认 `zh-CN`，最大 20 字符。
- `pageSize`：可省略，默认 24；只能是 12～24 的整数。
- `history`：最多 20 条；仅上传完播或进度不少于 5% 的记录，按 `watchedAt` 从新到旧裁剪。
- `library`：最多 10 条；仅上传收藏或追更记录，按 `updatedAt` 从新到旧裁剪。
- 日期使用带时区的 ISO 8601。`progress` 范围为 0～1。
- 请求体不超过 64 KiB；不要上传 VOD URL、来源配置、Cookie、Authorization、API Key 或硬件标识。

个性化成功：HTTP 200。

```json
{
  "requestId": "req_server-generated-id",
  "clientRequestId": "0aa95bdf-3454-4e40-8209-e423293e5858",
  "generatedAt": "2026-09-14T02:28:01.000Z",
  "servedAt": "2026-09-14T02:28:01.000Z",
  "expiresAt": "2026-09-14T02:58:01.000Z",
  "sessionId": "opaque-session-id",
  "source": "llm",
  "mode": "personalized",
  "items": [
    {
      "title": "银翼杀手2049",
      "originalTitle": "Blade Runner 2049",
      "aliases": ["银翼杀手 2049"],
      "year": "2017",
      "mediaType": "movie",
      "category": "movie",
      "latestSeasonNumber": null,
      "modelConfidence": 0.91,
      "reason": "与你偏爱的科幻悬疑相近"
    }
  ],
  "page": {
    "index": 1,
    "pageSize": 24,
    "hasMore": true,
    "nextCursor": "opaque-server-cursor"
  },
  "meta": {
    "requested": 24,
    "llmReturned": 24,
    "validAfterSchema": 22,
    "duplicatesRemovedInPage": 1,
    "duplicatesRemovedInSession": 1,
    "returned": 20,
    "cache": "miss"
  }
}
```

字段注意：

- 客户端必须读取 `modelConfidence`，不得继续只读取旧直连响应中的 `confidence`。
- `mediaType` 只可能是 `movie|tv`；`category` 只可能是 `movie|tv|animation|variety`。
- `meta.cache` 为 `miss|fresh|stale|cursor_replay`；不得依赖它判断 Cursor 是否有效。
- `items` 是候选，不代表真实存在或可播；必须经过客户端当前 VOD 源严格匹配。
- 未知的新增响应字段应忽略，以保持向前兼容。

## 3. 冷启动响应

当有效历史和内容库均为空时，服务端不调用 LLM，HTTP 200 返回：

```json
{
  "requestId": "req_server-generated-id",
  "clientRequestId": "0aa95bdf-3454-4e40-8209-e423293e5858",
  "servedAt": "2026-09-14T02:28:01.000Z",
  "source": "none",
  "mode": "cold_start",
  "items": [],
  "page": {"index": 1, "pageSize": 24, "hasMore": false, "nextCursor": null},
  "meta": {"reason": "insufficient_preference_signals", "llmCalled": false, "cache": "miss"}
}
```

客户端展示：「看过或收藏几部影片后，这里会出现更懂你的推荐。」不要用热门内容伪装个性化结果。

## 4. 获取下一页

使用上一页原样返回的 `nextCursor`：

```http
POST /api/v1/recommendations/personalized
Content-Type: application/json
X-Jive-Anonymous-Subject: v1.opaque-signed-value
```

```json
{
  "clientRequestId": "f2d69ca4-8c9c-4106-a0d1-cbf0e55e6a45",
  "cursor": "opaque-server-cursor"
}
```

续页请求只能包含这两个字段，不能再发送 `history`、`library`、`locale` 或 `pageSize`。同一 Cursor 的串行或并发重试会重放同一结果，不重复触发 LLM。客户端仍应在本地合并请求，避免浪费 HTTP 限流额度。

会话和 Cursor 只保存在服务端进程内，约 30 分钟过期；部署或重启后旧 Cursor 返回 410。收到 410 时保留已展示内容，清除旧 Cursor，并用当前最新偏好发起一个新首页请求。

## 5. 回传事件

```http
POST /api/v1/recommendations/events
Content-Type: application/json
X-Jive-Anonymous-Subject: v1.opaque-signed-value
```

```json
{
  "clientRequestId": "98a7f174-0134-4fe6-ae4c-0955d822c845",
  "sessionId": "opaque-session-id",
  "pageIndex": 1,
  "candidatePosition": 3,
  "event": "vod_matched",
  "occurredAt": "2026-09-14T02:28:05.000Z"
}
```

成功：HTTP 204，无响应体。允许的 `event`：

- `candidate_exposed`
- `vod_matched`
- `vod_not_found`
- `vod_ambiguous`
- `vod_search_failed`
- `manual_search_opened`
- `source_switch_opened`
- `manual_playable_found`

`pageIndex` 为 1～3，`candidatePosition` 为 1～24。事件不得携带标题、VOD URL、来源凭据或播放地址。事件失败不阻塞推荐展示或播放；不做高频自动重试。

## 6. 错误格式与处理

```json
{
  "error": {
    "code": "RECOMMENDATION_UPSTREAM_TIMEOUT",
    "message": "推荐服务暂时不可用",
    "requestId": "req_server-generated-id",
    "clientRequestId": "f2d69ca4-8c9c-4106-a0d1-cbf0e55e6a45",
    "retryable": true,
    "retryAfterSeconds": 10
  }
}
```

| HTTP/code | 客户端动作 |
| --- | --- |
| 400 `INVALID_RECOMMENDATION_INPUT` | 视为客户端契约错误；记录 `requestId`，不自动重试 |
| 400 `INVALID_RECOMMENDATION_CURSOR` | 清除 Cursor，用最新偏好新建会话 |
| 401 `INVALID_ANONYMOUS_SUBJECT` | 重新签发主体并仅重试一次 |
| 410 `RECOMMENDATION_CURSOR_EXPIRED` | 保留已展示内容，清除 Cursor，新建会话 |
| 413 `RECOMMENDATION_PAYLOAD_TOO_LARGE` | 修复客户端裁剪，不重试原请求 |
| 429 `RECOMMENDATION_RATE_LIMITED` | 遵循 `Retry-After`，显示稍后重试，不立即自动重试 |
| 429 `RECOMMENDATION_SUBJECT_BUDGET_EXHAUSTED` | 当日不再自动请求，允许用户稍后手动重试 |
| 502 `RECOMMENDATION_INVALID_RESPONSE` | 可保留已有内容并提供手动重试 |
| 503 `RECOMMENDATION_DISABLED` | 隐藏/降级推荐入口，不轮询 |
| 503 `RECOMMENDATION_CAPACITY_EXCEEDED` | 遵循 `Retry-After`；无值时退避后由用户重试 |
| 503 `RECOMMENDATION_GLOBAL_BUDGET_EXHAUSTED` | 当日不自动请求 |
| 503 `RECOMMENDATION_BUDGET_STATE_UNAVAILABLE` | 服务不可用，不自动重试风暴 |
| 503 `RECOMMENDATION_UPSTREAM_RATE_LIMITED` | 严格遵循 `Retry-After` |
| 503 `RECOMMENDATION_UPSTREAM_UNAVAILABLE` | 保留已有内容，退避后允许手动重试 |
| 504 `RECOMMENDATION_UPSTREAM_TIMEOUT` | 首页可重新发起；续页优先用原 Cursor 重试 |

客户端总超时设为 25～30 秒。一次用户操作最多进行一次透明重签重试；429/503 不得立即循环重试。
