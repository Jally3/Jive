# Jive

Flutter Android/iOS 视频点播 MVP。无需后端：列表、搜索和详情直连需求文档中的 VOD API；首页始终保留一个 Flutter 官方演示视频，确保核心播放链路可以独立验收。

## 已实现

- 夜幕影院深色主题、首页双列视频卡片和底部四栏导航
- 首页分类入口、下拉刷新和去重分页加载
- VOD 分类、搜索、详情与 `vod_play_url` 剧集解析
- 搜索防抖和旧请求隔离，统一加载、空数据、错误及重试状态
- 详情页简介、状态、更新时间、剧集选择和播放前地址刷新
- HLS/MP4 播放、暂停、进度拖动、全屏、横竖屏和失效地址重试
- 本地保存最近观看、当前剧集和播放进度，支持继续播放
- 封面图片缓存和两分钟详情请求缓存
- 第三方接口不可用时自动回退到官方演示视频
- **多 VOD 源架构**：`VodSourceRegistry` + `VodSourceAdapter`（Mac CMS V10）按源发起请求，源列表从本地 `config/vod_sources.json` 加载（该文件不纳入 git）
- **全局内容源切换**：首页标题区可切换全局浏览源，切换后首页分类与列表重建，新搜索默认使用新源
- **搜索页局部切源**：1 个当前源 + 最多 3 个备用源自动探测，来源标签展示准确数量/估算数量/失败状态，"更多"按需请求
- **详情页局部切源**：默认只请求当前源，点击"检测其他来源"才探测最多 3 个备用源；跨源候选确认后原子切换，保留当前选集
- **资源身份**：`Video` 带 `sourceId`/`sourceVideoId`，`globalId = sourceId:sourceVideoId`；收藏、历史和播放器重试均按源绑定，不同源的相同 `vod_id` 互不冲突
- **多播放线路**：`PlaybackLine` 解析模型保留多条线路，不丢弃后续有效线路

## 运行

```bash
flutter pub get
flutter run
```

Android 调试包输出：`build/app/outputs/flutter-apk/app-debug.apk`。

## VOD 源配置

应用内置的 VOD 源列表放在 `config/vod_sources.json`，该文件已加入 `.gitignore`，不会纳入版本控制。默认情况下仓库自带一份示例配置；如需启用真实源，可参考 `config/vod_sources.json` 的字段格式自行维护：

```json
{
  "sources": [
    {
      "id": "storm",
      "name": "暴风资源",
      "baseUri": "https://bfzyapi.com/api.php/provide/vod",
      "adapterType": "mac_cms_v10",
      "search": true,
      "enabled": true,
      "priority": 1
    }
  ]
}
```

> 仅允许 HTTPS 源；HTTP 源会被标记但需要人工确认授权后使用。

实现与验证状态见 `doc/IMPLEMENTATION_STATUS.md`。

> 第三方 VOD 内容和播放源在正式发布前必须完成授权与平台合规确认。
