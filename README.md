# Adjust for Defold

独立的 Defold 原生扩展，封装官方 **Adjust Android / iOS SDK 5.8.0**。
运行时配置使用 Lua 文件。HTML5、Windows、macOS、Linux 使用日志空实现，
可调用相同公开接口，无需有效 token，也不会发送数据或模拟 SDK 成功回调。

首版包含事件、收入、归因、Adjust ID、iOS ATT，以及可选的 Lua 业务辅助层。
不依赖 AppLovin 扩展，不包含游戏工程接入、深度链接或购买验证。

当前为实验阶段：Android / iOS 完整构建和真机收数尚未完成验收。
已执行检查与待验证项目见 [验证记录](docs/validation.md)。

## 接入

将本仓库发布到自己的 Git 仓库并打版本标签后，将标签 ZIP 地址加入
`game.project` 的 Dependencies，然后 Fetch Libraries。
也可以将本仓库的 `extension-adjust/` 文件夹完整复制到游戏根目录。

要求 Defold **1.13.0+**，示例使用 Android API **24+**；iOS Pod 要求 **12.0+**，
实际系统下限还取决于所用 Defold 版本。两端依赖由 Defold 构建服务解析。

1. 将 [`example/adjust_config.lua`](example/adjust_config.lua) 复制到游戏，例如 `config/adjust.lua`。
2. 分别填写 Android、iOS 的 app token 和事件 token。
3. 明确设置 `environment = "sandbox"` 或 `"production"`；不会根据构建模式自动切换。
4. 在脚本中显式注册回调和初始化。`require` 配置文件不会启动 SDK。

```lua
local adjust = require "extension-adjust.adjust"
local attribution = require "extension-adjust.attribution"
local config = require "config.adjust"

local function on_adjust(self, event, data)
    if event == "initialized" then
        -- 本地 SDK 初始化完成；不代表归因或后台收数完成。
        attribution.set_common_parameters({storeId="google_play"})
        attribution.daily_activated()
        adjust.get_adid()
    elseif event == "adid" then
        print("Adjust ID:", data.adid)
    elseif event == "initialization_failed" or event == "error" then
        print(event, data.operation, data.message)
    end
end

function init(self)
    adjust.set_callback(on_adjust)
    local ok, err = attribution.initialize(config)
    if not ok then print("Adjust:", err) end
    -- 非移动平台立即继续游戏流程，不等待 initialized 回调。
end

function final(self)
    adjust.set_callback(nil)
end
```

只需要通用能力时，使用 `adjust.initialize(config)`，无需加载业务模块。
同一进程只初始化一次；两个初始化入口二选一。后续更换脚本只需重新注册回调。

## Lua 配置

```lua
return {
    environment = "sandbox",
    log_level = "debug",
    android = {
        app_token = "YOUR_APP_TOKEN",
        event_tokens = {sevent="EVENT_TOKEN", purchase="PURCHASE_TOKEN"},
    },
    ios = {
        app_token = "YOUR_APP_TOKEN",
        event_tokens = {sevent="EVENT_TOKEN", purchase="PURCHASE_TOKEN"},
        options = {idfa_reading=true, ad_services=true},
    },
    options = {cost_data_in_attribution=false},
    callback_parameters = {},
    partner_parameters = {},
    business = {},
}
```

示意 token 必须替换为后台的真实值：app token 12 位，event token 6 位。
只校验当前平台配置。`event_tokens` 可以省略不用的事件名，不能给已声明的事件填空值。

| 配置 | 行为 |
|---|---|
| `environment` | 必填，`sandbox` / `production` |
| `log_level` | 默认 `info`；支持 verbose/debug/info/warn/error/assert/suppress；SDK 可能限制 sandbox 下 suppress |
| `<platform>.app_token` | 当前平台的 Adjust app token |
| `<platform>.event_tokens` | 事件名称到 token 的映射；业务层使用 sevent、purchase |
| `options` / `<platform>.options` | 平台选项覆盖同名公共选项，读取时不修改原配置 |
| `callback_parameters` / `partner_parameters` | 静态 SDK 公共参数，包含首次 session；键为字符串，值为字符串／有限数值／布尔值 |
| `business.transform_ad_revenue` | 可选 `function(amount, ad) -> amount`，签名前执行 |
| `business.sign_ad_revenue` | 可选 `function(ad) -> string`，结果写入 callback parameter `usig` |

支持的 `options`：

- `idfa_reading`、`ad_services`：iOS，省略时使用 SDK 默认值（开启）。不会自动请求 ATT。
- `google_ad_id_reading`：Android，省略时使用 SDK 默认值（开启）。
- `cost_data_in_attribution`：两端，默认关闭。
- `att_consent_waiting_interval`：iOS，整数 0–360 秒；默认 0。初始化后 SDK 等待 ATT 结果的最长时间，不会主动弹窗。
- `event_deduplication_ids_max_size`：两端，正整数；省略时 SDK 默认保留最近 10 个事件去重 ID。

运行中账号、玩家、服务器等变化使用业务层 `set_common_parameters()`。
环境和 app token 不能通过修改已加载的配置热切换，需重新启动进程。

## 调用与返回值

移动平台操作返回 `true` 表示**已接受本地调用**；校验失败或未初始化时返回 `false, reason`。
SDK 的网络成功／失败通过回调报告，广告收入没有独立成功回调。
在 `initialized` 回调后发送业务事件，便于处理异步初始化失败。

非移动平台操作打印方法名并返回 `false, "unsupported_platform"`；
`is_supported()` / `is_initialized()` 返回 false，`get_adid()` / `get_attribution()` 返回 nil。
不保存每日活跃日期、不执行收入处理函数、不触发用户回调。

完整接口、参数和事件见 [API 文档](docs/api.md)。

## 广告收入与购买

从 MAX 的真实 **RevenuePaid** 回调转发，不能用广告完成／发奖励事件代替。
本扩展不会订阅 MAX，也不会自动重复上报。

```lua
-- data 来自 AppLovin RevenuePaid 回调
attribution.track_max_ad_revenue({
    revenue = data.revenue, currency = "USD",
    network = data.networkName,
    unit = data.adUnitIdentifier,
    placement = data.placement ~= "" and data.placement or nil,
})

attribution.track_purchase({
    revenue = 0.99, currency = "USD", product_id = "coins.small",
    transaction_id = transaction_id, -- App Store 交易 ID / Android order ID
    purchase_token = purchase_token, -- Google Play token；与交易 ID 独立
    deduplication_id = unique_purchase_id,
})
```

不提供收入累计阈值或默认缩放。自定义收入转换和 `usig` 签名由 Lua 处理函数提供。
购买上报不等于购买验证；不将交易 ID 自动复制为 purchase token，也不隐式生成去重 ID。

## ATT 与构建配置

游戏决定初始化和 ATT 请求的时机。先设置回调，再在应用处于前台且没有其它授权弹窗时调用
`adjust.request_tracking_authorization()`；允许在 SDK 初始化之前调用。
回调 `tracking_authorization` 的 `status` 为 Apple 状态值：0 未决定、1 受限制、2 拒绝、3 允许。

ATT 文案必须在打包前配置：

```ini
[adjust]
ios_user_tracking_usage_description = 允许跟踪以帮助衡量广告效果。
```

默认不写入空文案。缺少文案或应用不在前台时，请求返回异步 `error`，避免直接触发系统异常。
SDK 依赖、Android 权限和 iOS plist 使用 manifests；这些打包数据不能由运行时 Lua 改写。

## 数据与日志

移动端显式初始化后，由 Adjust SDK 处理归因与上报；事件、购买、广告收入及传入的
`callback_parameters` / `partner_parameters` 会交给 SDK。广告标识读取选项见上文。
示例会将完整回调数据打印到控制台，其中可能包含 Adjust ID、归因信息和 SDK 响应。
接入真实应用时按需减少日志，并在分享日志前移除标识及业务数据。
仓库示例不包含真实 token；实际应用配置由接入方管理，不应提交到本扩展示例中。
需要保密的服务器签名密钥应保留在服务器端，不应嵌入 Lua 或客户端包。

## 示例与验证

直接用 Defold 打开本仓库的 `game.project`。示例提供初始化、事件、广告收入、购买、查询、ATT 和每日活跃按钮。
示例的模拟事件与金额按钮只在 sandbox 配置下可用；生产环境不会发送这些示例数据。

```sh
lua tests/test.lua
```

[开发与验收说明](DEVELOPMENT.md) 包含原生构建、真机步骤和已知验证边界。
[验证记录](docs/validation.md) 区分本地检查、完整构建与真机收数。

## 参考

- [Defold extension-applovin](https://github.com/defold/extension-applovin)：文件组织与原生回调设计参考。
- [Adjust Android v5.8.0](https://github.com/adjust/android_sdk/tree/v5.8.0)
- [Adjust iOS v5.8.0](https://github.com/adjust/ios_sdk/tree/v5.8.0)

MIT License；第三方 SDK 按各自许可证使用。
