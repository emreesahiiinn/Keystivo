#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

/*
 * Data layout of the MultitouchSupport private framework (the same layout used by
 * open-source projects such as MiddleClick and Jitouch). The framework is loaded
 * at runtime with dlopen, so Keystivo degrades gracefully if it is unavailable.
 */

typedef struct {
    float x;
    float y;
} KSMTPoint;

typedef struct {
    KSMTPoint position;
    KSMTPoint velocity;
} KSMTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;   // stable per-finger identifier while the finger is down
    int32_t state;       // 1 start … 4 touching, 7 lifting
    int32_t fingerID;
    int32_t handID;
    KSMTVector normalized; // 0…1 within the trackpad surface
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    KSMTVector absolute;   // millimetres
    int32_t field14;
    int32_t field15;
    float zDensity;
} KSMTTouch;

typedef void *KSMTDeviceRef;
typedef int (*KSMTContactCallback)(KSMTDeviceRef device, const KSMTTouch *touches, int count, double timestamp, int frame);

typedef CFMutableArrayRef (*KSMTDeviceCreateListFn)(void);
typedef void (*KSMTRegisterContactFrameCallbackFn)(KSMTDeviceRef device, KSMTContactCallback callback);
typedef void (*KSMTUnregisterContactFrameCallbackFn)(KSMTDeviceRef device, KSMTContactCallback callback);
typedef void (*KSMTDeviceStartFn)(KSMTDeviceRef device, int mode);
typedef void (*KSMTDeviceStopFn)(KSMTDeviceRef device);
typedef bool (*KSMTDeviceIsBuiltInFn)(KSMTDeviceRef device);

/// Loads MultitouchSupport and resolves the symbols above. Returns false if unavailable.
bool KSMTLoad(void);
CFMutableArrayRef KSMTCreateDeviceList(void);
void KSMTRegister(KSMTDeviceRef device, KSMTContactCallback callback);
void KSMTUnregister(KSMTDeviceRef device, KSMTContactCallback callback);
void KSMTStart(KSMTDeviceRef device);
void KSMTStop(KSMTDeviceRef device);

#endif
