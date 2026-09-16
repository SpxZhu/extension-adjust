-- Public, platform-neutral API. Native implementation is private to this module.
local M = {}
local native = rawget(_G, "adjust_native")
local system = sys.get_sys_info().system_name
local platform = ({ Android = "android", ["iPhone OS"] = "ios" })[system]
local mobile = platform ~= nil
local configured_tokens = {}

local function unsupported(name)
    print("[Adjust] " .. name .. ": unsupported on " .. tostring(system))
    return false, "unsupported_platform"
end

local function string_value(value, name, optional)
    if optional and value == nil then return end
    assert(type(value) == "string" and #value > 0, name .. " must be a non-empty string")
end

local function token(value, name, length)
    string_value(value, name)
    assert(#value == length and value:match("^%w+$"), name .. " must contain " .. length .. " letters/digits")
end

local function number_value(value, name)
    assert(type(value) == "number" and value == value and value >= 0 and value < math.huge,
        name .. " must be a finite non-negative number")
end

local function parameters(value)
    if value == nil then return nil end
    assert(type(value) == "table", "parameters must be a table")
    local result = {}
    for k, v in pairs(value) do
        string_value(k, "parameter key")
        local kind = type(v)
        assert(kind == "string" or kind == "number" or kind == "boolean", "parameter values must be scalar")
        if kind == "number" then assert(v == v and math.abs(v) < math.huge, "parameter must be finite") end
        result[k] = tostring(v)
    end
    return next(result) and result or nil
end

local function copy(value)
    local result = {}
    for k, v in pairs(value or {}) do result[k] = v end
    return result
end

local function perform(name, build)
    if not mobile then return unsupported(name) end
    if not native then return false, "native_extension_missing" end
    local ok, payload = pcall(build)
    if not ok then return false, tostring(payload) end
    local encoded, data = pcall(json.encode, payload)
    if not encoded then return false, tostring(data) end
    return native.execute(name, data)
end

function M.is_supported()
    return mobile and native ~= nil
end

function M.is_initialized()
    if not mobile then unsupported("is_initialized"); return false end
    return native ~= nil and native.is_initialized()
end

function M.set_callback(callback)
    if not mobile then return unsupported("set_callback") end
    if not native then return false, "native_extension_missing" end
    if callback ~= nil and type(callback) ~= "function" then return false, "callback must be a function or nil" end
    native.set_callback(callback)
    return true
end

-- Loading a config module has no side effects. Environment is always explicit.
function M.initialize(config)
    local selected_tokens
    local ok, err = perform("initialize", function()
        assert(type(config) == "table", "config must be a table")
        local selected = config[platform]
        assert(type(selected) == "table", "config." .. platform .. " is required")
        token(selected.app_token, "app_token", 12)
        assert(config.environment == "sandbox" or config.environment == "production", "environment must be sandbox or production")
        local level = config.log_level or "info"
        assert(({verbose=true, debug=true, info=true, warn=true, error=true, assert=true, suppress=true})[level], "invalid log_level")
        local result = { app_token = selected.app_token, environment = config.environment, log_level = level }
        -- Platform options override common runtime options, without modifying config.
        local options = copy(config.options)
        for k, v in pairs(selected.options or {}) do options[k] = v end
        local boolean_options = { "idfa_reading", "ad_services", "google_ad_id_reading", "cost_data_in_attribution" }
        for _, key in ipairs(boolean_options) do
            if options[key] ~= nil then
                assert(type(options[key]) == "boolean", key .. " must be boolean")
                result[key] = options[key]
            end
        end
        if options.att_consent_waiting_interval ~= nil then
            local n = options.att_consent_waiting_interval
            number_value(n, "att_consent_waiting_interval")
            assert(n <= 360 and n % 1 == 0, "ATT wait must be an integer from 0 to 360 seconds")
            result.att_consent_waiting_interval = n
        end
        if options.event_deduplication_ids_max_size ~= nil then
            local n = options.event_deduplication_ids_max_size
            number_value(n, "event_deduplication_ids_max_size")
            assert(n >= 1 and n <= 2147483647 and n % 1 == 0, "deduplication capacity must be a positive integer")
            result.event_deduplication_ids_max_size = n
        end
        result.callback_parameters = parameters(config.callback_parameters)
        result.partner_parameters = parameters(config.partner_parameters)
        selected_tokens = copy(selected.event_tokens)
        for name, value in pairs(selected_tokens) do token(value, "event_tokens." .. tostring(name), 6) end
        return result
    end)
    if ok then configured_tokens = selected_tokens end
    return ok, err
end

local function event_payload(event_token, event)
    token(event_token, "event_token", 6)
    event = event or {}
    assert(type(event) == "table", "event must be a table")
    local result = { event_token = event_token }
    if event.revenue ~= nil or event.currency ~= nil then
        number_value(event.revenue, "revenue")
        assert(type(event.currency) == "string" and event.currency:match("^[A-Z][A-Z][A-Z]$"), "currency must be a three-letter uppercase code")
        result.revenue, result.currency = event.revenue, event.currency
    end
    for _, key in ipairs({ "product_id", "transaction_id", "purchase_token", "deduplication_id", "callback_id" }) do
        string_value(event[key], key, true)
        result[key] = event[key]
    end
    result.callback_parameters = parameters(event.callback_parameters)
    result.partner_parameters = parameters(event.partner_parameters)
    return result
end

function M.track_event(event_token, event)
    return perform("track_event", function() return event_payload(event_token, event) end)
end

function M.track_named_event(name, event)
    return M.track_event(configured_tokens[name], event)
end

function M.track_ad_revenue(ad)
    return perform("track_ad_revenue", function()
        assert(type(ad) == "table", "ad must be a table")
        string_value(ad.source, "source")
        number_value(ad.revenue, "revenue")
        assert(type(ad.currency) == "string" and ad.currency:match("^[A-Z][A-Z][A-Z]$"), "currency must be a three-letter uppercase code")
        local result = {source=ad.source, revenue=ad.revenue, currency=ad.currency}
        for _, key in ipairs({"network", "unit", "placement"}) do
            string_value(ad[key], key, true)
            result[key] = ad[key]
        end
        if ad.impressions ~= nil then
            number_value(ad.impressions, "impressions")
            assert(ad.impressions % 1 == 0 and ad.impressions <= 2147483647, "impressions must be an integer")
            result.impressions = ad.impressions
        end
        result.callback_parameters = parameters(ad.callback_parameters)
        result.partner_parameters = parameters(ad.partner_parameters)
        return result
    end)
end

-- Queries are asynchronous: data arrives through set_callback(self, event, data).
function M.get_adid()
    if not mobile then unsupported("get_adid"); return nil end
    return perform("get_adid", function() return {} end)
end

function M.get_attribution()
    if not mobile then unsupported("get_attribution"); return nil end
    return perform("get_attribution", function() return {} end)
end

function M.request_tracking_authorization()
    if platform ~= "ios" then return unsupported("request_tracking_authorization") end
    return perform("request_tracking_authorization", function() return {} end)
end

function M.set_global_callback_parameters(values)
    return perform("set_global_callback_parameters", function() return {parameters=parameters(values)} end)
end

function M.set_global_partner_parameters(values)
    return perform("set_global_partner_parameters", function() return {parameters=parameters(values)} end)
end

return M
