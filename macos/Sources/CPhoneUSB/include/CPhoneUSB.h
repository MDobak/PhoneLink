#ifndef CPHONEUSB_H
#define CPHONEUSB_H

// USB access to Android phones through IOKit: device notifications, the Android Open Accessory (AOA) switch, and a
// byte stream over the bulk endpoints of the accessory interface.

#include <dispatch/dispatch.h>
#include <stdint.h>

typedef struct {
    int added;           // 1: added, 0: removed
    uint16_t vid, pid;
    uint64_t entry;      // IORegistry entry ID. Use it as the handle in the other functions.
    uint32_t location;
    char serial[128];
    char product[128];
} pu_device;

typedef void (*pu_callback)(void *ctx, const pu_device *d);

/// Reports the devices that are attached now, then each change. Calls cb on q. Returns 0 or an IOReturn code.
int pu_watch(dispatch_queue_t q, pu_callback cb, void *ctx);

/// The AOA protocol version (1 or 2), or a negative value if the device does not support AOA.
int pu_aoa_protocol(uint64_t entry);
/// Sends the 6 identification strings, then starts accessory mode. Returns 0 or an IOReturn code.
int pu_aoa_start(uint64_t entry, const char *const strings[6]);
/// Disconnects and connects the device again in software. Returns 0 or an IOReturn code.
int pu_reenumerate(uint64_t entry);

typedef struct pu_stream pu_stream;
/// Opens interface 0 of a device in accessory mode. Returns NULL on failure (err gets the code).
pu_stream *pu_open(uint64_t entry, int *err);
/// Blocks until data comes. Returns 0 or an IOReturn code.
int pu_read(pu_stream *s, void *buf, uint32_t cap, uint32_t *got);
/// Blocks until the device took the data. Returns 0 or an IOReturn code.
int pu_write(pu_stream *s, const void *buf, uint32_t len);
/// Stops a blocked pu_read or pu_write. Safe from any thread.
void pu_abort(pu_stream *s);
void pu_close(pu_stream *s);

#endif
