# 播放全链路：从点击到出画面的十步流水线

状态：持续生效（基于 v1.1.0+5）
相关文档：[CACHE_DOWNLOAD_FLOWS.md](CACHE_DOWNLOAD_FLOWS.md)、[USER_FLOWS.md](USER_FLOWS.md)、[../archive/cache/边播边下与广告过滤技术解析.md](../archive/cache/边播边下与广告过滤技术解析.md)

## 1. 全链路总览

入口：`detail_page.dart` `_play()` push `PlayerPage` → `player_page.dart` `_setup()`。总耗时路径如下（每步的失败回退见第 2 节）：

```text
┌─────────────────────────────────────────────────────────────────────┐
│ ① 选线   selectionFor：playbackLines 评分 m3u8 > mp4 > /play/，      │
│          identity 匹配优先于 name/id；绑定请求头 → PlaybackStatus.preparing │
├─────────────────────────────────────────────────────────────────────┤
│ ② 缓存优先 PlaybackSession.prepare：offlineOnly 只找完整离线缓存；    │
│          否则按 ContentKey 查已有缓存 → 命中则用 proxy_manifest      │
│          重建会话（cachePlayback，跳过 ③④⑤）                         │
├─────────────────────────────────────────────────────────────────────┤
│ ③ URL 解析 playback_url_resolver.dart：已知名式直接过；未知格式       │
│          抓播放页(≤128KB) → 正则抽脚本变量/url/src/video 候选        │
│          → HTTPS 限定 → m3u8>mp4>mpd 评分 → HEAD + 512B Range        │
│          探测真实格式与重定向终 URL；结果缓存 10 分钟                 │
│          失败 → 按线路顺序静默换线重试（无显式换线 UI）               │
├─────────────────────────────────────────────────────────────────────┤
│ ④ 格式嗅探兜底 content_type_sniffer.dart：非 HLS 且格式 unknown 时    │
│          HEAD Content-Type → Range 文件头魔数确认（TTL 10 分钟）      │
├─────────────────────────────────────────────────────────────────────┤
│ ⑤ HLS 解析+广告过滤 hls_parser.dart + ad_filter.dart：                │
│          master 最多一层变体 → 不支持标签/加密(SAMPLE-AES/DRM)/      │
│          直播流 → directFallback 直连回退                            │
│          可播清单 → AdFilter v3 删广告分片 → TimelineMapping          │
│          (过滤前后时间轴映射) + AdFilterReport                        │
├─────────────────────────────────────────────────────────────────────┤
│ ⑥ 缓存接入 cache_manager：ContentKey(sourceId+videoId+线路+剧集      │
│          identity 哈希) + 清单 SHA256 指纹 → upsertEntry、保存       │
│          timeline/proxy_manifest/source_manifest → CacheRef          │
│          → ResourceFetcher（边播边写缓存）                            │
├─────────────────────────────────────────────────────────────────────┤
│ ⑦ 本地代理 local_proxy.dart：随机 token + HlsParser.buildProxyPlan   │
│          改写分片为代理 URL → 注册 ProxySessionRoute                 │
│          → 播放器拿 proxyManifestUrl（仅监听 127.0.0.1）             │
│          无缓存管理器时 = proxyWithoutCaching                         │
├─────────────────────────────────────────────────────────────────────┤
│ ⑧ 起播 VideoPlayerController.networkUrl(代理或直连地址, formatHint)   │
│          initialize 超时 20s → 失败关会话换直连地址重试一次           │
├─────────────────────────────────────────────────────────────────────┤
│ ⑨ 续播/跳片头 用 TimelineMapping 把历史进度换算到过滤后时间轴，       │
│          按 SkipPolicy(按影片持久化，≤200 条)自动 seek 过片头        │
├─────────────────────────────────────────────────────────────────────┤
│ ⑩ 预取与收尾 SegmentPrefetcher 按时间开窗( Wi-Fi 领先 300s /          │
│          蜂窝 120s / 可关，并发 5，指数退避)；播放中 updatePosition   │
│          重锚定；close() 停预取→等在途读(≤2s)→注销路由→释放          │
│          CacheRef→flush 索引；TTL=onExit 时立即删本条目               │
└─────────────────────────────────────────────────────────────────────┘
```

## 2. 播放模式与降级

`playback_status.dart` 定义五种模式，UI 上表现为播放器内一枚彩色状态圆点（`playback_status_indicator.dart`，长按弹详情底栏含降级原因与广告过滤报告）：

| PlaybackMode | 含义 | 状态圆点 |
| --- | --- | --- |
| preparing | 解析/准备中 | 灰 |
| streamingAndCaching | 边下边播 | 绿 |
| cachePlayback | 命中缓存直接播放 | 蓝 |
| proxyWithoutCaching | 走本地代理但不写缓存 | 橙 |
| direct | 直连（HLS 不可缓存或非 HLS） | 白 |

降级原因（`PlaybackFallbackReason`）举例：稳定 identity 缺失、格式不支持、代理控制器初始化失败（`proxyControllerInitializationFailed`）等，每种都有中文文案。

关键回退路径汇总：

```text
URL 解析失败 ──► 按线路顺序换线重试
HLS 不可缓存(加密/直播/不支持标签) ──► directFallback 直连
代理起播失败(20s 超时/初始化失败) ──► 关会话换直连地址重试一次
offlineOnly 但缓存不完整 ──► 报错「请重新下载」，不回退在线
```

## 3. 播放页交互盘点（player_page.dart + player/widgets/）

### 3.1 手势矩阵（PlayerGestureLayer）

| 手势 | 行为 | 反馈 |
| --- | --- | --- |
| 单击 | 切换控制条显隐 | — |
| 双击 | 播放/暂停 | — |
| 横向拖动 | 快进/快退（滑屏 seek） | 预览浮层（目标时间） |
| 长按右半屏 | 临时 2 倍速，松手恢复 | 缓冲不足自动回退，8s 缓冲充足后自动重试 |
| 纵向拖左半屏 | 亮度 | PlayerGestureIndicator 浮层 |
| 纵向拖右半屏 | 音量 | PlayerGestureIndicator 浮层 |

seek 管线：暂停 → seek → 校验落点（可重试一次）→ 恢复播放 → 保存进度 → 预取重锚定；拖动期间用 `playback_seek_clock.dart` 冻结时长尺（防广告分片扰乱 PTS）。

### 3.2 控制条按钮清单（player_controls_bar.dart）

进度条（`PlaybackScrubber`，含缓冲区段合并绘制）、播放/暂停、上一集/下一集、音量（弹 `PlayerVolumeSlider`，长按静音）、播放状态圆点（长按详情）、下载当前集（仅 HLS，自动剔除广告分片）、倍速菜单（PopupMenuButton）、选集菜单（当前线路剧集列表，当前集高亮）、铺满切换（cover 裁剪）、全屏切换。另有：屏幕锁（`PlayerScreenLockButton`，全屏左侧中部，锁定后仅可单击唤出解锁钮）、暂停时中央大播放键、缓冲菊花。

### 3.3 TV 遥控器按键映射（`_handleRemoteKeyEvent`）

| 按键 | 行为 |
| --- | --- |
| OK | 控制条未显示时唤出；已显示时播放/暂停 |
| 左 / 右 | ±10s |
| 上 / 下 | 唤出 / 收起控制条 |
| 返回 | 先收控制条，再退出播放 |
| 菜单键 | 打开选集菜单 |

### 3.4 自动化行为

- **自动连播**：播完自动下一集；片尾按 `SkipPolicy.shouldSkipOutro` 提前跳集。
- **进度保存**：每 15s 定时 + 进后台暂停时保存。
- **后台行为**：进后台暂停并保存，回前台恢复；播放中 WakeLock 心跳（10s）。
- **页面形态**：竖屏窗口模式（AppBar + 16:9 播放面 + `PlayerInfoPanel`：跳过设置/简介/选集）；全屏或设备横屏进入沉浸模式（`PlayerTopBar` 顶栏、锁横屏（竖屏视频除外）、`SystemUiMode.immersiveSticky`，手机退出时锁回竖屏）。
- 失败/初始化中在 16:9 区域内展示 `PlayerErrorView`（错误文案 +「重新获取并重试」）。

## 4. 改版观察（供规划参考）

1. **线路切换无显式 UI**：解析失败时按 `playbackLines` 顺序静默换线，用户无感知也无手动选线路入口；对坏线路站点用户无法自救。
2. **状态语义靠一枚圆点**：边下边播/缓存/直连的差别对用户几乎不可见（长按才有详情）；若做下载/流量展示，这层信息值得显性化。
3. **倍速入口仅菜单**：无快捷循环切换，长按 2x 是隐藏手势，可发现性低。
4. **跳过片头设置按影片持久化**（≤200 条），剧集整部共享一份设置，但入口在详情页与竖屏信息面板两处。
5. **广告过滤报告已有数据**（AdFilterReport），目前只在长按状态圆点的底栏露出，可考虑作为「已过滤 N 段广告」的轻提示。
6. **20s 起播超时 + 一次直连重试**已覆盖主要失败面，但失败文案与换线静默重试之间没有进度提示，用户看到的是长时间「准备中」。
