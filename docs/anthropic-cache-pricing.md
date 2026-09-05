# Anthropic 缓存计费

核对日期：2026-09-05。依据 [Anthropic Prompt caching 官方文档](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)。

## 协议与价格

- API 默认缓存有效期为 5 分钟，1 小时通过 `cache_control.ttl = "1h"` 显式指定。现有缓存请求选项保持原有行为。
- `usage.cache_creation.ephemeral_5m_input_tokens` 和 `ephemeral_1h_input_tokens` 分别表示两种有效期的创建用量；`cache_creation_input_tokens` 是两者总和，不能再次累加收费。
- 缓存命中使用 `cache_read_input_tokens`，共用一个价格。`input_tokens` 已经排除缓存创建及命中，用独立的 `uncachedInputTokens` 保留这个口径，避免再次扣减命中量。
- 官方标准创建单价分别为基础输入单价的 1.25 倍和 2 倍；应用仍由用户自行填写，适用于自定义提供商的实际价格。

## 配置兼容

是否显示双档由模型最终生效的适配器决定：单模型覆盖优先，否则跟随提供商。iOS 和 watchOS 的基础、阶梯、峰谷价格均支持双档，各档独立继承。

原 `cacheWritePerMillionTokens` 承接默认 5 分钟价格，新增 `cacheWriteOneHourPerMillionTokens`。旧配置无需重填。切换到非 Anthropic 格式后，保留默认档，清除基础、阶梯及峰谷的一小时价格，并删除因此变空的阶梯或时间段。再次切回不会恢复已清除的价格。

未返回时长明细的旧记录或代理响应继续按原单档估算，不推断一小时用量。已知为一小时的用量只使用对应价格；该价格留空时不参与估算，填写零则表示免费。已保存的消息费用快照不因修改适配器而重算。

## 保存与验证

两档用量及非缓存输入量随消息和请求日志的 JSON 保存。聊天数据库迁移 `v18_anthropic_cache_pricing_usage` 为用量事件、按天和按模型汇总添加可空字段；同步日包、流式分片合并及同步指纹包含新增信息。

已补充 ETOSCore 回归用例：普通与流式响应解析、混合时长计费、空值与零价、旧配置解码、阶梯和峰谷继承、提供商及单模型覆盖切换、费用快照序列化、同步合并、SQLite 用量汇总及仪表盘估算。

按项目约定，本次未运行构建或测试。获得测试授权后，运行 AGENTS.md 中指定的 ETOSCore 测试命令；获得构建授权后，运行指定 iOS App 构建（含嵌入的 watch App）。界面复核需检查两端的价格输入、说明卡片、语言切换和适配器切换后的单档展示。
