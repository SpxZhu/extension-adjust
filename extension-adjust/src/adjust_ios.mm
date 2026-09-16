#if defined(DM_PLATFORM_IOS)
#define DLIB_LOG_DOMAIN "Adjust"
#include "adjust_private.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdjustSdk/Adjust.h>

static void Put(NSMutableDictionary* data, NSString* key, id value)
{
    if (value) data[key] = value;
}

static NSDictionary* AttributionData(ADJAttribution* a)
{
    NSMutableDictionary* data = [NSMutableDictionary dictionary];
    if (!a) return data;
    Put(data, @"tracker_token", a.trackerToken); Put(data, @"tracker_name", a.trackerName);
    Put(data, @"network", a.network); Put(data, @"campaign", a.campaign);
    Put(data, @"adgroup", a.adgroup); Put(data, @"creative", a.creative);
    Put(data, @"click_label", a.clickLabel); Put(data, @"cost_type", a.costType);
    Put(data, @"cost_amount", a.costAmount); Put(data, @"cost_currency", a.costCurrency);
    return data;
}

static NSMutableDictionary* Response(NSString* message, NSString* timestamp, NSString* adid, NSDictionary* json)
{
    NSMutableDictionary* data = [NSMutableDictionary dictionary];
    Put(data, @"message", message); Put(data, @"timestamp", timestamp);
    Put(data, @"adid", adid); Put(data, @"json_response", json);
    return data;
}

@interface DefoldAdjustPlugin : NSObject<AdjustDelegate>
@property (atomic, assign) BOOL active;
@property (nonatomic, assign) BOOL initialized;
- (void)emit:(NSString*)name data:(NSDictionary*)data;
- (void)execute:(NSString*)command payload:(NSDictionary*)payload;
@end

@implementation DefoldAdjustPlugin
- (void)emit:(NSString*)name data:(NSDictionary*)data
{
    if (!self.active) return;
    NSError* error = nil;
    NSData* json = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    if (!json) { dmLogError("Adjust callback encoding failed: %s", error.localizedDescription.UTF8String); return; }
    NSString* text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    dmAdjust::QueueEvent(name.UTF8String, text.UTF8String);
}

- (void)adjustAttributionChanged:(ADJAttribution*)attribution
{
    [self emit:@"attribution_changed" data:AttributionData(attribution)];
}
- (void)adjustEventTrackingSucceeded:(ADJEventSuccess*)e
{
    NSMutableDictionary* data = Response(e.message, e.timestamp, e.adid, e.jsonResponse);
    Put(data, @"event_token", e.eventToken); Put(data, @"callback_id", e.callbackId);
    [self emit:@"event_success" data:data];
}
- (void)adjustEventTrackingFailed:(ADJEventFailure*)e
{
    NSMutableDictionary* data = Response(e.message, e.timestamp, e.adid, e.jsonResponse);
    Put(data, @"event_token", e.eventToken); Put(data, @"callback_id", e.callbackId);
    data[@"will_retry"] = @(e.willRetry);
    [self emit:@"event_failure" data:data];
}
- (void)adjustSessionTrackingSucceeded:(ADJSessionSuccess*)e
{
    [self emit:@"session_success" data:Response(e.message, e.timestamp, e.adid, e.jsonResponse)];
}
- (void)adjustSessionTrackingFailed:(ADJSessionFailure*)e
{
    NSMutableDictionary* data = Response(e.message, e.timestamp, e.adid, e.jsonResponse);
    data[@"will_retry"] = @(e.willRetry);
    [self emit:@"session_failure" data:data];
}

- (void)initializeSdk:(NSDictionary*)p
{
    if (self.initialized) [NSException raise:@"Adjust" format:@"SDK already initialized"];
    ADJConfig* config = [[ADJConfig alloc] initWithAppToken:p[@"app_token"]
        environment:p[@"environment"] suppressLogLevel:YES];
    if (!config || ![config isValid]) [NSException raise:@"Adjust" format:@"Invalid Adjust config"];
    NSDictionary* levels = @{@"verbose":@(ADJLogLevelVerbose), @"debug":@(ADJLogLevelDebug),
        @"info":@(ADJLogLevelInfo), @"warn":@(ADJLogLevelWarn), @"error":@(ADJLogLevelError),
        @"assert":@(ADJLogLevelAssert), @"suppress":@(ADJLogLevelSuppress)};
    config.logLevel = (ADJLogLevel)[levels[p[@"log_level"]] unsignedIntegerValue];
    config.delegate = self;
    if (p[@"idfa_reading"] && ![p[@"idfa_reading"] boolValue]) [config disableIdfaReading];
    if (p[@"ad_services"] && ![p[@"ad_services"] boolValue]) [config disableAdServices];
    if ([p[@"cost_data_in_attribution"] boolValue]) [config enableCostDataInAttribution];
    if (p[@"att_consent_waiting_interval"]) config.attConsentWaitingInterval = [p[@"att_consent_waiting_interval"] unsignedIntegerValue];
    if (p[@"event_deduplication_ids_max_size"]) config.eventDeduplicationIdsMaxSize = [p[@"event_deduplication_ids_max_size"] integerValue];
    for (NSString* key in p[@"callback_parameters"]) [Adjust addGlobalCallbackParameter:p[@"callback_parameters"][key] forKey:key];
    for (NSString* key in p[@"partner_parameters"]) [Adjust addGlobalPartnerParameter:p[@"partner_parameters"][key] forKey:key];
    [Adjust initSdk:config];
    self.initialized = YES;
    // Adjust's own UIApplication notifications handle foreground/background.
    [self emit:@"initialized" data:@{@"platform":@"ios", @"sdk_version":@"5.8.0"}];
}

- (void)trackEvent:(NSDictionary*)p
{
    ADJEvent* event = [[ADJEvent alloc] initWithEventToken:p[@"event_token"]];
    if (p[@"revenue"]) [event setRevenue:[p[@"revenue"] doubleValue] currency:p[@"currency"]];
    if (p[@"product_id"]) [event setProductId:p[@"product_id"]];
    if (p[@"transaction_id"]) [event setTransactionId:p[@"transaction_id"]];
    if (p[@"deduplication_id"]) [event setDeduplicationId:p[@"deduplication_id"]];
    if (p[@"callback_id"]) [event setCallbackId:p[@"callback_id"]];
    for (NSString* key in p[@"callback_parameters"]) [event addCallbackParameter:key value:p[@"callback_parameters"][key]];
    for (NSString* key in p[@"partner_parameters"]) [event addPartnerParameter:key value:p[@"partner_parameters"][key]];
    if (!event || ![event isValid]) [NSException raise:@"Adjust" format:@"Invalid Adjust event"];
    [Adjust trackEvent:event];
}

- (void)trackAdRevenue:(NSDictionary*)p
{
    ADJAdRevenue* ad = [[ADJAdRevenue alloc] initWithSource:p[@"source"]];
    [ad setRevenue:[p[@"revenue"] doubleValue] currency:p[@"currency"]];
    if (p[@"network"]) [ad setAdRevenueNetwork:p[@"network"]];
    if (p[@"unit"]) [ad setAdRevenueUnit:p[@"unit"]];
    if (p[@"placement"]) [ad setAdRevenuePlacement:p[@"placement"]];
    if (p[@"impressions"]) [ad setAdImpressionsCount:[p[@"impressions"] intValue]];
    for (NSString* key in p[@"callback_parameters"]) [ad addCallbackParameter:key value:p[@"callback_parameters"][key]];
    for (NSString* key in p[@"partner_parameters"]) [ad addPartnerParameter:key value:p[@"partner_parameters"][key]];
    if (!ad || ![ad isValid]) [NSException raise:@"Adjust" format:@"Invalid ad revenue"];
    [Adjust trackAdRevenue:ad];
}

- (void)execute:(NSString*)command payload:(NSDictionary*)p
{
    if (!self.active) return;
    @try {
        if ([command isEqualToString:@"initialize"]) { [self initializeSdk:p]; return; }
        if ([command isEqualToString:@"request_tracking_authorization"]) {
            NSString* usage = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSUserTrackingUsageDescription"];
            if (![usage isKindOfClass:[NSString class]] || usage.length == 0) {
                [NSException raise:@"Adjust" format:@"Set adjust.ios_user_tracking_usage_description before requesting ATT"];
            }
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
                [NSException raise:@"Adjust" format:@"Request ATT while the application is active"];
            }
            [Adjust requestAppTrackingAuthorizationWithCompletionHandler:^(NSUInteger status) {
                [self emit:@"tracking_authorization" data:@{@"status":@(status)}];
            }];
            return;
        }
        if (!self.initialized) [NSException raise:@"Adjust" format:@"SDK is not initialized"];
        if ([command isEqualToString:@"track_event"]) [self trackEvent:p];
        else if ([command isEqualToString:@"track_ad_revenue"]) [self trackAdRevenue:p];
        else if ([command isEqualToString:@"get_adid"]) {
            [Adjust adidWithCompletionHandler:^(NSString* adid) {
                [self emit:@"adid" data:adid ? @{@"adid":adid} : @{}];
            }];
        } else if ([command isEqualToString:@"get_attribution"]) {
            [Adjust attributionWithCompletionHandler:^(ADJAttribution* a) {
                [self emit:@"attribution" data:AttributionData(a)];
            }];
        } else if ([command isEqualToString:@"set_global_callback_parameters"]) {
            [Adjust removeGlobalCallbackParameters];
            for (NSString* key in p[@"parameters"]) [Adjust addGlobalCallbackParameter:p[@"parameters"][key] forKey:key];
        } else if ([command isEqualToString:@"set_global_partner_parameters"]) {
            [Adjust removeGlobalPartnerParameters];
            for (NSString* key in p[@"parameters"]) [Adjust addGlobalPartnerParameter:p[@"parameters"][key] forKey:key];
        } else [NSException raise:@"Adjust" format:@"Unknown command: %@", command];
    } @catch (NSException* exception) {
        [self emit:[command isEqualToString:@"initialize"] ? @"initialization_failed" : @"error"
            data:@{@"operation":command, @"message":exception.reason ?: @"Unknown native error"}];
    }
}
@end

namespace dmAdjust {
static DefoldAdjustPlugin* g_Plugin;

bool PlatformCreate()
{
    g_Plugin = [DefoldAdjustPlugin new];
    g_Plugin.active = YES;
    return g_Plugin != nil;
}

void PlatformDestroy()
{
    g_Plugin.active = NO;
    g_Plugin = nil;
}

bool PlatformExecute(const char* command, const char* json)
{
    if (!g_Plugin) return false;
    NSString* name = [NSString stringWithUTF8String:command];
    NSString* text = [NSString stringWithUTF8String:json];
    if (!name || !text) return false;
    NSError* error = nil;
    id payload = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    if (![payload isKindOfClass:[NSDictionary class]]) return false;
    DefoldAdjustPlugin* plugin = g_Plugin;
    dispatch_async(dispatch_get_main_queue(), ^{ [plugin execute:name payload:payload]; });
    return true;
}
}
#endif
