# Lua API

```lua
local adjust = require "extension-adjust.adjust"
local attribution = require "extension-adjust.attribution"
```

`adjust_native` 是内部桥接模块，业务代码不要直接调用。

## 通用接口

| 方法 | 说明 |
|---|---|
| `adjust.initialize(config)` | 使用 Lua 配置初始化；每进程一次；重复请求返回 already_initialized_or_initializing |
| `adjust.is_supported()` | 当前是移动平台且已装入桥接模块 |
| `adjust.is_initialized()` | SDK 本地初始化已完成 |
| `adjust.set_callback(fn_or_nil)` | 注册／替换／清除全局回调；须从有效的 Defold script/gui_script 上下文调用 |
| `adjust.track_event(token, event)` | 使用 Adjust event token 上报 |
| `adjust.track_named_event(name, event)` | 使用已选平台 event_tokens 映射 |
| `adjust.track_ad_revenue(ad)` | 通用来源广告收入上报 |
| `adjust.get_adid()` | 异步查询，结果事件 adid |
| `adjust.get_attribution()` | 异步查询，结果事件 attribution |
| `adjust.request_tracking_authorization()` | iOS ATT 请求，可在 SDK 初始化前调用；其它平台不执行 |
| `adjust.set_global_callback_parameters(values)` | 完整替换 SDK 公共 callback 参数；nil / 空表清空 |
| `adjust.set_global_partner_parameters(values)` | 完整替换 SDK 公共 partner 参数；nil / 空表清空 |

事件 `event` 是可选 table：

| 字段 | 类型及说明 |
|---|---|
| revenue / currency | 金额为有限非负数；币种为大写三字母；必须一起给出 |
| callback_parameters / partner_parameters | string 键、scalar 值；统一转换为字符串 |
| callback_id | 对应事件成功／失败回调中的 callback_id |
| product_id | 商店商品 ID |
| transaction_id | iOS setTransactionId / Android setOrderId |
| purchase_token | 仅 Android setPurchaseToken；iOS 不使用 |
| deduplication_id | 独立的 SDK 去重 ID；不从交易 ID 自动推导 |

`ad` table 必填 `source`、`revenue`、`currency`；可选 `network`、`unit`、`placement`、
`impressions`（非负整数）、`callback_parameters` 和 `partner_parameters`。
可选字符串没有值时传 nil，不能传空字符串。负收入（例如 MAX 尚无有效收入）会返回校验错误。

## 回调

签名为 `function(self, event, data)`。数据字段未知时省略；不要假设归因一定有 network 或 campaign。
所有回调在 Defold update 线程执行。当前只保留一个回调；替换或清除回调会丢弃已排队的旧事件。
回调内可以安全调用 `set_callback(nil)` 或替换自身。在脚本 `final` 中清除回调。
没有回调时不累积历史事件；重新注册后可以主动查询 ID／归因。
队列上限 256，超过会记录警告并丢弃新回调数据；不影响 SDK 的网络队列。

| 事件 | data |
|---|---|
| initialized | platform, sdk_version；只表示本地初始化 |
| initialization_failed | operation, message；允许修正后重试初始化 |
| attribution_changed / attribution | tracker_token, tracker_name, network, campaign, adgroup, creative, click_label, cost_type, cost_amount, cost_currency |
| adid | adid；首次归因尚未完成时查询可能延后返回 |
| event_success | adid, message, timestamp, event_token, callback_id, json_response |
| event_failure | 上述字段及 will_retry |
| session_success | adid, message, timestamp, json_response |
| session_failure | 上述字段及 will_retry |
| tracking_authorization | status（Apple ATT 状态码） |
| error | operation, message；原生参数处理或 SDK 调用异常 |

Lua `true` 返回值不代表后台成功。没有广告收入成功回调；需从 SDK 日志和 Adjust 后台验证。
不支持的平台没有这些回调，查询立即返回 nil。

## 可选业务辅助层

| 方法 | 行为 |
|---|---|
| `attribution.initialize(config)` | 初始化通用层并载入每日活跃状态、收入处理函数 |
| `attribution.set_common_parameters(values)` | 完整替换业务公共字段，nil / 空表用于登出清理 |
| `attribution.track_sevent(name, values)` | 使用 sevent token；将 name 写入 callback parameter sevent |
| `attribution.daily_activated()` | 本地日历日期递增时发送 dailyActivated，接受调用后持久化 |
| `attribution.ad_not_ready(guid, ad_type)` | sevent=adNotReady，附 guid、adType |
| `attribution.track_purchase(purchase)` | 使用 purchase token，默认 USD，附业务公共字段 |
| `attribution.track_max_ad_revenue(ad)` | 固定 source=applovin_max_sdk，默认 USD，附业务公共字段和可选 usig |

业务参数只附在业务事件／收入上，不自动附在 SDK session 上。优先级为 SDK 全局值、业务公共值、
单次事件值；`sevent` 始终使用方法传入的名称。静态全局参数在初始化配置里设置。

每日活跃按设备本地日期、当前 app token 持久化；同日、时间回拨时不重复。
这是本地接受调用去重，不承诺服务端 exactly-once：卸载／清数据会重置；设备日期或时区变化会影响日界线。
原生拒绝调用不会推进日期。磁盘保存失败时保持本进程内去重，并返回 `true, "daily_state_not_persisted"`。
游戏需自行在登录／恢复等合适节点调用该方法；扩展不订阅游戏生命周期。

自定义业务字段、归因缓存、收入转换和签名由游戏通过参数、归因回调与收入处理函数提供。
扩展不内置签名密钥，也不自动进行收入去重或累计。
