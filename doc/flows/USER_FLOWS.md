# 核心用户流程：浏览、搜索、详情换源、续播、追更、设置

状态：持续生效（基于 v1.1.0+5）
相关文档：[NAVIGATION_MAP.md](NAVIGATION_MAP.md)、[PLAYBACK_PIPELINE.md](PLAYBACK_PIPELINE.md)、[CACHE_DOWNLOAD_FLOWS.md](CACHE_DOWNLOAD_FLOWS.md)

## 1. 内容浏览（首页四种信息流）

首页一个页面骨架承载五种 feed 模式（`home_page.dart`，控制器在 `paged_video_controller.dart` / `recommended_feed_controller.dart` / `curated_feed_controller.dart`）：

| feed 模式 | 名称 | 数据来源 | 网格组件 |
| --- | --- | --- | --- |
| updated | 综合 | 当前 VOD 源分类分页 API | `VideoGrid` |
| recommended | 猜你喜欢 | 后端 LLM 推荐 → VOD 源匹配 | `VideoGrid` |
| popular / newReleases / topRated | 热门 / 新片 / 高分 | TMDB 榜单策展 | `CuratedVideoGrid` |

### 1.1 综合流（分页浏览）

```text
选中根分类 → 默认叶子分类
  │ 拉取第 1 页（经内容过滤：黑名单分类/敏感片名，受长按标题的过滤开关控制）
  ▼
视频网格展示 ◄──────────────────────┐
  │ 滚动接近底部 400px 自动 loadMore │  下拉刷新 = 回到第 1 页
  ▼                                  │
追加下一页 ──────────────────────────┘
```

- 卡片角标「新增 N 集」：与收藏库快照对比剧集数得出（综合流启用）。
- 分类头为 SliverPersistentHeader（毛玻璃吸顶）：feed 主 tab 行 + 根分类 chips + 叶子分类行，右侧「全部频道」宫格入口。

### 1.2 猜你喜欢（推荐流，两阶段）

```text
阶段 1/2  拉取后端 LLM 推荐候选（personalized / coldStart 两模式）
   │
   ▼
阶段 2/2  VOD 匹配：并发搜索池(curated_vod_search_pool.dart)在当前源
          逐个候选检索，严格匹配（标题/别名/年份）后变成可播卡片
   │
   ├─ 匹配成功 ──► 卡片进入网格（流式追加）
   ├─ 匹配中 ────► 槽位显示搜索中角标
   └─ 匹配失败 ──► 不可播槽位 RecommendationUnavailableSection
                    └─ 点槽位弹三选项：取消 / 继续查找 3 个备用源 / 查看搜索结果(跳搜索页)
```

footer 状态件：「阶段 2/2 · VOD 匹配」进度卡、统计摘要行（模型 N 部 / 已搜索 / 可播放）、手动「加载更多推荐」按钮。

### 1.3 TMDB 榜单流（热门/新片/高分）

- 次级 chips 换为 TMDB 范围：全部 / 电影 / 电视剧 / 动漫 / 综艺。
- 卡片为 TMDB 海报 + 状态角标（搜索中 / 不可播）；共享搜索池命中去重。
- footer：统计摘要 +「重试失败项」「继续加载榜单」；不可播区 `CuratedUnavailableSection` 同样弹三选项对话框。
- 不可播槽位「查看搜索结果」与首页跨页搜索通道对接（见 NAVIGATION_MAP 3.1）。

## 2. 搜索流程（多源聚合）

```text
SearchPage（进入即聚焦键盘）
  │ 输入关键词（防抖）→ 保存最近搜索（search_history_v1，去重最近优先 ≤20 条）
  ▼
当前源搜索 ── 结果入 VideoGrid（带「新增 N 集」角标）
  │
  ▼ 来源标签条 _sourceLabelBar
  ├─ 激活源 chip
  ├─ 已查备用源 chip（显示「名称 条数」；失败显示红色状态）
  └─「更多 ▾」→ _MoreSourcesSheet：全部来源列表（未搜索/0 条/N+ 条/请求失败/搜索中）
                   └─「查找全部来源」按钮
                        └─ 来源 >6 个先弹流量确认对话框 → 并发搜索所有源
```

- 空闲态（无关键词）显示最近搜索：InputChip Wrap，单个长按/删除钮删词，标题行「清空」全清。
- reviewCurrentSource 模式（从详情页跳来复核某源）：来源标签条位置显示提示文案。
- 加载 / 错误 / 空态统一用 `AppLoadingView` / `AppErrorView` / `AppEmptyView`；错误态可带「切换来源」次级动作。

## 3. 详情与换源（detail_page.dart，控制器 detail_source_controller.dart）

### 3.1 详情页动作

| 动作 | 交互 | 后续 |
| --- | --- | --- |
| 播放第 N 集 | FilledButton（TV 默认聚焦） | push PlayerPage，携带选中集 + 续播点 |
| 收藏 / 追更 | 支持追更的源弹锚定菜单四项：追更并收藏 / 仅收藏 / 取消追更 / 取消追更并移除 | 写入收藏库（`library_repository.dart`） |
| 下载 | AppBar 下载图标 → 选集 bottom sheet → 确认 | 入队下载管理器（仅 HLS） |
| 换源 | 见 3.2 | 重载详情 |
| 简介展开 | 4 行（平板 8 行）省略 + 展开/收起 | — |
| 选集 | 总数 + 正序/倒序切换；>100 集按 100 集分组手风琴；手机 Wrap chips / 平板等宽网格 | 点集直接播放 |

### 3.2 换源流程

```text
播放来源区（横滚来源 FilterChip，chip 上显示状态：N 集 / 有资源 / 0 / 请求失败…）
  │ 点「查找其他来源」（或「更多 ▾」）
  ▼
逐源并发探测（拿搜索首条严格匹配 → 拉详情）
  │
  ├─ 有候选 ──► 候选列表 bottom sheet（带海报 ListTile）
  │               └─ 选中候选 → 确认对话框 → 换源：以该源的 Video 重载详情页
  ├─ 全部无候选 ─► 空态提示
  └─ 探测中 ────► chip 逐个出结果（N 集 / 有资源 / !）
```

## 4. 续播

```text
入口 A：首页续播条 ContinueWatchingSection（横滑卡片：海报+片名+集数+进度条+关闭）
入口 B：我的 → 最近观看卡片
   │ 点卡片 → resumeWatchRecord（features/player/resume_watch.dart）
   ▼
├─ 该记录有完整离线缓存 ──► 直接用离线文件起播（PlayerPage offlineOnly）
├─ 否则 ─────────────────► push PlayerPage(resumePosition) 走正常解析链路
└─ 已播完（≥95%）───────► 跳下一集起播（无下一集则从头/提示）
```

- 续播条收录规则：电影进度 **<2/3** 才展示（`history_repository.dart` `homeContinueWatchingRecord()`，按分类名启发式区分电影/剧集）；条内「✕」仅本会话隐藏，不删记录。
- 我的页历史卡：右上删除钮 / 长按删除（确认对话框）/ 顶部「清空」。
- 历史存储上限 50 条（`watch_history_v1`），新记录挤掉最旧。

## 5. 收藏与追更（library_repository.dart）

```text
详情页四项菜单 toggle
  ▼
收藏库（content_library_v2，串行队列写入；快照剥离剧集列表）
  ├─ isFavorite   收藏 tab 展示
  └─ isFollowing  追更 tab 展示
  ▼
追更检查 checkForUpdates（30 分钟间隔，单轮最多 50 条，每源并发 3）
  ├─ 触发时机：App 启动后 / 回前台（_DownloadLifecycle）
  ├─ 拉远端详情对比各剧集版本签名(episodeVersionSignature)
  └─ 有新集 → unreadAddedCount + 未读徽标（底栏「我的」红点 / tab 徽标）
```

- 追更 tab：有更新的排前；顶部「N 部内容有更新」提示行 +「全部标为已读」；下拉强制立即检查。
- 卡片角标：「更新至 N 集」/「新增 N 集」。

## 6. 设置流

| 入口 | 设置项 | 交互要点 |
| --- | --- | --- |
| 更多设置-外观 | 主题模式：跟随系统 / 日间 / 夜间 | bottom sheet 选择，`themeModeProvider` 即时生效并持久化 |
| 更多设置-播放 | 预加载（预取）开关 | Wi-Fi 领先 300s / 蜂窝 120s，见 PLAYBACK_PIPELINE |
| 更多设置-下载 | 允许蜂窝网络下载 | 开启前确认对话框；默认仅 Wi-Fi |
| 更多设置-存储 | 自动清理 TTL | 7 档：不自动 / 退出播放时 / 1h / 5h / 1 天 / 3 天 / 7 天；「播放缓存」入口显示用量摘要 |
| 来源管理 | 设默认来源 | 「检测全部」逐源测速（8s 超时）结果持久化；资源站/高清站双 Tab；点击源项即设为默认并 toast |

## 7. 改版观察（供规划参考）

1. **换源路径较长**：详情页换源需「点来源 chip/更多 → 候选 sheet → 确认对话框」两到三步；搜索页备用源发现与详情页换源是两套相似但独立的 UI，可考虑统一。
2. **首页三套 feed 三套 footer/角标逻辑**：综合/推荐/榜单各自有加载态、失败重试、统计摘要实现，改版时是收敛组件的机会。
3. **续播入口分散**：首页续播条、我的历史卡两处直达播放器，绕过详情页；「关闭续播条」只是会话内隐藏，无持久「不再推荐」能力。
4. **历史/搜索词上限固定**（50 条 / 20 条），无分页与搜索。
5. **追更检查固定 30 分钟间隔 + 仅前台触发**，无推送；未读数全靠本地对比。
6. **敏感内容过滤开关藏得深**：长按首页大标题才能发现。
