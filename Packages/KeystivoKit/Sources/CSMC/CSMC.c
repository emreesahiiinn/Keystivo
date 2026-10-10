#include "CSMC.h"
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCKeyDataVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyDataPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyDataKeyInfo;

typedef struct {
    uint32_t key;
    SMCKeyDataVers vers;
    SMCKeyDataPLimit pLimitData;
    SMCKeyDataKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must match the kernel's layout");

static uint32_t fourCC(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) | ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static kern_return_t call(io_connect_t connection, SMCKeyData *input, SMCKeyData *output) {
    size_t outputSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(connection, KERNEL_INDEX_SMC, input, sizeof(SMCKeyData), output, &outputSize);
}

io_connect_t KSSMCOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}

void KSSMCClose(io_connect_t connection) {
    if (connection != 0) IOServiceClose(connection);
}

bool KSSMCGetKeyInfo(io_connect_t connection, const char key[4], KSSMCKeyInfo *info) {
    SMCKeyData input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = fourCC(key);
    input.data8 = SMC_CMD_READ_KEYINFO;
    if (call(connection, &input, &output) != KERN_SUCCESS || output.result != 0) return false;
    info->dataSize = output.keyInfo.dataSize;
    info->dataType = output.keyInfo.dataType;
    info->dataAttributes = (uint8_t)output.keyInfo.dataAttributes;
    return output.keyInfo.dataSize > 0;
}

bool KSSMCRead(io_connect_t connection, const char key[4], uint8_t bytes[32], uint32_t *size) {
    KSSMCKeyInfo info;
    if (!KSSMCGetKeyInfo(connection, key, &info)) return false;
    SMCKeyData input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = fourCC(key);
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = SMC_CMD_READ_BYTES;
    if (call(connection, &input, &output) != KERN_SUCCESS || output.result != 0) return false;
    *size = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(bytes, output.bytes, *size);
    return true;
}

kern_return_t KSSMCWrite(io_connect_t connection, const char key[4], const uint8_t *bytes, uint32_t size) {
    KSSMCKeyInfo info;
    if (!KSSMCGetKeyInfo(connection, key, &info)) return kIOReturnNotFound;
    if (info.dataSize != size || size > 32) return kIOReturnBadArgument;
    SMCKeyData input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = fourCC(key);
    input.data8 = SMC_CMD_WRITE_BYTES;
    input.keyInfo.dataSize = size;
    memcpy(input.bytes, bytes, size);
    kern_return_t result = call(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    return output.result == 0 ? KERN_SUCCESS : kIOReturnError;
}
