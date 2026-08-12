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

## 运行

```bash
flutter pub get
flutter run
```

Android 调试包输出：`build/app/outputs/flutter-apk/app-debug.apk`。

实现与验证状态见 `doc/IMPLEMENTATION_STATUS.md`。

> 第三方 VOD 内容和播放源在正式发布前必须完成授权与平台合规确认。
