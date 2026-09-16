-- Run from the repository root: lua tests/test.lua (Lua 5.1+).
package.path = "./?.lua;" .. package.path
local passed, failed = 0, 0
local function equal(a, b, message)
    assert(a == b, (message or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

local day, saved, calls, reject, save_fails
local function modules(system, has_native)
    day, saved, calls, reject, save_fails = "2026-09-15", {}, {}, nil, false
    _G.sys = {
        get_sys_info = function() return {system_name=system} end,
        get_save_file = function(app, name) return app .. "/" .. name end,
        load = function(path) return saved[path] or {} end,
        save = function(path, data) if save_fails then return false end; saved[path] = data; return true end,
    }
    _G.json = {encode=function(data) return data end}
    _G.adjust_native = has_native and {
        execute = function(command, data)
            if reject then return false, reject end
            calls[#calls + 1] = {command=command, data=data}
            return true
        end,
        is_initialized = function() return #calls > 0 end,
        set_callback = function(callback) calls.callback = callback end,
    } or nil
    package.loaded["extension-adjust.adjust"] = nil
    package.loaded["extension-adjust.attribution"] = nil
    return require("extension-adjust.adjust"), require("extension-adjust.attribution")
end
local function config()
    return {
        environment="sandbox", log_level="debug",
        android={app_token="android12345", event_tokens={sevent="abc123", purchase="pay123"}},
        ios={app_token="ios123456789", event_tokens={sevent="ios123", purchase="buy123"}},
    }
end
local function last() return calls[#calls].data end

for _, platform in ipairs({"HTML5", "Windows", "Darwin", "Linux"}) do
    test(platform .. " all APIs work without native bridge, config, JSON or storage", function()
        local a, b = modules(platform, false)
        _G.json = nil
        sys.load, sys.save, sys.get_save_file = nil, nil, nil
        equal(a.is_supported(), false)
        equal(a.is_initialized(), false)
        equal(a.initialize(), false)
        equal(a.set_callback(function() error("must never be invoked") end), false)
        equal(a.track_event(), false)
        equal(a.track_named_event(), false)
        equal(a.track_ad_revenue(), false)
        equal(a.get_adid(), nil)
        equal(a.get_attribution(), nil)
        equal(a.request_tracking_authorization(), false)
        equal(a.set_global_callback_parameters(), false)
        equal(a.set_global_partner_parameters(), false)
        equal(b.initialize(), false)
        equal(b.set_common_parameters(), false)
        equal(b.track_sevent(), false)
        equal(b.ad_not_ready(), false)
        equal(b.track_purchase(), false)
        equal(b.track_max_ad_revenue(), false)
        equal(b.daily_activated(), false)
        equal(#calls, 0)
    end)
end

test("mobile missing native bridge reports installation error", function()
    local a = modules("Android", false)
    local ok, err = a.initialize(config())
    equal(ok, false); equal(err, "native_extension_missing")
end)

test("platform config selection and explicit environment", function()
    local a = modules("iPhone OS", true)
    local c = config()
    c.options = {idfa_reading=true, cost_data_in_attribution=true}
    c.ios.options = {idfa_reading=false}
    assert(a.initialize(c))
    equal(last().app_token, c.ios.app_token)
    equal(last().idfa_reading, false)
    equal(last().cost_data_in_attribution, true)
    equal(c.options.idfa_reading, true)
    equal(last().environment, "sandbox")
    assert(a.track_named_event("sevent"))
    equal(last().event_token, "ios123")
    c.environment = nil
    equal(a.initialize(c), false)
end)

test("invalid config does not cross native boundary", function()
    local a = modules("Android", true)
    for _, change in ipairs({
        function(c) c.android.app_token="" end,
        function(c) c.android.event_tokens.purchase="wrong" end,
        function(c) c.environment="release" end,
        function(c) c.log_level="invalid" end,
        function(c) c.options={idfa_reading="false"} end,
        function(c) c.options={att_consent_waiting_interval=361} end,
        function(c) c.options={event_deduplication_ids_max_size=0} end,
    }) do local c=config(); change(c); equal(a.initialize(c), false) end
    equal(#calls, 0)
end)

test("production is explicit and independent of build mode", function()
    local a = modules("Android", true)
    local c = config(); c.environment="production"; c.log_level="suppress"
    assert(a.initialize(c)); equal(last().environment, "production"); equal(last().log_level, "suppress")
end)

test("callback parameters preserve Unicode and normalize scalars", function()
    local a = modules("Android", true)
    assert(a.track_event("abc123", {callback_parameters={message="中文 🎮", amount=0.001, enabled=false}}))
    equal(last().callback_parameters.message, "中文 🎮")
    equal(last().callback_parameters.amount, "0.001")
    equal(last().callback_parameters.enabled, "false")
    equal(a.track_event("abc123", {callback_parameters={nested={}}}), false)
end)

test("revenue rejects NaN infinity negative values and invalid currency", function()
    local a = modules("Android", true)
    for _, n in ipairs({-1, math.huge, 0/0}) do
        equal(a.track_event("abc123", {revenue=n, currency="USD"}), false)
        equal(a.track_ad_revenue({source="applovin_max_sdk", revenue=n, currency="USD"}), false)
    end
    equal(a.track_event("abc123", {revenue=1, currency="usd"}), false)
    assert(a.track_event("abc123", {revenue=0, currency="USD"}))
end)

test("purchase store fields and deduplication ID remain distinct", function()
    local a, b = modules("Android", true)
    assert(b.initialize(config()))
    assert(b.track_purchase({revenue=1.99, transaction_id="order", purchase_token="play-token", product_id="sku", deduplication_id="dedup"}))
    equal(last().transaction_id, "order"); equal(last().purchase_token, "play-token")
    equal(last().product_id, "sku"); equal(last().deduplication_id, "dedup")
    equal(last().event_token, "pay123"); equal(last().currency, "USD")
    assert(b.track_purchase({revenue=1, transaction_id="ios-order"}))
    equal(last().purchase_token, nil); equal(last().deduplication_id, nil)
end)

test("global parameter replacement supports clearing", function()
    local a = modules("Android", true)
    assert(a.set_global_callback_parameters({player="old"}))
    assert(a.set_global_callback_parameters({}))
    equal(last().parameters, nil)
end)

test("business identities can be replaced on logout without mutating input", function()
    local a, b = modules("Android", true)
    assert(b.initialize(config()))
    local input = {playerId="one", serverId=1}
    assert(b.set_common_parameters(input))
    input.playerId="changed"
    assert(b.track_sevent("level", {serverId=2, sevent="ignored"}))
    equal(last().callback_parameters.playerId, "one")
    equal(last().callback_parameters.serverId, "2")
    equal(last().callback_parameters.sevent, "level")
    assert(b.set_common_parameters({}))
    assert(b.ad_not_ready("request-1", "rewarded"))
    equal(last().callback_parameters.playerId, nil)
    equal(last().callback_parameters.sevent, "adNotReady")
end)

test("MAX reports each supplied revenue without accumulating or scaling", function()
    local a, b = modules("Android", true)
    assert(b.initialize(config()))
    for _, amount in ipairs({0.001, 0.002, 0.003}) do
        assert(b.track_max_ad_revenue({revenue=amount, network="MAX"}))
        equal(last().revenue, amount); equal(last().source, "applovin_max_sdk")
    end
    equal(#calls, 4)
end)

test("optional revenue transform runs before signing and preserves caller data", function()
    local a, b = modules("Android", true)
    local c=config()
    c.business={
        transform_ad_revenue=function(amount) return amount * 0.5 end,
        sign_ad_revenue=function(ad) equal(ad.revenue, 0.01); return "signature" end,
    }
    assert(b.initialize(c))
    local ad={revenue=0.02, callback_parameters={custom="value"}}
    assert(b.track_max_ad_revenue(ad))
    equal(last().revenue, 0.01); equal(last().callback_parameters.usig, "signature")
    equal(ad.revenue, 0.02); equal(ad.callback_parameters.usig, nil)
    equal(b.track_max_ad_revenue({revenue=1, partner_parameters="bad"}), false)
end)

local original_date = os.date
os.date = function(format) if format == "%Y-%m-%d" then return day end; return original_date(format) end
test("daily activation persists and handles restart and clock rollback", function()
    local a, b=modules("Android", true)
    assert(b.initialize(config()))
    assert(b.daily_activated())
    equal(b.daily_activated(), false)
    day="2026-09-14"; equal(b.daily_activated(), false)
    day="2026-09-16"; assert(b.daily_activated())
    -- Recreate only the business module, retaining simulated persisted state.
    package.loaded["extension-adjust.attribution"]=nil
    b=require "extension-adjust.attribution"
    assert(b.initialize(config()))
    equal(b.daily_activated(), false)
end)

test("rejected daily event is retryable; disk failure still deduplicates in memory", function()
    local a, b=modules("Android", true)
    assert(b.initialize(config()))
    reject="not_initialized"
    equal(b.daily_activated(), false)
    reject=nil; save_fails=true
    local ok, err=b.daily_activated()
    equal(ok, true); equal(err, "daily_state_not_persisted")
    equal(b.daily_activated(), false)
end)
os.date = original_date

test("ATT and queries dispatch without synthesizing callback results", function()
    local a=modules("iPhone OS", true)
    local count=0
    assert(a.set_callback(function() count=count+1 end))
    assert(a.request_tracking_authorization()); equal(calls[#calls].command, "request_tracking_authorization")
    assert(a.get_adid()); equal(calls[#calls].command, "get_adid")
    assert(a.get_attribution()); equal(calls[#calls].command, "get_attribution")
    equal(count, 0)
    assert(a.set_callback(nil)); equal(calls.callback, nil)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
