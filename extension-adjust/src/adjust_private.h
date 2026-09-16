#ifndef ADJUST_PRIVATE_H
#define ADJUST_PRIVATE_H

#include <dmsdk/sdk.h>

namespace dmAdjust {
// Callback data is copied immediately. May be called from any native thread.
void QueueEvent(const char* name, const char* json);
bool PlatformCreate();
void PlatformDestroy();
bool PlatformExecute(const char* command, const char* json);
}

#endif
