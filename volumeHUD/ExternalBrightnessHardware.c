// MIT License
// DDC transport and Apple Silicon registry discovery informed by MonitorControl:
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others.
// See ThirdPartyNotices.txt for the source revision and license.

#include "ExternalBrightnessHardware.h"
#include "DDCBrightnessPacket.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <dlfcn.h>
#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef bool (*VHCanChange)(CGDirectDisplayID);
typedef int (*VHGetBrightness)(CGDirectDisplayID, float *);
typedef int (*VHSetBrightness)(CGDirectDisplayID, float);
typedef CFDictionaryRef (*VHCopyDisplayInfo)(CGDirectDisplayID);
#if defined(__arm64__)
typedef CFTypeRef (*VHCreateAVService)(CFAllocatorRef, io_service_t);
typedef IOReturn (*VHAVI2C)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
static VHCreateAVService createAVService;
static VHAVI2C avRead, avWrite;
#endif
static VHCanChange canChange;
static VHGetBrightness getBrightness;
static VHSetBrightness setBrightness;
static VHCopyDisplayInfo copyDisplayInfo;
static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;

struct VHExternalBrightnessDevice {
    CGDirectDisplayID display;
    CFUUIDRef uuid;
    bool native;
    uint16_t maximum;
#if defined(__arm64__)
    CFTypeRef service;
#else
    io_service_t framebuffer;
#endif
};

static void VHLoadFunctions(void) {
    // Keep framework handles loaded for the lifetime of these function pointers.
    void *native = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    if (native) {
        canChange = (VHCanChange)dlsym(native, "DisplayServicesCanChangeBrightness");
        getBrightness = (VHGetBrightness)dlsym(native, "DisplayServicesGetBrightness");
        setBrightness = (VHSetBrightness)dlsym(native, "DisplayServicesSetBrightness");
    }
    void *core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
    if (core) copyDisplayInfo = (VHCopyDisplayInfo)dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary");
#if defined(__arm64__)
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (io) {
        createAVService = (VHCreateAVService)dlsym(io, "IOAVServiceCreateWithService");
        avRead = (VHAVI2C)dlsym(io, "IOAVServiceReadI2C");
        avWrite = (VHAVI2C)dlsym(io, "IOAVServiceWriteI2C");
    }
#endif
}

static bool VHIsSameDisplay(VHExternalBrightnessDevice *device) {
    if (!CGDisplayIsActive(device->display) || CGDisplayIsBuiltin(device->display)) return false;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(device->display);
    bool same = uuid && device->uuid && CFEqual(uuid, device->uuid);
    if (uuid) CFRelease(uuid);
    return same;
}

static CFStringRef VHDisplayLocation(CGDirectDisplayID display) {
    if (!copyDisplayInfo) return NULL;
    CFDictionaryRef info = copyDisplayInfo(display);
    if (!info) return NULL;
    CFTypeRef value = CFDictionaryGetValue(info, CFSTR(kIODisplayLocationKey));
    CFStringRef location = value && CFGetTypeID(value) == CFStringGetTypeID() ? CFRetain(value) : NULL;
    CFRelease(info);
    return location;
}

static bool VHUniqueIdentity(CGDirectDisplayID display) {
    CGDirectDisplayID displays[32];
    uint32_t count = 0, matches = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i]) &&
            CGDisplayVendorNumber(displays[i]) == CGDisplayVendorNumber(display) &&
            CGDisplayModelNumber(displays[i]) == CGDisplayModelNumber(display) &&
            CGDisplaySerialNumber(displays[i]) == CGDisplaySerialNumber(display)) matches++;
    }
    return matches == 1;
}

#if defined(__arm64__)
static bool VHFramebufferMatches(io_service_t entry, CGDirectDisplayID display, CFStringRef location) {
    io_string_t path = {0};
    if (location && IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS) {
        CFStringRef candidate = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
        bool exact = candidate && CFEqual(location, candidate);
        if (candidate) CFRelease(candidate);
        if (exact) return true;
    }
    // Identity fallback is permitted only when no identical display can be confused with it.
    if (!VHUniqueIdentity(display)) return false;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("EDID UUID"), NULL, 0);
    char uuid[128] = {0};
    bool valid = value && CFGetTypeID(value) == CFStringGetTypeID() &&
        CFStringGetCString(value, uuid, sizeof(uuid), kCFStringEncodingASCII);
    if (value) CFRelease(value);
    unsigned vendor = 0, productLow = 0, productHigh = 0;
    if (!valid || sscanf(uuid, "%4x%2x%2x", &vendor, &productLow, &productHigh) != 3 ||
        vendor != CGDisplayVendorNumber(display) || (productLow | (productHigh << 8)) != CGDisplayModelNumber(display)) return false;
    CFTypeRef attributes = IORegistryEntryCreateCFProperty(entry, CFSTR("DisplayAttributes"), NULL, 0);
    int64_t serial = 0;
    if (attributes && CFGetTypeID(attributes) == CFDictionaryGetTypeID()) {
        CFTypeRef product = CFDictionaryGetValue(attributes, CFSTR("ProductAttributes"));
        if (product && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
            CFTypeRef number = CFDictionaryGetValue(product, CFSTR("SerialNumber"));
            if (number && CFGetTypeID(number) == CFNumberGetTypeID()) CFNumberGetValue(number, kCFNumberSInt64Type, &serial);
        }
    }
    if (attributes) CFRelease(attributes);
    return (uint32_t)serial == CGDisplaySerialNumber(display);
}

static CFTypeRef VHFindAVService(CGDirectDisplayID display) {
    if (!createAVService || !avRead || !avWrite) return NULL;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (!root) return NULL;
    kern_return_t result = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(root);
    if (result != KERN_SUCCESS) return NULL;
    CFStringRef location = VHDisplayLocation(display);
    CFTypeRef found = NULL;
    unsigned matches = 0;
    bool framebufferMatches = false;
    io_service_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS) {
            if (strcmp(name, "AppleCLCD2") == 0 || strcmp(name, "IOMobileFramebufferShim") == 0) {
                framebufferMatches = VHFramebufferMatches(entry, display, location);
            } else if (strcmp(name, "DCPAVServiceProxy") == 0 && framebufferMatches) {
                CFTypeRef where = IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0);
                if (where && CFEqual(where, CFSTR("External"))) {
                    CFTypeRef service = createAVService(NULL, entry);
                    if (service) {
                        matches++;
                        if (found) CFRelease(found);
                        found = service;
                    }
                }
                if (where) CFRelease(where);
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    if (location) CFRelease(location);
    if (matches != 1 && found) { CFRelease(found); found = NULL; }
    return found;
}

static bool VHDDCRead(VHExternalBrightnessDevice *device, uint16_t *current) {
    // IOAVService read-request checksum differs on some paths. Try each form once.
    for (unsigned attempt = 0; attempt < 2; attempt++) {
        uint8_t request[4] = {0x82, 0x01, 0x10, 0};
        request[3] = 0x6e ^ request[0] ^ request[1] ^ request[2] ^ (attempt ? 0x51 : 0);
        uint8_t reply[11] = {0};
        if (avWrite(device->service, 0x37, 0x51, request, sizeof(request)) != KERN_SUCCESS) continue;
        usleep(50000);
        if (avRead(device->service, 0x37, 0, reply, sizeof(reply)) == KERN_SUCCESS &&
            VHDDCParseBrightness(reply, current, &device->maximum)) return true;
    }
    return false;
}

static bool VHDDCWrite(VHExternalBrightnessDevice *device, uint16_t value) {
    uint8_t request[6] = {0x84, 0x03, 0x10, (uint8_t)(value >> 8), (uint8_t)value, 0};
    request[5] = 0x6e ^ 0x51;
    for (unsigned i = 0; i < 5; i++) request[5] ^= request[i];
    usleep(10000);
    bool success = avWrite(device->service, 0x37, 0x51, request, sizeof(request)) == KERN_SUCCESS;
    if (success) usleep(50000); // Let Set VCP settle before a subsequent Get VCP.
    return success;
}
#else
static uint32_t VHNumber(CFDictionaryRef info, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(info, key);
    int64_t number = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &number);
    return (uint32_t)number;
}

static io_service_t VHFindFramebuffer(CGDirectDisplayID display) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) != KERN_SUCCESS) return IO_OBJECT_NULL;
    CFStringRef location = VHDisplayLocation(display);
    io_service_t found = IO_OBJECT_NULL, entry;
    unsigned matches = 0;
    while ((entry = IOIteratorNext(iterator))) {
        CFDictionaryRef info = IODisplayCreateInfoDictionary(entry, kIODisplayOnlyPreferredName);
        if (info) {
            CFTypeRef candidate = CFDictionaryGetValue(info, CFSTR(kIODisplayLocationKey));
            bool exact = location && candidate && CFEqual(location, candidate);
            bool identity = VHUniqueIdentity(display) &&
                VHNumber(info, CFSTR(kDisplayVendorID)) == CGDisplayVendorNumber(display) &&
                VHNumber(info, CFSTR(kDisplayProductID)) == CGDisplayModelNumber(display) &&
                VHNumber(info, CFSTR(kDisplaySerialNumber)) == CGDisplaySerialNumber(display);
            if (exact || identity) {
                matches++;
                if (found) IOObjectRelease(found);
                found = entry;
                IOObjectRetain(found);
            }
            CFRelease(info);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    if (location) CFRelease(location);
    if (matches != 1 && found) { IOObjectRelease(found); found = IO_OBJECT_NULL; }
    return found;
}

static bool VHSendI2C(VHExternalBrightnessDevice *device, uint8_t *send, uint32_t sendCount, uint8_t *reply) {
    IOItemCount count = 0;
    if (IOFBGetI2CInterfaceCount(device->framebuffer, &count) != KERN_SUCCESS) return false;
    for (IOOptionBits bus = 0; bus < count; bus++) {
        io_service_t interface = IO_OBJECT_NULL;
        if (IOFBCopyI2CInterfaceForBus(device->framebuffer, bus, &interface) != KERN_SUCCESS) continue;
        IOOptionBits replyType = kIOI2CDDCciReplyTransactionType;
        CFTypeRef types = IORegistryEntryCreateCFProperty(interface, CFSTR(kIOI2CTransactionTypesKey), NULL, 0);
        int64_t supportedTypes = 0;
        if (types && CFGetTypeID(types) == CFNumberGetTypeID() &&
            CFNumberGetValue(types, kCFNumberSInt64Type, &supportedTypes) &&
            !(supportedTypes & (1LL << kIOI2CDDCciReplyTransactionType)) &&
            (supportedTypes & (1LL << kIOI2CSimpleTransactionType))) replyType = kIOI2CSimpleTransactionType;
        if (types) CFRelease(types);
        IOI2CConnectRef connection = NULL;
        kern_return_t status = IOI2CInterfaceOpen(interface, 0, &connection);
        IOObjectRelease(interface);
        if (status != KERN_SUCCESS) continue;
        IOI2CRequest request = {0};
        request.sendAddress = 0x6e;
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.sendBuffer = (vm_address_t)send;
        request.sendBytes = sendCount;
        request.replyTransactionType = reply ? replyType : kIOI2CNoTransactionType;
        request.replyAddress = 0x6f;
        request.replySubAddress = 0x51;
        request.replyBuffer = (vm_address_t)reply;
        request.replyBytes = reply ? 11 : 0;
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        request.minReplyDelay = 50000000ULL * timebase.denom / timebase.numer; // 50 ms in absolute time units.
        status = IOI2CSendRequest(connection, 0, &request);
        IOI2CInterfaceClose(connection, 0);
        if (status == KERN_SUCCESS && request.result == KERN_SUCCESS) return true;
    }
    return false;
}

static bool VHDDCRead(VHExternalBrightnessDevice *device, uint16_t *current) {
    uint8_t send[5] = {0x51, 0x82, 0x01, 0x10, 0};
    send[4] = 0x6e ^ send[0] ^ send[1] ^ send[2] ^ send[3];
    uint8_t reply[11] = {0};
    return VHSendI2C(device, send, sizeof(send), reply) && VHDDCParseBrightness(reply, current, &device->maximum);
}

static bool VHDDCWrite(VHExternalBrightnessDevice *device, uint16_t value) {
    uint8_t send[7] = {0x51, 0x84, 0x03, 0x10, (uint8_t)(value >> 8), (uint8_t)value, 0};
    send[6] = 0x6e;
    for (unsigned i = 0; i < 6; i++) send[6] ^= send[i];
    usleep(10000);
    bool success = VHSendI2C(device, send, sizeof(send), NULL);
    if (success) usleep(50000);
    return success;
}
#endif

VHExternalBrightnessDevice *VHExternalBrightnessOpen(CGDirectDisplayID display) {
    pthread_once(&loadOnce, VHLoadFunctions);
    if (CGDisplayIsBuiltin(display) || !CGDisplayIsActive(display)) return NULL;
    VHExternalBrightnessDevice *device = calloc(1, sizeof(*device));
    if (!device) return NULL;
    device->display = display;
    device->uuid = CGDisplayCreateUUIDFromDisplayID(display);
    float current = 0;
    device->native = canChange && getBrightness && setBrightness && canChange(display);
    if (device->native && VHExternalBrightnessRead(device, &current)) return device;
    device->native = false;
#if defined(__arm64__)
    device->service = VHFindAVService(display);
    bool available = device->service != NULL;
#else
    device->framebuffer = VHFindFramebuffer(display);
    bool available = device->framebuffer != IO_OBJECT_NULL;
#endif
    if (available && VHExternalBrightnessRead(device, &current)) return device;
    VHExternalBrightnessClose(device);
    return NULL;
}

bool VHExternalBrightnessRead(VHExternalBrightnessDevice *device, float *value) {
    if (!VHIsSameDisplay(device)) return false;
    if (device->native) {
        return getBrightness(device->display, value) == 0 && isfinite(*value) && *value >= 0 && *value <= 1;
    }
    uint16_t current = 0;
    if (!VHDDCRead(device, &current)) return false;
    *value = (float)current / device->maximum;
    return true;
}

bool VHExternalBrightnessWrite(VHExternalBrightnessDevice *device, float value) {
    if (!VHIsSameDisplay(device) || !isfinite(value) || value < 0 || value > 1) return false;
    if (device->native) return setBrightness(device->display, value) == 0;
    if (!device->maximum) return false;
    return VHDDCWrite(device, (uint16_t)lroundf(value * device->maximum));
}

void VHExternalBrightnessClose(VHExternalBrightnessDevice *device) {
    if (!device) return;
    if (device->uuid) CFRelease(device->uuid);
#if defined(__arm64__)
    if (device->service) CFRelease(device->service);
#else
    if (device->framebuffer) IOObjectRelease(device->framebuffer);
#endif
    free(device);
}
