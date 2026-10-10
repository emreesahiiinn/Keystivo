#ifndef CSMC_H
#define CSMC_H

#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>

/*
 * Minimal AppleSMC user-client access (the same interface used by smcFanControl,
 * Stats and the `battery` CLI). Reading works unprivileged; writing requires root,
 * which is why Keystivo only writes from its privileged helper.
 */

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} KSSMCKeyInfo;

/// Opens a connection to the AppleSMC service. Returns 0 on failure.
io_connect_t KSSMCOpen(void);
void KSSMCClose(io_connect_t connection);

/// Reads key info; returns false when the key does not exist.
bool KSSMCGetKeyInfo(io_connect_t connection, const char key[4], KSSMCKeyInfo *info);

/// Reads up to 32 bytes; `size` receives the key's data size.
bool KSSMCRead(io_connect_t connection, const char key[4], uint8_t bytes[32], uint32_t *size);

/// Writes exactly `size` bytes (must equal the key's data size).
kern_return_t KSSMCWrite(io_connect_t connection, const char key[4], const uint8_t *bytes, uint32_t size);

#endif
