# Jive 接入 SyncnextPlugin 源 — 方案与改动计划

## 1. 文档信息

| 项目 | 内容 |
| --- | --- |
| 状态 | 第二期进行中（第一期 AGE Dart Adapter 已合入本分支） |
| 平台 | Flutter Android / iOS |
| 基线分支 | `feature/cache-streaming-proxy` |
| 实现分支 | `feature/syncnext-age-source` |
| 本期核心 | AGE Dart Adapter + 通用 `syncnext_plugin` JS 运行时；浏览页共用 |
| 数据策略 | 继续客户端直连源站；插件脚本从 HTTPS `pluginConfigUri` 加载；不突破 V1 后端边界 |
| 地域约束 | **第一期站点必须大陆 IP 可访问**。已放弃「新欧乐」（官方标注阻挡中国地区） |
| 成熟度 | 约 80%。闭合 §6.4 三点后可开工 |

本文是接入 Syncnext 订阅源的权威方案。第一期以第 6 节为准。未确认第 11 节前不改业务代码。

相关文档：

- 现有多源架构：`ARCHITECTURE.md`、`doc/archive/vod-source/VOD_SOURCE_SWITCH_PRD_AND_PLAN.md`
- V1 后端边界：`doc/backend/BACKEND_TECHNICAL_REQUIREMENTS.md`
- 上游协议： [qoli/syncnextPlugin `doc.md`](https://github.com/qoli/syncnextPlugin/blob/main/doc.md)
- 第一期插件： [plugin_age](https://github.com/qoli/syncnextPlugin/tree/main/plugin_age)

---

## 2. 背景与目标

Jive 目前只实现 `mac_cms_v10` Adapter。源列表来自远程 `vod_sources.json`（失败则用本地缓存 / 内置资产），页面通过 `VodSourceRegistry` 按 `adapterType` 选 Adapter。

最初评估的四个 Syncnext 源：

| 名称 | api | 实际形态 | 大陆 IP |
| --- | --- | --- | --- |
| 埋堆堆 | `Syncnext://MDD` | Syncnext App **内置原生频道**，无公开 JS / HTTP 契约 | 未知，无公开协议 |
| 低调影视 DDYS | `syncnextPlugin://…/plugin_ddys/config.json` | HTML + 验证闸道 + cookie 池 + `$vision` OCR | 未标海外，但反爬过重 |
| 新欧乐影院 | `syncnextPlugin://…/plugin_olevod/config.json` | HTTPS JSON API + `_vv` 签名 | **否**（官方：阻挡中国地区） |
| 新 AGE | `syncnextPlugin://…/plugin_age/config.json` | HTTPS JSON API + resolver 二次解析 | **未标海外**；catalog API 实测可返回 JSON |

另：官方源表里「新厂长」明确写「要求大陆 IP」，但是 HTML + WAF + AES/iframe 解密，不适合作为第一个 Dart Adapter。

目标：

1. 新增源尽量只加 Adapter 和少量播放解析补丁，不改首页 / 搜索 / 详情的业务流程。
2. 第一期打通一条 **大陆 IP 可直连** 的非 Mac CMS 全链路：分类、分页、搜索、详情、多线路剧集、按集解析播放、多源探测。
3. 不把 `sourcesv3.json` 整表导入；不接 `Syncnext://MDD`；不做需要出海的欧乐。
4. HTML 站（厂长 / DDYS）留给后续 JS 运行时或网关。

---

## 3. 协议差异（必须先对齐）

### 3.1 Jive 当前三阶段

```text
fetchCategories → fetchPage(list / search) → fetchDetail
                                              ↓
                                      resolvePlayback
                                              ↓
                                      Episode.url 已是可播 HTTPS
                                              ↓
                                      Player / PlaybackUrlResolver
```

分类是 Mac CMS 整数 `type_id`，首页按父子分类树导航。`VodSource.baseUri` 必须 HTTPS 且 host 非空。

### 3.2 Syncnext 插件四阶段

```text
config.json.pages[]   → JS buildMedias(url)              → $next.toMedias
config.json.search    → JS Search(url, pluginKey)        → $next.toSearchMedias
config.json.episodes  → JS Episodes(detailURL)           → $next.toEpisodes
config.json.player    → JS Player(episodeDetailURL)      → $next.toPlayer / toPlayerByJSON / toPlayerCandidates
```

媒体卡片：`id / title / coverURLString / descriptionText / detailURLString`。  
剧集：`id / title / episodeDetailURL`。AGE 的该字段是 resolver 包装地址或 `age-payload:` 私有串，**不是**最终 m3u8。

### 3.3 领域模型缺口

| Jive | Syncnext / AGE | 处理策略 |
| --- | --- | --- |
| `baseUri` 必须 HTTPS + host | AGE host 为 `https://ageapi.omwjhz.com:18888` | 满足 `isLoadable`；MDD / `Syncnext://` 仍不放行 |
| `adapterType` 仅 `mac_cms_v10` | 需要新类型 | 第一期新增 `age_v2` |
| `VideoCategory.id` 为 `int`，首页走父子树 | `pages[].key` 为字符串，扁平页签 | Adapter 内分配稳定 int；无子分类时首页已支持直接按该 id 查询 |
| `resolvePlayback` 后 `Episode.url` 可播 | AGE 剧集是 resolver URL，点播时才解出 m3u8 | 剧集 URL 存 resolver；播放走现有 `PlaybackUrlResolver`，并补 `Vurl` 匹配与格式误判 |
| `inferPlaybackFormat` 把 path 含 `m3u8` 当成 HLS | resolver 形如 `/m3u8/?url=age_…`，其实是 HTML 包装页 | 收紧推断：目录名 `m3u8` 不等于 `.m3u8` 文件 |
| 播放 headers 已有 `PlaybackSource.headers` | 终态 HLS 必须带 UA / Referer | HTML 解出 Vurl 后**显式重建**最终 `PlaybackSource.headers`，不依赖 copyWith 碰巧保留 |
| 源检测调用 `fetchCategories` | AGE 分类是本地常量，不访问 18888 | 健康检测改为 `fetchPage(page: 1)`，必须打到 AGE API |
| 未知 `adapterType` | 远程配置可能混入插件源 | Registry 构建时丢弃，**不得出现在源管理 / 切源 UI** |

首页分类逻辑已经兼容「全部是顶级、没有子分类」。AGE 返回扁平分类即可，不必改首页 UI。

---

## 4. 源选型结论

### 4.1 新 AGE（第一期唯一实现对象）

选定理由：

- 官方未标注海外 IP；与欧乐「阻挡中国地区」相对。
- 列表 / 搜索 / 详情都是 HTTPS JSON，适合手写 Dart Adapter。
- 本次从当前环境请求 catalog 返回 `200` 且含 `total` / `videos`。
- 在最初四个候选里，它是唯一「大陆可直连 + 公开 JSON」的组合。

代价：

- 内容以动漫为主（TV / 剧场版 / WEB / 连载），不是综合影视站。
- 播放必须二次解析；API host 使用 **非标准端口 18888**，部分校园网 / 企业网可能拦 TCP。若真机验证端口不通，再评估改做「新厂长」或网关，不在第一期预做双 Adapter。

站点要点：

| 项 | 值 |
| --- | --- |
| Host | `https://ageapi.omwjhz.com:18888` |
| 列表 | `GET /v2/catalog?…&page={page}&size=32` |
| 搜索 | `GET /v2/search?page={page}&query={keyword}`（插件写死 page=1；接口实际返回 `total` / `totalPage`，第一期按页请求） |
| 详情 | `GET /v2/detail/{id}` |
| 剧集 | `video.playlists[lineKey] = [[title, cryptograph], …]` |
| 解析前缀 | 详情里的 `player_jx.zj` / `player_jx.vip`（实测为 `https://jx.wuzhoupai.com:8443/m3u8/?url=`） |
| VIP 线路 | `player_vip` 逗号列表（含 `xigua`、`qq` 等）；插件丢掉 VIP 线，只保留 `ffm3u8` / `bfzym3u8` 等 |
| 播放 | 请求 `zjPrefix + cryptograph`，从 HTML 取 `var Vurl = '真实m3u8'` |

分类与 Jive `categoryId`（`parentId = 0`）：

| page key | 展示名 | categoryId | catalog 差异 |
| --- | --- | --- | --- |
| （首页未选） | 最近更新 | `null` | `order=time`，其余 `all` |
| `popular` | 热门 | `1` | `order=click` |
| `ongoing` | 连载 | `2` | `status=连载` |
| `movie` | 剧场版 | `3` | `genre=剧场版` |
| `web` | WEB | `4` | `genre=WEB` |

### 4.2 新欧乐（因大陆 IP 不可达，第一期不做）

JSON 直链播放最简单，但官方明确「阻挡中国地区访问」。保留为后续「有出海环境时」的候选，不进入第一期配置。

### 4.3 新厂长（大陆 IP 明确，但 HTML 过重）

`sourcesv3.json` 标注「要求大陆 IP」。实现是抓 HTML、cookie 罐、SafeLine 属性改写、iframe、AES、混淆 URL，以及阿里云盘。作为 AGE 端口被拦时的备选，不作为第一期。

### 4.4 DDYS（第三期候选）

cookie 池 + ALTCHA + `$vision` 点击验证。不适合第一个 Adapter。

### 4.5 埋堆堆 MDD（明确不做）

闭源 `Syncnext://MDD`。没有公开契约前不进源列表。

---

## 5. 总体策略（方案 D）与备选

| 方案 | 做法 | 覆盖 | 与当前架构 | 决策 |
| --- | --- | --- | --- | --- |
| A 手写 Dart Adapter | 按源移植 JSON / 解析 | AGE 可行；欧乐更简单但大陆不可达 | 最高 | **第一期采用（AGE）** |
| B 内嵌 JS 运行时 | Flutter 执行官方 `app.js`，桥 `$http` / `$next` | 理论覆盖全部 JS 插件 | 中，兼容与供应链风险高 | 第三期候选 |
| C 后端插件网关 | Node 跑插件，对 App 暴露 Jive DTO | 厂长 / DDYS / 欧乐地域墙更现实 | 低，突破 V1「后端不代理内容请求」 | 仅当直连失败 |
| D 按源选型分期 | AGE 走 A；HTML 走 B 或 C；欧乐需出海；MDD 不做 | 按阶段扩大 | 最高 | **总策略** |

第一期 = 方案 D 的第一步 = AGE Dart Adapter + 通用 Resolver 补丁（见第 6 节）。

不采用「一开始就做通用 JS 运行时」：官方文档明确 Node smoke ≠ tvOS JavaScriptCore 真机。

---

## 6. 第一期范围（修订）

路线：**AGE + Dart Adapter + 通用 Resolver 补丁**。浏览页（首页 / 搜索 / 详情）共用；不为 AGE 另起页面。Mac CMS XML、JS 运行时、网关不在本期。

### 6.1 做（12 项）

1. **新增 `AgeAdapter`**（`adapterType: age_v2`），实现分类 / 分页 / 搜索 / 详情 / 剧集清单。
2. **新增 `notification`**：`VodSource` 读写；源管理页展示。
3. **Registry 过滤未注册 Adapter**：未知 `adapterType` 不进 `VodSourceRegistry`，不出现在源管理、首页切源、搜索/详情备用源。单条坏数据不得让整表失败。
4. **收紧媒体格式推断**：`inferPlaybackFormat` 只认 `.m3u8` / `.mp4` / `.mpd` 等明确媒体形态；path 段名为 `m3u8`（如 `/m3u8/?url=age_…`）视为 `unknown`，进入 HTML resolver。`.m3u8` 直链回归不得变。
5. **支持 `Vurl`**：`PlaybackUrlResolver` 从 HTML 提取 `var Vurl = '…'`（AGE 解析页变量名）。
6. **HEAD 失败时用 Range GET 探测**：抽出候选媒体后，HEAD 非 2xx / 405 / 超时 / 传输失败不得直接判死，改为 `GET` + `Range: bytes=0-511`；**206 与 200 都算成功**。
7. **HTML resolver 解析后正确构造最终媒体 Header**：终态 `PlaybackSource.headers` 必须显式含 `User-Agent` 与 `Referer`（Referer = resolver 页 URL），不依赖 `copyWith` 碰巧保留包装页头。
8. **AGE 默认线路使用明确优先级**：见 §7.2，禁止「JSON 对象键顺序第一条」。
9. **源健康检测必须实际访问 AGE API**：检测改为 `fetchPage(page: 1)`（或等价 catalog 探活）。`AgeAdapter.fetchCategories` 仍为本地常量，**不能**再作为健康检测入口。18888 不通必须失败。
10. **AGE 下载第一期明确禁用**：详情页对 `age_v2` 显示「该来源暂不支持下载」，禁止 `enqueue`。完整下载 / 重启恢复放到第二期，本期不做「半套下载」。
11. **本地配置优先级放到现有源末尾**：本地 `config/vod_sources.json`（gitignore）增加 AGE，`priority` = 现有最大优先级 + 1（当前样例为 `31`）。
12. **大陆真机成功后才发布远程配置**：客户端合入 ≠ 远程 `vod_sources.json` 上 AGE。先本地配置验收，真机通过再发配置服务。

### 6.2 不做

- 欧乐 / 厂长 / DDYS / MDD Adapter；MacCMS XML codec
- Flutter JS 引擎、`$http` / `$next` 桥、后端内容代理
- 导入 `sourcesv3.json`；用户粘贴 `syncnextPlugin://`
- 为 18888 做客户端代理
- `resolvePlayback` 预解析全部剧集真实 m3u8
- AGE 下载、下载重启恢复、自动换线（`toPlayerCandidates`）
- 另起 AGE 专用 Home / Detail / Player 页面

### 6.3 本地源配置（不入库；远程暂不发）

```json
{
  "id": "age",
  "name": "新 AGE",
  "baseUri": "https://ageapi.omwjhz.com:18888",
  "adapterType": "age_v2",
  "search": true,
  "enabled": true,
  "priority": 31,
  "notification": "AGE 动漫；部分网络可能拦截 18888 端口"
}
```

`id` 保持 `age`。收藏 / 历史 / 缓存绑 `sourceId`。

### 6.4 开工前置三点（已闭合，待确认）

修订前不建议开工的三项，闭合如下。确认第 11 节即视为同意这三点。

#### （1）HEAD → Range GET fallback

现状：候选 URL 已被推断为 HLS/MP4 时只发 HEAD；4xx/5xx 直接抛「真实视频地址不可用」。AGE / 部分 CDN 对 HEAD 回 502/405，但 Range GET 能 206。

规则（写在通用 `PlaybackUrlResolver`，Mac CMS 包装页同样受益）：

```text
抽出 candidate
  → HEAD（带 session headers）
      2xx     → 用 HEAD 的最终 URL + 已推断 format
      否则    → GET Range bytes=0-511（同一套 headers）
                200 / 206 → 用 GET 的最终 URL，必要时用 body 再 sniff
                其他      → 失败
```

超时、连接重置与 502 同等进入 GET 回退。GET 的 206 不得当失败。

#### （2）修正源健康检测

现状：源管理 `_check` 只调 `fetchCategories`。AGE 分类不发网，18888 全死也会显示「检测成功」。

规则：

- `_check` 改为 `fetchPage(source, page: 1)`，超时仍 8 秒。
- Mac CMS：打 `ac=detail&pg=1`，行为仍是真实探活。
- AGE：打 `/v2/catalog?…&page=1&size=32`（或 `size=1`）。连接失败 / 非 200 / 非 JSON → 检测失败。
- 不把「分类常量可返回」当成健康。

#### （3）Header 与下载

**Header（本期做）：**

| 阶段 | User-Agent | Referer |
| --- | --- | --- |
| 请求 AGE catalog/detail | 默认客户端 UA 即可 | 无 |
| 请求 resolver HTML | 固定播放 UA（与插件一致的 Safari UA） | resolver 页自身或 AGE host |
| 终态 HLS/MP4 `PlaybackSource` | **同一播放 UA** | **resolver 页完整 URL** |

构造终态时显式传入 `headers` 映射，经 `filterSessionHeaders` 后再交给播放器 / 代理。禁止终态 headers 为空。

**下载（本期不做 AGE）：**

- `adapterType == age_v2` 时详情下载按钮可点，但 toast「该来源暂不支持下载」，不建任务。
- 理由：下载链路用 `selectionFor` + `inferPlaybackFormat(episode.url)`，AGE 的 episode.url 是 resolver；重启恢复又不带齐 Referer，半套实现会留下「任务在、文件坏」。
- 第二期若做：必须走与在线播放同一套 resolver（含 HEAD fallback 与终态 Header），并验收进程被杀后恢复。

---

## 7. 第一期设计

### 7.1 Adapter 行为

| 方法 | 行为 |
| --- | --- |
| `fetchCategories` | 返回 §4.1 扁平分类。不发网络请求。 |
| `fetchPage` | 有 `keyword` → `/v2/search`；有 `categoryId` → 对应 catalog；否则最近更新 catalog。`size=32`。 |
| `fetchDetail` | `GET /v2/detail/{id}`。填简介、年份、地区、标签、更新状态；剧集只保留名称，`url` 为空（与 Mac CMS `includeEpisodes: false` 一致）。 |
| `resolvePlayback` | 同一详情接口。丢弃 VIP 线路；每条非 VIP 线生成 `PlaybackLine`；`Episode.url` 为 **resolver HTTPS**（`player_jx.zj + cryptograph`），不是最终 m3u8。按集号对齐各线剧集名。 |

列表字段映射：

| 上游 | Jive |
| --- | --- |
| `id` | `sourceVideoId` / `id` |
| `name` | `title` |
| `cover` | `posterUrl` |
| `uptodate` 或 `status` + `type` | `remarks` |
| `type` | `category` |
| catalog 页对应的 `categoryId` | `typeId`（搜索结果用 `0` 或条目 `type` 无法映射时保持 0） |

详情补充：

| 上游 | Jive |
| --- | --- |
| `intro` / `intro_clean` | `description` |
| `year` | `year` |
| `area` | `area` |
| `writer` | `director`（AGE 无独立导演字段） |
| `uptodate` | `remarks` |
| `time_format_*` 或 `time` | `updatedAt`（能解析再填，否则留空） |

分页：catalog 响应含 `total`，`pageCount = ceil(total / 32)`。搜索响应含 `total` / `totalPage`，优先用 `totalPage`。

### 7.2 线路与剧集身份

- 线路名：`player_label_arr[lineKey]`，缺省则用 `lineKey`。
- `PlaybackLine.identity`：`age:line:{lineKey}`。
- `Episode.identity`：`age:episode:{alignKey}`，`alignKey` 优先 `num:{集数}`，否则 `slot:{顺序}`（与插件对齐逻辑一致）。
- 默认播放线（**确定优先级**，先排除 `player_vip` 中的 key）：

  1. `ffm3u8`（非凡）
  2. `bfzym3u8`（暴风）
  3. `wjm3u8`（无尽）
  4. `lzm3u8`（计算云）
  5. `hnm3u8`（红牛）
  6. 其余非 VIP 线：保持详情 JSON 中的相对顺序

  `Video.episodes` = 默认线剧集。`preferredPlaybackLine` 对 AGE 不得再用「URL 里有没有 `.m3u8`」打分盖过上述顺序（AGE 在 Adapter 内排好 `playbackLines`，默认线放 `first`；或给 AGE 线写死高 identity 顺序，由测试锁死）。

不把 `age-payload:` 私有串写入 `Episode.url`。resolver 地址已是 HTTPS。

### 7.3 播放解析

```text
resolvePlayback → Episode.url = https://jx…/m3u8/?url=age_…
                → inferPlaybackFormat → unknown
                → PlaybackUrlResolver GET HTML（UA + Referer）
                → 提取 var Vurl = 'https://…m3u8'
                → 对候选：HEAD，失败则 Range GET（接受 206）
                → PlaybackSource(url, hls, headers={UA, Referer: resolverUrl})
```

在线播放失败走现有 Player 重试：清 resolver 缓存、再 `resolvePlayback` + 再解析当前集。第一期不自动换 AGE 线路。

### 7.3.1 收紧 `inferPlaybackFormat` 与 Mac CMS

只改「目录名 `m3u8` ≠ 文件 `.m3u8`」。回归：

- `https://cdn.example.com/a.m3u8` → 仍为 hls，不进 HTML 解析
- `https://jx.example.com:8443/m3u8/?url=age_x` → unknown

若 Mac CMS 存在无扩展名但 path 含 `m3u8` 的真直链，会多一次 Range GET；resolver 已能用 `#EXTM3U` sniff，配合 HEAD fallback，视为可接受的共用补丁，必须有回归测试。

### 7.3.2 Mac CMS 播放风险边界（执行约束）

第一期允许改共用播放栈，但 **Mac CMS 直链起播契约不得变**：

```text
Mac CMS Episode.url 含 .m3u8 / .mp4
  → inferPlaybackFormat = hls/mp4
  → 不进 PlaybackUrlResolver
  → 不强制 UA/Referer
  → 边下边播 / 预取 / 下载与今天一致
```

| 改动 | 是否进 Mac CMS 起播 | 允许的写法 | 禁止的写法 |
| --- | --- | --- | --- |
| `AgeAdapter` | 否 | 新 `adapterType` | 改 `MacCmsV10Adapter` |
| `notification` | 否 | 可选字段，缺省空 | 无 |
| Registry 丢未知类型 | 否（配置层） | 只丢未注册 adapter | 因一条坏数据清空整表 |
| `inferPlaybackFormat` | **是** | 仅取消「path 段名叫 `m3u8`/`hls` 就算 HLS」 | 收紧 `.m3u8` 直链、query 含 `m3u8`、`contains('mp4')` |
| 提取 `Vurl` | 仅 HTML 包装页 | **追加**正则；`.m3u8` 候选仍优先 | 用 `Vurl` 覆盖已有 `var url` |
| HEAD→Range GET | 仅 HTML 包装页已抽出的媒体候选 | HEAD 失败再 GET；206 成功 | 对已是 `.m3u8` 的直链先 HEAD 再播 |
| 终态 Header | 仅「入参已有 session headers」 | 把入参 UA/Referer **抄到**终态 | 全局「终态不得空头」、给 Mac CMS 直链发明 Referer |
| 默认线路优先级 | 否 | 只在 `AgeAdapter` 把首选线放到 `playbackLines.first` | 改全局 `_lineScore` / `preferredPlaybackLine` |
| 健康检测改 `fetchPage` | 否（源管理） | 仅 `_check` | 改首页 `fetchCategories` |
| 禁用 AGE 下载 | 否 | `adapterType == age_v2` | 动 Mac CMS 下载 |

Mac CMS 必须锁住的回归（没有这些测试不算第一期完成）：

1. `https://cdn.example.com/a/1.m3u8` → `hls`，Player **零** HTML/HEAD。
2. `selection prefers a direct m3u8 line over an HTML wrapper` 现有用例仍绿。
3. Mac CMS `resolvePlayback` 过滤 http / 非法集的行为不变。
4. 包装页 `var url = '/play/token/index.m3u8'` 仍抽出 HLS；若同页有 `Vurl`，不得抢走更高分的 `.m3u8`。
5. 终态 headers：入参为空则出参仍为空（Mac CMS 常见）；入参有 UA/Referer 才复制。
6. 源管理检测改 `fetchPage` 后，Mac CMS 检测失败不得影响正在播的 Player。

**结论：** 执行本方案会改共用 Resolver / 格式推断，但默认 Mac CMS 路径（直链 `.m3u8`）不经过这些分支。只要按上表实施，**不应影响现有 Mac CMS 直链播放、边下边播、预取和下载**。有条件影响仅限「Mac CMS HTML 包装页」和「源管理点检测」。


### 7.4 错误

沿用 `VideoDataException`：HTTP 非 200、JSON 无法解析、详情无 `video`、`resolvePlayback` 后无非 VIP 剧集。超时与现有 Adapter 同级（约 12 秒）；详情 `episodes.timeout` 在插件里是 120 秒，第一期仍用 12～20 秒，避免搜索探测被单源拖死。resolver 沿用 `PlaybackUrlResolver` 的 8 秒。

### 7.5 配置加载

- `isLoadable` 仍要求 `enabled + https + 非空 host + 非空 id`。AGE 满足（host 含端口亦可）。
- 解析源列表时：单条 JSON 损坏或 `adapterType` 不在已注册集合，**跳过该条**，其余继续。第一期已注册：`mac_cms_v10`、`age_v2`。
- 远程配置**第一期不包含 AGE**。发布顺序：客户端 Adapter 合入 → 本地 gitignore 配置真机验收 → 通过后再写入远程 `vod_sources.json`。

---

## 8. 代码改动清单（第一期）

| 文件 | 改动 |
| --- | --- |
| `lib/domain/vod_source.dart` | 可选 `notification` |
| `lib/domain/playback_selection.dart` | 收紧 `inferPlaybackFormat`；AGE 默认线不被 URL 打分打乱 |
| `lib/data/adapters/age_adapter.dart` | 新建：分类、catalog、搜索、详情、VIP 过滤、默认线优先级、resolver URL |
| `lib/data/vod_source_registry.dart` | 注册 `age_v2`；丢弃未注册 adapter |
| `lib/data/video_repository.dart` | 默认 Adapter 表增加 `age_v2` |
| `lib/data/vod_source_config.dart` | 与 Registry 配合过滤未知类型 |
| `lib/data/cache/playback_url_resolver.dart` | `Vurl`；HEAD→Range GET；终态 headers |
| `lib/features/source_management_page.dart` | `notification`；健康检测改 `fetchPage` |
| `lib/features/detail_page.dart` | `age_v2` 下载入口提示暂不支持，不 enqueue |
| `lib/features/player_page.dart` | 构造 AGE `PlaybackSource` 时带播放 UA；失败可重试（清 resolver 缓存） |
| `config/vod_sources.json` | 本地末尾增加 AGE（不入库、不发远程） |
| `test/age_adapter_test.dart` | 新建（含默认线优先级） |
| `test/playback_url_resolver_test.dart` | `Vurl`；HEAD 502 + GET 206；终态 UA/Referer |
| `test/playback_selection_test.dart` | `/m3u8/?url=` 不得判为 HLS；`.m3u8` 仍为 HLS |
| `test/vod_source_test.dart` | `notification`；未知 adapter 不进 Registry |
| `ARCHITECTURE.md` / `README.md` | 补 `age_v2` 与「AGE 暂不支持下载」 |

不改：`home_page` 分类树、搜索多源协调器、详情切源、HLS 代理核心、后端需求文档、MacCMS XML。

---

## 9. 验收

### 9.1 自动化

- catalog / 搜索 / 详情字段与分页。
- VIP 线丢弃；默认线按 §7.2 优先级；夹具打乱 JSON 键序仍选中 `ffm3u8`（若存在）。
- `inferPlaybackFormat('https://jx.example.com:8443/m3u8/?url=age_x') == unknown`。
- `inferPlaybackFormat('https://cdn.example.com/a.m3u8') == hls`。
- HTML 含 `var Vurl = 'https://cdn.example.com/a.m3u8'` → 终态 HLS。
- **resolver 候选 HEAD 502、随后 GET 206 仍解析成功。**
- **终态 `PlaybackSource.headers` 含正确 `User-Agent` 与 `Referer`（resolver URL）。**
- 配置混入未注册 `adapterType` → Registry / 源列表 UI 都不含该条，其余源正常。
- `notification` 往返。
- `flutter analyze`、`flutter test` 全绿。

### 9.2 真机（大陆 IP，无需代理）

1. 源管理能看到「新 AGE」及 notification；**检测会请求 AGE catalog**。18888 不通时该项失败，不得显示成功。
2. 切到 AGE 后，「最近更新」+ 热门 / 连载 / 剧场版 / WEB 可刷、可分页。AGE 排在源列表末尾。
3. 搜索有结果；多源探测可把它当备用源。未知 adapter 不出现在切源 UI。
4. 详情有简介 / 集数；**默认线路选择确定**（多次进入同一片，默认线名称一致）。
5. 点播非 VIP 集可起播；**在线播放失败可重试**（清 resolver 缓存后再解析，不必杀进程）。
6. 下载入口明确「该来源暂不支持下载」，不产生下载任务。
7. 收藏 / 历史 `globalId` 为 `age:{id}`。
8. 远程配置在真机通过前不得出现 AGE。

---

## 10. 合规与安全

- README 与仓库规范：第三方 VOD 上架前须完成授权与平台合规。AGE 是社区订阅源，**大陆真机验收通过前不进入生产远程配置**。
- 不提交密钥。cryptograph 与 resolver 前缀来自详情接口，不是客户端密钥。
- 不执行远程 JS。
- 不放行 HTTP 明文 API。resolver 与最终播放地址仍须 HTTPS。
- 内容过滤开关对 AGE 同样生效（按 `category` / 标题黑名单）。动漫站误伤风险较低，但仍走统一策略。

---

## 11. 请确认

修订后的第一期即 §6.1 十二条 + §6.4 三点闭合。请确认：

1. **范围**：AGE Dart Adapter + 通用 Resolver 补丁（格式收紧、`Vurl`、HEAD→Range GET、终态 Header）。不为 AGE 另起页面。
2. **健康检测**：源管理改 `fetchPage(page: 1)`；18888 不通必须失败。
3. **下载**：第一期 AGE **禁用**并明确文案，不做半套、不做重启恢复。
4. **默认线**：§7.2 固定优先级，不靠 JSON 键序。
5. **本地 priority 放现有源末尾**；远程配置等大陆真机通过后再发。
6. **`id`**：`age`（不用 Syncnext UUID）。
7. **开工前置三点**按 §6.4 闭合，不再视为开放问题。

---

## 12. 最终判断

这份方案大约 **80% 已成熟**。对当前 Jive，首期最合适的路线是：

> **AGE + Dart Adapter + 通用 Resolver 补丁**

- 浏览链路复用现有多源页面，产品不裂。
- 起播差异用「收紧推断 + Vurl + HEAD fallback + 终态 Header」消化，并用回归锁住 Mac CMS 直链 `.m3u8`。
- 健康检测、下载、远程发布从文档上堵掉三个坑：探活假成功、半套下载脏任务、未真机就全量开关。

**确认第 11 节之前不改业务代码。** 确认后按 §8 开工。

后续不在第一期（历史规划，第二期范围见 §14）：

| 期 | 内容 | 前置 |
| --- | --- | --- |
| 二 | AGE 下载走同一套 resolver + Header，验收重启恢复 | 在线播放稳定 |
| 二′ | 18888 不通则厂长 / 网关；或多线路 UI、播放失败自动换线 | 真机结论 |
| 三 | DDYS JS 运行时或出海欧乐 | 运行时 / 网关决策 |
| — | MDD；MacCMS XML | 有配置需求再做 |

---

## 14. 第二期：通用 Syncnext 插件运行时

用户继续适配官方源表后，本分支增加 `adapterType: syncnext_plugin`。AGE 仍走 `age_v2` Dart Adapter，不改用 JS。

### 14.1 源清单

| 名称 | 处理 | 说明 |
| --- | --- | --- |
| 埋堆堆 `Syncnext://MDD` | **不做** | 闭源原生频道，无公开 JS / HTTP 契约 |
| 新 AGE | 已有 `age_v2` | 不重复走插件运行时 |
| 低调影视 DDYS | `syncnext_plugin` | `$vision` 识别未实现；验证闸道可能失败 |
| 新欧乐 | `olevod_v1` Dart Adapter | JSON + `_vv` 签名直链 HLS；官方阻挡中国地区 |
| 新厂长 | `syncnext_plugin` | 要求大陆 IP；WAF / AES 由官方 `app.js` 处理 |
| YouKnowTV | `syncnext_plugin` | HTML |
| libvio | `syncnext_plugin` | 部分网盘资源无法直播放 |
| 韩剧网 | `syncnext_plugin` | 需海外 IP |
| 独播库 | `syncnext_plugin` | HTML |

不导入整表 `sourcesv3.json`；不支持用户粘贴 `syncnextPlugin://`。远程 `vod_sources.json` 仍不发布，本地配置验收。

### 14.2 运行时

- `flutter_js`：iOS / macOS JavaScriptCore，Android QuickJS。
- 加载 `pluginConfigUri`（必须 HTTPS）及同目录 `files[]`，按数组顺序 `evaluate`。
- 注入 `$http.fetch` / `$http.head`（Dart `http` + 简易 cookie）、`$next.toMedias|toSearchMedias|toEpisodes|toEpisodesCandidates|toPlayer|toPlayerByJSON|toPlayerCandidates|emptyView`。
- `$vision.recognizeText` 与阿里云盘 API 回 `unsupported` / emptyView。
- 只允许 HTTPS 请求；播放 `Player()` 在点播时由 `EpisodePlaybackResolver` 调用，不在详情页预解析全部剧集。
- 下载对 `syncnext_plugin` 与 `age_v2` 一样禁用。

### 14.3 配置字段

```json
{
  "id": "dbku",
  "name": "独播库",
  "baseUri": "https://www.dbku.tv",
  "adapterType": "syncnext_plugin",
  "pluginConfigUri": "https://raw.githubusercontent.com/qoli/syncnextPlugin/main/plugin_dbku/config.json",
  "search": true,
  "enabled": true,
  "priority": 38,
  "notification": "dbku.tv 线上看"
}
```

`baseUri` 仍是站点 HTTPS host（`isLoadable`）；`pluginConfigUri` 是插件 `config.json`。缺少 HTTPS 插件配置的条目不会进源列表。

插件脚本从 GitHub raw 拉取，大陆网络可能失败，表现为源检测 / 列表加载失败，不是 Mac CMS 回归。

---

## 13. 参考：AGE 请求与解析

```text
GET https://ageapi.omwjhz.com:18888/v2/catalog?...&page=1&size=32
GET https://ageapi.omwjhz.com:18888/v2/search?page=1&query={keyword}
GET https://ageapi.omwjhz.com:18888/v2/detail/{id}

resolver = player_jx.zj + cryptograph
GET resolver
  HTML 含: var Vurl = 'https://….m3u8';
```

catalog 条目关键字段：`id, name, cover, uptodate, status, type, intro`。  
详情关键字段：`video.playlists`、`player_jx`、`player_vip`、`player_label_arr`。  
不新增 Dart 包；HTTP 与 `crypto`（若签名类源后续再用）均已在工程中。
