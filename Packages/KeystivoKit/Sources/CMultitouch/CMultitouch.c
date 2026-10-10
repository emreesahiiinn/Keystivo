#include "CMultitouch.h"
#include <dlfcn.h>

static void *handle = NULL;
static KSMTDeviceCreateListFn createList = NULL;
static KSMTRegisterContactFrameCallbackFn registerCallback = NULL;
static KSMTUnregisterContactFrameCallbackFn unregisterCallback = NULL;
static KSMTDeviceStartFn startDevice = NULL;
static KSMTDeviceStopFn stopDevice = NULL;

bool KSMTLoad(void) {
    if (handle != NULL) {
        return createList != NULL;
    }
    handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (handle == NULL) {
        return false;
    }
    createList = (KSMTDeviceCreateListFn)dlsym(handle, "MTDeviceCreateList");
    registerCallback = (KSMTRegisterContactFrameCallbackFn)dlsym(handle, "MTRegisterContactFrameCallback");
    unregisterCallback = (KSMTUnregisterContactFrameCallbackFn)dlsym(handle, "MTUnregisterContactFrameCallback");
    startDevice = (KSMTDeviceStartFn)dlsym(handle, "MTDeviceStart");
    stopDevice = (KSMTDeviceStopFn)dlsym(handle, "MTDeviceStop");
    return createList != NULL && registerCallback != NULL && startDevice != NULL && stopDevice != NULL;
}

CFMutableArrayRef KSMTCreateDeviceList(void) {
    return createList ? createList() : NULL;
}

void KSMTRegister(KSMTDeviceRef device, KSMTContactCallback callback) {
    if (registerCallback) registerCallback(device, callback);
}

void KSMTUnregister(KSMTDeviceRef device, KSMTContactCallback callback) {
    if (unregisterCallback) unregisterCallback(device, callback);
}

void KSMTStart(KSMTDeviceRef device) {
    if (startDevice) startDevice(device, 0);
}

void KSMTStop(KSMTDeviceRef device) {
    if (stopDevice) stopDevice(device);
}
