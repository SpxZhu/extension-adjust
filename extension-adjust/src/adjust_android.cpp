#if defined(DM_PLATFORM_ANDROID)
#define DLIB_LOG_DOMAIN "Adjust"
#include "adjust_private.h"
#include <dmsdk/dlib/android.h>
#include <string>
#include <string.h>

namespace dmAdjust {
static jobject g_Plugin = 0;
static jmethodID g_Execute = 0;
static jmethodID g_Destroy = 0;

static bool Check(JNIEnv* env)
{
    if (!env->ExceptionCheck()) return true;
    env->ExceptionDescribe();
    env->ExceptionClear();
    dmLogError("Adjust JNI call failed");
    return false;
}

bool PlatformCreate()
{
    dmAndroid::ThreadAttacher thread;
    JNIEnv* env = thread.GetEnv();
    if (!env) return false;
    jclass cls = dmAndroid::LoadClass(env, "com.defold.adjust.AdjustPlugin");
    if (!Check(env) || !cls) return false;
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Landroid/app/Activity;)V");
    if (!Check(env) || !ctor) { env->DeleteLocalRef(cls); return false; }
    g_Execute = env->GetMethodID(cls, "execute", "(Ljava/lang/String;[B)V");
    if (!Check(env) || !g_Execute) { env->DeleteLocalRef(cls); return false; }
    g_Destroy = env->GetMethodID(cls, "destroy", "()V");
    if (!Check(env) || !g_Destroy) { env->DeleteLocalRef(cls); return false; }
    jobject local = env->NewObject(cls, ctor, thread.GetActivity()->clazz);
    bool ok = Check(env) && local;
    if (ok) {
        g_Plugin = env->NewGlobalRef(local);
        ok = Check(env) && g_Plugin;
    }
    if (local) env->DeleteLocalRef(local);
    env->DeleteLocalRef(cls);
    return ok;
}

void PlatformDestroy()
{
    if (!g_Plugin) return;
    dmAndroid::ThreadAttacher thread;
    JNIEnv* env = thread.GetEnv();
    if (!env) return;
    env->CallVoidMethod(g_Plugin, g_Destroy);
    Check(env);
    env->DeleteGlobalRef(g_Plugin);
    g_Plugin = 0;
}

bool PlatformExecute(const char* command, const char* json)
{
    if (!g_Plugin) return false;
    dmAndroid::ThreadAttacher thread;
    JNIEnv* env = thread.GetEnv();
    if (!env) return false;
    // Commands are ASCII; JSON uses real UTF-8 bytes, not JNI modified UTF-8.
    jstring name = env->NewStringUTF(command);
    if (!Check(env) || !name) return false;
    jsize size = (jsize)strlen(json);
    jbyteArray bytes = env->NewByteArray(size);
    if (!Check(env) || !bytes) { env->DeleteLocalRef(name); return false; }
    env->SetByteArrayRegion(bytes, 0, size, (const jbyte*)json);
    bool ok = Check(env);
    if (ok) { env->CallVoidMethod(g_Plugin, g_Execute, name, bytes); ok = Check(env); }
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(name);
    return ok;
}
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_adjust_AdjustPlugin_nativeOnEvent(
    JNIEnv* env, jclass, jstring name, jbyteArray bytes)
{
    if (!name || !bytes) return;
    const char* event = env->GetStringUTFChars(name, 0);
    if (!event) return;
    const jsize size = env->GetArrayLength(bytes);
    std::string json(size, '\0');
    if (size) env->GetByteArrayRegion(bytes, 0, size, (jbyte*)&json[0]);
    if (!env->ExceptionCheck()) dmAdjust::QueueEvent(event, json.c_str());
    env->ReleaseStringUTFChars(name, event);
}
#endif
