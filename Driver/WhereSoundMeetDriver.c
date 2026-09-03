// WhereSoundMeetDriver: HAL AudioServerPlugIn exposing up to kLB_MaxDevices virtual loopback devices.
// Audio written by the owner app to a device's output is looped to its input stream; other
// clients' output is silenced so the app can capture it via a process tap (Pass-Thru).
#include "WhereSoundMeetDriver.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

static AudioServerPlugInHostRef gHost = NULL;
static LBDevice gDevices[kLB_MaxDevices];
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static ULONG gRefCount = 0;
static os_log_t gLog;
static OSStatus gLastNotifyStatus = 0;
static UInt32 gNotifyCount = 0;

#define kLB_TraceSize 96
typedef struct { char kind; AudioObjectID obj; AudioObjectPropertySelector sel; AudioObjectPropertyScope scope; UInt32 el; OSStatus status; } LBTrace;
static LBTrace gTrace[kLB_TraceSize];
static UInt32 gTraceHead = 0;

static void LB_Trace(char kind, AudioObjectID obj, const AudioObjectPropertyAddress* a, OSStatus status) {
    UInt32 i = __sync_fetch_and_add(&gTraceHead, 1) % kLB_TraceSize;
    gTrace[i].kind = kind; gTrace[i].obj = obj; gTrace[i].sel = a->mSelector; gTrace[i].scope = a->mScope; gTrace[i].el = a->mElement; gTrace[i].status = status;
}
static void LB_FourCC(UInt32 v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 32 || out[i] > 126) out[i] = '?';
}

#pragma mark - Forward declarations

static HRESULT  LB_QueryInterface(void*, REFIID, LPVOID*);
static ULONG    LB_AddRef(void*);
static ULONG    LB_Release(void*);
static OSStatus LB_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus LB_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus LB_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus LB_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LB_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus LB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  LB_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus LB_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus LB_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus LB_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus LB_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus LB_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LB_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LB_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus LB_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus LB_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus LB_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus LB_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, LB_QueryInterface, LB_AddRef, LB_Release, LB_Initialize, LB_CreateDevice, LB_DestroyDevice,
    LB_AddDeviceClient, LB_RemoveDeviceClient, LB_PerformDeviceConfigurationChange, LB_AbortDeviceConfigurationChange,
    LB_HasProperty, LB_IsPropertySettable, LB_GetPropertyDataSize, LB_GetPropertyData, LB_SetPropertyData,
    LB_StartIO, LB_StopIO, LB_GetZeroTimeStamp, LB_WillDoIOOperation, LB_BeginIOOperation, LB_DoIOOperation, LB_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

#pragma mark - CFPlugIn boilerplate

void* WhereSoundMeetDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* WhereSoundMeetDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT LB_QueryInterface(void* driver, REFIID iid, LPVOID* out) {
    (void)driver;
    if (out == NULL) return E_POINTER;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean ok = uuid != NULL && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID));
    if (uuid) CFRelease(uuid);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    ++gRefCount;
    *out = gDriverRef;
    return S_OK;
}
static ULONG LB_AddRef(void* d) { (void)d; return ++gRefCount; }
static ULONG LB_Release(void* d) { (void)d; return gRefCount > 0 ? --gRefCount : 0; }

#pragma mark - Device list management

static CFArrayRef LB_CopyDeviceListLocked(void) {
    CFMutableArrayRef arr = CFArrayCreateMutable(NULL, kLB_MaxDevices, &kCFTypeArrayCallBacks);
    for (int i = 0; i < kLB_MaxDevices; i++) {
        if (!gDevices[i].active) continue;
        CFTypeRef keys[2] = { kLB_Key_UID, kLB_Key_Name };
        CFTypeRef vals[2] = { gDevices[i].uid, gDevices[i].name };
        CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(arr, d);
        CFRelease(d);
    }
    return arr;
}

static int LB_SlotForUIDLocked(CFStringRef uid) {
    for (int i = 0; i < kLB_MaxDevices; i++)
        if (gDevices[i].active && CFEqual(gDevices[i].uid, uid)) return i;
    return -1;
}

// Applies a new device list: deactivates missing slots, activates new UIDs, renames changed ones.
static void LB_ApplyDeviceList(CFArrayRef list, bool persist, bool notify) {
    if (list == NULL || CFGetTypeID(list) != CFArrayGetTypeID()) return;
    CFIndex count = CFArrayGetCount(list);
    if (count > kLB_MaxDevices) count = kLB_MaxDevices;
    bool renamed[kLB_MaxDevices] = { false };

    pthread_mutex_lock(&gStateMutex);
    for (int i = 0; i < kLB_MaxDevices; i++) {
        if (!gDevices[i].active) continue;
        bool keep = false;
        for (CFIndex j = 0; j < count && !keep; j++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(list, j);
            if (CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
            CFStringRef uid = CFDictionaryGetValue(d, kLB_Key_UID);
            keep = uid && CFGetTypeID(uid) == CFStringGetTypeID() && CFEqual(uid, gDevices[i].uid);
        }
        if (!keep) {
            CFRelease(gDevices[i].uid); CFRelease(gDevices[i].name);
            gDevices[i].uid = NULL; gDevices[i].name = NULL;
            gDevices[i].active = false; gDevices[i].ownerPID = 0; gDevices[i].clientCount = 0;
        }
    }
    for (CFIndex j = 0; j < count; j++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, j);
        if (CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
        CFStringRef uid = CFDictionaryGetValue(d, kLB_Key_UID);
        CFStringRef name = CFDictionaryGetValue(d, kLB_Key_Name);
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID()) continue;
        if (!name || CFGetTypeID(name) != CFStringGetTypeID()) name = uid;
        int slot = LB_SlotForUIDLocked(uid);
        if (slot >= 0) {
            if (!CFEqual(gDevices[slot].name, name)) {
                CFRelease(gDevices[slot].name);
                gDevices[slot].name = CFStringCreateCopy(NULL, name);
                renamed[slot] = true;
            }
            continue;
        }
        for (int i = 0; i < kLB_MaxDevices; i++) {
            if (gDevices[i].active) continue;
            gDevices[i].active = true;
            gDevices[i].uid = CFStringCreateCopy(NULL, uid);
            gDevices[i].name = CFStringCreateCopy(NULL, name);
            gDevices[i].ownerPID = 0;
            gDevices[i].clientCount = 0;
            break;
        }
    }
    CFArrayRef snapshot = persist ? LB_CopyDeviceListLocked() : NULL;
    pthread_mutex_unlock(&gStateMutex);

    if (gHost && notify) {
        if (snapshot) gHost->WriteToStorage(gHost, kLB_StorageKey, snapshot);
        UInt32 renamedMask = 0;
        for (int i = 0; i < kLB_MaxDevices; i++) if (renamed[i]) renamedMask |= (1u << i);
        // Notify off the caller's thread: the host is still inside SetPropertyData here.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            AudioObjectPropertyAddress addrs[2] = {
                { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            gLastNotifyStatus = gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 2, addrs);
            gNotifyCount++;
            os_log(gLog, "device list notify status %d", (int)gLastNotifyStatus);
            for (int i = 0; i < kLB_MaxDevices; i++) {
                if (!(renamedMask & (1u << i))) continue;
                AudioObjectPropertyAddress nameAddr = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                gHost->PropertiesChanged(gHost, LB_DeviceID(i), 1, &nameAddr);
            }
        });
    }
    if (snapshot) CFRelease(snapshot);
}

#pragma mark - Basic operations

static OSStatus LB_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d;
    gHost = host;
    gLog = os_log_create(kLB_BundleID, "driver");
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerFrame = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9 / kLB_SampleRate;
    for (int i = 0; i < kLB_MaxDevices; i++) {
        memset(&gDevices[i], 0, sizeof(LBDevice));
        gDevices[i].ring = calloc((size_t)kLB_RingFrames * kLB_Channels, sizeof(Float32));
        gDevices[i].passRing = calloc((size_t)kLB_RingFrames * kLB_Channels, sizeof(Float32));
        gDevices[i].hostTicksPerFrame = ticksPerFrame;
        pthread_mutex_init(&gDevices[i].ioMutex, NULL);
    }
    CFPropertyListRef stored = NULL;
    if (host->CopyFromStorage(host, kLB_StorageKey, &stored) == 0 && stored) {
        LB_ApplyDeviceList((CFArrayRef)stored, false, false);
        CFRelease(stored);
    }
    os_log(gLog, "initialized");
    return 0;
}

static OSStatus LB_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus LB_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus LB_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* info) {
    (void)d;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    if (s->clientCount < kLB_MaxClients) {
        s->clients[s->clientCount].id = info->mClientID;
        s->clients[s->clientCount].pid = info->mProcessID;
        s->clientCount++;
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus LB_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* info) {
    (void)d;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    for (UInt32 i = 0; i < s->clientCount; i++) {
        if (s->clients[i].id != info->mClientID) continue;
        s->clients[i] = s->clients[s->clientCount - 1];
        s->clientCount--;
        break;
    }
    // Owner went away entirely: fall back to plain loopback for every client.
    if (s->ownerPID != 0 && s->ownerPID == info->mProcessID) {
        bool stillPresent = false;
        for (UInt32 i = 0; i < s->clientCount; i++) if (s->clients[i].pid == s->ownerPID) stillPresent = true;
        if (!stillPresent) s->ownerPID = 0;
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus LB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void* i) {
    (void)d; (void)dev; (void)a; (void)i; return 0;
}
static OSStatus LB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void* i) {
    (void)d; (void)dev; (void)a; (void)i; return 0;
}

#pragma mark - Property tables

static bool LB_PlugInHas(AudioObjectPropertySelector sel) {
    switch (sel) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyResourceBundle: case kAudioObjectPropertyCustomPropertyInfoList:
        case kLB_Selector_DeviceList: case kLB_Selector_Debug:
            return true;
        default: return false;
    }
}

static bool LB_DeviceHas(AudioObjectPropertySelector sel) {
    switch (sel) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioObjectPropertyControlList: case kLB_Selector_OwnerPID:
            return true;
        default: return false;
    }
}

static bool LB_StreamHas(AudioObjectPropertySelector sel) {
    switch (sel) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default: return false;
    }
}

static Boolean LB_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)d; (void)pid;
    Boolean has = false;
    if (obj == kAudioObjectPlugInObject) has = LB_PlugInHas(a->mSelector);
    else if (LB_IsDeviceID(obj) && gDevices[LB_SlotForID(obj)].active) has = LB_DeviceHas(a->mSelector) && !(LB_IsCapDeviceID(obj) && a->mSelector == kLB_Selector_OwnerPID);
    else if (LB_IsStreamID(obj) && gDevices[LB_SlotForID(obj)].active) has = LB_StreamHas(a->mSelector);
    LB_Trace('H', obj, a, has ? 0 : -1);
    return has;
}

static OSStatus LB_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    if (!LB_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
        case kLB_Selector_DeviceList: *out = obj == kAudioObjectPlugInObject; break;
        case kLB_Selector_OwnerPID: case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = true; break;
        default: *out = false;
    }
    return 0;
}

static AudioStreamBasicDescription LB_Format(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kLB_SampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket = kLB_Channels * sizeof(Float32);
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kLB_Channels * sizeof(Float32);
    f.mChannelsPerFrame = kLB_Channels;
    f.mBitsPerChannel = 32;
    return f;
}

// Shared getter: when outData is NULL only the required size is reported.
#define LB_RETURN_VALUE(type, value) do { \
    *outSize = sizeof(type); \
    if (outData) { if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type*)outData = (value); } \
    return 0; } while (0)

static OSStatus LB_GetPlugInProperty(const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, UInt32 inSize, UInt32* outSize, void* outData) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: LB_RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: LB_RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: LB_RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: LB_RETURN_VALUE(CFStringRef, CFRetain(kLB_Manufacturer));
        case kAudioPlugInPropertyResourceBundle: LB_RETURN_VALUE(CFStringRef, CFSTR(""));
        case kAudioPlugInPropertyBoxList: *outSize = 0; return 0;
        case kAudioPlugInPropertyTranslateUIDToBox: LB_RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[kLB_MaxDevices * 2]; UInt32 n = 0;
            pthread_mutex_lock(&gStateMutex);
            for (int i = 0; i < kLB_MaxDevices; i++) if (gDevices[i].active) { ids[n++] = LB_DeviceID(i); ids[n++] = LB_CapDeviceID(i); }
            pthread_mutex_unlock(&gStateMutex);
            UInt32 max = outData ? inSize / sizeof(AudioObjectID) : n;
            if (max < n) n = max;
            *outSize = n * sizeof(AudioObjectID);
            if (outData) memcpy(outData, ids, *outSize);
            return 0;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            *outSize = sizeof(AudioObjectID);
            if (!outData) return 0;
            if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (qualSize < sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)qual;
            AudioObjectID found = kAudioObjectUnknown;
            pthread_mutex_lock(&gStateMutex);
            int slot = uid ? LB_SlotForUIDLocked(uid) : -1;
            if (slot >= 0) found = LB_DeviceID(slot);
            else if (uid && CFStringHasSuffix(uid, CFSTR(kLB_PassThruSuffix))) {
                CFStringRef base = CFStringCreateWithSubstring(NULL, uid, CFRangeMake(0, CFStringGetLength(uid) - (CFIndex)strlen(kLB_PassThruSuffix)));
                slot = LB_SlotForUIDLocked(base);
                CFRelease(base);
                if (slot >= 0) found = LB_CapDeviceID(slot);
            }
            pthread_mutex_unlock(&gStateMutex);
            *(AudioObjectID*)outData = found;
            return 0;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info[2] = {
                { kLB_Selector_DeviceList, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                { kLB_Selector_Debug, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone },
            };
            UInt32 n = outData ? inSize / sizeof(info[0]) : 2;
            if (n > 2) n = 2;
            *outSize = n * sizeof(info[0]);
            if (outData) memcpy(outData, info, *outSize);
            return 0;
        }
        case kLB_Selector_Debug: {
            *outSize = sizeof(CFStringRef);
            if (!outData) return 0;
            if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            int active = 0;
            pthread_mutex_lock(&gStateMutex);
            for (int i = 0; i < kLB_MaxDevices; i++) if (gDevices[i].active) active++;
            pthread_mutex_unlock(&gStateMutex);
            CFMutableStringRef str = CFStringCreateMutable(NULL, 0);
            CFStringAppendFormat(str, NULL, CFSTR("host=%d active=%d notifies=%u lastNotifyStatus=%d\n"),
                                 gHost != NULL, active, (unsigned)gNotifyCount, (int)gLastNotifyStatus);
            UInt32 head = gTraceHead;
            UInt32 start = head > kLB_TraceSize ? head - kLB_TraceSize : 0;
            for (UInt32 i = start; i < head; i++) {
                const LBTrace* t = &gTrace[i % kLB_TraceSize];
                if (t->obj == kAudioObjectPlugInObject && t->sel == kLB_Selector_Debug) continue;
                char sel[5], scope[5];
                LB_FourCC(t->sel, sel); LB_FourCC(t->scope, scope);
                CFStringAppendFormat(str, NULL, CFSTR("%c obj=%u %s/%s/%u -> %d\n"), t->kind, (unsigned)t->obj, sel, scope, (unsigned)t->el, (int)t->status);
            }
            *(CFStringRef*)outData = str;
            return 0;
        }
        case kLB_Selector_DeviceList: {
            *outSize = sizeof(CFPropertyListRef);
            if (!outData) return 0;
            if (inSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            *(CFPropertyListRef*)outData = LB_CopyDeviceListLocked();
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus LB_GetDeviceProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* outData) {
    int slot = (int)LB_SlotForID(obj);
    bool cap = LB_IsCapDeviceID(obj);
    LBDevice* s = &gDevices[slot];
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: LB_RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: LB_RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: LB_RETURN_VALUE(AudioObjectID, kAudioObjectPlugInObject);
        case kAudioObjectPropertyManufacturer: LB_RETURN_VALUE(CFStringRef, CFRetain(kLB_Manufacturer));
        case kAudioObjectPropertyName: {
            *outSize = sizeof(CFStringRef);
            if (!outData) return 0;
            if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            CFStringRef base = s->name ? s->name : CFSTR("Where Sound Meet");
            *(CFStringRef*)outData = cap ? CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ Pass-Thru"), base) : CFStringCreateCopy(NULL, base);
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        }
        case kAudioDevicePropertyDeviceUID: {
            *outSize = sizeof(CFStringRef);
            if (!outData) return 0;
            if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            CFStringRef base = s->uid ? s->uid : CFSTR("");
            *(CFStringRef*)outData = cap ? CFStringCreateWithFormat(NULL, NULL, CFSTR("%@%s"), base, kLB_PassThruSuffix) : CFStringCreateCopy(NULL, base);
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        }
        case kAudioDevicePropertyModelUID: LB_RETURN_VALUE(CFStringRef, CFRetain(kLB_ModelUID));
        case kAudioDevicePropertyTransportType: LB_RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID ids[2] = { LB_DeviceID(slot), LB_CapDeviceID(slot) };
            UInt32 n = outData ? inSize / sizeof(AudioObjectID) : 2;
            if (n > 2) n = 2;
            *outSize = n * sizeof(AudioObjectID);
            if (outData) memcpy(outData, ids, *outSize);
            return 0;
        }
        case kAudioDevicePropertyClockDomain: LB_RETURN_VALUE(UInt32, (UInt32)(0x4C420000 + slot));
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioDevicePropertyDeviceIsAlive: LB_RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: LB_RETURN_VALUE(UInt32, s->ioCount > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: LB_RETURN_VALUE(UInt32, cap ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: LB_RETURN_VALUE(UInt32, cap ? 0 : 1);
        case kAudioDevicePropertyLatency: LB_RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: LB_RETURN_VALUE(UInt32, kLB_SafetyOffset);
        case kAudioDevicePropertyZeroTimeStampPeriod: LB_RETURN_VALUE(UInt32, kLB_ZeroTSPeriod);
        case kAudioDevicePropertyIsHidden: LB_RETURN_VALUE(UInt32, cap ? 1 : 0);
        case kAudioDevicePropertyNominalSampleRate: LB_RETURN_VALUE(Float64, kLB_SampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kLB_SampleRate, kLB_SampleRate };
            if (outData && inSize < sizeof(r)) { *outSize = 0; return 0; }
            LB_RETURN_VALUE(AudioValueRange, r);
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2]; UInt32 n = 0;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput) ids[n++] = cap ? LB_CapInStreamID(slot) : LB_InStreamID(slot);
            if (!cap && (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput)) ids[n++] = LB_OutStreamID(slot);
            UInt32 max = outData ? inSize / sizeof(AudioObjectID) : n;
            if (max < n) n = max;
            *outSize = n * sizeof(AudioObjectID);
            if (outData) memcpy(outData, ids, *outSize);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            *outSize = 2 * sizeof(UInt32);
            if (outData) { if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError; ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2; }
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 need = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kLB_Channels * sizeof(AudioChannelDescription));
            *outSize = need;
            if (!outData) return 0;
            if (inSize < need) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mChannelBitmap = 0;
            l->mNumberChannelDescriptions = kLB_Channels;
            for (UInt32 c = 0; c < kLB_Channels; c++) {
                l->mChannelDescriptions[c].mChannelLabel = kAudioChannelLabel_Left + c;
                l->mChannelDescriptions[c].mChannelFlags = 0;
                l->mChannelDescriptions[c].mCoordinates[0] = l->mChannelDescriptions[c].mCoordinates[1] = l->mChannelDescriptions[c].mCoordinates[2] = 0;
            }
            return 0;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info = { kLB_Selector_OwnerPID, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone };
            if (outData && inSize < sizeof(info)) { *outSize = 0; return 0; }
            LB_RETURN_VALUE(AudioServerPlugInCustomPropertyInfo, info);
        }
        case kLB_Selector_OwnerPID: {
            *outSize = sizeof(CFPropertyListRef);
            if (!outData) return 0;
            if (inSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            SInt32 pid = (SInt32)s->ownerPID;
            *(CFPropertyListRef*)outData = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
            return 0;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus LB_GetStreamProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* outData) {
    bool isInput = LB_IsInStream(obj) || LB_IsCapInStream(obj);
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: LB_RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: LB_RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: LB_RETURN_VALUE(AudioObjectID, LB_DeviceID(LB_SlotForID(obj)));
        case kAudioStreamPropertyIsActive: LB_RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: LB_RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType: LB_RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: LB_RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: LB_RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: LB_RETURN_VALUE(AudioStreamBasicDescription, LB_Format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = LB_Format();
            r.mSampleRateRange.mMinimum = kLB_SampleRate;
            r.mSampleRateRange.mMaximum = kLB_SampleRate;
            if (outData && inSize < sizeof(r)) { *outSize = 0; return 0; }
            LB_RETURN_VALUE(AudioStreamRangedDescription, r);
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus LB_GetProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, UInt32 inSize, UInt32* outSize, void* outData) {
    if (obj == kAudioObjectPlugInObject) return LB_GetPlugInProperty(a, qualSize, qual, inSize, outSize, outData);
    if (LB_IsDeviceID(obj) && gDevices[LB_SlotForID(obj)].active) return LB_GetDeviceProperty(obj, a, inSize, outSize, outData);
    if (LB_IsStreamID(obj) && gDevices[LB_SlotForID(obj)].active) return LB_GetStreamProperty(obj, a, inSize, outSize, outData);
    return kAudioHardwareBadObjectError;
}

static OSStatus LB_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, UInt32* outSize) {
    (void)d; (void)pid;
    OSStatus st = LB_GetProperty(obj, a, qualSize, qual, 0, outSize, NULL);
    LB_Trace('S', obj, a, st);
    return st;
}

static OSStatus LB_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, UInt32 inSize, UInt32* outSize, void* outData) {
    (void)d; (void)pid;
    OSStatus st = LB_GetProperty(obj, a, qualSize, qual, inSize, outSize, outData);
    LB_Trace('G', obj, a, st);
    return st;
}

static OSStatus LB_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, UInt32 inSize, const void* inData) {
    (void)d; (void)pid; (void)qualSize; (void)qual;
    if (obj == kAudioObjectPlugInObject && a->mSelector == kLB_Selector_DeviceList) {
        if (inSize < sizeof(CFPropertyListRef) || inData == NULL) return kAudioHardwareBadPropertySizeError;
        CFPropertyListRef list = *(const CFPropertyListRef*)inData;
        if (list == NULL || CFGetTypeID(list) != CFArrayGetTypeID()) return kAudioHardwareIllegalOperationError;
        os_log(gLog, "device list update: %ld entries", (long)CFArrayGetCount(list));
        LB_ApplyDeviceList((CFArrayRef)list, true, true);
        return 0;
    }
    if (LB_IsDeviceID(obj) && gDevices[LB_SlotForID(obj)].active) {
        LBDevice* s = &gDevices[LB_SlotForID(obj)];
        switch (a->mSelector) {
            case kLB_Selector_OwnerPID: {
                if (LB_IsCapDeviceID(obj)) return kAudioHardwareUnknownPropertyError;
                if (inSize < sizeof(CFPropertyListRef) || inData == NULL) return kAudioHardwareBadPropertySizeError;
                CFPropertyListRef v = *(const CFPropertyListRef*)inData;
                if (v == NULL || CFGetTypeID(v) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
                SInt32 pidValue = 0;
                CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &pidValue);
                s->ownerPID = (pid_t)pidValue;
                os_log(gLog, "slot %d owner pid = %d", (int)LB_SlotForID(obj), (int)pidValue);
                return 0;
            }
            case kAudioDevicePropertyNominalSampleRate: {
                if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                return *(const Float64*)inData == kLB_SampleRate ? 0 : kAudioHardwareIllegalOperationError;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (LB_IsStreamID(obj) && gDevices[LB_SlotForID(obj)].active) {
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* f = inData;
            AudioStreamBasicDescription want = LB_Format();
            bool same = f->mSampleRate == want.mSampleRate && f->mFormatID == want.mFormatID && f->mChannelsPerFrame == want.mChannelsPerFrame && f->mBitsPerChannel == want.mBitsPerChannel;
            return same ? 0 : kAudioDeviceUnsupportedFormatError;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

#pragma mark - IO

static void LB_NotifyRunning(AudioObjectID dev) {
    if (!gHost) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        AudioObjectPropertyAddress addr = { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        gHost->PropertiesChanged(gHost, dev, 1, &addr);
    });
}

static OSStatus LB_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    if (s->ioCount == 0) {
        pthread_mutex_lock(&s->ioMutex);
        s->anchorHostTime = mach_absolute_time();
        s->periodCounter = 0;
        memset(s->ring, 0, sizeof(Float32) * kLB_RingFrames * kLB_Channels);
        memset(s->passRing, 0, sizeof(Float32) * kLB_RingFrames * kLB_Channels);
        pthread_mutex_unlock(&s->ioMutex);
    }
    s->ioCount++;
    pthread_mutex_unlock(&gStateMutex);
    LB_NotifyRunning(dev);
    return 0;
}

static OSStatus LB_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    if (s->ioCount > 0) s->ioCount--;
    pthread_mutex_unlock(&gStateMutex);
    LB_NotifyRunning(dev);
    return 0;
}

static OSStatus LB_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&s->ioMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = s->hostTicksPerFrame * kLB_ZeroTSPeriod;
    UInt64 nextHost = s->anchorHostTime + (UInt64)((Float64)(s->periodCounter + 1) * ticksPerPeriod);
    if (now >= nextHost) s->periodCounter++;
    *outSampleTime = (Float64)(s->periodCounter * kLB_ZeroTSPeriod);
    *outHostTime = s->anchorHostTime + (UInt64)((Float64)s->periodCounter * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&s->ioMutex);
    return 0;
}

static OSStatus LB_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean* willDo, Boolean* inPlace) {
    (void)d; (void)client;
    if (LB_IsCapDeviceID(dev)) *willDo = (op == kAudioServerPlugInIOOperationReadInput);
    else *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationProcessOutput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return 0;
}

static OSStatus LB_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)dev; (void)c; (void)op; (void)n; (void)i; return 0;
}
static OSStatus LB_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)dev; (void)c; (void)op; (void)n; (void)i; return 0;
}

static pid_t LB_ClientPID(const LBDevice* s, UInt32 clientID) {
    UInt32 n = s->clientCount;
    for (UInt32 i = 0; i < n && i < kLB_MaxClients; i++) if (s->clients[i].id == clientID) return s->clients[i].pid;
    return -1;
}

static void LB_RingAdd(Float32* ring, UInt64 start, const Float32* buf, UInt32 frames) {
    const UInt64 mask = kLB_RingFrames - 1;
    for (UInt32 f = 0; f < frames; f++) {
        Float32* dst = ring + ((start + f) & mask) * kLB_Channels;
        dst[0] += buf[f * kLB_Channels];
        dst[1] += buf[f * kLB_Channels + 1];
    }
}

static OSStatus LB_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuf, void* secBuf) {
    (void)d; (void)stream; (void)secBuf;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    Float32* buf = (Float32*)mainBuf;
    const UInt64 mask = kLB_RingFrames - 1;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        Float32* ring = LB_IsCapDeviceID(dev) ? s->passRing : s->ring;
        UInt64 start = (UInt64)cycle->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            Float32* src = ring + ((start + f) & mask) * kLB_Channels;
            buf[f * kLB_Channels] = src[0];
            buf[f * kLB_Channels + 1] = src[1];
            src[0] = 0; src[1] = 0;
        }
    } else if (op == kAudioServerPlugInIOOperationProcessOutput) {
        // Owned device: only the owner app's output is looped back. Other clients' audio is left
        // untouched so the app can capture it through a process tap (Pass-Thru) and route it itself.
        pid_t owner = s->ownerPID;
        if (owner != 0) {
            bool isOwner = LB_ClientPID(s, client) == owner;
            LB_RingAdd(isOwner ? s->ring : s->passRing, (UInt64)cycle->mOutputTime.mSampleTime, buf, frames);
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        // Unowned device: plain loopback of the full mix (BlackHole-style).
        if (s->ownerPID == 0) LB_RingAdd(s->ring, (UInt64)cycle->mOutputTime.mSampleTime, buf, frames);
    }
    return 0;
}
