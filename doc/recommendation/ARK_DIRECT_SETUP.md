# 方舟客户端直连验证（已停止作为生产方案）

> 状态：历史过渡方案，仅供本地 Debug/Profile 排障。客户端生产开发请从 [`README.md`](README.md) 开始。

这是「猜你喜欢」的客户端直连开发验证入口，仅用于本地 Debug/Profile 验证，不得作为公开 Release 的生产链路。客户端读取本地观看历史与内容库，调用方舟生成候选片名，再在当前 VOD 源逐项严格匹配；TMDB 不参与本链路。

## 启动

Token Plan 使用 OpenAI 兼容地址和模型别名：

```text
ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/coding/v3
ARK_MODEL=ark-code-latest
```

将密钥放在仓库外或已被 Git 忽略的本地文件中，例如 `secrets/ark.local.json`：

```json
{
  "ENABLE_DIRECT_LLM_RECOMMENDATION": true,
  "ARK_API_KEY": "替换为 Token Plan API Key",
  "ARK_BASE_URL": "https://ark.cn-beijing.volces.com/api/coding/v3",
  "ARK_MODEL": "ark-code-latest"
}
```

然后运行：

```bash
flutter run --dart-define-from-file=secrets/ark.local.json
```

不要改成 `https://ark.cn-beijing.volces.com/api/v3`；该地址不是截图中的 Token Plan 数据面，可能产生套餐外按量费用。

## 当前验证范围

- Tab 在配置已启用、密钥非空且当前源支持搜索时出现，不限制构建模式。
- 发送最多 20 条有效观看记录和 10 条内容库记录；忽略低于 5% 且未完播的播放。
- 模型最多保留 24 个候选，VOD 搜索并发 3、单候选最多 2 个关键词、单次最多 30 个搜索请求，最终展示最多 12 部。
- 推荐缓存 30 分钟；请求失败可使用同一偏好画像 24 小时内的旧缓存。
- 下拉刷新会跳过推荐缓存并重新调用模型。
- 请求失败会在 `flutter run` 终端输出 `[Jive][ArkRecommendation]` 前缀，同时以 `jive.ark_recommendation` 名称写入 DevTools 日志；内容包括阶段、耗时、HTTP 状态、request-id 和响应字节数，不会输出 API Key、用户偏好载荷或完整响应体。

## 安全边界

`--dart-define` 不会让密钥真正保密，密钥仍可能从 APK/IPA 或运行内存中提取。当前实现即使技术上能够生成 Release，也不得公开分发带生产方舟密钥的安装包。正式生产必须迁移到服务端推荐接口；具体匿名主体、限流、预算、Cursor 和审计契约以 [`LLM_RECOMMENDATION_BACKEND_REQUIREMENTS.md`](LLM_RECOMMENDATION_BACKEND_REQUIREMENTS.md) 为准。
