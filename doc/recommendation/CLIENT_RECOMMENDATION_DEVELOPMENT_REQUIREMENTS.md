# 「猜你喜欢」客户端开发需求 V1

> 状态：后端 V1 已部署，客户端待实现
> 目标分支：`codex/backend-recommendation-client-v1`
> 生产 Base URL：`https://hey-rickytse.com`

## 1. 目标

将客户端从“直接调用方舟”迁移为“调用 Jive 后端生成候选，再由客户端在当前 VOD 源确认可播”。生产包不包含方舟密钥、模型 ID 或方舟接口地址。

本期包括：匿名主体、推荐首页、冷启动、Cursor 续页、结构化错误、30 分钟 UI 缓存、VOD 严格匹配、最小化事件回传和相关测试。

本期不包括：登录账号、跨设备同步、客户端调用 LLM、服务端搜索 VOD、Cursor 跨服务重启恢复。

## 2. 配置与安全

- 生产客户端只配置 Jive Backend Base URL；默认 `https://hey-rickytse.com`。
- 新增环境配置时建议命名为 `JIVE_API_BASE_URL`，禁止加入 `ARK_API_KEY`、`ARK_MODEL`、`ARK_BASE_URL`。
- 从公开 Release 的 Dart Define、Asset、远程配置、日志和构建脚本中移除生产方舟密钥。
- 如保留 `ArkRecommendationClient`，必须由只在本地 Debug/Profile 可用且不进入发布配置的开关隔离；默认路径必须是后端 Client。
- 日志只记录阶段、耗时、HTTP 状态、服务端 `requestId` 和错误码；不得记录匿名主体、Cursor、完整历史、完整响应、VOD 地址或凭据。

## 3. 匿名主体生命周期

1. App 启动或首次进入推荐模块时读取本地持久化值。
2. 不存在时调用匿名主体签发接口。
3. 成功后持久化。优先 Keychain/Keystore；若当前 Flutter 技术栈暂用普通偏好存储，必须单独记录安全债务且不得同步或备份为用户数据。
4. 所有推荐和事件请求携带 `X-Jive-Anonymous-Subject`。
5. 401 时清除旧值、重新签发，并最多重试原操作一次。
6. 重装、存储被清除或签名密钥轮换后生成新主体是预期行为。

不得根据同一主体跨天主动换 ID。同一 `anonymousSubjectId` 的每日额度由服务端按自然日账本计算，第二天自动进入新日额度；客户端无需处理预算计数。

## 4. 数据采集与请求构造

首页每次生成新的 UUID `clientRequestId`，上传：

- 最近 20 条有效历史：完播或 `progress >= 0.05`，按 `watchedAt` 降序。
- 最近 10 条有效内容库记录：`favorite || following`，按 `updatedAt` 降序。
- 标题最多 100 字符；分类、剧集名最多 50 字符。
- 默认 `locale=zh-CN`、`pageSize=24`。

不要上传播放 URL、当前 VOD 源配置、Cookie、Authorization、API Key、设备硬件 ID。必须保证序列化请求不超过 64 KiB。

续页生成新的 `clientRequestId`，请求体只能包含它和上一页 `nextCursor`。不得根据本地历史重新构造续页，也不得修改 Cursor。

## 5. 客户端模型

`RecommendationCandidate` 应与接口字段一致：

- 将现有 `confidence` JSON 读取迁移到 `modelConfidence`；如为了短期本地缓存兼容可读取旧字段，写出和网络契约必须使用 `modelConfidence`。
- 未知枚举或必要字段非法时丢弃该候选，不让解析异常中断整页。
- 服务端顺序是推荐顺序，客户端异步 VOD 搜索完成后仍按该顺序展示。

`RecommendationBatch` 至少包含：

- `requestId`、`clientRequestId`
- `mode`、`source`
- `generatedAt?`、`servedAt`、`expiresAt?`
- `sessionId?`
- `items`
- `page.index/pageSize/hasMore/nextCursor`
- 个性化或冷启动 `meta`

新增结构化异常 `RecommendationApiException`，至少保留 HTTP 状态、`code`、`message`、`requestId`、`clientRequestId?`、`retryable`、`retryAfterSeconds?`。

## 6. 页面与会话状态

Controller 至少区分：

- 首次加载、个性化成功、冷启动、加载下一页、部分结果、无更多、可重试错误。
- 当前 `sessionId`、当前页号、`nextCursor`、`hasMore`、正在请求的 Cursor。
- 服务端候选、匹配成功的可播项、未匹配/歧义/搜索失败项。

同一时刻只允许一个首页请求和一个续页请求。对同一个 Cursor 的重复 UI 触发必须合并为同一个 Future；服务端虽可 single-flight/重放，客户端仍不能用重复 HTTP 请求消耗每主体低频限流。

### 首页

- 有 30 分钟内且偏好一致的 UI 缓存时可先展示缓存。
- 普通重进页面可用缓存；用户明确下拉刷新时创建新首页会话。
- 缓存内容必须保留服务端真实 Cursor 和过期时间，不得伪造、延长或拼接 Cursor。
- 缓存超过会话有效期后可以展示已有可播内容，但不得再用过期 Cursor 续页。

### 续页

- 仅在 `hasMore=true` 且 `nextCursor != null` 时允许 `loadMore`。
- 请求期间禁用重复触发；成功后追加，不替换已展示页。
- 使用候选身份 `mediaType + 规范化标题 + year` 做跨页防御性去重。
- 同一 Cursor 超时或可重试失败时保留它，以便原 Cursor 重试。
- 410 时保留当前列表，清除会话/Cursor，用最新偏好新建会话；新会话结果应按产品交互决定替换或作为新一轮推荐，不能当作旧会话下一页直接拼接。

### 冷启动

`mode=cold_start` 时不进入 VOD 搜索，显示：「看过或收藏几部影片后，这里会出现更懂你的推荐。」

## 7. VOD 匹配

每页严格执行以下预算：

- 最多处理 24 个服务端候选。
- 搜索并发最多 3。
- 每个候选按 `title → originalTitle → aliases` 生成去重词，最多使用 2 个。
- 每页 VOD 搜索总请求最多 30 次。
- 每页最多新增 12 个可播项。

匹配使用标题、年份、媒体类型和季号；多个接近结果判定为歧义。只有严格匹配成功的 VOD `Video` 可以进入可播主列表。未找到、歧义或搜索失败不能以 LLM 候选直接替代可播项。

异步搜索可以并发，但最终列表保持服务端候选顺序。首页达到 12 个可播项后仍保存服务端 Cursor。未匹配候选可进入手动查找区，允许用户查原结果、换源，或主动搜索最多 3 个备用源。

## 8. 事件回传

按照 [`CLIENT_RECOMMENDATION_API.md`](CLIENT_RECOMMENDATION_API.md) 回传候选曝光、匹配结果、手动查找和换源行为。事件关联当前 `sessionId/pageIndex/candidatePosition`，位置按服务端候选原始顺序从 1 开始。

事件请求与推荐主链路解耦：失败不能阻塞 UI、VOD 匹配或播放，也不能形成自动重试风暴。事件载荷禁止包含标题和播放/来源敏感信息。

## 9. 超时、限流与降级

- 推荐 HTTP 总超时 25～30 秒；不沿用方舟直连的 300 秒超时。
- 429/503 优先遵循响应头 `Retry-After`，其次使用 `retryAfterSeconds`。
- 不在页面加载、生命周期恢复或滚动监听中无条件循环重试。
- 504 续页优先保留并重试原 Cursor；首页可创建新请求。
- 推荐不可用时不得影响 Catalog、搜索、收藏和播放等主功能。
- 已有页面或 UI 缓存可以作为只读展示降级；客户端不得把它标记为一次新的服务端生成。

完整错误动作见接口文档第 6 节。

## 10. 建议代码改动

| 路径 | 改动 |
| --- | --- |
| `lib/data/recommendation/backend_recommendation_client.dart` | 新增签发主体、首页、续页和事件接口 |
| `lib/data/recommendation/backend_recommendation_config.dart` | 仅保留 Jive Base URL 和超时配置 |
| `lib/data/recommendation/anonymous_subject_store.dart` | 新增匿名主体持久化和 401 重签逻辑 |
| `lib/data/recommendation/recommendation_repository.dart` | 默认切到后端 Client，调整 UI 缓存和错误模型 |
| `lib/domain/recommendation.dart` | 增加 mode/session/page/meta/requestId，迁移 `modelConfidence` |
| `lib/features/home/recommended_feed_controller.dart` | 增加冷启动、Cursor、loadMore、请求合并、410 恢复和页追加 |
| `lib/features/home/home_page.dart` | 增加加载更多、冷启动、部分失败和稍后重试交互 |
| `test/data/recommendation/` | 增加接口解析、主体持久化、错误和 Cursor 测试 |
| `test/features/home/recommended_feed_controller_test.dart` | 增加状态机、并发合并、分页顺序和恢复测试 |

现有 `ark_recommendation_client.dart`、`ark_recommendation_config.dart` 及其 Provider 不得继续作为生产默认路径。

## 11. 必测场景

- 首次签发并持久化；重启 App 复用同一主体；401 后只重签一次。
- 首页请求字段裁剪、日期和 UUID 格式、64 KiB 上限。
- 个性化、冷启动、空候选、未知字段和非法单个候选解析。
- `modelConfidence` 正确读取。
- 下一页请求不携带首页字段；成功追加并保持服务端顺序。
- 连续点击/并发滚动对同一 Cursor 只发一个 HTTP 请求。
- 同一 Cursor 超时后重试；410 后保留旧列表并创建新会话。
- 429/503 遵循 `Retry-After`，无立即重试循环。
- 每页 VOD 并发、关键词、总请求和最多 12 个可播项的预算。
- 未匹配和歧义候选不进入可播列表；事件位置仍对应原候选顺序。
- 事件失败不影响展示和播放。
- Release 构建产物与配置中不存在生产 `ARK_API_KEY`。

## 12. 完成标准

- [ ] 生产默认链路只调用 Jive 后端。
- [ ] 匿名主体可持久化，401 恢复无循环。
- [ ] 首页、冷启动、续页、重试和 410 恢复可用。
- [ ] 同一 Cursor 的客户端并发只产生一次 HTTP 请求。
- [ ] 只有 VOD 严格匹配成功项进入可播列表，顺序和预算符合要求。
- [ ] 结构化错误和 `Retry-After` 行为通过测试。
- [ ] 推荐事件按最小数据集回传且不阻塞主流程。
- [ ] 25～30 秒超时生效，推荐故障不影响其他功能。
- [ ] Release 不含方舟密钥、直连接口或原始 LLM 响应日志。
- [ ] 与当前部署版本完成真机联调并记录后端 commit/OpenAPI 版本。
