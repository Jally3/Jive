# 缓存自动过期清理（TTL）—— 方案设计

> 目标：长期未访问的缓存视频自动清理，避免缓存只增不减、长期占用磁盘。
>
> 状态：**待评审**。确认后实施。

---

## 1. 现状

- 唯一的自动清理是配额驱动的 LRU 淘汰：写新片段且空间不足时触发，按 `lastAccess` 先 partial 后 complete。
- 无时间维度的清理：磁盘充裕时缓存永久保留。
- 已有基础设施可直接复用：`lastAccessMs` 字段、启动 reconcile 扫描、引用保护（`_refs`）、deleting 流程、淘汰粒度（revision 目录）。

## 2. 核心语义

**过期判据：`lastAccessMs`，不是 `createdAtMs`。**
"超过 N 天没看过"比"缓存了 N 天"更符合直觉——常看的内容永续保鲜，躺着的缓存到期清理。与现有 LRU 语义同源。

- 粒度：revision（与淘汰/删除一致）。
- 保护：活跃引用（播放中/下载中）条目跳过，与现有淘汰一致。
- 过期清理产物走与 LRU 淘汰相同的目录删除 + 索引更新路径，并计入脱敏指标（次数、释放字节）。

## 3. 触发时机（三层）

| 时机 | 说明 |
|---|---|
| 启动 reconcile 后 | 主路径。每次冷启动扫一遍，清理已过期条目。成本已摊在现有扫描里 |
| 配额淘汰前 | 写预留空间不足时，先清过期条目，再走现有 partial→complete LRU——过期内容永远是最优候选 |
| 播放会话期间定时 | 长会话不重启也要生效。与 P2「配额周期刷新」合并为同一定时器（如每 30 分钟），一次遍历同时刷新配额 + 清过期 |

不做后台/进程终止后的清理（与 MVP 前台策略一致）；条目过期但 App 一直不开，留着也无害。

## 4. 用户配置

「我的」页新增「自动清理缓存」项（与"预加载"设置同款交互）：

- 档位：**关闭 / 1 天 / 3 天 / 5 天 / 7 天 / 30 天**，默认 **3 天**。（已评审确认）
- 存 SharedPreferences，经 provider 注入 `CacheManager`（核心层保持平台无关，只接收 `maxAge` 参数）。
- 修改档位后下一次触发时机生效，不立即大扫除（避免误操作瞬间清空）。

## 5. 显式下载豁免（已评审确认：豁免）

边播边下缓存和显式下载共用存储，通过**来源标记**区分：

- `state.json` / `index.json` 条目新增可选布尔字段 `downloadOrigin`（缺省 `false`，旧记录无此字段按 `false` 读取，向后兼容，不升 schemaVersion）。
- `DownloadTaskManager` 创建/启动剧集下载任务时将对应条目标记为 `downloadOrigin = true`；条目一旦置位不再自动清除。
- TTL 清理跳过 `downloadOrigin == true` 的条目；LRU 配额淘汰**不豁免**（空间真不够时仍按现有规则淘汰，豁免只针对时间过期）。
- 下载任务被用户删除时条目整体删除，标记随条目消失。

## 6. 实施步骤

1. `cache_index.dart`：`RevisionState` / `CacheEntry` 增加可选 `downloadOrigin` 字段，JSON 读写缺省 false；确认严格校验对该可选字段放行。
2. `CacheManager`：
   - `markDownloadOrigin(entryKey)`（持久化到 state 并更新索引）；
   - `evictExpired({required Duration maxAge, DateTime? now})`：筛选 `lastAccess < now - maxAge`、无引用、非 deleting、非 downloadOrigin 的条目，复用淘汰删除路径；返回清理统计。
3. `DownloadTaskManager` 启动/创建剧集下载任务时调用 `markDownloadOrigin`。
4. 接入触发点：`initialize()`（reconcile + 反向清扫之后）、`reserve()` 淘汰前（先清过期再 LRU）。长会话定时器与 P2 配额刷新合并，本期不做。
5. 设置项：SharedPreferences + provider + 「我的」页入口（关闭/1/3/5/7/30 天，默认 3 天）。
6. 脱敏指标：过期清理次数、释放字节。
7. 测试：
   - 过期/未过期/恰好在边界的条目筛选（注入 fake 时钟）；
   - downloadOrigin 条目豁免、LRU 配额淘汰不豁免；
   - 活跃引用条目跳过；
   - "关闭"档位不清理；
   - downloadOrigin 缺省字段的旧 state.json 兼容读取；
   - 启动集成：initialize 后过期条目消失、索引一致；
   - reserve 路径先清过期再 LRU 的顺序。

## 7. 验收标准

- `flutter analyze` / `flutter test` 全通过。
- 默认 3 天档位下，构造 4 天未访问的条目，冷启动后被清理且缓存管理页统计正确；downloadOrigin 条目同等条件下保留。
- 播放中的条目即使 lastAccess 过期也不被清理。
- 关闭档位后行为与现状完全一致。
