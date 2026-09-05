// MIT License
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

// Opaque device, confined to the external brightness worker's serial queue.
typedef struct VHExternalBrightnessDevice VHExternalBrightnessDevice;
VHExternalBrightnessDevice * _Nullable VHExternalBrightnessOpen(CGDirectDisplayID display);
bool VHExternalBrightnessRead(VHExternalBrightnessDevice * _Nonnull device, float * _Nonnull value);
bool VHExternalBrightnessWrite(VHExternalBrightnessDevice * _Nonnull device, float value);
void VHExternalBrightnessClose(VHExternalBrightnessDevice * _Nullable device);
