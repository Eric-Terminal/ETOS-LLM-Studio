# 原生 MVU 运行时设计

## 目标

ETOS 原生 MVU 运行时负责变量初始化、消息版本继承、命令执行、结构调和和持久化。酒馆助手脚本只通过兼容 API 访问数据，不再由远程 MagVarUpdate 包持有变量真值。

该设计同时用于 iOS 和 watchOS，不设平台功能降级。

## 数据真值

每个消息版本保存一份完整 MVU 数据：

- `stat_data`：当前变量真值。
- `schema`：原生推导结构或角色脚本导出的 JSON Schema。
- `display_data`：更新前快照，其中发生变化的路径替换为变化描述。
- `delta_data`：仅记录本轮变化路径和变化描述。
- `initialized_lorebooks`：已经加载过 `[initvar]` 的世界书与条目标识。

消息版本键由消息 UUID 和 swipe 索引共同组成。重 Roll、切换版本和删除消息时，变量与对应版本同步切换或清理。

## 初始化顺序

1. 读取绑定角色的初始变量。
2. 读取已绑定世界书中名称包含 `[initvar]` 的条目；条目即使处于禁用状态也参与初始化，因为酒馆使用禁用条目避免它进入普通提示词。
3. 如果当前开场白包含 `<initvar>`，以开场白内容替代角色主世界书的 `[initvar]`。
4. 合并附加世界书 `[initvar]`；开场白已有值优先。
5. 解析角色和用户宏，生成标准 MVU 数据及原生 schema。
6. 将结果写入聊天作用域和当前开场白版本。
7. 执行开场白中剩余的 JSON Patch 或 lodash 命令。

解析失败不会写入半截数据，原因记录到开发日志。

## 更新管线

1. 新消息版本优先继承上一条包含 `stat_data` 的有效消息；没有有效消息时继承聊天初始数据。
2. 兼容旧版把变量直接写在消息根节点的快照，并在首次更新时迁移到 `stat_data`。
3. 按原文位置解析 `<JSONPatch>`、`<JSON_Patch>` 和 lodash 风格命令。
4. 支持 `replace`、`delta`、`insert/add`、`remove`、`move`，以及 `set`、`add`、`insert/assign`、`delete/remove/unset`、`move`。
5. `/-` 表示数组尾部；ValueWithDescription `[值, 描述]` 只更新第一个元素。
6. 使用 schema 调和类型、默认值、枚举和数值范围。
7. 生成 `display_data`、`delta_data` 和逐路径变化记录。
8. 原子保存当前消息版本，并广播 MVU 生命周期事件。

没有变量命令的回复仍保存继承后的完整快照，保证任意楼层都可独立读取当前状态。

## 酒馆助手兼容层

- 角色脚本以 ES Module 运行，支持静态 `import` / `export`。
- MagVarUpdate 导入由加载器拦截，改用 ETOS 内置 `window.Mvu`。
- `Mvu` 对齐当前公开 API，并保留旧初始化事件拼写作为兼容别名。
- 变量结构脚本可使用 Zod 4.3.6；`registerVariableSchema` 将可表示部分写成 JSON Schema供原生引擎同步校验。
- Zod 的 transform 等无法完整表示为 JSON Schema 的规则，会在原生更新事件后由角色脚本再次执行并写回修正值。

## 边界

原生 MVU 不接管酒馆扩展设置面板、酒馆页面 DOM 或 MagVarUpdate 自身的配置 UI。它只实现角色游玩需要的数据协议、命令语义、事件和脚本接口。
