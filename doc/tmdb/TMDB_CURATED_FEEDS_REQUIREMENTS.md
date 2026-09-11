# Jive TMDB 自建榜单需求文档

> 文档状态：部分决策已确认，剩余项目待产品拍板，未进入开发  
> 适用平台：Flutter Android / iOS  
> 功能范围：使用 TMDB 发现内容，再在当前 VOD 源中搜索并映射为可播放视频  
> 决策方式：先确认第 1 节；确认后冻结为开发和验收基线

## 1. 待确认项与建议

以下问题会实质改变产品行为或请求成本。表中的“建议”是本文其余章节采用的默认值，不代表已经确认。

| ID | 待确认问题 | 建议方案 | 其他选项及影响 | 最终决定 |
| --- | --- | --- | --- | --- |
| D1 | 首页栏目名称 | 使用“默认 / 最新 / 最热 / 高分” | “默认”表示当前 VOD 源的默认排序，与 TMDB“最新”明确区分 | **已确认** |
| D2 | 内容覆盖 | 覆盖电影、电视剧、动漫、综艺四类 | TMDB 没有完全等同中文产品习惯的“动漫/综艺”分类，具体映射见 D18 | **已确认** |
| D3 | “最新”时间范围 | 使用滚动最近 180 天，不含未来日期 | 按自然月计算会造成每次月初/月末跨度变化 | **已确认** |
| D4 | “最热”时间窗 | 优先月榜；TMDB 无原生月榜，因此实际采用 `trending/*/week` | 自行累计四个周榜不能准确还原月榜，还需要服务端长期采样 | **已确认：当前使用周榜** |
| D5 | “高分”门槛 | 评分不低于 7.0，评分人数不低于 200，按评分倒序 | 500 更稳但新片和小众内容更少 | **已确认** |
| D6 | 地区和语言 | 返回语言 `zh-CN`；不限制原产地区 | 只看中国大陆会显著缩小范围；按用户地区配置会增加设置项 | 待确认 |
| D7 | 成人内容 | 支持该参数的 TMDB 请求固定 `include_adult=false`；其余端点按返回字段二次过滤，并继续经过 Jive 内容过滤 | 允许成人内容会扩大合规与审核风险 | 待确认 |
| D8 | 搜索哪些 VOD 源 | 第一期只搜索当前全局选中的 VOD 源 | 自动搜索备用源能提高命中率，但会改变“当前源”语义并显著增加请求 | **已确认** |
| D9 | 单批展示目标 | 首轮先解析 12 个候选，未满时自动补位，目标新增 12 个可展示结果 | 自动补位必须受 D10 的扫描和请求上限约束 | **已确认** |
| D10 | 单次加载请求上限 | 建议最多扫描 24 个 TMDB 候选：24 次主搜索 + 最多 6 次补搜，VOD 搜索硬上限 30 次 | 上限更高可提高低覆盖源的填满率，但等待时间和封禁风险同步增加 | 待确认新上限 |
| D11 | 未匹配条目 | 与已匹配结果分层，在列表尾折叠展示，用户点击后最多探测 3 个备用源 | 不挤占可播放主网格，不在首屏自动跨源 | **已确认** |
| D12 | 匹配策略 | 精确优先，宁可漏掉也不误匹配；低置信度和并列候选不展示 | 宽松包含匹配命中率高，但同名、翻拍、季度错配风险高 | 待确认 |
| D13 | 海报和评分展示 | TMDB 标题/海报/评分/排名 + VOD 更新状态和播放身份 | TMDB 海报失败时回退 VOD 海报 | **已确认** |
| D14 | TMDB Token 放置 | 第一期采用定时生成的在线静态 JSON；Token 只存在于生成任务 | App 直连会暴露 Token；动态代理能力更强但运维成本更高 | **已确认** |
| D15 | 切换 VOD 源后的行为 | 保留 TMDB 榜单，清空匹配结果并对当前可见批次重新搜索 | 自动回到“默认”更省请求，但会打断用户当前浏览位置 | 待确认 |
| D16 | 无资源时是否自动补位 | 自动继续扫描候选，直到新增 12 个匹配或达到 D10 上限 | 达到上限仍不足 12 个时展示已有结果，不继续无限请求 | **已确认** |
| D17 | TMDB 署名入口 | 在“更多设置 → 关于/数据来源”展示 TMDB Logo 和官方声明 | 无署名不符合 TMDB 开发者 API 要求 | 待确认 |
| D18 | “动漫/综艺”精确定义 | 动漫=`genre 16 Animation`，包含全球动画；综艺包含 `10764 Reality`、`10767 Talk`、`10763 News`，分类互斥 | 无 | **已确认** |
| D19 | 老剧推出新一季是否属于“最新” | 属于；新剧走近 180 天，老剧新季由 `on_the_air` 补充后去重 | 合并时需要单独计算新季排序，不能使用整部剧的首次播出年份 | **已确认** |
| D20 | 正式版发布架构 | 先用在线静态 JSON；需要实时参数、用户个性化或真正月榜时再升级动态代理 | 静态 JSON 已能隐藏 Token、共享缓存，且比动态服务简单 | **已确认** |
| D21 | 最新/最热在哪里刷新 | 三个 Feed 都由在线 JSON 定时生成，客户端不直连 TMDB | 客户端只按 manifest revision 下载更新 | **已确认** |
| D22 | 在线 JSON 打包粒度 | `manifest + 每个 Feed 一个 JSON`，共 4 个入口文件 | 每个 Feed 内含五个 Group 的有序 ID 与共享条目字典 | **已确认** |

### 1.1 建议直接批准的默认组合

如果没有特殊产品偏好，建议批准所有仍待确认项的“建议方案”。核心原则是：

1. TMDB 只负责发现、排序和展示元数据。
2. 当前 VOD 源负责确认资源存在并提供后续详情及播放。
3. 错配的伤害高于漏配，因此采用严格匹配。
4. 每次操作有明确请求上限，不能为了凑满列表无限搜索源站。

### 1.2 三项关键方案分析

#### 当前 VOD 源还是自动跨源

**已确认：榜单严格只搜索当前 VOD 源。** 当一批命中率过低时，展示“切换来源后重新查找”，打开现有全局源选择器；第一期不自动混入备用源。

只搜当前源的优点：

- 与首页全局来源选择一致，用户知道影片将从哪个源打开。
- 单次加载最多扫描 24 个候选、发起 30 次 VOD 搜索，请求预算仍有硬上限。
- 卡片不会混合多个来源，收藏、详情、播放和缓存身份更稳定。
- 某个备用源失效时不会拖慢整个榜单。
- 切换来源后重新匹配的行为清晰，也能直接比较各源覆盖率。

缺点：

- 当前源内容较少或中文搜索较弱时，榜单可能只显示少量影片。
- 用户可能需要手动切源才能找到想看的内容。

自动跨源的优点是命中率高，但成本会近似乘以探测来源数。例如当前源加 3 个备用源，单次上限理论上可能从 30 次增长到约 120 次 VOD 搜索，而且最终列表会混合来源。这与 Jive 当前“全局浏览源”的语义冲突。

可作为二期的折中方案：默认只搜当前源；用户主动点击“尝试其他来源”后，只对某一部影片或当前未匹配项探测备用源。该动作必须由用户显式触发，不能在首屏后台自动执行。

#### 在线静态 JSON 还是动态代理

在线静态 JSON 可以作为第一期的正式数据通道。定时任务持有 TMDB Token 并预先生成 Feed 快照，App 只下载公开 JSON，因此同样可以隐藏 Token、共享缓存和远程调整榜单。

```text
在线 JSON：定时任务 → TMDB → 静态 JSON → Jive App
动态代理：Jive App → Jive Catalog API → TMDB
```

静态 JSON 的优点：

- 不需要常驻 API 进程，部署和运行成本低。
- App 和 APK 不包含 TMDB Token。
- 与项目现有 `hey-rickytse.com/data/` 远程 JSON 模式一致。
- 榜单是预生成内容，不会因为用户数量增长而等比例增加 TMDB 请求。
- revision 发布和客户端旧缓存能提供简单可靠的回滚。

局限：

- 数据最多按定时任务频率更新，不能处理任意用户筛选。
- 只能加载预生成的页数，第一期建议每个 Feed/分类最多 200 条。
- 真正月榜仍需长期保存热度采样，不能从当前周榜即时推导。
- 生成任务、Secret 管理和原子上传仍然属于必要的轻量后端工作，并非手工维护 JSON。

**建议：第一期采用在线静态 JSON，不做动态代理。** 只有需要个性化筛选、任意深度分页、近实时数据或自建月榜时再升级；两种方案保持相同 DTO，升级时客户端页面和匹配器不需要重写。

#### 卡片使用 TMDB 还是 VOD 数据

**建议采用混合展示：**

- 标题、海报、评分、榜单排名来自 TMDB。
- `更新至 X 集 / 已完结 / HD` 等资源备注来自匹配后的 VOD。
- 点击身份和后续详情使用 VOD `VideoRef`。
- TMDB 海报缺失或加载失败时回退 VOD 海报。
- 详情页进入后继续展示 VOD 详情，不要求把 TMDB 元数据覆盖整个详情页。

优点：榜单视觉稳定，评分含义与高分排序一致；换 VOD 源不会导致同一榜单突然更换标题和主海报。缺点是 TMDB 的剧集总海报可能与自动匹配到的最新一季海报不同，需要接受“榜单展示作品、详情展示具体资源”的差异。

完全使用 VOD 数据能确保卡片与资源一致，但海报清晰度、标题和评分字段不稳定；完全使用 TMDB 数据则无法向用户展示当前源的更新集数。因此混合方案最适合现有首页。

### 1.3 新发现的分类口径问题

TMDB 没有独立的中文“动漫”和“综艺”一级媒体类型，只有电影/电视剧及 genre：

- `16 Animation` 会同时包含日本动画、国产动画和欧美动画。
- `10764 Reality`、`10767 Talk` 与 `10763 News` 共同归入综艺。

已确认第一期“动漫”包含全球动画，不限定日本；“综艺”包含 Reality、Talk 和 News。四个分类互斥，优先判定动漫和综艺，再归入普通电影或电视剧，避免同一条目重复出现。

已确认首播多年前但最近推出新一季的剧属于“最新”。因此近 180 天新条目之外，再合并 `on_the_air`，但不能把这类剧按首次播出年份排到榜尾。

## 2. 背景

Jive 当前首页列表来自所选 VOD 源。不同源对“热门”“高分”“新片”的支持不一致：

- `VideoFeed` 已定义 `updated / popular / newReleases / topRated`。
- 首页原有“更新 / 热门”，现已调整为“默认 / 最新 / 最热 / 高分”。
- “默认”继续使用当前 VOD Adapter 的原生列表。
- AGE 当前能按 `time` 和 `click` 排序，但其他源未必具备对应能力。

本需求使用 TMDB 建立与 VOD 协议无关的统一榜单。TMDB 结果本身不可播放，必须映射到当前 VOD 源的 `Video` 后才能进入详情和播放器。

## 3. 产品目标

### 3.1 目标

1. 首页稳定提供“最新 / 最热 / 高分”三个统一榜单。
2. 榜单顺序由 TMDB 决定，不受不同 VOD 源排序能力影响。
3. 榜单条目只在当前 VOD 源中找到可信匹配后才可播放。
4. 用户切换 VOD 源后，榜单不变，资源匹配按新源重新计算。
5. 所有网络操作有超时、缓存、并发和总量限制。

### 3.2 非目标

- 不提供 TMDB 账号登录、收藏同步或评分写入。
- 不使用 TMDB 的 Watch Provider 作为播放地址。
- 不抓取豆瓣、IMDb 或其他站点网页。
- 不因为榜单未命中而自动切换用户当前 VOD 源。
- 不在第一期建立跨设备榜单缓存和用户画像推荐。
- 不修改现有播放解析、缓存、下载和广告过滤链路。

## 4. 用户故事

1. 用户进入首页，可以在“默认 / 最新 / 最热 / 高分”之间切换。
2. 用户选择“最热”，看到 TMDB 本周热门且当前 VOD 源确实拥有的影片。
3. 用户选择“高分”，看到评分和评分人数达到门槛的影片。
4. 用户点击榜单卡片，进入当前 VOD 源对应的现有详情页。
5. 用户切换 VOD 源后，当前榜单使用新来源重新匹配。
6. 部分影片没有资源或搜索失败时，其他影片仍能继续展示。

## 5. 榜单定义

### 5.1 默认

“默认”不是 TMDB 榜单，继续使用当前 VOD Adapter 的原生列表：

```text
VideoFeed.updated → 当前 VodSourceAdapter.fetchPage / fetchFeedPage
```

### 5.2 最新

#### 电影

建议使用 TMDB Discover，而不是直接使用 `upcoming`：

```http
GET /3/discover/movie
  ?language=zh-CN
  &include_adult=false
  &include_video=false
  &sort_by=popularity.desc
  &primary_release_date.gte={今天-180天}
  &primary_release_date.lte={今天}
  &page={page}
```

规则：

- 只取已经上映的电影。
- 默认时间窗为滚动最近 180 天。
- 为避免零热度的个人短片、测试或垃圾条目占满最新列表，只保留 `popularity >= 10` 的候选；通过后仍按日期倒序。
- TMDB Discover 先在 180 天范围内按热度取候选，避免有效内容被大量低质量的当日条目挤出前 10 页；生成器再按上映日期倒序生成最终排名。
- 不使用未来上映影片填充列表。

#### 电视剧

电视剧、动漫剧集和综艺先用 Discover 获取近 180 天首次播出的新条目：

```http
GET /3/discover/tv
  ?language=zh-CN
  &include_adult=false
  &sort_by=popularity.desc
  &first_air_date.gte={今天-180天}
  &first_air_date.lte={今天}
  &page={page}
```

同时用 `tv/on_the_air` 补充近期推出新一季、但首播早于 180 天的老剧，并按 TMDB ID 去重。生成任务为这些候选补查 TV Detail，读取 `last_episode_to_air.air_date` 和 `season_number`，分别作为榜单 `sortDate` 和 VOD 季度匹配依据。该补充列表不等于 VOD 源最近入库。

#### 电影与电视剧合并

TMDB 没有一个完全符合本需求的“最新电影 + 最新电视剧”统一端点。若 D2 确认两类都做，客户端或代理需要分别请求，再按日期归并：

1. 电影使用 `release_date` 作为 `sortDate`。
2. 新电视剧使用 `first_air_date`；老剧新季使用 `last_episode_to_air.air_date` 作为 `sortDate`。
3. 日期相同则保持各自 TMDB 顺序。
4. 合并后每页仍向客户端返回 20 条。

不含老剧新季时，“最新”每个 TMDB 逻辑页实际需要 2 个上游请求；包含 `on_the_air` 补充时需要 3 个。

### 5.3 最热

```http
GET /3/trending/movie/week?language=zh-CN&page={page}
GET /3/trending/tv/week?language=zh-CN&page={page}
```

TMDB 当前只提供日榜和周榜，没有月榜，所以按已确认决策使用周榜。电影和电视剧分别取回后按 TMDB `popularity` 归并；若未来发现跨类型的 `popularity` 不适合直接比较，则改用交错合并：电影 1 条、电视剧 1 条，分别保持原榜顺序。

默认使用周榜，缓存 2 小时。下拉刷新可以绕过客户端缓存，但不得绕过代理或 TMDB 的服务端限制。

### 5.4 高分

```http
GET /3/discover/movie
  ?language=zh-CN
  &include_adult=false
  &sort_by=vote_average.desc
  &vote_average.gte=7.0
  &vote_count.gte=200
  &page={page}

GET /3/discover/tv
  ?language=zh-CN
  &include_adult=false
  &sort_by=vote_average.desc
  &vote_average.gte=7.0
  &vote_count.gte=200
  &page={page}
```

合并排序规则：

1. `vote_average` 降序。
2. 评分相同按 `vote_count` 降序。
3. 两者仍相同则保持 TMDB 原顺序。

第一期不提供用户可调评分门槛。

### 5.5 四类内容映射

TMDB 上游仍只有 `movie` 和 `tv`，Jive 展示层按 genre 映射成四类：

| Jive 分类 | TMDB 条件 | 排除条件 |
| --- | --- | --- |
| 电影 | `media_type=movie` | 排除 `genre_ids` 含 16 的动画电影 |
| 电视剧 | `media_type=tv` | 排除动画、Reality、Talk 和 News |
| 动漫 | `media_type=movie/tv` 且 `genre_ids` 含 16 | 无；已确认包含全球动画 |
| 综艺 | `media_type=tv` 且 `genre_ids` 含 10764、10767 或 10763 | 排除动画 |

同一条目只进入一个分类，判定优先级为“动漫 → 综艺 → 电影/电视剧”。“全部”视图可以混合四类，但按 `tmdb:{mediaType}:{id}` 去重。

## 6. 单次取数和请求预算

### 6.1 名词

- **TMDB 页**：一次榜单分页，固定 20 条；“最新”和“高分”的电影/电视剧合并可能包含两个上游请求。
- **解析批次**：一次交给当前 VOD 源进行资源搜索的 TMDB 条目集合。
- **主搜索**：使用 TMDB `zh-CN` 标题搜索 VOD。
- **补充搜索**：主搜索没有可信结果后，使用原始标题或一个补充别名再搜索一次。

### 6.2 目标 12 个结果与自动补位

后续加载更多属于本期范围。每次首屏或加载更多以“新增最多 12 个匹配成功的可展示结果”为目标：

1. 从尚未消费的 TMDB 候选队列先取 12 条作为首轮。
2. 首轮不足 12 个匹配时，按榜单顺序每次再取最多 6 个候选补位。
3. 一旦累计得到 12 个匹配结果，停止启动新的搜索；已发请求完成后只写匹配缓存，不插入本批 UI。
4. 单次用户操作最多扫描 24 个 TMDB 候选；达到上限仍不足 12 个时，展示已有结果并结束本次加载。
5. 候选队列不足时继续读取在线榜单后续数据，直到补足候选或榜单结束。
6. 用户再次上拉时，从上次尚未消费的位置继续，目标再新增 12 个结果。

| 场景 | 展示目标 | 首轮候选 | 最大扫描候选 | 主搜索上限 | 补搜上限 | VOD 搜索硬上限 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 首次进入榜单 | 12 | 12 | 24 | 24 | 6 | 30 |
| 每次加载更多 | 12 | 12 | 24 | 24 | 6 | 30 |
| 榜单剩余不足 12 | 最多为剩余命中数 | 剩余量 | 剩余量 | 剩余量 | 不超过 6 | 剩余量 + 补搜 |

未匹配项不展示，但会被标记为已消费。不得为了凑满 12 个结果突破 24 个候选或 30 次 VOD 搜索上限。

补充搜索名额按 TMDB 排名从前向后分配。用完后其余未匹配项直接记为本批未匹配，不得继续尝试更多别名。

### 6.3 单次 VOD 搜索的数据量

每个榜单条目只请求当前 VOD 源搜索结果的第一页：

```dart
videoRepository.fetchPage(
  selectedSource,
  page: 1,
  keyword: query,
);
```

匹配器最多检查返回结果的前 10 个候选。即使源返回更多，也不在第一期请求第二页，因为相关候选通常集中在第一页，搜索第二页会使请求量和延迟翻倍。

### 6.4 并发和时间限制

- VOD 搜索并发数：最多 3。
- 单个请求超时：8 秒。
- 单批整体软超时：建议随自动补位调整为 30 秒；达到软超时后已完成结果正常展示，队列中尚未开始的搜索取消。
- 已发出的 Dart HTTP 请求未必能物理取消，但 generation 失效后不得写回界面。
- 同一个 VOD 源的相同关键词在 10 分钟内复用搜索缓存。
- 遇到 HTTP 429 时，本批不立即重试；记录失败并等待下一次用户刷新或缓存过期。
- 同一批出现 3 次连续传输错误、超时或 5xx 时视为来源级异常，停止尚未开始的搜索；“搜索成功但没有结果”不计入连续失败。

### 6.5 请求量示例

在线 JSON 已命中客户端缓存时，首屏最常见情况：

```text
VOD：12 个主标题搜索
合计：12 个榜单匹配请求（不计算海报）
```

首次加载在线榜单时，另增加 manifest 和对应 Feed 数据请求。单次自动补位的 VOD 最坏情况：

```text
在线榜单：建议打包方案下最多 2 个请求
VOD：24 个主搜索 + 6 个补充搜索
合计：最多 32 个 HTTP 请求（不计算海报）
```

上述请求不会同时发出：VOD 搜索最多并发 3，且一旦补满 12 个结果就停止启动新请求。

## 7. TMDB 数据模型

建议新增独立模型，避免把不可播放的 TMDB 条目伪装成 `Video`：

```dart
enum CatalogMediaType { movie, tv }

class TmdbCatalogItem {
  final int tmdbId;
  final CatalogMediaType mediaType;
  final String localizedTitle;
  final String originalTitle;
  final List<String> aliases;
  final String releaseDate;
  final String sortDate;
  final String year;
  final int? latestSeasonNumber;
  final double rating;
  final int voteCount;
  final double popularity;
  final String posterPath;
  final int rank;
}

class ResolvedCatalogItem {
  final TmdbCatalogItem catalog;
  final Video? matchedVideo;
  final MatchStatus status;
  final int? matchScore;
}
```

稳定身份：

```text
tmdb:{mediaType}:{tmdbId}
```

播放身份仍使用：

```text
{vodSourceId}:{sourceVideoId}
```

两者不能互相替代。

## 8. VOD 精准搜索与匹配

### 8.1 搜索关键词生成

每条 TMDB 数据按以下顺序生成关键词，去空、去重后使用：

1. `localizedTitle`：`language=zh-CN` 返回的 `title` 或 `name`。
2. `originalTitle`：电影 `original_title` 或电视剧 `original_name`。
3. 按需从 TMDB 详情的 `alternative_titles` / `translations` 中选一个中文常用别名。

默认只执行第 1 项。第 1 项没有可信结果时才能消耗补充搜索名额执行第 2 或第 3 项；同一条目总计最多搜索 2 个关键词。

### 8.2 标题标准化

TMDB 标题和 VOD 标题进入评分前统一：

- 转小写。
- 去除首尾及内部空白。
- 统一全角/半角标点。
- 去除 `·・—-_:/：` 等非语义分隔符。
- 中文数字季数与阿拉伯数字季数统一，例如“第二季”与“第2季”。
- 提取但不直接删除季数、部数、上下篇、年份等限定信息。
- 不使用简单的任意子串命中短标题；标准化标题少于 4 个字符时必须完全相等。

需要分别保存：

```text
baseTitle       去掉可识别季度/版本后缀的主体标题
seasonNumber    第几季，无法识别为 null
edition         剧场版、电影版、特别篇、上篇、下篇等
```

### 8.3 候选评分

匹配器只检查每次 VOD 搜索结果的前 10 条：

| 条件 | 分值 |
| --- | ---: |
| 本地化标题完全一致 | +120 |
| 原始标题或已知别名完全一致 | +100 |
| 主体标题完全一致 | +70 |
| 合法长标题包含关系 | +35 |
| 年份完全一致 | +30 |
| 年份相差 1 年 | +10 |
| 年份相差至少 2 年 | -40 |
| 电影/电视剧类型一致 | +20 |
| 电影/电视剧类型明确冲突 | -60 |
| 季数完全一致 | +40 |
| 一侧有季数、另一侧没有 | -20 |
| 季数明确冲突 | -120 |
| 版本信息完全一致 | +20 |
| 版本信息明确冲突 | -50 |

同一条件组不可重复累计，例如“本地化标题完全一致”后不再叠加“主体标题完全一致”。

### 8.4 接受阈值

候选必须同时满足：

1. 最高分不低于 120。
2. 最高分与第二名至少相差 25 分；只有一个候选时不受本条限制。
3. 不存在季数、媒体类型或版本的明确冲突。
4. 标题必须至少满足完全一致、别名一致或合法主体标题一致之一。

以下情况直接判为未匹配：

- 两个同名候选都没有年份，无法区分翻拍版本。
- TMDB 是第二季，VOD 只找到第一季。
- TMDB 是电影，候选明确是同名电视剧。
- 只有短标题包含关系，例如“家”命中“回家”。

### 8.5 电视剧季度的特殊限制

TMDB 的电视剧榜单通常以整部 Series 为单位，而部分 VOD 源按季度拆分。这是当前最难完全自动化的场景。

已确认季度歧义时自动选择最新一季，但必须满足以下限制：

- TMDB 标题明确带季数时，VOD 季数必须一致。
- `latestSeasonNumber` 存在时，优先选择与其相同的 VOD 季数。
- `latestSeasonNumber` 缺失时，如果 VOD 返回多个同主体标题季度，选择能够解析出的最大季数。
- “特别篇 / SP / OVA / 剧场版”不参与电视剧季度大小比较。
- 最大季数存在多个候选时，优先标题完全一致；仍并列再按 VOD `updatedAt` 选择最近更新。
- 候选标题主体、媒体类型或版本存在冲突时，不得因为季数更大而选中。
- 所有候选都无法解析季数且评分并列时，仍判为未匹配。

TMDB 的 `first_air_date` 是整部剧首次播出日期，不是最新季度日期，因此在“自动选最新一季”分支中不得用它对 VOD 季度年份施加强负分。

### 8.6 不提前验证播放地址

榜单阶段只确认存在可信的 VOD 搜索结果，不调用 `resolvePlayback`：

- 避免首屏为 12 部影片解析详情和播放地址。
- 用户点击后继续走现有详情页流程。
- 若详情或播放最终失效，沿用现有错误状态和换源能力。

## 9. 展示与交互

### 9.1 Feed 行

固定顺序建议为：

```text
默认 | 最新 | 最热 | 高分
```

“默认”始终可用。TMDB 初始化失败时，后三项仍显示；点击后展示带重试按钮的错误状态。

### 9.2 卡片

匹配成功的卡片：

- 标题：TMDB `zh-CN` 标题，缺失时用 VOD 标题。
- 海报：TMDB 海报，缺失时用 VOD 海报。
- 右上角：高分榜显示一位小数评分；其他榜单可不显示评分。
- 左上角：可选显示 `#1`～`#10` 排名，第一期建议显示。
- 底部备注：继续使用 VOD `remarks`，让用户看到“更新至 X 集”等资源状态。
- 点击：把 `matchedVideo` 传入现有 `VideoDetailPage`。

### 9.3 加载状态

列表分两阶段渐进加载：

1. “正在获取榜单”。
2. “正在当前来源查找资源 4/12”。

已有匹配结果可以逐步出现，但最终展示顺序必须按 TMDB `rank`，不能按请求完成时间。

### 9.4 未匹配反馈

主网格只展示当前来源可直接播放的影片。本批未匹配项在底部折叠展示：

```text
当前来源未找到 5 部
[查看并在其他来源查找]
```

展开后的 TMDB 卡片不显示播放按钮，标记“当前来源未找到”。只有用户显式点击某张卡片时，才使用共享跨源服务并发检索最多 3 个备用源；严格匹配后先解析真实播放信息，成功才使用真实 `VideoRef` 进入详情页。全部失败时明确告知用户，不得自动切换全局来源。

策展状态必须区分 `matched` / `notFound` / `ambiguous` / `requestFailed`；只有 `notFound` 和 `ambiguous` 可归入“当前来源未找到”，请求失败单独提示刷新重试。

### 9.5 刷新

- 下拉刷新：清除当前 Feed 的 TMDB 短缓存和当前来源的本批匹配缓存，再执行一次。
- 反复点击当前 Feed：不刷新。
- App 返回前台：缓存未过期时不刷新。

## 10. 缓存

### 10.1 TMDB 榜单缓存

| Feed | TTL |
| --- | --- |
| 最新 | 2 小时 |
| 最热 | 2 小时 |
| 高分 | 12 小时 |

缓存键：

```text
tmdb:{feed}:{mediaScope}:{language}:{region}:{page}
```

### 10.2 VOD 匹配缓存

成功缓存：

```text
match:{vodSourceId}:{tmdbMediaType}:{tmdbId} → VideoRef + score
TTL = 24 小时
```

未匹配缓存：

```text
miss:{vodSourceId}:{tmdbMediaType}:{tmdbId}
TTL = 2 小时
```

缓存必须包含 `vodSourceId`。切换来源不删除旧来源缓存，只是自然读取新来源对应的缓存空间。

第一期允许仅内存缓存；若真机测试确认请求量明显，发布前改为持久化缓存。

## 11. TMDB 接入与安全

### 11.1 第一期采用在线静态 JSON

可行，而且比让 App 直连 TMDB 更适合作为第一期正式方案。它不是常驻动态代理，而是“定时生成榜单快照”：

```text
定时任务（持有 TMDB Token）
  → 请求 TMDB
  → 合并、分类、排序、过滤
  → 生成静态 JSON
  → 原子发布到 hey-rickytse.com/data/tmdb/

Jive App
  → 只下载公开静态 JSON
  → 在当前 VOD 源进行本地搜索和匹配
```

Jive 已经从 `https://hey-rickytse.com/data/vod_sources.json` 加载远程源配置，因此榜单可以沿用同一 HTTPS 域名和“远程成功 → 最近缓存 → 错误态”的客户端模式，但必须使用独立 URL、独立缓存键和独立 schema，不能把榜单塞进 `vod_sources.json`。

静态 JSON 的能力边界：

- 能隐藏 TMDB Token，App 和 APK 中都不需要 Token。
- 能在所有设备之间共享已经合并好的榜单。
- 能集中完成电影、电视剧、动漫、综艺分类和成人内容过滤。
- 能通过替换 JSON 调整榜单，不需要发布新版 App，前提是 schema 不变。
- 不能根据每个用户临时改变筛选参数。
- 更新速度取决于生成任务频率，不是真正的实时 API。
- 生成失败时必须继续保留上一版，不能发布空榜单。
- 当前仍无法直接获得 TMDB 月榜；若未来持续存储每次采样，才可以计算 Jive 自己的月度热度。

### 11.2 文件组织

有三种可选粒度：

| 方案 | 文件 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 单一大 JSON | `catalog.json` 包含三个 Feed 和全部分类 | 客户端最简单；一次下载后切换 Feed 无请求；单文件天然一致 | 最热每 6 小时变化时必须重下完全没变的高分数据；首次只看一个 Feed 也下载全部；文件损坏会使三个 Feed 同时失效 |
| 每个 Feed 一个 JSON | `manifest + latest + popular + top_rated` | 更新频率互不牵连；用户只下载打开的 Feed；总共仅四个入口文件；失败隔离较好 | 比单文件多一次 manifest 请求；需要分别缓存三个 Feed |
| 每页一个 JSON | `manifest + feed/scope/page` | 流量最省，深分页按需加载；单页失败隔离最好 | 文件和请求数量最多；revision、一致性、缓存和回滚实现最复杂 |

**建议采用中间方案：一个 manifest + 每个 Feed 一个 JSON。** 当前每类最多 200 条，压缩后的 Feed 文件仍处于移动端容易接受的量级；同时避免“热门更新导致高分榜也重复下载”。

建议 URL：

```text
https://hey-rickytse.com/data/tmdb/v1/manifest.json
https://hey-rickytse.com/data/tmdb/v1/latest.json
https://hey-rickytse.com/data/tmdb/v1/popular.json
https://hey-rickytse.com/data/tmdb/v1/top-rated.json
```

每个 Feed 文件内部包含五个有序 ID 列表和一份去重后的条目字典：

```text
groups = all | movie | tv | animation | variety
items  = 以 tmdb:{mediaType}:{id} 为键的元数据字典
```

第一期每个 Group 最多保存 200 个候选。App 不按 HTTP 页加载，而是从 Group 的 ID 队列持续取候选，每次目标补满 12 个 VOD 匹配结果。

`manifest.json` 示例：

```json
{
  "schemaVersion": 1,
  "language": "zh-CN",
  "feeds": {
    "popular": {
      "revision": "20260907T120000Z",
      "generatedAt": "2026-09-07T12:00:00Z",
      "expiresAt": "2026-09-07T18:00:00Z",
      "path": "popular.json"
    }
  }
}
```

Feed 文件示例：

```json
{
  "schemaVersion": 1,
  "revision": "20260907T120000Z",
  "feed": "popular",
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
      "releaseDate": "2026-08-10",
      "sortDate": "2026-08-10",
      "latestSeasonNumber": null,
      "rating": 8.1,
      "voteCount": 1680,
      "popularity": 512.4,
      "posterPath": "/example.jpg",
      "rank": 1
    }
  }
}
```

Feed 文件只保存 TMDB 元数据，不提前保存 VOD 搜索结果，因为 VOD 匹配依赖用户当前选择的来源。使用 ID 列表加字典可以让 `all` 与四个分类共享同一份元数据，避免在单个文件内重复保存完整对象。

### 11.3 生成和发布规则

- 最新：每 6 小时生成一次。
- 最热周榜：每 6 小时生成一次。
- 高分：每天生成一次即可。
- Token 保存在定时任务的 Secret/Vault 中，不写入仓库、日志或 JSON。
- 生成任务先校验 schema、每页数量、重复 ID、成人内容和空榜单。
- 先上传三份新 Feed JSON，全部成功后最后替换 `manifest.json`；revision 校验防止客户端接受新旧混合数据。
- 任一步失败都保留旧 manifest；禁止让客户端读到半套 revision。
- HTTP 建议提供 `ETag`、`Cache-Control` 和 gzip/Brotli。
- 至少保留前一个 revision，方便发现数据异常时回滚 manifest。
- 可由服务器 cron、GitHub Actions 定时任务或云函数定时任务生成；选择哪种执行环境不影响客户端协议。

### 11.4 客户端缓存和降级

当前正式客户端加载顺序：

```text
内存 / 持久化 / 打包快照
  → 立即展示

后台 GET /api/tmdb/v1/catalog?feed=...
  → 200：展示并缓存新 revision 与 ETag
  → 304：保留本地快照并更新最近验证时间

远程失败
  → 使用最近一次完整缓存

没有完整缓存
  → 使用打包快照；打包快照也无效时显示错误，不影响“默认”Feed
```

- `stale: true` 仍可展示，但需要保留 stale 状态。
- 新响应解析失败时不得删除旧 revision 的完整缓存。
- JSON 为空、Feed 不一致或 schema 不支持时视为损坏，回退旧缓存。
- 下拉刷新携带 `If-None-Match`；Feed 未变化时使用 304 响应，不重复下载响应体。

### 11.5 最新/最热能否在客户端定时刷新

技术上可以，但只能可靠地实现“App 在前台且缓存过期时按需刷新”，不能依赖普通 Timer 保证 App 关闭后每 6 小时执行：

- iOS 会挂起后台 App，系统不保证指定时间唤醒。
- Android 省电、待机和厂商策略会延迟后台任务。
- 即使接入平台后台任务，执行时间仍由系统调度，不适合作为榜单发布时钟。
- 客户端直连 TMDB 必须携带 Token，公开 APK 中可以被提取。
- 每台设备都会重复请求和执行电影/电视剧合并、四类映射及老剧新季详情补查。
- 最新/最热走直连、高分走静态 JSON 会形成两套数据通道、缓存和错误处理。

若确认接受 Token 暴露，只用于本人/家庭侧载，可以采用：

```text
打开 Feed 或 App 回到前台
  → 检查 lastFetchedAt
  → 未超过 TTL：使用本地缓存
  → 已超过 TTL：直接请求 TMDB 并刷新缓存
```

这不应称为后台定时任务，也不得承诺每 6 小时一定执行。建议 TTL：最新和最热 2 小时，高分 12 小时。

**当前建议仍是三个 Feed 都由同一个在线 JSON 生成任务发布。** 一个任务可以按不同 TTL 决定是否重算各 Feed，不会因为高分更新慢就产生明显额外成本；客户端因此只有一套稳定数据协议，也无需 TMDB Token。

### 11.6 何时升级成动态代理

出现以下任一需求时，再从静态 JSON 升级为动态 Catalog API：

- 用户可以自由组合地区、年份、评分门槛或内容类型。
- 需要近实时热度，而不是 6 小时级快照。
- 需要基于用户画像生成不同榜单。
- 需要服务端返回任意深度分页，超过预生成的 200 个候选。
- 需要记录历史热度并计算真正的月榜。
- 静态文件数量或生成时间达到不可接受水平。

升级时保持 `TmdbCatalogItem` 字段和分页语义不变，客户端只替换 Repository 数据来源。

### 11.7 本地开发

- 开发者自行申请 TMDB Read Access Token。
- Token 放入 gitignore 覆盖的本地配置或 `--dart-define`。
- 测试和文档不得包含真实 Token。
- HTTP Header 使用 `Authorization: Bearer ...`。
- 本地直连仅用于验证生成器和字段映射；App 正式数据路径读取在线 JSON。

### 11.8 署名

“关于/数据来源”必须保留 TMDB 官方要求的声明及批准 Logo。不得暗示 Jive 获得 TMDB 背书。

## 12. 异常处理

| 场景 | 行为 |
| --- | --- |
| 在线榜单 JSON 超时 | 榜单错误态；若有过期缓存则展示缓存并提示可能不是最新 |
| 当前 VOD 源不支持搜索 | 不发匹配请求，提示“当前来源不支持榜单资源检索” |
| 单条 VOD 搜索失败 | 该条记失败，其他队列继续 |
| VOD 源整体连续失败 | 停止尚未开始的队列，展示来源异常及重试入口 |
| 切换 Feed | 当前 generation 作废，旧请求不得写回 |
| 切换 VOD 源 | 当前匹配 generation 作废，按新来源重建可见批次 |
| TMDB 字段缺失 | ID、媒体类型、标题缺一则丢弃；海报、日期、评分允许缺失 |
| 图片加载失败 | 使用现有海报占位，不影响点击 |
| 内容过滤命中 | 与普通 VOD 列表一致地隐藏 |

## 13. 数据流和职责边界

```text
HomePage
  ↓ 选择 latest / popular / topRated
CuratedFeedController
  ↓
TmdbCatalogRepository ───→ Jive 在线静态榜单 JSON
  ↓ TmdbCatalogItem[20]
CuratedFeedResolver
  ├──→ VideoRepository.fetchPage(currentVodSource, keyword)
  ├──→ VideoMatcher
  └──→ ResolvedCatalogItem[]
          ↓ matchedVideo
      VideoDetailPage → 现有详情/播放链路
```

推荐新增文件：

```text
lib/domain/tmdb_catalog.dart
lib/domain/video_search_target.dart
lib/data/catalog/tmdb_catalog_repository.dart
lib/data/content/video_matcher.dart
lib/data/content/cross_source_search_service.dart
lib/features/home/curated_feed_controller.dart
lib/features/home/curated_unavailable_section.dart
```

首页与 `DetailSourceController` 统一通过 `CrossSourceSearchService` 使用公共 `VideoMatcher`，避免详情跨源匹配与榜单匹配出现两套规则。

## 14. 埋点与评估指标

若当前项目没有远程埋点，第一期先保留结构化本地日志接口：

- Feed、TMDB 批次大小。
- 当前源 ID（不得记录源密钥或完整 URL）。
- 主搜索次数、补充搜索次数。
- 匹配成功数、未匹配数、歧义数、超时数。
- 单批首个结果时间和全部完成时间。
- 用户点击的 TMDB ID 与最终 VOD `sourceVideoId`。

真机抽样目标：

- 首批 12 条中，主流综合 VOD 源命中至少 6 条。
- 人工检查 100 个匹配，错误匹配不超过 1 个。
- 网络正常时首个可展示结果在 3 秒内出现。
- 单批请求量不得突破本需求硬上限。

命中率目标用于评估，不应通过降低匹配阈值强行达成。

## 15. 测试要求

### 15.1 TMDB 数据

- 电影和电视剧字段映射。
- `zh-CN` 标题缺失时回退原始标题。
- 日期、海报、评分缺失时容错。
- 电影/电视剧合并后排序稳定。
- 支持 `include_adult` 的请求固定关闭；其他列表返回的成人条目会被二次过滤。
- 缓存命中、过期和强制刷新。

### 15.2 匹配器

- 中文标题完全一致。
- 原始标题和别名一致。
- 同名不同年份。
- 同名电影和电视剧。
- 第一季和第二季。
- 剧场版和 TV 版。
- 短标题不做包含误匹配。
- 第一、第二候选分差不足时拒绝。
- 结果超过 10 条时只检查前 10 条。

### 15.3 控制器

- 首轮只解析 12 条，未满时按 6 个候选一组自动补位。
- 单次加载最多扫描 24 个候选，主搜索不超过 24 次，补搜不超过 6 次。
- 并发不超过 3。
- 建议 30 秒后不再启动新搜索。
- 搜索完成顺序不同但展示顺序稳定。
- 快速切换 Feed 时旧结果不覆盖新结果。
- 切换 VOD 源后缓存隔离并重新匹配。
- 单条失败不阻断全批。
- 连续源级失败会停止队列。

### 15.4 Widget

- 四个 Feed 顺序和选中态正确。
- TMDB 加载、匹配中、部分成功、全无结果和错误态。
- 评分、排名、VOD remarks 显示正确。
- 点击后进入匹配到的 VOD 详情。
- 下拉刷新和加载更多请求量符合预算。

## 16. 验收标准

- [ ] 首页存在“默认 / 最新 / 最热 / 高分”，且语义与第 5 节一致。
- [ ] 榜单覆盖电影、电视剧、动漫、综艺，且同一条目不会跨分类重复。
- [ ] TMDB 返回语言为简体中文，成人内容固定关闭。
- [ ] 在线 Feed 每个分类最多提供 200 个有序候选，并使用稳定身份去重。
- [ ] 首轮解析 12 条；自动补位时最多扫描 24 个候选、发起 30 次 VOD 搜索，并发最多 3。
- [ ] 上拉加载更多以新增 12 个匹配结果为目标，持续到候选结束或达到单次硬上限。
- [ ] 每个关键词只搜索当前 VOD 源第一页，只评估前 10 个候选。
- [ ] 展示顺序跟随 TMDB 排名，而不是网络完成顺序。
- [ ] 匹配结果满足阈值、分差和冲突检查。
- [ ] 同名翻拍、季度和媒体类型冲突不会自动误配。
- [ ] 未匹配、超时或单条错误不阻断其余结果。
- [ ] 点击卡片走现有详情和播放链路，不使用 TMDB 播放信息。
- [ ] 切换 VOD 源后使用新源重新匹配，旧异步结果不会写回。
- [ ] Feed、搜索和匹配缓存按规定隔离和过期。
- [ ] 正式发布不在 APK 中保存 TMDB 长期 Token。
- [ ] 关于/数据来源页面完成 TMDB 署名。
- [ ] `flutter analyze` 和全部相关测试通过。
- [ ] 新增、移动或删除 Dart 文件后同步更新 `doc/codebase/CODEBASE_MAP.md`。

## 17. 开发前置条件

进入开发前必须完成：

1. 对第 1 节 D1～D22 的剩余项目逐项确认，或明确接受建议组合。
2. 准备开发用 TMDB Read Access Token，不提交仓库。
3. 确认第一期采用第 11 节的在线静态 JSON 发布方案，并选择定时任务执行环境。
4. 用至少两个现有 VOD 源抽样电影、电视剧、动漫、综艺各 20 条，记录标题、年份、季度和分类字段质量。
5. 根据抽样结果最终冻结第 8 节匹配阈值，不在开发过程中凭感觉放宽。

## 18. TMDB 官方参考

- Popular Movies：<https://developer.themoviedb.org/reference/movie-popular-list>
- Trending：<https://developer.themoviedb.org/reference/trending-all>
- Upcoming Movies：<https://developer.themoviedb.org/reference/movie-upcoming-list>
- On The Air TV：<https://developer.themoviedb.org/reference/tv-series-on-the-air-list>
- Top Rated Movies：<https://developer.themoviedb.org/reference/movie-top-rated-list>
- Top Rated TV：<https://developer.themoviedb.org/reference/tv-series-top-rated-list>
- Discover Movie：<https://developer.themoviedb.org/reference/discover-movie>
- 应用鉴权：<https://developer.themoviedb.org/v4/docs/authentication-application>
- 授权与署名 FAQ：<https://developer.themoviedb.org/docs/faq>
