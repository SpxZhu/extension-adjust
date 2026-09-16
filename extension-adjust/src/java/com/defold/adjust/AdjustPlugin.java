package com.defold.adjust;

import android.app.Activity;
import android.util.Log;
import com.adjust.sdk.*;
import org.json.JSONObject;
import org.json.JSONException;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.Locale;

public final class AdjustPlugin {
    private final Activity activity;
    private volatile boolean active = true;
    private boolean initialized;

    public AdjustPlugin(Activity activity) { this.activity = activity; }
    private static native void nativeOnEvent(String event, byte[] json);

    private void emit(String name, JSONObject data) {
        if (active) nativeOnEvent(name, data.toString().getBytes(StandardCharsets.UTF_8));
    }

    private static JSONObject object(Object... pairs) {
        JSONObject json = new JSONObject();
        try {
            for (int i = 0; i < pairs.length; i += 2) {
                if (pairs[i + 1] != null) json.put((String)pairs[i], pairs[i + 1]);
            }
        } catch (JSONException e) { Log.e("Adjust", "Invalid callback data", e); }
        return json;
    }

    private static JSONObject attribution(AdjustAttribution a) {
        if (a == null) return new JSONObject();
        return object("tracker_token", a.trackerToken, "tracker_name", a.trackerName,
            "network", a.network, "campaign", a.campaign, "adgroup", a.adgroup,
            "creative", a.creative, "click_label", a.clickLabel,
            "cost_type", a.costType, "cost_amount", a.costAmount, "cost_currency", a.costCurrency);
    }

    private interface ParameterSink { void add(String key, String value); }
    private static void parameters(JSONObject p, ParameterSink sink) throws JSONException {
        if (p == null) return;
        Iterator<String> keys = p.keys();
        while (keys.hasNext()) { String key = keys.next(); sink.add(key, p.getString(key)); }
    }

    private void initialize(JSONObject p) throws JSONException {
        if (initialized) throw new IllegalStateException("SDK already initialized");
        AdjustConfig config = new AdjustConfig(activity.getApplicationContext(),
            p.getString("app_token"), p.getString("environment"), true);
        if (!config.isValid()) throw new IllegalArgumentException("Invalid Adjust config");
        config.setLogLevel(LogLevel.valueOf(p.getString("log_level").toUpperCase(Locale.ROOT)));
        if (!p.optBoolean("google_ad_id_reading", true)) config.disableGoogleAdIdReading();
        if (p.optBoolean("cost_data_in_attribution", false)) config.enableCostDataInAttribution();
        if (p.has("event_deduplication_ids_max_size")) config.setEventDeduplicationIdsMaxSize(p.getInt("event_deduplication_ids_max_size"));
        config.setOnAttributionChangedListener(a -> emit("attribution_changed", attribution(a)));
        config.setOnEventTrackingSucceededListener(e -> emit("event_success", object(
            "adid", e.adid, "message", e.message, "timestamp", e.timestamp,
            "event_token", e.eventToken, "callback_id", e.callbackId, "json_response", e.jsonResponse)));
        config.setOnEventTrackingFailedListener(e -> emit("event_failure", object(
            "adid", e.adid, "message", e.message, "timestamp", e.timestamp,
            "event_token", e.eventToken, "callback_id", e.callbackId,
            "will_retry", e.willRetry, "json_response", e.jsonResponse)));
        config.setOnSessionTrackingSucceededListener(e -> emit("session_success", object(
            "adid", e.adid, "message", e.message, "timestamp", e.timestamp, "json_response", e.jsonResponse)));
        config.setOnSessionTrackingFailedListener(e -> emit("session_failure", object(
            "adid", e.adid, "message", e.message, "timestamp", e.timestamp,
            "will_retry", e.willRetry, "json_response", e.jsonResponse)));
        // Global values must be queued before init so the first session includes them.
        parameters(p.optJSONObject("callback_parameters"), Adjust::addGlobalCallbackParameter);
        parameters(p.optJSONObject("partner_parameters"), Adjust::addGlobalPartnerParameter);
        Adjust.initSdk(config);
        // SDK 5.8.0's SystemLifecycleContentProvider handles Activity resume/pause.
        initialized = true;
        emit("initialized", object("platform", "android", "sdk_version", "5.8.0"));
    }

    private void trackEvent(JSONObject p) throws JSONException {
        AdjustEvent event = new AdjustEvent(p.getString("event_token"));
        if (p.has("revenue")) event.setRevenue(p.getDouble("revenue"), p.getString("currency"));
        if (p.has("product_id")) event.setProductId(p.getString("product_id"));
        if (p.has("purchase_token")) event.setPurchaseToken(p.getString("purchase_token"));
        if (p.has("transaction_id")) event.setOrderId(p.getString("transaction_id"));
        if (p.has("deduplication_id")) event.setDeduplicationId(p.getString("deduplication_id"));
        if (p.has("callback_id")) event.setCallbackId(p.getString("callback_id"));
        parameters(p.optJSONObject("callback_parameters"), event::addCallbackParameter);
        parameters(p.optJSONObject("partner_parameters"), event::addPartnerParameter);
        if (!event.isValid()) throw new IllegalArgumentException("Invalid Adjust event");
        Adjust.trackEvent(event);
    }

    private void trackAdRevenue(JSONObject p) throws JSONException {
        AdjustAdRevenue ad = new AdjustAdRevenue(p.getString("source"));
        ad.setRevenue(p.getDouble("revenue"), p.getString("currency"));
        if (p.has("network")) ad.setAdRevenueNetwork(p.getString("network"));
        if (p.has("unit")) ad.setAdRevenueUnit(p.getString("unit"));
        if (p.has("placement")) ad.setAdRevenuePlacement(p.getString("placement"));
        if (p.has("impressions")) ad.setAdImpressionsCount(p.getInt("impressions"));
        parameters(p.optJSONObject("callback_parameters"), ad::addCallbackParameter);
        parameters(p.optJSONObject("partner_parameters"), ad::addPartnerParameter);
        if (!ad.isValid()) throw new IllegalArgumentException("Invalid ad revenue");
        Adjust.trackAdRevenue(ad);
    }

    public void execute(final String command, final byte[] bytes) {
        activity.runOnUiThread(() -> {
            if (!active) return;
            try {
                JSONObject p = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
                if (command.equals("initialize")) { initialize(p); return; }
                if (!initialized) throw new IllegalStateException("SDK is not initialized");
                switch (command) {
                    case "track_event": trackEvent(p); break;
                    case "track_ad_revenue": trackAdRevenue(p); break;
                    case "get_adid": Adjust.getAdid(adid -> emit("adid", object("adid", adid))); break;
                    case "get_attribution": Adjust.getAttribution(a -> emit("attribution", attribution(a))); break;
                    case "set_global_callback_parameters":
                        Adjust.removeGlobalCallbackParameters();
                        parameters(p.optJSONObject("parameters"), Adjust::addGlobalCallbackParameter);
                        break;
                    case "set_global_partner_parameters":
                        Adjust.removeGlobalPartnerParameters();
                        parameters(p.optJSONObject("parameters"), Adjust::addGlobalPartnerParameter);
                        break;
                    default: throw new IllegalArgumentException("Unknown command: " + command);
                }
            } catch (Exception e) {
                Log.e("Adjust", "Command failed: " + command, e);
                emit(command.equals("initialize") ? "initialization_failed" : "error",
                    object("operation", command, "message", e.getMessage()));
            }
        });
    }

    public void destroy() { active = false; }
}
