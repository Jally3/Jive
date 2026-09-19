# 缓存体系与下载任务生命周期

状态：持续生效（基于 v1.1.0+5）
相关文档：[PLAYBACK_PIPELINE.md](PLAYBACK_PIPELINE.md)、[../archive/cache/CACHE_MANAGEMENT_PLAN.md](../archive/cache/CACHE_MANAGEMENT_PLAN.md)（权威总纲）、[../archive/cache/DOWNLOAD_REQUIREMENTS_AND_TEST_PLAN.md](../archive/cache/DOWNLOAD_REQUIREMENTS_AND_TEST_PLAN.md)

## 1. 体系关系：边下边播与离线下载共用一套磁盘缓存

```text
                    ┌────────────────────────────┐
 在线播放链路 ──────►│  ResourceFetcher（边播边写） │
 (PLAYBACK_PIPELINE) │                            │
                    │   CacheManager 配额/引用/租约 │
                    │   CacheIndex  磁盘索引       │
                    │   CacheTtlPolicy 过期清理    │────► <AppSupport>/jive_cache/
                    │                            │        index.json
 离线下载链路 ──────►│  DownloadTaskManager        │        entries/<hash>/
 (显式下载)          │  (构建在缓存之上，逐资源     │          state.json
                    │   下载 + finalizeEntry 验收) │          resources/ (ts/m4s/mp4/key…)
                    └────────────────────────────┘          source_manifest.m3u8
                                                            proxy_manifest.m3u8
 播放器 ◄── LocalProxyServer(127.0.0.1) ◄── CacheRef 读缓存 / 回源     timeline.json
                                                        download_tasks.json
```

- 同一部剧「边下边播到一半」的缓存，可以被显式下载任务续用，反之亦然；入口都是同一个 `CacheManager`（`cache_manager.dart`）。
- 播放缓存根目录为 `getApplicationSupportDirectory()/jive_cache`（从临时目录迁移过，避开 Android 临时缓存配额清理）。

## 2. 缓存体系（lib/data/cache/）

### 2.1 配额

```text
安全余量 safety = 总容量 × 5%（钳制在 2GB–10GB）        # cache_manager.dart
播放缓存配额   = 磁盘可用空间 + 当前已占用 − safety
```

- 磁盘信息经 `DiskSpaceProvider`；平台通道 `jive/cache`（`platform_disk_space.dart`）提供 totalCapacity/available/platformCacheLimit。
- 写入需 `WriteLease`（写租约，不足时触发扩容判断/清理）；并发访问经 `single_flight.dart` 合并。
- `initialize`：过期清扫 `evictExpired` + 孤儿目录清扫 + 刷索引。

### 2.2 磁盘布局（cache_index.dart）

| 内容 | 说明 |
| --- | --- |
| `index.json` | 总索引（条目元信息） |
| `entries/<hash>/state.json` | 单条目状态 |
| `entries/<hash>/resources/` | 分片资源，资源 ID 为 `sha256:…`，扩展名白名单（ts/m4s/mp4/key/…） |
| `entries/<hash>/source_manifest.m3u8` | 源清单（原始） |
| `entries/<hash>/proxy_manifest.m3u8` | 代理改写后清单（重放会话用） |
| `entries/<hash>/timeline.json` | 广告过滤前后时间轴映射 |
| `download_tasks.json` | 下载任务持久化 |

条目身份：`ContentKeyBuilder`（sourceId + videoId + 线路 identity + 剧集 identity 的哈希，`content_key.dart`）+ 清单 SHA256 指纹——源站换清单即视为不同内容。

### 2.3 TTL 自动清理（cache_ttl_policy.dart）

| 选项 | 行为 |
| --- | --- |
| never | 不自动清理 |
| onExit | 退出播放器时立即删本条目（兜底 1 天，覆盖进程被杀/中途切集） |
| hours1 / hours5 / days1 / days3 / days7 | 按最后访问时间过期清扫 |

存储 key `cache_ttl_option`（含旧值迁移）。管理页（CacheManagementPage）可看统计、单删条目（播放中的条目拒绝删除并 toast）、清空全部播放缓存。

## 3. 下载任务生命周期（download_task_manager.dart）

### 3.1 状态机

```text
            enqueue(仅 HLS + identity 稳定的选择；先经 URL 解析)
                │
                ▼
             queued ──► downloading ──► completed(经 finalizeEntry 验收
                │            │ ▲           offlinePlayable)
                │            │ │            │
                │            ▼ │            ▼
                │          paused ◄──── 对账不一致(cacheWriteFailed)
                │            │
                ├────────────┼──────► failed(带失败原因)
                │            └──────► cancelled
                ▼
  启动恢复：读 download_tasks.json，与缓存索引对账
    ├─ 条目完整 ────► 标记 completed
    ├─ 不一致 ──────► paused + cacheWriteFailed
    └─ 无记录 ──────► 保持原状态等待用户重试
```

- 管线：解析 → HlsParser + AdFilter（与在线播放同一套，广告分片不下载）→ 逐资源下载 → `finalizeEntry` 验收完整性。
- 任务按片分组展示（DownloadManagementPage），下载中的组自动展开可折叠；单任务操作：暂停/恢复/重试/取消；编辑模式支持全选批量暂停/删除。
- 失败原因枚举（`DownloadFailureReason`）涵盖：选区无效、配额不足、网络不可用/蜂窝受限、完整性校验失败、缓存写入失败等，映射到任务卡上的中文文案。

### 3.2 网络策略（download_network_policy.dart）

```text
download_allow_cellular（默认 false，仅 Wi-Fi）
    ├─ Wi-Fi / 有线 ────────► allowed，正常下载
    ├─ 蜂窝 + 未允许开关 ───► cellularBlocked（任务显示受限，可手动开启开关）
    └─ 无网络 ──────────────► unavailable
```

App 进后台 → `pauseForBackground()`；回前台 → `resumeFromForeground()`（`app.dart` `_DownloadLifecycle`）。

## 4. 离线进度与播放

- 离线集进度：`offline_episode_progress_v1`，上限 100 条（`offline_progress_repository.dart`），与在线历史分开存。
- 离线续播：`resume_watch.dart` 优先找完整离线缓存，`offlineOnly` 模式下缓存不完整直接报「请重新下载」（见 PLAYBACK_PIPELINE 第 2 节）。
- 点下载管理里「已完成」任务 → `PlayerPage(offlineOnly: true)`，全程不走网络。

## 5. 改版观察（供规划参考）

1. **下载准入仅限 HLS**：mp4/未知格式无法下载（`enqueue` 直接拒绝），详情页下载入口对这类内容不可解释（无提示原因）。
2. **配额无用户可见设置**：2–10GB 自动钳制，用户既看不到当前配额，也不能手动调；管理页只有「用量摘要」。
3. **paused + cacheWriteFailed 的对账恢复**依赖启动时对账，播放中途写缓存失败的条目要等下次启动才修正状态。
4. **下载与播放缓存共享配额**：离线内容可能被 TTL 清理波及（依赖 TTL 选项），「已下载内容被自动清理」是潜在的用户惊吓点——TTL 清理与离线完成条目的关系值得在改版中显式化。
5. **蜂窝受限状态可感知**（任务卡显示受限），但无法单任务「本次允许蜂窝」，粒度只有全局开关。
