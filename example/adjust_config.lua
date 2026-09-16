-- Copy this module into your game and require it explicitly before initialize().
return {
    environment = "sandbox", -- Explicitly change to "production" for release.
    log_level = "debug",
    android = {
        app_token = "",
        event_tokens = { sevent = "", purchase = "" },
    },
    ios = {
        app_token = "",
        event_tokens = { sevent = "", purchase = "" },
        options = {
            idfa_reading = true,
            ad_services = true,
            -- Optional wait after init; does not display the ATT prompt.
            att_consent_waiting_interval = 0,
        },
    },
    options = {
        cost_data_in_attribution = false,
        event_deduplication_ids_max_size = 10,
    },
    callback_parameters = {}, -- Static SDK parameters, also sent with sessions.
    partner_parameters = {},
    business = {
        -- Optional functions, executed only by the Lua business module.
        -- transform_ad_revenue = function(amount, ad) return amount end,
        -- sign_ad_revenue = function(ad) return your_signature end,
    },
}
