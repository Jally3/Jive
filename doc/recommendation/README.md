# 「猜你喜欢」客户端开发交接

> 交接状态：后端 V1 已部署，客户端已接入 NDJSON 流式推荐、增量 VOD 匹配与 done 提交/失败回滚，待生产环境真机联调。
>
> 生产地址：`https://hey-rickytse.com`

## 客户端必读

请按以下顺序阅读：

1. [`CLIENT_RECOMMENDATION_DEVELOPMENT_REQUIREMENTS.md`](CLIENT_RECOMMENDATION_DEVELOPMENT_REQUIREMENTS.md)：客户端范围、状态机、VOD 匹配、异常恢复和验收清单。
2. [`CLIENT_RECOMMENDATION_API.md`](CLIENT_RECOMMENDATION_API.md)：可直接用于联调的 HTTP 接口与数据模型。
3. [`LLM_RECOMMENDATION_BACKEND_REQUIREMENTS.md`](LLM_RECOMMENDATION_BACKEND_REQUIREMENTS.md)：跨端完整需求和服务端约束，客户端只需重点阅读第 3、4、12～15、18 节。

机器可读契约以 Jive-Backend 仓库的 [`docs/openapi.yaml`](../../../Jive-Backend/docs/openapi.yaml) 为准。客户端交付或冻结版本时，应同时记录对应的后端 Git commit，避免接口快照漂移。

## 文档职责

| 文档 | 用途 | 是否作为生产实现依据 |
| --- | --- | --- |
| `CLIENT_RECOMMENDATION_DEVELOPMENT_REQUIREMENTS.md` | 客户端需求与验收 | 是 |
| `CLIENT_RECOMMENDATION_API.md` | 推荐接口联调契约 | 是 |
| 后端 `docs/openapi.yaml` | 字段、类型、枚举的机器契约 | 是，优先级最高 |
| `LLM_RECOMMENDATION_BACKEND_REQUIREMENTS.md` | 跨端设计背景、容量和服务端保护 | 是，发生冲突时以 OpenAPI 和已部署行为为准 |
| `ARK_DIRECT_SETUP.md` | 旧方舟直连的本地验证说明 | 否；不得进入生产包 |

## 交付给客户端团队的最小文档包

- 本目录下的 `README.md`、客户端开发需求和客户端接口文档。
- 后端仓库的 `docs/openapi.yaml`，并附后端版本或 commit。
- 测试环境/生产环境 Base URL；当前生产环境为 `https://hey-rickytse.com`。
- 不提供 `ARK_API_KEY`、`ARK_MODEL` 或方舟 Base URL。生产客户端只连接 Jive 后端。

## 当前实现提醒

生产推荐链路使用 Jive 后端。普通首页 Feed 或底部 Tab 切换只隐藏推荐视图并暂停新的 VOD 匹配调度，NDJSON 流继续接收；切回后恢复匹配。VOD 来源变化只取消旧来源搜索，保留候选、Session 和 Cursor，并按原顺序在新来源重新匹配；未提交的续页会先回滚。刷新、协议失败或页面销毁才取消当前推荐流，且只有收到 `done` 后才提交 Session/Cursor、写缓存和上报推荐事件。方舟直连仅保留为本地历史调试路径，不得进入生产配置。
