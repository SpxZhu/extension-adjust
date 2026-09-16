-- Optional business helpers. No dependency on a game framework.
local adjust = require "extension-adjust.adjust"
local M = {}
local common = {}
local storage_path
local last_day = ""
local transform_revenue
local sign_revenue

local function copy(values)
    local result = {}
    for k, v in pairs(values or {}) do result[k] = v end
    return result
end

local function merged(values)
    local result = copy(common)
    for k, v in pairs(values or {}) do result[k] = v end
    return result
end

function M.initialize(config)
    if not adjust.is_supported() then return adjust.initialize(config) end
    if type(config) ~= "table" then return false, "config must be a table" end
    local business = config.business or {}
    if type(business) ~= "table" then return false, "business must be a table" end
    if business.transform_ad_revenue ~= nil and type(business.transform_ad_revenue) ~= "function" then
        return false, "transform_ad_revenue must be a function"
    end
    if business.sign_ad_revenue ~= nil and type(business.sign_ad_revenue) ~= "function" then
        return false, "sign_ad_revenue must be a function"
    end
    local ok, err = adjust.initialize(config)
    if not ok then return ok, err end
    local platform = sys.get_sys_info().system_name == "Android" and "android" or "ios"
    storage_path = sys.get_save_file("adjust_" .. config[platform].app_token, "daily_activated")
    local loaded, state = pcall(sys.load, storage_path)
    last_day = loaded and type(state) == "table" and type(state.day) == "string" and state.day or ""
    transform_revenue = business.transform_ad_revenue
    sign_revenue = business.sign_ad_revenue
    return true
end

-- Replaces the entire business parameter set, so logout can clear old identity.
function M.set_common_parameters(values)
    if not adjust.is_supported() then
        print("[Adjust] set_common_parameters: unsupported platform")
        return false, "unsupported_platform"
    end
    if values ~= nil and type(values) ~= "table" then return false, "parameters must be a table" end
    local result = {}
    for k, v in pairs(values or {}) do
        local kind = type(v)
        if type(k) ~= "string" or k == "" or (kind ~= "string" and kind ~= "number" and kind ~= "boolean") then
            return false, "parameters must have string keys and scalar values"
        end
        if kind == "number" and (v ~= v or math.abs(v) == math.huge) then return false, "parameter must be finite" end
        result[k] = v
    end
    common = result
    return true
end

function M.track_sevent(name, values)
    if not adjust.is_supported() then return adjust.track_named_event("sevent") end
    if type(name) ~= "string" or name == "" then return false, "event name is required" end
    if values ~= nil and type(values) ~= "table" then return false, "parameters must be a table" end
    local params = merged(values)
    params.sevent = name
    return adjust.track_named_event("sevent", {callback_parameters=params})
end

function M.daily_activated()
    if not adjust.is_supported() then return adjust.track_named_event("sevent") end
    if not storage_path then return false, "not_initialized" end
    local day = os.date("%Y-%m-%d")
    if day <= last_day then return false, "already_reported" end
    local ok, err = M.track_sevent("dailyActivated")
    if not ok then return false, err end
    last_day = day
    local saved, result = pcall(sys.save, storage_path, {day=day})
    if not saved or result == false then
        print("[Adjust] dailyActivated accepted, but its date could not be saved")
        return true, "daily_state_not_persisted"
    end
    return true
end

function M.ad_not_ready(guid, ad_type)
    return M.track_sevent("adNotReady", {guid=guid, adType=ad_type})
end

function M.track_purchase(purchase)
    if not adjust.is_supported() then return adjust.track_named_event("purchase") end
    if type(purchase) ~= "table" then return false, "purchase must be a table" end
    if purchase.callback_parameters ~= nil and type(purchase.callback_parameters) ~= "table" then
        return false, "callback_parameters must be a table"
    end
    local event = copy(purchase)
    event.currency = event.currency or "USD"
    event.callback_parameters = merged(purchase.callback_parameters)
    -- Distinct store fields: never copy an iOS transaction ID into a Play token.
    if purchase.transaction_id then event.callback_parameters.transactionId = purchase.transaction_id end
    return adjust.track_named_event("purchase", event)
end

function M.track_max_ad_revenue(ad)
    if not adjust.is_supported() then return adjust.track_ad_revenue() end
    if type(ad) ~= "table" then return false, "ad must be a table" end
    if ad.callback_parameters ~= nil and type(ad.callback_parameters) ~= "table" then return false, "callback_parameters must be a table" end
    if ad.partner_parameters ~= nil and type(ad.partner_parameters) ~= "table" then return false, "partner_parameters must be a table" end
    local data = copy(ad)
    data.source = "applovin_max_sdk"
    data.currency = data.currency or "USD"
    data.callback_parameters = merged(ad.callback_parameters)
    data.partner_parameters = copy(ad.partner_parameters)
    if transform_revenue then
        local ok, result = pcall(transform_revenue, data.revenue, data)
        if not ok then return false, "transform_ad_revenue: " .. tostring(result) end
        data.revenue = result
    end
    if sign_revenue then
        local ok, signature = pcall(sign_revenue, data)
        if not ok then return false, "sign_ad_revenue: " .. tostring(signature) end
        if type(signature) ~= "string" or signature == "" then return false, "sign_ad_revenue must return a non-empty string" end
        data.callback_parameters.usig = signature
    end
    return adjust.track_ad_revenue(data)
end

return M
