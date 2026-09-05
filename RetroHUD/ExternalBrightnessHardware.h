// Retro HUD by Patrick Bösch (2026)
// MIT License
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

// Opaque device, confined to the external brightness worker's serial queue.
typedef struct RHExternalBrightnessDevice RHExternalBrightnessDevice;
RHExternalBrightnessDevice * _Nullable RHExternalBrightnessOpen(CGDirectDisplayID display);
bool RHExternalBrightnessRead(RHExternalBrightnessDevice * _Nonnull device, float * _Nonnull value);
bool RHExternalBrightnessWrite(RHExternalBrightnessDevice * _Nonnull device, float value);
void RHExternalBrightnessClose(RHExternalBrightnessDevice * _Nullable device);
