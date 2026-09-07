# Jive Android APK 新版本提醒需求文档

> 文档状态：一期核心流程已实现，待部署远程清单与真机验收  
> 创建日期：2026-09-06  
> 适用平台：Android 手机、平板、电视  
> 关联文档：[生产热更新技术调研与实施方案](HOT_UPDATE_TECHNICAL_RESEARCH.md)

## 1. 背景

Jive 当前主要通过直接安装 APK 的方式分发。新版本发布后，用户无法从应用内得知版本变化，需要开发者通过外部渠道通知并由用户自行寻找下载地址。

本需求增加轻量的新版本提醒能力：App 在不影响正常启动和播放的前提下检查线上版本信息；存在新版本时弹窗展示更新说明；用户点击后使用系统外部浏览器打开 APK 下载地址。APK 的下载、打开和安装均由用户及系统处理，Jive 不跟踪安装结果。

当前实现状态：

- 已实现：首页首帧后单次后台检查、本地 versionName 比较、HTTPS/JSON 容错、更新弹窗、立即下载外部跳转和打开失败 Toast；
- 待部署：`https://hey-rickytse.com/data/version.json` 及真实 APK 下载地址；
- 待后续实现：12 小时检查间隔、「稍后」跨进程记忆、设置页主动检查和远程埋点。

## 2. 目标

- 新 APK 发布后，已安装旧版本的用户能够在 App 内收到提醒。
- 用户可以通过一次点击进入可信的 HTTPS 下载地址。
- 更新服务不可用时，App 仍能正常启动、浏览和播放。
- Android 手机触屏和电视遥控器都能完成弹窗操作。
- 客户端实现不申请安装应用、文件读写等额外高风险权限。

## 3. 非目标

本期不实现：

- App 内下载 APK、下载进度、断点续传或文件管理；
- 自动或静默安装 APK；
- 监听 APK 是否下载或安装成功；
- 强制更新、阻断首页或阻断播放；
- 增量 APK、差分包、Shorebird Dart Patch；
- iOS 版本更新提醒；
- 用户分群、灰度发布、账号定向发布；
- 后台常驻任务或系统通知栏更新提醒。

## 4. 用户故事

### US-1 发现新版本

作为已安装旧版 Jive 的用户，我希望启动 App 后收到新版本提醒，以便知道有可用更新。

### US-2 查看更新内容

作为用户，我希望在弹窗中看到新版本号和简短更新说明，以便决定是否下载。

### US-3 前往下载

作为用户，我希望点击“立即下载”后由系统浏览器打开 APK 下载地址，以便自行完成后续操作。

### US-4 暂不更新

作为用户，我希望关闭提醒并继续使用当前版本，且本次使用过程中不再被重复打扰。

## 5. 核心流程

```text
App 完成启动并显示首页
  -> 后台判断是否达到检查条件
  -> 请求远程版本清单
  -> 校验响应和 HTTPS 下载地址
  -> 按数字分段比较远端 latestVersionName 与本地 versionName
     -> 没有新版本：静默结束
     -> 请求或解析失败：静默结束并记录诊断日志
     -> 存在新版本：显示更新弹窗
        -> 稍后：关闭弹窗，本次进程不再提示
        -> 立即下载：关闭弹窗，交给外部浏览器打开 apkUrl
           -> 打开成功：流程结束
           -> 无可用浏览器/打开失败：提示“无法打开下载链接”
```

## 6. 功能需求

### FR-1 检查触发

- App 首次进入首页后异步检查，不得在 Splash 或启动 Gate 中等待版本接口。
- 单次 App 进程最多自动弹出一次更新提醒。
- 默认每 12 小时最多发起一次远程检查，间隔应定义为可测试常量。
- 用户可在“我的 → 更多设置”中点击“检查新版本”主动检查；主动检查不受 12 小时间隔限制。
- 自动检查失败时不向用户提示网络错误；主动检查失败时显示轻量 Toast。

### FR-2 当前版本读取

- 从平台 Package Info 获取当前 `versionName`，不读取或比较 `buildNumber`。
- 远端 `latestVersionName` 与本地 `versionName` 均按点分隔的数字版本比较，例如 `1.10.0 > 1.9.9`。
- 缺失的尾部分段按 `0` 处理，例如 `1.0 = 1.0.0`。
- 支持可选 `v` 前缀、`-beta.1` 类预发布标识和 `+5` 构建元数据；构建元数据不参与比较。
- 版本号无法解析时不弹更新提醒。

### FR-3 远程版本清单

- 只允许请求 HTTPS 地址。
- 接口地址为 `https://hey-rickytse.com/data/version.json`。
- 请求超时为 8 秒。
- 仅接受 HTTP 200；其他状态码均视为检查失败。
- 响应体建议不超过 32 KB；超过限制时拒绝解析。
- 未识别字段应忽略，保证接口可向后扩展。

接口响应：

```json
{
  "schemaVersion": 1,
  "platform": "android",
  "latestVersionName": "1.0.14",
  "apkUrl": "https://download.example.com/jive/jive-1.0.14.apk",
  "releaseNotes": [
    "修复部分视频无法播放的问题",
    "优化电视遥控器操作体验"
  ],
  "publishedAt": "2026-09-06T12:00:00+08:00"
}
```

字段规则：

| 字段 | 类型 | 必填 | 规则 |
| --- | --- | --- | --- |
| `schemaVersion` | integer | 是 | 本期仅支持 `1` |
| `platform` | string | 是 | 必须为 `android` |
| `latestVersionName` | string | 是 | 展示用，去除首尾空白后不能为空，最长 32 字符 |
| `apkUrl` | string | 是 | 必须为 HTTPS，host 非空 |
| `releaseNotes` | string[] | 否 | 最多 8 条，每条最多 100 字符；非法项忽略 |
| `publishedAt` | string | 否 | ISO 8601，仅用于诊断和展示扩展，不参与版本判断 |

以下情况视为无效响应并静默降级：

- JSON 不是对象；
- schema 或 platform 不匹配；
- 缺失必填字段；
- `latestVersionName` 不符合数字分段版本格式；
- `apkUrl` 不是 HTTPS；
- `versionName` 为空。

### FR-4 更新弹窗

- 标题：`发现新版本 {versionName}`。
- 正文优先逐行展示 `releaseNotes`；为空时显示“新版本已经发布，是否前往下载？”。
- 操作按钮：`稍后`、`立即下载`。
- `立即下载`为主按钮。
- 弹窗允许通过系统返回键关闭，效果与“稍后”一致。
- 内容过长时正文区域可滚动，按钮始终可操作。
- 每条更新说明按普通文本处理，不解析 HTML、Markdown 或链接。
- 不在播放页、全屏播放或下载确认交互上方主动弹出；自动检查应在首页稳定显示后执行。

### FR-5 打开下载地址

- 点击“立即下载”后使用外部应用模式打开 `apkUrl`，不得在内嵌 WebView 中加载。
- 点击后立即关闭更新弹窗，避免用户返回 App 后看到重复弹窗。
- 能打开链接时不再显示成功提示。
- 无法打开时显示 Toast：`无法打开下载链接，请稍后重试`。
- 不读取下载文件，不申请 `REQUEST_INSTALL_PACKAGES`，不申请存储权限，不唤起系统安装器。

### FR-6 稍后提醒与本地状态

使用 `SharedPreferences` 保存：

| Key | 类型 | 用途 |
| --- | --- | --- |
| `app_update_last_check_at` | ISO 8601 string | 最近一次自动检查完成时间 |
| `app_update_ignored_version_name` | string | 用户最近点击“稍后”的远端版本 |

规则：

- 用户点击“稍后”或返回键关闭时，保存当前远端 `latestVersionName`。
- 自动检查再次拿到相同 `latestVersionName` 时，当天不重复弹窗；次日可再次提醒。
- 主动检查发现相同版本时仍显示弹窗，用户明确要求检查的操作不受忽略状态影响。
- 服务端发布更高 `latestVersionName` 后，不受旧版本忽略记录影响。
- 本地偏好读取或写入失败不能影响更新检查和 App 使用。

### FR-7 主动检查反馈

“更多设置”新增“检查新版本”入口：

- 检查中：入口显示加载状态，防止连续点击发起并发请求。
- 已是最新版：Toast `当前已是最新版本`。
- 发现新版本：显示 FR-4 弹窗。
- 请求失败：Toast `检查更新失败，请稍后重试`。
- 打开下载地址失败：Toast `无法打开下载链接，请稍后重试`。

### FR-8 多端交互

- 手机和平板支持触摸点击。
- Android TV 弹窗打开时默认焦点落在“立即下载”。
- 遥控器方向键可以在“稍后”和“立即下载”之间移动，确认键可触发按钮。
- 弹窗关闭后，焦点应回到打开前的可操作区域。
- 若电视系统没有可处理 HTTPS 的浏览器，按 FR-5 显示失败 Toast。

## 7. 非功能需求

### NFR-1 可用性

- 更新服务器、DNS、TLS、JSON 解析或外部浏览器失败均不得影响首页和播放。
- 自动检查全流程不得出现未捕获异常。
- 同一时刻最多存在一个检查请求和一个更新弹窗。

### NFR-2 性能

- 检查在首页首帧后执行，不与启动关键路径争抢。
- 版本清单保持轻量，不下载 APK 内容用于预检查。
- 不创建后台常驻任务。

### NFR-3 安全

- 版本清单和 APK 地址只允许 HTTPS。
- 客户端不接受接口下发的 HTML、JavaScript 或自定义 Intent URI。
- 日志不得记录 URL query 中可能存在的临时密钥。
- APK 发布服务器应设置正确的 `Content-Type`、TLS 证书和访问控制。
- 推荐后续为版本清单增加数字签名；本期至少由受控域名托管，并限制重定向后的协议仍为 HTTPS。

### NFR-4 可测试性

- 网络客户端、当前版本读取器、时钟和 URL 打开器必须支持依赖注入。
- 版本比较和 JSON 解析为不依赖 Flutter UI 的纯 Dart 逻辑。
- 自动检查间隔使用可覆盖的配置，不在测试中等待真实时间。

### NFR-5 可观测性

在不包含隐私信息的前提下记录：

- `update_check_started`；
- `update_check_no_update`；
- `update_available`，包含本地和远端 versionName；
- `update_prompt_later`；
- `update_download_opened`；
- `update_download_open_failed`；
- `update_check_failed`，只记录归一化错误类型，不记录完整响应体。

若当前项目尚无远程埋点，先保留结构化本地日志接口，不为本需求额外引入统计 SDK。

## 8. UI 文案

| 场景 | 文案 |
| --- | --- |
| 弹窗标题 | `发现新版本 {versionName}` |
| 无更新说明 | `新版本已经发布，是否前往下载？` |
| 次按钮 | `稍后` |
| 主按钮 | `立即下载` |
| 已是最新版 | `当前已是最新版本` |
| 检查失败 | `检查更新失败，请稍后重试` |
| 打开失败 | `无法打开下载链接，请稍后重试` |
| 设置入口 | `检查新版本` |

## 9. 建议代码结构

```text
lib/
├── domain/
│   └── app_update_info.dart          # 版本清单领域模型和版本比较
├── data/
│   └── update/
│       ├── app_update_service.dart   # 请求、解析、当前版本和检查编排
│       └── update_preferences.dart   # 检查时间和忽略版本
└── shared/
    └── app_update_dialog.dart          # 手机/TV 可操作的更新弹窗

test/
├── domain/
│   └── app_update_info_test.dart
├── data/
│   └── update/
│       ├── app_update_service_test.dart
│       └── update_preferences_test.dart
└── shared/
    └── app_update_dialog_test.dart
```

依赖建议：

- `package_info_plus`：读取当前 `versionName`；
- `url_launcher`：外部打开 HTTPS 下载地址；
- 复用现有 `http`、`shared_preferences` 和 `app_toast.dart`。

新增依赖包含平台接入代码，因此实现本需求后需要手动分发一次新的完整 APK；之后只需上传更高版本 APK 并更新远程 JSON，旧客户端即可收到提醒。

实现后新增、移动或删除 Dart 文件时，应同步维护 `doc/codebase/CODEBASE_MAP.md`。

## 10. 验收标准

### AC-1 自动发现新版本

Given 本地 `versionName = 1.0.13`，远端 `latestVersionName = 1.0.14`  
When 用户进入首页且自动检查成功  
Then 显示标题为“发现新版本 1.0.14”的弹窗，并展示更新说明。

### AC-2 无新版本

Given 远端 `latestVersionName` 不高于本地 `versionName`  
When 检查成功  
Then 不显示更新弹窗，App 可正常使用。

### AC-3 前往下载

Given 更新弹窗已显示且 `apkUrl` 合法  
When 用户点击“立即下载”  
Then 弹窗关闭，并由外部应用打开 APK HTTPS 地址。

### AC-4 暂不更新

Given 更新弹窗已显示  
When 用户点击“稍后”或返回  
Then 弹窗关闭，当前进程不再自动提示相同版本。

### AC-5 网络失败降级

Given 版本服务器超时、非 200 或响应非法  
When 自动检查执行  
Then 不显示错误界面，不阻塞首页、搜索、详情和播放。

### AC-6 非 HTTPS 地址

Given 接口返回 HTTP、Intent 或其他非 HTTPS `apkUrl`  
When 客户端解析响应  
Then 拒绝打开，不显示可下载的新版本弹窗，并记录归一化错误。

### AC-7 主动检查

Given 用户进入“更多设置”  
When 点击“检查新版本”  
Then 根据结果显示更新弹窗、“当前已是最新版本”或检查失败 Toast。

### AC-8 TV 遥控器

Given App 运行在 Android TV  
When 更新弹窗显示  
Then 默认焦点和方向键导航可见，确认键能触发“立即下载”。

## 11. 测试清单

- `latestVersionName` 大于、等于、小于本地版本；
- 多位数分段、分段数不同、`v` 前缀、预发布标识、构建元数据和非法版本号；
- schema/platform 不匹配；
- releaseNotes 缺失、为空、超长、包含非字符串项；
- HTTPS、HTTP、空 host、非法 URL；
- 200、404、500、超时、断网、TLS 失败、超大响应；
- 自动检查频率和进程内只弹一次；
- “稍后”记录、次日再提醒、更高版本立即提醒；
- 主动检查绕过频率限制；
- 外部浏览器可用与不可用；
- 手机返回键、屏幕旋转、页面销毁后的异步回调；
- TV 默认焦点、方向键、确认键和关闭后的焦点恢复；
- 检查期间开始播放，确保不在播放器上方突然弹窗；
- `flutter analyze` 和完整 `flutter test` 通过。

## 12. 发布操作

每次发布新 APK：

1. 更新 `pubspec.yaml` 的版本，例如从 `1.0.13+5` 改为 `1.0.14+6`；
2. 使用长期固定的同一签名证书构建 Release APK；
3. 在真实手机和 Android TV 上安装并验证；
4. 上传 APK 到最终 HTTPS 下载地址；
5. 校验下载地址可访问且文件完整；
6. 最后更新远程版本清单，使 `latestVersionName` 高于旧 APK 的 `versionName`；
7. 使用旧版 App 验证弹窗和跳转。

可从 `tool/version.example.json` 复制发布清单，但上传前必须替换示例 APK 域名、版本号和更新说明。

必须先上传并验证 APK，再发布版本清单，避免旧客户端收到尚不可下载的更新。

## 13. 待确认项

- 最终版本清单 URL；
- APK 正式下载域名与目录规则；
- 自动检查间隔是否采用默认 12 小时；
- “稍后”后是否按默认次日再次提醒；
- 是否在设置页展示当前版本号；
- Android TV 是否预装可处理 HTTPS 下载的浏览器。
