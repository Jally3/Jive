# Jive TMDB Catalog 语言元数据与新片榜清洗需求及实施计划

> 文档状态：后端可行性评审后修订，待服务端实施
> 目标版本：Catalog V1 兼容升级
> 适用对象：TMDB Catalog 生成任务、Catalog API、Jive Flutter 客户端
> 相关文档：TMDB_CATALOG_BACKEND_API_REQUIREMENTS.md、TMDB_CURATED_FEEDS_REQUIREMENTS.md
> 当前数据版本：schemaVersion = 1

## 1. 文档目的

本文供服务端直接读取和实施，解决两个问题：

1. 当前“新片”榜混合了最近首映的新作品和仍在更新的多年老剧，大量海外日播长寿剧因最近一集的播出日期占据榜首。
2. Catalog 条目缺少原始语言和来源地区，客户端无法可靠提供“全部、华语优先、仅华语、仅非华语”筛选。

职责原则：

- 服务端负责公共榜单质量：识别新作品与老作品更新，清理低价值海外长寿日播剧。
- 服务端负责元数据事实：返回原始语言和来源国家/地区。
- 客户端负责个人偏好：基于服务端字段过滤或重排，不重复判断长寿剧。

本文中的“必须”是上线前要求，“建议”是默认实施方式，“可选”允许后续迭代。

## 2. 通俗版改造说明

### 2.1 服务端

现有接口地址和 feed 参数保持不变。服务端需要：

1. 生成“新片”时将候选拆为“最近首映的新作品”和“老作品最近更新”。
2. 只清理第二类中的低价值海外长寿日播剧。
3. 限制老作品更新在新片榜中的比例。
4. 给每条内容增加 originalLanguage 和 originCountries。

客户端拿到的“新片”应已经是清洗后的公共榜单。

### 2.2 客户端

客户端需要：

1. 兼容读取语言和地区新字段。
2. 旧快照缺少字段时归类为“未知”，不能加载失败。
3. 后续按用户设置做华语优先或仅华语等过滤。
4. 在发起 VOD 搜索之前完成偏好过滤，避免无效请求。

## 3. 本期范围

### 3.1 必须实现

1. Catalog 条目增加原始语言和来源地区。
2. 服务端拆分新作品池和老作品更新池。
3. 只在老作品更新池执行海外长寿剧清理。
4. 新片的五个分组分别使用稳定的新旧内容配额。
5. 保持 schemaVersion = 1 和现有 HTTP 路径兼容。
6. 增加结构校验、生成报告、自动化测试和发布检查。
7. 重新生成线上快照及 App 打包的本地兜底快照。
8. 保留现有综艺语言准入：三个 Feed 的综艺只允许 originalLanguage 为 zh、ja、ko。

### 3.2 不在本期

- 不改造成可透传任意 TMDB 参数的动态代理。
- 不为每个用户在服务端生成不同快照。
- 不根据标题是否含汉字判断华语。
- 不改变热门和高分中电影、普通电视剧、动漫的地区或语言覆盖；综艺继续执行 zh、ja、ko 全局准入。
- 不在服务端执行 VOD 搜索或返回播放地址。

## 4. 职责和数据流

~~~text
TMDB API
  ↓ 语言、地区、genre、季度、集数、最近播出日期
Catalog 生成任务
  ├─ 拆分新作品 / 老作品更新
  ├─ 清理海外长寿日播剧
  ├─ 按配额生成五个分组
  └─ 输出语言和地区元数据
  ↓
Catalog API / 静态 JSON
  ↓
Jive 客户端
  ├─ 用户语言偏好过滤或重排
  ├─ 当前 VOD 源搜索与严格匹配
  └─ 展示和播放
~~~

## 5. HTTP 接口契约

### 5.1 请求不变

~~~http
GET /api/tmdb/v1/catalog?feed=latest
GET /api/tmdb/v1/catalog?feed=popular
GET /api/tmdb/v1/catalog?feed=top_rated
~~~

现有 ETag、If-None-Match、revision、generatedAt、expiresAt，以及失败时返回最近成功快照的行为保持不变。

### 5.2 Item 新字段

| 字段 | 类型 | 要求 | 说明 |
| --- | --- | --- | --- |
| originalLanguage | string | 必须输出，可为空 | TMDB original_language，规范为小写 |
| originCountries | string[] | 必须输出，可为空数组 | ISO 3166-1 国家/地区代码，大写、去重 |

示例：

~~~json
{
  "tmdbId": 79481,
  "mediaType": "tv",
  "category": "animation",
  "localizedTitle": "斗破苍穹",
  "originalTitle": "斗破苍穹",
  "originalLanguage": "zh",
  "originCountries": ["CN"],
  "releaseDate": "2017-01-07",
  "sortDate": "2026-09-12",
  "latestSeasonNumber": 5,
  "rating": 7.919,
  "voteCount": 61,
  "popularity": 52.3758,
  "posterPath": "/example.jpg"
}
~~~

### 5.3 兼容要求

- 本次属于 Item 内增量字段，保持 schemaVersion = 1。
- 旧客户端必须能够忽略新增字段。
- 新客户端必须能读取没有新增字段的旧快照。
- 非法语言或地区值应使单条降级为“未知”，不能使整份快照失效。
- “必须输出新字段”仅约束本版本新生成的快照；部署期间恢复的历史快照允许暂时缺少新字段。
- 服务端不得在保持原 revision 和 ETag 不变时，静默改写历史快照并补默认字段。
- 部署新版本后必须主动刷新三个 Feed；刷新完成前，新客户端按缺字段即未知处理。
- OpenAPI 中新增字段应先声明为可选并注明新生成快照必有，避免把合法的历史快照定义为无效。

## 6. TMDB 字段来源

### 6.1 列表响应

从 Discover、Trending 和 tv/on_the_air 的列表条目读取：

~~~text
original_language
origin_country
genre_ids
~~~

- original_language 用于电影和电视。
- origin_country 通常可直接用于电视。
- genre_ids 必须在生成器内部保留，用于识别 Soap 及现有动漫/综艺分类。
- 三个 Feed 的综艺继续只允许 original_language 为 zh、ja、ko；该规则在 Feed 候选阶段执行，不能隐藏在通用 DTO 规范化函数中。

### 6.2 TV Detail

对老作品更新候选请求：

~~~http
GET /3/tv/{tmdbId}?language=zh-CN
~~~

读取：

~~~text
original_language
origin_country
number_of_seasons
number_of_episodes
type
genres[*].id
last_episode_to_air.air_date
last_episode_to_air.season_number
~~~

现有生成器已对 tv/on_the_air 去重候选请求 TV Detail。本次必须复用同一响应，不增加重复请求。

### 6.3 Movie Detail

电影列表通常不含完整制作国家。对最终会写入快照的电影请求：

~~~http
GET /3/movie/{tmdbId}?language=zh-CN
~~~

将 production_countries[*].iso_3166_1 映射为 originCountries。

### 6.4 请求成本

- 必须先排序、去重并选出可能发布的条目，再补查 Detail。
- 同一生成周期按 mediaType + tmdbId 合并 Detail 请求。
- 列表和 Detail 共用同一个全局请求并发上限，默认 4，禁止分别创建两个可同时跑满的并发池。
- 必须增加进程内跨生成周期 Detail 缓存和同 Key 在途请求合并。默认成功缓存：Movie Detail 7 天、TV Detail 12 小时；失败缓存 30 分钟。后续可增加持久化缓存。
- Detail 失败时保留列表已有数据，地区允许为空，不能中断整次生成。
- 沿用现有 429、5xx、超时重试策略。

## 7. 华语判定契约

统一规则：

~~~text
originalLanguage 属于 zh、cn
或者
originCountries 与 CN、HK、TW、MO 有交集
→ 华语
~~~

其他非空值为非华语；语言和地区均缺失时为未知。

边界规则：

- SG 不能仅按国家判断，必须结合原始语言。
- 禁止根据标题是否包含汉字判断，避免误判日语作品。
- 多国合拍作品命中任一华语条件时，V1 归为华语。
- 服务端和客户端必须使用相同契约测试样例。
- 快照仍返回原始字段，不增加只能由服务端解释的单一布尔值。
- 华语分类与综艺准入是两条独立规则：originalLanguage 为 cn 时可分类为华语，但不满足综艺仅允许 zh、ja、ko 的准入条件。

## 8. 新片生成规则

### 8.1 候选池

必须拆成：

~~~text
freshItems     = 最近 180 天首次上映或首播
returningItems = 首播早于 180 天，但最近仍有新集播出
~~~

#### 新作品池

来源：

- 最近 180 天上映的电影。
- 最近 180 天首次开播的电视、动漫和综艺。
- 沿用 popularity >= 10 的最低质量门槛。

排序：

1. releaseDate 降序。
2. 日期相同时 popularity 降序。
3. 仍相同时 voteCount 降序。
4. 仍相同时按 globalId 排序，保证可重现。

#### 老作品更新池

来源和条件：

- tv/on_the_air 去重候选。
- last_episode_to_air.air_date 在最近 14 天。
- releaseDate 早于 180 天分界。
- 与 freshItems 重复时只保留 fresh 身份。

排序：

1. 最近一集播出日期降序。
2. 日期相同时 popularity 降序。
3. 仍相同时 voteCount 降序。
4. 仍相同时按 globalId 排序。

### 8.2 准入规则

本节只能用于 returningItems，禁止用于最近 180 天首播的新作品。

华语更新作品：

- 满足基础合法性和 popularity >= 10 即可进入候选。
- 不执行海外长寿剧排除。
- 仍受最终每页更新作品总配额限制。

非华语更新作品：

- 普通电视剧命中第 8.3 节任一规则时排除。
- 动漫不套用普通电视剧集数规则，但每 20 条最多 1 条非华语老动漫，按热度优先。
- 综艺不套用普通电视剧集数规则，但仍须先通过 zh、ja、ko 全局语言准入；通过后不再设置单独的“非华语老综艺”额度，只受 returningItems 总配额限制。

该规则允许保留少量成熟的非华语动漫；中日韩成熟综艺由 returningItems 总配额控制，不再叠加单独额度。

### 8.3 海外长寿日播剧

对非华语、category == tv 的 returningItems，命中任一条件即排除：

1. genreIds 包含 10766，即 Soap。
2. 首播超过 5 年，且 numberOfEpisodes >= 500。
3. 首播超过 5 年，numberOfSeasons >= 8，且 voteCount < 500。
4. 首播超过 3 年、numberOfEpisodes >= 200，且平均每年集数超过 80。

伪代码：

~~~text
isChinese = language/region 命中华语契约
ageYears  = max(1, 当前日期与首播日期的年差)
pace      = numberOfEpisodes / ageYears

reject = candidateKind == returning
  && !isChinese
  && category == tv
  && (
    genreIds contains 10766
    || (ageYears >= 5 && numberOfEpisodes >= 500)
    || (ageYears >= 5 && numberOfSeasons >= 8 && voteCount < 500)
    || (ageYears >= 3 && numberOfEpisodes >= 200 && pace > 80)
  )
~~~

字段缺失时保守处理：

- 不能证明命中时不得仅因缺字段排除。
- 记录 unknown_metadata 原因。
- 该条目仍受 returningItems 总配额限制。

### 8.4 新旧内容配额

每个连续 20 条窗口：

| 候选 | 目标数量 | 硬上限 |
| --- | ---: | ---: |
| 新作品 | 14 | 20 |
| 老作品更新 | 6 | 6 |
| 其中非华语老动漫 | 1 | 1 |

合并必须保证：

1. 两个池内部相对顺序不变。
2. returningItems 不足时由 freshItems 补齐。
3. freshItems 不足时不放宽 returningItems 每 20 条最多 6 条的硬上限，也不放宽海外长寿剧规则；尾块允许不足 20 条。
4. 相同输入得到相同输出，禁止随机打乱。

“每个连续 20 条窗口”在本需求中专指从排名第 1 条开始的非重叠 20 条分块，不按任意起点的滑动窗口计算。合并使用以下固定 10 槽模板并重复两次：

~~~text
fresh, fresh, returning, fresh, fresh,
returning, fresh, fresh, returning, fresh
~~~

- 模板天然形成每 20 条 14 个 fresh 槽和 6 个 returning 槽。
- 两个池均按各自排序依次取值，池内相对顺序不变。
- returning 不足时，其空槽由 fresh 补齐。
- fresh 不足时，合格 returning 可在 6 条硬上限内占用空槽；达到上限后尾块不强行填满。
- 最后不足 20 条的尾块继续使用模板前缀，因此配额上限可直接按实际槽位校验。
- 非华语老动漫每个非重叠 20 条分块最多 1 条；选择时按 returning 池既定排序，不另行随机或重排。

### 8.5 分组独立计算

以下分组必须分别对各自的 freshItems 和 returningItems 执行合并：

~~~text
all
movie
tv
animation
variety
~~~

禁止先生成 all 再简单切出其余分组，否则单独切到电视剧时仍可能被长寿剧占满。

## 9. 产品样本

以下样本来自 2026-09-13 的线上新片快照，只用于表达产品意图，禁止在代码中硬编码标题或 TMDB ID。

### 9.1 应保留的代表

| TMDB ID | 标题 | 原因 |
| --- | --- | --- |
| tv:45140 | 少年泰坦出击 | 有价值的非华语成熟动漫，限额保留 |
| tv:79481 | 斗破苍穹 | 华语动漫更新 |
| tv:314939 | 不是你的恋爱 | 最近 180 天首播的新剧 |
| tv:65282 | 我独自生活 | 符合 ko 综艺准入，并受 returningItems 总配额控制 |

### 9.2 应移出新片首屏的代表

~~~text
加冕街
明天属于我们
好时光，坏时光
比勒陀利亚医院
秘密人生
Ulice
Board AF
ARTE Re:
一切从这里开始
艾玛镇
天空之主
如此大的太阳
东南
自由的梦想
~~~

验收看的是通用规则和首屏结果。若字段不足以区分，应补充元数据或调整分类配额，禁止添加标题黑名单。

## 10. 生成器改造

当前仓库参考实现：tool/generate_tmdb_catalog.dart。服务端可使用其他语言，但必须保持相同契约和算法意图。

### 10.1 内部数据结构

增加：

~~~text
originalLanguage: string
originCountries: string[]
genreIds: int[]
numberOfSeasons: int?
numberOfEpisodes: int?
seriesType: string
candidateKind: fresh | returning
~~~

对外 JSON 只必须新增 originalLanguage 和 originCountries；其他字段可仅用于生成规则和日志。

### 10.2 函数拆分

建议将现有 buildLatest 拆为可独立测试的 I/O 和纯函数：

~~~text
fetchFreshCandidates()
fetchReturningCandidates()
enrichCatalogItems()
classifyLanguage()
filterReturningCandidates()
mergeLatestCandidates()
buildLatestGroups()
validateGeneratedCatalog()
serializeSnapshot()
validateSnapshot()
~~~

过滤和合并逻辑必须与 HTTP 解耦，使用固定 fixture 即可执行单元测试。

### 10.3 集中配置

初始值：

~~~text
freshWindowDays = 180
returningRecentDays = 14
minimumPopularity = 10
latestWindowSize = 20
freshTargetPerWindow = 14
returningMaxPerWindow = 6
foreignReturningAnimationMaxPerWindow = 1
detailConcurrency = 4
minimumAllItems = 20
movieDetailCacheTtl = 7 days
tvDetailCacheTtl = 12 hours
detailFailureCacheTtl = 30 minutes
~~~

这些值必须集中在策略对象或配置区，禁止散落在多个函数中。

`minimumAllItems` 按 Feed 独立配置，初始值三个 Feed 均为 20。不得给 movie、tv、animation、variety 设置统一最低数量，因为单个分类可能自然不足。

## 11. 校验和可观测性

### 11.1 快照校验

校验分为两层。

生成阶段校验在序列化前执行，可访问 candidateKind、genreIds、集数、季度数和过滤原因：

1. 新片每个非重叠 20 条分块中 returningItems 不超过 6。
2. 非华语老动漫每块不超过 1。
3. 已命中长寿规则的非华语 TV 不得出现在新片。
4. 五个分组确实分别执行合并，不得由 all 二次切分。

新快照结构校验在持久化前严格执行：

1. originalLanguage 为空或为规范化小写代码。
2. originCountries 是大写、非空、无重复的字符串数组。
3. 分组不超过 200 条，ID 不重复，引用的 Item 存在。
4. 每个 Item 都包含 originalLanguage 和 originCountries。
5. all 非空并达到该 Feed 配置的 minimumAllItems。

恢复持久化状态时使用兼容模式：仍校验顶层结构、分组上限、重复 ID、引用完整性和 all 非空，但允许历史 Item 缺少 originalLanguage 和 originCountries，也不对历史快照应用新版本的 minimumAllItems 门槛。

语言和地区在进入严格校验前先做容错规范化：originalLanguage 先 trim、转小写，仅接受 `^[a-z]{2}$`，否则转为空字符串；originCountries 中不符合 `^[A-Za-z]{2}$` 的值丢弃，其余值大写并去重。这里做格式校验而不维护静态国家白名单。单条非法元数据不得导致整个快照失败。日期必须做真实日历日期校验，不能只检查 `YYYY-MM-DD` 外形。

### 11.2 生成报告

每次生成至少输出：

~~~text
feed / scope
原始候选数
新作品数
老作品更新数
排除 Soap 数
排除超长剧数
排除高频日播剧数
华语 / 非华语 / 未知数
Detail 缓存命中 / 上游成功 / 失败 / 重试数
最终快照数
~~~

被排除条目使用结构化原因，例如：

~~~json
{
  "tmdbId": 291,
  "mediaType": "tv",
  "title": "加冕街",
  "reason": "foreign_soap",
  "originalLanguage": "en",
  "originCountries": ["GB"],
  "numberOfEpisodes": 10000
}
~~~

日志禁止包含 TMDB Token。

逐条排除日志必须设置单次生成上限，默认最多输出 100 条；完整数量保留在汇总报告，避免异常上游数据造成日志洪泛。

## 12. 错误处理

1. 列表请求失败：本次生成失败，不覆盖上一份成功快照。
2. 单个 Detail 失败：保留列表已有元数据并降级，不中止整次生成。Movie Detail 失败时电影仍可入榜，originCountries 允许为空。TV returning 候选若因 Detail 失败无法证明最近 14 天有新集，则本轮不入榜并记录 missing_recent_episode_date；只有列表数据已能提供有效最近播出日期时才可降级进入。
3. 日期无效：不得用日期规则误删，可在排序中降级。
4. 结果未通过结构或产品门槛：拒绝原子发布。
5. TMDB 不可用：Catalog API 继续返回最近成功快照并标记 stale。

## 13. 测试要求

### 13.1 服务端单元测试

必须覆盖：

1. 最近 180 天首播的非华语新剧保留。
2. 华语老剧或动漫更新可进入 returningItems。
3. 非华语 Soap 排除。
4. 非华语超过 5 年且至少 500 集的 TV 排除。
5. 非华语高频日播剧排除。
6. 动漫和综艺不直接套用普通 TV 集数规则。
7. 非华语老动漫的每个 20 条分块上限生效。
8. 元数据缺失时保守保留并记录原因。
9. 新旧候选按 14:6 上限稳定合并。
10. 五个分组独立计算。
11. 语言小写化，地区大写、去重。
12. 相同 fixture 多次生成得到相同顺序。
13. 三个 Feed 的综艺只保留 originalLanguage 为 zh、ja、ko；该规则不影响其他分类。
14. Detail 单条失败不使整个 Feed 失败；无法证明近期更新的 TV returning 候选不入榜。
15. 10 槽固定模板、尾块和池不足时的补位行为符合契约。

### 13.2 契约测试

- 新 JSON 仍为 schemaVersion = 1。
- 旧客户端依赖的字段全部保留。
- groups 结构和分组名不变。
- ETag 和 304 行为不变。
- 新客户端同时解析新旧快照。

### 13.3 回归测试

热门和高分必须验证：

- 原有入选和排序算法不因语言字段改变。
- 电影、普通电视剧和动漫只增加元数据，不新增语言或地区过滤。
- 综艺继续只允许 originalLanguage 为 zh、ja、ko。
- Detail 失败不使整个 Feed 失败。

## 14. 实施计划

### 阶段 A：冻结契约

1. 确认字段名、华语判定和初始阈值。
2. 将字段补充到 Catalog API 契约。
3. 准备新旧快照 fixture。

产出：已评审契约和 fixture。

### 阶段 B：元数据采集

1. 扩展生成器内部 Item。
2. 从列表读取语言、地区和 genre。
3. 复用 TV Detail 补全更新候选。
4. 对最终入榜电影补查 Movie Detail。
5. 实现请求去重、并发限制和失败降级。

产出：带语言和地区的未发布快照。

### 阶段 C：新片清洗

1. 拆分 freshItems 和 returningItems。
2. 实现候选身份和日期判断。
3. 实现华语分类。
4. 实现 Soap、超长剧和高频日播规则。
5. 实现非华语老动漫独立上限，并保留综艺 zh、ja、ko 全局准入。
6. 实现五个分组的 14:6 合并。
7. 输出过滤原因和生成报告。

产出：清洗后的未发布新片快照。

### 阶段 D：验证和调参

1. 运行单元、契约和回归测试。
2. 对比改造前后五个分组的前 20/50 条。
3. 验证第 9 节产品样本。
4. 检查新作品是否误删。
5. 只通过集中配置调整阈值，禁止标题黑名单。

产出：评审通过的策略参数和快照。

### 阶段 E：发布

1. 发布 staging 版本并逐 Feed 刷新快照，完成验收。
2. 备份生产 `state.json`，文件名包含备份时间和发布版本；同时保留上一版本程序包。
3. 发布服务端程序，按 latest、popular、top_rated 逐 Feed 原子刷新。每次刷新先将包含新 Feed 和其余最近成功 Feed 的完整状态写入临时文件，再 rename 覆盖 `state.json`，成功后更新内存缓存。
4. 动态 manifest 自动反映各 Feed 当前 revision；不要求三个 Feed 使用同一 revision，也不使用 manifest 指针切换。
5. 验证旧客户端正常加载。
6. 监控两个刷新周期。
7. 更新 App 的 assets/tmdb/v1 兜底快照。

产出：线上快照、`state.json` 备份、上一版本程序包和发布报告。

### 阶段 F：客户端语言偏好

1. 扩展 TmdbCatalogItem 并兼容旧快照。
2. 增加华语、非华语、未知分类。
3. 增加全部、华语优先、仅华语、仅非华语设置。
4. 在 VOD 搜索前应用过滤或重排。
5. 将语言偏好加入 Catalog 会话缓存键。

阶段 F 不阻塞服务端先发布新字段和清洗后的公共榜单。

## 15. 发布和回滚

发布顺序：

~~~text
生成器支持新字段和新规则
  → staging 快照验证
  → 备份生产 state.json 和上一版本程序包
  → 发布服务端并逐 Feed 原子刷新
  → 验证旧客户端
  → 发布支持语言偏好的新客户端
~~~

回滚条件：

- 任一 Feed 为空、引用缺失或无法解析。
- 新片可展示候选显著下降。
- 新作品被大量误判和排除。
- Detail 请求量、失败率或生成时长超过运维阈值。
- 旧客户端无法消费新快照。

回滚分为两种：

- 仅快照数据异常：停止服务，恢复发布前备份的 `state.json`，再启动并验证三个 Feed。若新生成器仍会再次产生异常数据，应同时回滚程序包。
- 程序或契约异常：部署上一版本程序包，并恢复与其兼容的 `state.json` 备份。

当前服务不使用 revision 目录或 manifest 指针回滚。每个 Feed 的刷新是独立事务：生成、校验或持久化任一步失败时，不替换该 Feed 的内存快照，并继续返回其最近成功快照。

## 16. 验收标准

1. 三个 Feed 的路径、参数和顶层 JSON 结构不变。
2. 所有由新版本生成的条目输出 originalLanguage 和 originCountries，缺失时分别为 "" 和 []；历史回退快照允许暂时缺字段。
3. 旧客户端正常加载。
4. 热门和高分中的电影、普通电视剧和动漫只增加元数据，不新增语言或地区过滤；综艺继续只允许 zh、ja、ko。
5. 新片每 20 条中老作品更新不超过 6 条。
6. 命中 Soap、超长或高频日播规则的非华语 TV 不出现在新片。
7. 第 9 节保留样本合理可见，排除样本不再大量占据首屏；综艺样本仍须满足 zh、ja、ko 准入。
8. Detail 部分失败时生成任务仍可完成并输出降级统计。
9. 生成报告、结构校验和自动化测试全部通过。
10. 已保存并验证发布前 `state.json` 及上一程序包的回滚方式。

## 17. 服务端交付清单

- [ ] 更新 Catalog Item DTO 和 JSON 契约。
- [ ] 读取列表语言、地区和 genre。
- [ ] 通过 TV/Movie Detail 补齐地区和过滤数据。
- [ ] 实现 Detail 去重、并发限制和失败降级。
- [ ] 拆分 freshItems 和 returningItems。
- [ ] 实现华语判定。
- [ ] 实现海外 Soap、超长和高频日播剧过滤。
- [ ] 实现非华语老动漫独立上限，并保留综艺 zh、ja、ko 全局准入。
- [ ] 实现五个分组的 14:6 稳定合并。
- [ ] 增加生成报告和排除原因。
- [ ] 增加单元、契约和回归测试。
- [ ] 生成 staging 快照并完成人工验收。
- [ ] 备份生产 state.json 和上一版本程序包。
- [ ] 按 Feed 原子刷新线上快照并验证失败时保留最近成功版本。
- [ ] 验证旧客户端兼容。
- [ ] 向客户端交付新快照、fixture、统计和回滚信息。
