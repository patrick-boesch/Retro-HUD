// MIT License. DDC/CI VCP 0x10 (luminance) only.
#pragma once
#include <stdbool.h>
#include <stdint.h>

static inline bool VHDDCParseBrightness(const uint8_t reply[11], uint16_t *current, uint16_t *maximum) {
    uint8_t checksum = 0x50;
    for (unsigned i = 0; i < 10; i++) checksum ^= reply[i];
    if (reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 0x02 ||
        reply[3] != 0 || reply[4] != 0x10 || reply[5] != 0 || checksum != reply[10]) return false;
    // Widen BEFORE shifting; brightness maxima need not be 100 or fit in a byte.
    *maximum = ((uint16_t)reply[6] << 8) | reply[7];
    *current = ((uint16_t)reply[8] << 8) | reply[9];
    return *maximum > 0 && *current <= *maximum;
}
