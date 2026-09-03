#pragma once
#include <CoreAudio/AudioServerPlugIn.h>
#include <pthread.h>
#include <stdbool.h>

#define kLB_MaxDevices        8
#define kLB_MaxClients        64
#define kLB_Channels          2
#define kLB_SampleRate        48000.0
#define kLB_RingFrames        16384          /* power of two */
#define kLB_ZeroTSPeriod      4096
#define kLB_SafetyOffset      96
#define kLB_BundleID          "com.zan.wheresoundmeet.driver"
#define kLB_Manufacturer      CFSTR("Zan")
#define kLB_ModelUID          CFSTR("com.zan.wheresoundmeet.model")
#define kLB_StorageKey        CFSTR("devices")

#define kLB_Selector_DeviceList   'lbdv'
#define kLB_Selector_OwnerPID     'lbpd'
#define kLB_Selector_Debug        'lbdg'
#define kLB_Key_UID   CFSTR("uid")
#define kLB_Key_Name  CFSTR("name")

/* Object ID layout: plug-in = kAudioObjectPlugInObject (1); slot i uses 8 IDs from 2 + 8*i:
   +0 main device, +1 its input stream, +2 its output stream,
   +4 hidden Pass-Thru capture device, +5 its input stream. */
enum { kLB_FirstDeviceID = 2, kLB_IDsPerSlot = 8 };
#define kLB_PassThruSuffix   ".passthru"
#define LB_DeviceID(slot)    ((AudioObjectID)(kLB_FirstDeviceID + (slot) * kLB_IDsPerSlot))
#define LB_InStreamID(slot)  (LB_DeviceID(slot) + 1)
#define LB_OutStreamID(slot) (LB_DeviceID(slot) + 2)
#define LB_CapDeviceID(slot) (LB_DeviceID(slot) + 4)
#define LB_CapInStreamID(slot) (LB_DeviceID(slot) + 5)
#define LB_SlotForID(id)     (((id) - kLB_FirstDeviceID) / kLB_IDsPerSlot)
#define LB_Offset(id)        (((id) - kLB_FirstDeviceID) % kLB_IDsPerSlot)
#define LB_InRange(id)       ((id) >= kLB_FirstDeviceID && (id) < kLB_FirstDeviceID + kLB_MaxDevices * kLB_IDsPerSlot)
#define LB_IsMainDeviceID(id) (LB_InRange(id) && LB_Offset(id) == 0)
#define LB_IsCapDeviceID(id) (LB_InRange(id) && LB_Offset(id) == 4)
#define LB_IsDeviceID(id)    (LB_IsMainDeviceID(id) || LB_IsCapDeviceID(id))
#define LB_IsInStream(id)    (LB_InRange(id) && LB_Offset(id) == 1)
#define LB_IsOutStream(id)   (LB_InRange(id) && LB_Offset(id) == 2)
#define LB_IsCapInStream(id) (LB_InRange(id) && LB_Offset(id) == 5)
#define LB_IsStreamID(id)    (LB_IsInStream(id) || LB_IsOutStream(id) || LB_IsCapInStream(id))

typedef struct { UInt32 id; pid_t pid; } LBClient;

typedef struct {
    bool        active;
    CFStringRef uid;
    CFStringRef name;
    pid_t       ownerPID;
    UInt32      ioCount;
    UInt64      anchorHostTime;
    UInt64      periodCounter;
    Float64     hostTicksPerFrame;
    Float32    *ring;                /* owner loopback: kLB_RingFrames * kLB_Channels, interleaved */
    Float32    *passRing;            /* other clients' output, read by the hidden capture device */
    pthread_mutex_t ioMutex;
    LBClient    clients[kLB_MaxClients];
    UInt32      clientCount;
} LBDevice;
