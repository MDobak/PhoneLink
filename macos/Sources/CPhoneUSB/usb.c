#include "CPhoneUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

typedef IOUSBDeviceInterface650 **Dev;
typedef IOUSBInterfaceInterface650 **Intf;

// MARK: - Registry

static io_service_t service_for(uint64_t entry) {
    CFMutableDictionaryRef m = IORegistryEntryIDMatching(entry);
    return m ? IOServiceGetMatchingService(kIOMainPortDefault, m) : 0; // Consumes m.
}

static int int_prop(io_service_t s, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
    CFRelease(k);
    int out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &out);
    if (v) CFRelease(v);
    return out;
}

static void str_prop(io_service_t s, const char *key, char *buf, size_t n) {
    buf[0] = 0;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
    CFRelease(k);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, buf, (CFIndex)n, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

static void describe(io_service_t s, int added, pu_device *d) {
    memset(d, 0, sizeof *d);
    d->added = added;
    IORegistryEntryGetRegistryEntryID(s, &d->entry);
    d->vid = (uint16_t)int_prop(s, "idVendor");
    d->pid = (uint16_t)int_prop(s, "idProduct");
    d->location = (uint32_t)int_prop(s, "locationID");
    str_prop(s, "USB Serial Number", d->serial, sizeof d->serial);
    if (!d->serial[0]) str_prop(s, "kUSBSerialNumberString", d->serial, sizeof d->serial);
    str_prop(s, "USB Product Name", d->product, sizeof d->product);
    if (!d->product[0]) str_prop(s, "kUSBProductString", d->product, sizeof d->product);
}

// MARK: - Notifications

typedef struct {
    pu_callback cb;
    void *ctx;
    int added;
} watcher;

static void drain(void *refcon, io_iterator_t it) {
    watcher *w = refcon;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        pu_device d;
        describe(s, w->added, &d);
        w->cb(w->ctx, &d);
        IOObjectRelease(s);
    }
}

int pu_watch(dispatch_queue_t q, pu_callback cb, void *ctx) {
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) return kIOReturnError;
    IONotificationPortSetDispatchQueue(port, q);
    watcher *add = calloc(1, sizeof *add), *rem = calloc(1, sizeof *rem);
    *add = (watcher){cb, ctx, 1};
    *rem = (watcher){cb, ctx, 0};
    io_iterator_t a = 0, r = 0;
    kern_return_t kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), drain, add, &a);
    if (!kr) kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), drain, rem, &r);
    if (kr) {
        if (a) IOObjectRelease(a);
        IONotificationPortDestroy(port);
        free(add);
        free(rem);
        return kr;
    }
    // Arm the notifications and report the devices that are attached now. The port and iterators live as long as the app.
    dispatch_async(q, ^{ drain(add, a); drain(rem, r); });
    return 0;
}

// MARK: - Device

static Dev open_dev(uint64_t entry, kern_return_t *err) {
    io_service_t s = service_for(entry);
    if (!s) { *err = kIOReturnNoDevice; return NULL; }
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(s);
    if (kr || !plug) { *err = kr ? kr : kIOReturnError; return NULL; }
    Dev dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plug);
    if (hr || !dev) { *err = kIOReturnUnsupported; return NULL; }
    *err = 0;
    return dev;
}

static kern_return_t vendor_request(Dev dev, int in, uint8_t req, uint16_t index, void *data, uint16_t len) {
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = USBmakebmRequestType(in ? kUSBIn : kUSBOut, kUSBVendor, kUSBDevice);
    r.bRequest = req;
    r.wValue = 0;
    r.wIndex = index;
    r.wLength = len;
    r.pData = data;
    r.noDataTimeout = 1000;
    r.completionTimeout = 2000;
    kern_return_t kr = (*dev)->DeviceRequestTO(dev, &r);
    if (kr == kIOReturnNotOpen) {
        // Some systems need the device open for requests on the default pipe.
        if ((*dev)->USBDeviceOpen(dev) == 0) {
            kr = (*dev)->DeviceRequestTO(dev, &r);
            (*dev)->USBDeviceClose(dev);
        }
    }
    return kr;
}

int pu_aoa_protocol(uint64_t entry) {
    kern_return_t kr;
    Dev dev = open_dev(entry, &kr);
    if (!dev) return -1;
    uint8_t v[2] = {0};
    kr = vendor_request(dev, 1, 51, 0, v, 2);
    (*dev)->Release(dev);
    if (kr) return -1;
    int version = v[0] | v[1] << 8;
    return version > 0 ? version : -1;
}

int pu_aoa_start(uint64_t entry, const char *const strings[6]) {
    kern_return_t kr;
    Dev dev = open_dev(entry, &kr);
    if (!dev) return kr;
    for (uint16_t i = 0; i < 6 && !kr; i++) {
        const char *s = strings[i] ? strings[i] : "";
        kr = vendor_request(dev, 0, 52, i, (void *)s, (uint16_t)(strlen(s) + 1));
    }
    if (!kr) kr = vendor_request(dev, 0, 53, 0, NULL, 0);
    (*dev)->Release(dev);
    return kr;
}

int pu_reenumerate(uint64_t entry) {
    kern_return_t kr;
    Dev dev = open_dev(entry, &kr);
    if (!dev) return kr;
    kr = (*dev)->USBDeviceReEnumerate(dev, 0);
    if (kr == kIOReturnNotOpen && (*dev)->USBDeviceOpen(dev) == 0) {
        kr = (*dev)->USBDeviceReEnumerate(dev, 0);
        (*dev)->USBDeviceClose(dev);
    }
    (*dev)->Release(dev);
    return kr;
}

// MARK: - Stream

struct pu_stream {
    Intf intf;
    UInt8 in, out;
    UInt16 maxPacket;
};

pu_stream *pu_open(uint64_t entry, int *err) {
    kern_return_t kr;
    Dev dev = open_dev(entry, &kr);
    if (!dev) { *err = kr; return NULL; }
    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it = 0;
    kr = (*dev)->CreateInterfaceIterator(dev, &req, &it);
    (*dev)->Release(dev);
    if (kr) { *err = kr; return NULL; }
    Intf found = NULL;
    io_service_t s;
    while (!found && (s = IOIteratorNext(it))) {
        IOCFPlugInInterface **plug = NULL;
        SInt32 score;
        if (IOCreatePlugInInterfaceForService(s, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) == 0 && plug) {
            Intf intf = NULL;
            (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID650), (LPVOID *)&intf);
            IODestroyPlugInInterface(plug);
            UInt8 num = 255;
            if (intf && (*intf)->GetInterfaceNumber(intf, &num) == 0 && num == 0) found = intf;
            else if (intf) (*intf)->Release(intf);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) { *err = kIOReturnNotFound; return NULL; }
    kr = (*found)->USBInterfaceOpen(found);
    if (kr) { (*found)->Release(found); *err = kr; return NULL; }
    pu_stream *st = calloc(1, sizeof *st);
    st->intf = found;
    UInt8 n = 0;
    (*found)->GetNumEndpoints(found, &n);
    for (UInt8 i = 1; i <= n; i++) {
        UInt8 dir, number, type, interval;
        UInt16 maxPacket;
        if ((*found)->GetPipeProperties(found, i, &dir, &number, &type, &maxPacket, &interval)) continue;
        if (type != kUSBBulk) continue;
        if (dir == kUSBIn && !st->in) st->in = i;
        if (dir == kUSBOut && !st->out) { st->out = i; st->maxPacket = maxPacket; }
    }
    if (!st->in || !st->out) { pu_close(st); *err = kIOReturnNotFound; return NULL; }
    *err = 0;
    return st;
}

int pu_read(pu_stream *s, void *buf, uint32_t cap, uint32_t *got) {
    UInt32 size = cap;
    kern_return_t kr = (*s->intf)->ReadPipe(s->intf, s->in, buf, &size);
    *got = kr ? 0 : size;
    return kr;
}

int pu_write(pu_stream *s, const void *buf, uint32_t len) {
    kern_return_t kr = (*s->intf)->WritePipe(s->intf, s->out, (void *)buf, len);
    // A transfer that fills its last packet needs a zero-length packet, or the phone waits for more data.
    if (!kr && len && s->maxPacket && len % s->maxPacket == 0) kr = (*s->intf)->WritePipe(s->intf, s->out, (void *)buf, 0);
    return kr;
}

void pu_abort(pu_stream *s) {
    (*s->intf)->AbortPipe(s->intf, s->in);
    (*s->intf)->AbortPipe(s->intf, s->out);
}

void pu_close(pu_stream *s) {
    if (!s) return;
    (*s->intf)->USBInterfaceClose(s->intf);
    (*s->intf)->Release(s->intf);
    free(s);
}
