// Portable protocol checks: no macOS SDK or physical monitor required.
#include "../RetroHUD/DDCBrightnessPacket.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void checksum(uint8_t reply[11]) {
    reply[10] = 0x50;
    for (unsigned i = 0; i < 10; i++) reply[10] ^= reply[i];
}

int main(void) {
    uint16_t current = 0, maximum = 0;
    uint8_t reply[11] = {0x6e, 0x88, 0x02, 0, 0x10, 0, 0x01, 0x2c, 0x01, 0x00, 0};
    checksum(reply);
    assert(RHDDCParseBrightness(reply, &current, &maximum));
    assert(maximum == 300 && current == 256);

    // Valid packet structure alone must not accept a different VCP code or unsupported status.
    const unsigned fields[] = {0, 1, 2, 3, 4, 5};
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        uint8_t invalid[11];
        memcpy(invalid, reply, sizeof(reply));
        invalid[fields[i]] ^= 1;
        checksum(invalid);
        assert(!RHDDCParseBrightness(invalid, &current, &maximum));
    }
    reply[10] ^= 1;
    assert(!RHDDCParseBrightness(reply, &current, &maximum));
    reply[6] = reply[7] = reply[8] = reply[9] = 0;
    checksum(reply);
    assert(!RHDDCParseBrightness(reply, &current, &maximum));
    reply[7] = 100;
    reply[9] = 101;
    checksum(reply);
    assert(!RHDDCParseBrightness(reply, &current, &maximum));
    reply[9] = 0;
    checksum(reply);
    assert(RHDDCParseBrightness(reply, &current, &maximum) && current == 0 && maximum == 100);
    reply[9] = 100;
    checksum(reply);
    assert(RHDDCParseBrightness(reply, &current, &maximum) && current == maximum);
    puts("DDC brightness response validation passed.");
    return 0;
}
