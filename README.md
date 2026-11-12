# Dify（云吞插件）

把 [Dify](https://dify.ai) 打包成[云吞](https://github.com/geraldpeng6/wonton)插件的仓库：LLM 应用平台，拖拽编排助手、知识库问答。

插件包是根目录的 `docker-compose.yml` 加它引用的文件；通用规则见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)和[开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

## 服务构成

以上游 [`docker/docker-compose.yaml`](https://github.com/langgenius/dify/blob/1.19.0/docker/docker-compose.yaml)（tag `1.19.0`）默认 profile 的服务为基准：`db_postgres`、`redis`、`pgvector`、`api`、`api_websocket`、`worker`、`worker_beat`、`web`、`nginx`、`sandbox`、`ssrf_proxy`、`plugin_daemon` 都在；Agent 应用引擎三件（`agent_backend`、`agent_ssrf_proxy`、`local_sandbox`）没打包——它的启动密钥格式（无填充 base64url、32 字节）和云吞密钥的两种编码（hex、base64）都对不上，装不上就起不来，见 PR「底座的问题」。聊天机器人、Chatflow、工作流、知识库应用不受影响；「Agent」类型的编排（Agent 策略节点、Agent 的 shell 工具）在云吞版暂不可用。上游 compose 里其余的向量库、MySQL、Milvus/Elasticsearch 等可选项不打包，需要外接时在上游支持的环境变量里自行配置。逐项改写对照（上游写法 → 我们的写法 → 原因）见 PR 描述。

## 图标

`icon.svg` 用的是上游的 Dify 标志（`web/public/logo/logo.svg`，1.19.0），白底等比放置。来源、版权、许可全文和商标说明见 [NOTICE](NOTICE)。

## 模型怎么配

Dify 1.x 的模型供应商是插件，装好后在 Dify 里自己添加凭据，插件包里不预置任何 key：

1. 打开 Dify → 头像 → **插件** → **市场**，确认 OpenAI-API-compatible 已装好（第一个注册的管理员会自动装；没有就在市场里手动装）。
2. **设置 → 模型供应商 → OpenAI-API-compatible → 添加模型**：
   - 想用云吞的模型网关：模型类型选 LLM，端点填 `http://models.wonton.internal:8080/v1`，模型名填网关默认模型（详情页里看），API key 向主人要。核心注入给插件的网关凭据只在容器环境变量里，Dify 的凭据存在它自己的数据库里，所以这一步要手填——见仓库 issue 记录的底座问题。
   - 想用别家：端点和 key 按那家服务商的文档填。

没接模型网关时 Dify 照常安装使用，配好供应商后模型才可用。

## 邮件

邀请成员、找回密码的邮件经云吞的发信服务转进收件人的「Wonton」私聊，只能在家庭成员内部收发；发给外部邮箱会失败，应用里照常报错。

## 资源

上游官方文档的最低要求是 2 核 CPU、4GB 内存（[docs.dify.ai 自托管前提](https://docs.dify.ai/en/self-host/deploy-with-docker-compose)），空闲时实测见 PR 验证一节。

## 许可

- 本插件包（compose、适配文件）：MIT，见 [LICENSE](LICENSE)。
- 上游应用 Dify：改过的 Apache-2.0（多租户 SaaS 与移除 LOGO 需商业授权），全文与商标说明见 [NOTICE](NOTICE)。
