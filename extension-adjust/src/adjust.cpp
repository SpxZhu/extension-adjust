#define DLIB_LOG_DOMAIN "Adjust"
#include "adjust_private.h"
#include <string>
#include <vector>
#include <string.h>

namespace dmAdjust {

#if defined(DM_PLATFORM_ANDROID) || defined(DM_PLATFORM_IOS)
struct Event {
    std::string name;
    std::string json;
    uint32_t generation;
};
enum State { COLD, STARTING, READY };
static State g_State = COLD;
// Process lifetime: a late SDK callback may arrive after extension finalization.
static dmMutex::HMutex g_Mutex = 0;
static std::vector<Event> g_Events;
static bool g_Active = false;
static bool g_HasCallback = false;
static uint32_t g_Generation = 0;
static dmScript::LuaCallbackInfo* g_Callback = 0;
static dmScript::LuaCallbackInfo* g_Invoking = 0;
static uint32_t g_Contexts = 0;
static bool g_PlatformReady = false;

void QueueEvent(const char* name, const char* json)
{
    if (!g_Mutex) return;
    DM_MUTEX_SCOPED_LOCK(g_Mutex);
    if (!g_Active) return;
    if (strcmp(name, "initialized") == 0) g_State = READY;
    if (strcmp(name, "initialization_failed") == 0) g_State = COLD;
    if (!g_HasCallback) return;
    if (g_Events.size() >= 256) {
        dmLogWarning("Callback queue full; dropping %s", name);
        return;
    }
    Event event = {name, json ? json : "{}", g_Generation};
    g_Events.push_back(event);
}

static void ReplaceCallback(dmScript::LuaCallbackInfo* next)
{
    dmScript::LuaCallbackInfo* previous = g_Callback;
    g_Callback = next;
    {
        DM_MUTEX_SCOPED_LOCK(g_Mutex);
        ++g_Generation;
        g_HasCallback = next != 0;
        g_Events.clear();
    }
    // set_callback(nil) or replacement from inside the callback must not free
    // its context until TeardownCallback has restored the current script.
    if (previous && previous != g_Invoking) dmScript::DestroyCallback(previous);
}

static int SetCallback(lua_State* L)
{
    dmScript::LuaCallbackInfo* next = 0;
    if (!lua_isnoneornil(L, 1)) {
        luaL_checktype(L, 1, LUA_TFUNCTION);
        next = dmScript::CreateCallback(L, 1);
    }
    ReplaceCallback(next);
    return 0;
}

static int IsInitialized(lua_State* L)
{
    DM_MUTEX_SCOPED_LOCK(g_Mutex);
    lua_pushboolean(L, g_State == READY);
    return 1;
}

static int Failure(lua_State* L, const char* reason)
{
    lua_pushboolean(L, false);
    lua_pushstring(L, reason);
    return 2;
}

static int Execute(lua_State* L)
{
    const char* command = luaL_checkstring(L, 1);
    const char* json = luaL_checkstring(L, 2);
    if (!g_PlatformReady) return Failure(L, "native_bridge_unavailable");
    const bool init = strcmp(command, "initialize") == 0;
    const bool att = strcmp(command, "request_tracking_authorization") == 0;
    const char* error = 0;
    {
        DM_MUTEX_SCOPED_LOCK(g_Mutex);
        if (init && g_State != COLD) error = "already_initialized_or_initializing";
        else if (!init && !att && g_State == COLD) error = "not_initialized";
        else if (init) g_State = STARTING;
    }
    if (error) return Failure(L, error);
    const bool accepted = PlatformExecute(command, json);
    if (!accepted) {
        if (init) {
            DM_MUTEX_SCOPED_LOCK(g_Mutex);
            g_State = COLD;
        }
        return Failure(L, "native_dispatch_failed");
    }
    lua_pushboolean(L, true);
    return 1;
}

static dmExtension::Result Update(dmExtension::Params* params)
{
    (void)params;
    std::vector<Event> pending;
    {
        DM_MUTEX_SCOPED_LOCK(g_Mutex);
        pending.swap(g_Events);
    }
    for (size_t i = 0; i < pending.size(); ++i) {
        const Event& event = pending[i];
        // Generation changes only on the engine thread during registration.
        if (!g_Callback || event.generation != g_Generation) continue;
        dmScript::LuaCallbackInfo* callback = g_Callback;
        if (!dmScript::IsCallbackValid(callback)) {
            ReplaceCallback(0);
            continue;
        }
        lua_State* L = dmScript::GetCallbackLuaContext(callback);
        const int top = lua_gettop(L);
        if (!dmScript::SetupCallback(callback)) continue;
        lua_pushstring(L, event.name.c_str());
        const int json_top = lua_gettop(L);
        if (dmScript::JsonToLua(L, event.json.c_str(), event.json.size()) != 1 || !lua_istable(L, -1)) {
            lua_settop(L, json_top);
            lua_newtable(L);
        }
        g_Invoking = callback;
        dmScript::PCall(L, 3, 0);
        dmScript::TeardownCallback(callback);
        g_Invoking = 0;
        if (callback != g_Callback) dmScript::DestroyCallback(callback);
        assert(lua_gettop(L) == top);
    }
    return dmExtension::RESULT_OK;
}

static dmExtension::Result Initialize(dmExtension::Params* params)
{
    if (!g_Mutex) g_Mutex = dmMutex::New();
    if (g_Contexts++ == 0) {
        { DM_MUTEX_SCOPED_LOCK(g_Mutex); g_Active = true; }
        g_PlatformReady = PlatformCreate();
        if (!g_PlatformReady) dmLogError("Native bridge could not be created");
    }
    const luaL_reg methods[] = {
        {"execute", Execute}, {"set_callback", SetCallback},
        {"is_initialized", IsInitialized}, {0, 0}
    };
    luaL_register(params->m_L, "adjust_native", methods);
    lua_pop(params->m_L, 1);
    return dmExtension::RESULT_OK;
}

static dmExtension::Result Finalize(dmExtension::Params* params)
{
    if (g_Callback && dmScript::GetCallbackLuaContext(g_Callback) == params->m_L) ReplaceCallback(0);
    if (--g_Contexts == 0) {
        {
            DM_MUTEX_SCOPED_LOCK(g_Mutex);
            g_Active = false;
            g_Events.clear();
        }
        ReplaceCallback(0);
        PlatformDestroy();
        g_PlatformReady = false;
        // Adjust is a process singleton; do not pretend teardown resets the SDK.
    }
    return dmExtension::RESULT_OK;
}
#else
// The public Lua module implements all non-mobile calls as logging no-ops.
static dmExtension::Result Initialize(dmExtension::Params*) { return dmExtension::RESULT_OK; }
static dmExtension::Result Finalize(dmExtension::Params*) { return dmExtension::RESULT_OK; }
static dmExtension::Result Update(dmExtension::Params*) { return dmExtension::RESULT_OK; }
#endif
}

DM_DECLARE_EXTENSION(AdjustExt, "Adjust", 0, 0, dmAdjust::Initialize, dmAdjust::Update, 0, dmAdjust::Finalize)
