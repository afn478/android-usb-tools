#import "MTPDevice.h"

#import <IOUSBHost/IOUSBHost.h>
#import <stdatomic.h>

NSErrorDomain const MTPErrorDomain = @"MTPErrorDomain";

enum {
    kContainerCommand = 1,
    kContainerData = 2,
    kContainerResponse = 3,
};

enum {
    kOpGetDeviceInfo = 0x1001,
    kOpOpenSession = 0x1002,
    kOpCloseSession = 0x1003,
    kOpGetStorageIDs = 0x1004,
    kOpGetStorageInfo = 0x1005,
    kOpGetObjectHandles = 0x1007,
    kOpGetObjectInfo = 0x1008,
    kOpGetPartialObject = 0x101B,
    kOpGetObjectPropValue = 0x9803,
    kOpGetObjectPropList = 0x9805,
    kOpAndroidGetPartialObject64 = 0x95C1,
};

enum {
    kRespOK = 0x2001,
    kRespOperationNotSupported = 0x2005,
    kRespSessionAlreadyOpen = 0x201E,
    kRespInvalidObjectPropCode = 0xA801,
    kRespSpecificationByDepthUnsupported = 0xA808,
};

enum {
    kPropObjectFormat = 0xDC02,
    kPropObjectSize = 0xDC04,
    kPropFileName = 0xDC07,
    kPropDateCreated = 0xDC08,
    kPropDateModified = 0xDC09,
};
enum { kHeaderLen = 12 };
// Largest single bulk read; a multiple of every USB max packet size.
static const NSUInteger kChunk = 1 << 20;
static const NSTimeInterval kTimeout = 15;

static NSError *mtp_error(NSInteger code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *mtp_error(NSInteger code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:MTPErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }
static uint16_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t get32(const uint8_t *p) { return get16(p) | (uint32_t)get16(p + 2) << 16; }

#pragma mark - Datasets

// Reads the little-endian PTP dataset encoding; out-of-range reads yield zeros
// and set `bad` instead of failing each call.
typedef struct {
    const uint8_t *p;
    size_t len, pos;
    bool bad;
} Reader;

static const uint8_t *take(Reader *r, size_t n) {
    if (r->pos + n > r->len) {
        r->bad = true;
        r->pos = r->len;
        return NULL;
    }
    const uint8_t *p = r->p + r->pos;
    r->pos += n;
    return p;
}

static uint8_t rd8(Reader *r) { const uint8_t *p = take(r, 1); return p ? p[0] : 0; }
static uint16_t rd16(Reader *r) { const uint8_t *p = take(r, 2); return p ? get16(p) : 0; }
static uint32_t rd32(Reader *r) { const uint8_t *p = take(r, 4); return p ? get32(p) : 0; }
static uint64_t rd64(Reader *r) { uint64_t lo = rd32(r); return lo | (uint64_t)rd32(r) << 32; }

// A count byte of UTF-16 code units including the terminating NUL.
static NSString *rdstr(Reader *r) {
    uint8_t n = rd8(r);
    if (!n) return @"";
    const uint8_t *p = take(r, n * 2u);
    if (!p) return @"";
    NSString *s = [[NSString alloc] initWithBytes:p length:(n - 1) * 2u encoding:NSUTF16LittleEndianStringEncoding];
    return s ?: @"";
}

static NSArray<NSNumber *> *rd16array(Reader *r) {
    uint32_t n = rd32(r);
    NSMutableArray *a = [NSMutableArray array];
    for (uint32_t i = 0; i < n && !r->bad; i++) [a addObject:@(rd16(r))];
    return a;
}

static NSArray<NSNumber *> *rd32array(Reader *r) {
    uint32_t n = rd32(r);
    NSMutableArray *a = [NSMutableArray array];
    for (uint32_t i = 0; i < n && !r->bad; i++) [a addObject:@(rd32(r))];
    return a;
}

// Reads one property value of a PTP data type; returns NO for types it can't size.
static BOOL rdvalue(Reader *r, uint16_t type, uint64_t *num, NSString **str) {
    if (type == 0xFFFF) {
        NSString *s = rdstr(r);
        if (str) *str = s;
        return YES;
    }
    if (type & 0x4000) {  // array: count, then elements
        uint32_t n = rd32(r);
        for (uint32_t i = 0; i < n && !r->bad; i++)
            if (!rdvalue(r, type & ~0x4000, NULL, NULL)) return NO;
        return YES;
    }
    static const uint8_t sizes[] = {0, 1, 1, 2, 2, 4, 4, 8, 8, 16, 16};
    if (type == 0 || type >= sizeof sizes) return NO;
    const uint8_t *p = take(r, sizes[type]);
    if (num && p) {
        uint64_t v = 0;
        for (int i = MIN(sizes[type], 8) - 1; i >= 0; i--) v = v << 8 | p[i];
        *num = v;
    }
    return YES;
}

// "YYYYMMDDThhmmss" with optional ".s" and zone; Android sends local time.
static NSDate *parse_date(NSString *s) {
    if (s.length < 15) return nil;
    NSDateComponents *c = [NSDateComponents new];
    const char *p = s.UTF8String;
    int y, mo, d, h, mi, se;
    if (sscanf(p, "%4d%2d%2dT%2d%2d%2d", &y, &mo, &d, &h, &mi, &se) != 6) return nil;
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = se;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    if ([s hasSuffix:@"Z"]) cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [cal dateFromComponents:c];
}

@implementation MTPDeviceInfo
- (BOOL)supportsOperation:(uint16_t)code { return [self.operationsSupported containsObject:@(code)]; }
@end

@implementation MTPStorageInfo
- (BOOL)isReadOnly { return self.accessCapability != 0; }
@end

@implementation MTPObjectInfo
- (BOOL)isDirectory { return self.format == MTPObjectFormatAssociation; }
@end

#pragma mark - Device

@implementation MTPDevice {
    IOUSBHostInterface *_iface;
    IOUSBHostPipe *_in, *_out;
    NSUInteger _inPacket;
    NSMutableData *_rx;
    uint32_t _tid;
    BOOL _sessionOpen;
    BOOL _noPropList;  // the phone can't list folders with GetObjectPropList
    NSLock *_lock;
    atomic_bool _gone;
}

static NSString *reg_string(io_service_t svc, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    id obj = CFBridgingRelease(v);
    return [obj isKindOfClass:[NSString class]] ? obj : nil;
}

static NSString *parent_string(io_service_t iface, const char *key) {
    io_registry_entry_t parent = 0;
    if (IORegistryEntryGetParentEntry(iface, kIOServicePlane, &parent) != KERN_SUCCESS) return nil;
    NSString *s = reg_string(parent, key);
    IOObjectRelease(parent);
    return s;
}

+ (NSArray<NSNumber *> *)copyInterfaceServices {
    // Android exposes MTP as a still-image class interface named "MTP" (PTP
    // mode uses the same class, named "PTP"); older phones use a vendor class.
    static const int classes[][3] = {{0x06, 0x01, 0x01}, {0xFF, 0xFF, 0x00}};
    NSMutableArray *found = [NSMutableArray array];
    for (size_t i = 0; i < sizeof classes / sizeof classes[0]; i++) {
        CFMutableDictionaryRef m = [IOUSBHostInterface
            createMatchingDictionaryWithVendorID:nil productID:nil bcdDevice:nil interfaceNumber:nil
                              configurationValue:nil interfaceClass:@(classes[i][0])
                               interfaceSubclass:@(classes[i][1]) interfaceProtocol:@(classes[i][2])
                                           speed:nil productIDArray:nil];
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) continue;
        io_service_t svc;
        while ((svc = IOIteratorNext(it))) {
            NSString *name = reg_string(svc, "kUSBString");
            if ([name isEqualToString:@"MTP"])
                [found addObject:@(svc)];
            else
                IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    return found;
}

+ (NSString *)serialForInterfaceService:(io_service_t)service {
    return parent_string(service, "kUSBSerialNumberString");
}

+ (NSString *)productNameForInterfaceService:(io_service_t)service {
    return parent_string(service, "kUSBProductString");
}

static IOUSBHostPipe *find_pipe(IOUSBHostInterface *iface, int xferType, bool in, NSUInteger *maxPacket) {
    const IOUSBConfigurationDescriptor *cfg = iface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = iface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep))) {
        if ((ep->bmAttributes & 0x03) != xferType || !!(ep->bEndpointAddress & 0x80) != in) continue;
        if (maxPacket) *maxPacket = ep->wMaxPacketSize & 0x7ff;
        return [iface copyPipeWithAddress:ep->bEndpointAddress error:nil];
    }
    return nil;
}

- (instancetype)initWithService:(io_service_t)service error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _lock = [NSLock new];
    dispatch_queue_t q = dispatch_queue_create("mtp.interest", DISPATCH_QUEUE_SERIAL);
    __weak MTPDevice *weakSelf = self;
    IOUSBHostInterestHandler interest = ^(IOUSBHostObject *obj, uint32_t type, void *arg) {
        MTPDevice *s = weakSelf;
        if (s && type == kIOMessageServiceIsTerminated) atomic_store(&s->_gone, true);
    };
    NSError *err = nil;
    _iface = [[IOUSBHostInterface alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsNone
                                                     queue:q error:&err interestHandler:interest];
    if (!_iface) {
        // Something else (Image Capture's ptpcamerad, usually) holds the
        // interface; ask it to let go.
        err = nil;
        _iface = [[IOUSBHostInterface alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsDeviceSeize
                                                         queue:q error:&err interestHandler:interest];
    }
    if (!_iface) {
        if (error) *error = mtp_error(1, @"cannot claim the MTP interface: %@", err.localizedDescription);
        return nil;
    }
    _in = find_pipe(_iface, kIOUSBEndpointTypeBulk, true, &_inPacket);
    _out = find_pipe(_iface, kIOUSBEndpointTypeBulk, false, NULL);
    if (!_in || !_out || !_inPacket) {
        if (error) *error = mtp_error(2, @"MTP interface has no bulk endpoints");
        [self close];
        return nil;
    }
    _rx = [NSMutableData dataWithLength:kChunk];
    // A client that went away mid-transaction leaves the phone waiting to send
    // its reply; reset its MTP state before starting over.
    [self resetDevice];
    if (![self openSession:error]) {
        [self close];
        return nil;
    }
    _deviceInfo = [self fetchDeviceInfo:error];
    if (!_deviceInfo) {
        [self close];
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    [_lock lock];
    if (_sessionOpen && !atomic_load(&_gone)) [self transact:kOpCloseSession params:NULL count:0 data:nil response:NULL error:nil];
    _sessionOpen = NO;
    [_in abortWithError:nil];
    [_out abortWithError:nil];
    _in = _out = nil;
    [_iface destroy];
    _iface = nil;
    [_lock unlock];
}

- (BOOL)disconnected {
    return atomic_load(&_gone);
}

#pragma mark Transport

// Still Image class Device Reset request, then whatever is left in the pipes.
- (void)resetDevice {
    IOUSBDeviceRequest req = {
        .bmRequestType = 0x21,  // class, interface, host to device
        .bRequest = 0x66,
        .wValue = 0,
        .wIndex = _iface.interfaceDescriptor->bInterfaceNumber,
        .wLength = 0,
    };
    NSUInteger n = 0;
    [_iface sendDeviceRequest:req data:nil bytesTransferred:&n completionTimeout:2 error:nil];
    [_in clearStallWithError:nil];
    [_out clearStallWithError:nil];
    _rx.length = kChunk;
    while ([_in sendIORequestWithData:_rx bytesTransferred:&n completionTimeout:0.2 error:nil] && n) {
    }
}

- (BOOL)bulkIn:(NSMutableData *)buf length:(NSUInteger)len got:(NSUInteger *)got error:(NSError **)error {
    buf.length = len;
    NSError *err = nil;
    NSUInteger n = 0;
    if (![_in sendIORequestWithData:buf bytesTransferred:&n completionTimeout:kTimeout error:&err]) {
        if (error) *error = mtp_error(3, @"USB read: %@", err.localizedDescription);
        return NO;
    }
    *got = n;
    return YES;
}

- (BOOL)bulkOut:(NSData *)data error:(NSError **)error {
    NSError *err = nil;
    NSUInteger n = 0;
    NSMutableData *buf = [data mutableCopy];
    if (![_out sendIORequestWithData:buf bytesTransferred:&n completionTimeout:kTimeout error:&err] || n != data.length) {
        if (error) *error = mtp_error(3, @"USB write: %@", err.localizedDescription);
        return NO;
    }
    return YES;
}

// One transaction without a host-to-device data phase. Data the phone sends
// is appended to `data`; response parameters land in `resp` (up to 5).
- (BOOL)transact:(uint16_t)code params:(const uint32_t *)params count:(int)count
            data:(NSMutableData *)data response:(uint32_t *)resp error:(NSError **)error {
    if (atomic_load(&_gone)) {
        if (error) *error = mtp_error(ENXIO, @"phone disconnected");
        return NO;
    }
    uint32_t tid = code == kOpOpenSession ? 0 : _tid++;
    uint8_t cmd[kHeaderLen + 5 * 4];
    size_t cmdLen = kHeaderLen + 4 * (size_t)count;
    put32(cmd, (uint32_t)cmdLen);
    put16(cmd + 4, kContainerCommand);
    put16(cmd + 6, code);
    put32(cmd + 8, tid);
    for (int i = 0; i < count; i++) put32(cmd + kHeaderLen + 4 * i, params[i]);
    if (![self bulkOut:[NSData dataWithBytes:cmd length:cmdLen] error:error]) return NO;

    NSUInteger n = 0;
    if (![self bulkIn:_rx length:kChunk got:&n error:error]) return NO;
    const uint8_t *p = _rx.bytes;
    if (n < kHeaderLen) {
        if (error) *error = mtp_error(4, @"short MTP container (%lu bytes)", (unsigned long)n);
        return NO;
    }

    // The response container, once we have it, in `resp`/`respLen`.
    NSData *response = nil;
    if (get16(p + 4) == kContainerData) {
        uint32_t total = get32(p);
        bool unknown = total == 0xFFFFFFFF;
        NSUInteger received = n;
        NSUInteger keep = unknown ? n : MIN(n, total);
        [data appendBytes:p + kHeaderLen length:keep - kHeaderLen];
        if (!unknown && n > total) response = [_rx subdataWithRange:NSMakeRange(total, n - total)];
        bool lastFull = n == kChunk;
        while (!response && (unknown ? lastFull : received < total)) {
            NSUInteger want = kChunk;
            if (!unknown) {
                NSUInteger left = total - received;
                want = MIN(kChunk, (left + _inPacket - 1) / _inPacket * _inPacket);
            }
            if (![self bulkIn:_rx length:want got:&n error:error]) return NO;
            p = _rx.bytes;
            keep = unknown ? n : MIN(n, total - received);
            [data appendBytes:p length:keep];
            if (!unknown && n > keep) response = [_rx subdataWithRange:NSMakeRange(keep, n - keep)];
            received += n;
            lastFull = n == want;
            if (n < want && !unknown && received < total) {
                if (error) *error = mtp_error(4, @"MTP data ended early (%lu of %u bytes)", (unsigned long)received, total);
                return NO;
            }
        }
        // A container that fills its last packet is followed by a zero-length
        // packet. Some stacks skip it and send the response directly.
        if (!response && !unknown && total % _inPacket == 0) {
            if (![self bulkIn:_rx length:kChunk got:&n error:error]) return NO;
            if (n) response = [_rx subdataWithRange:NSMakeRange(0, n)];
        }
        if (!response) {
            if (![self bulkIn:_rx length:kChunk got:&n error:error]) return NO;
            response = [_rx subdataWithRange:NSMakeRange(0, n)];
        }
    } else {
        response = [_rx subdataWithRange:NSMakeRange(0, n)];
    }

    p = response.bytes;
    if (response.length < kHeaderLen || get16(p + 4) != kContainerResponse) {
        if (error) *error = mtp_error(4, @"expected an MTP response container");
        return NO;
    }
    if (code != kOpOpenSession && get32(p + 8) != tid) {
        if (error) *error = mtp_error(4, @"MTP transaction ID mismatch (%u, want %u)", get32(p + 8), tid);
        return NO;
    }
    uint16_t rc = get16(p + 6);
    if (resp) {
        size_t np = MIN((MIN(get32(p), response.length) - kHeaderLen) / 4, 5u);
        for (size_t i = 0; i < np; i++) resp[i] = get32(p + kHeaderLen + 4 * i);
    }
    if (rc != kRespOK) {
        if (error) *error = mtp_error(rc, @"MTP operation 0x%04x failed with 0x%04x", code, rc);
        return NO;
    }
    return YES;
}

- (BOOL)run:(uint16_t)code params:(const uint32_t *)params count:(int)count
       data:(NSMutableData *)data error:(NSError **)error {
    [_lock lock];
    BOOL ok = [self transact:code params:params count:count data:data response:NULL error:error];
    [_lock unlock];
    return ok;
}

- (BOOL)openSession:(NSError **)error {
    uint32_t sid = 1;
    NSError *err = nil;
    if (![self transact:kOpOpenSession params:&sid count:1 data:nil response:NULL error:&err]) {
        if (err.code != kRespSessionAlreadyOpen) {
            if (error) *error = err;
            return NO;
        }
        // Left open by an earlier client; Android accepts closing it as is.
        _tid = 0;
        [self transact:kOpCloseSession params:NULL count:0 data:nil response:NULL error:nil];
        if (![self transact:kOpOpenSession params:&sid count:1 data:nil response:NULL error:error]) return NO;
    }
    _tid = 1;
    _sessionOpen = YES;
    return YES;
}

#pragma mark Operations

- (MTPDeviceInfo *)fetchDeviceInfo:(NSError **)error {
    NSMutableData *d = [NSMutableData data];
    if (![self run:kOpGetDeviceInfo params:NULL count:0 data:d error:error]) return nil;
    Reader r = {d.bytes, d.length, 0, false};
    MTPDeviceInfo *info = [MTPDeviceInfo new];
    rd16(&r);  // standard version
    rd32(&r);  // vendor extension ID
    rd16(&r);  // vendor extension version
    info.vendorExtension = rdstr(&r);
    rd16(&r);  // functional mode
    info.operationsSupported = rd16array(&r);
    rd16array(&r);  // events
    rd16array(&r);  // device properties
    rd16array(&r);  // capture formats
    rd16array(&r);  // playback formats
    info.manufacturer = rdstr(&r);
    info.model = rdstr(&r);
    info.deviceVersion = rdstr(&r);
    info.serialNumber = rdstr(&r);
    if (r.bad) {
        if (error) *error = mtp_error(5, @"malformed DeviceInfo");
        return nil;
    }
    return info;
}

- (NSArray<NSNumber *> *)storageIDs:(NSError **)error {
    NSMutableData *d = [NSMutableData data];
    if (![self run:kOpGetStorageIDs params:NULL count:0 data:d error:error]) return nil;
    Reader r = {d.bytes, d.length, 0, false};
    NSArray *ids = rd32array(&r);
    // Android reports storages it hasn't mounted yet with a zero low half.
    return [ids filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *n, id b) {
                    return (n.unsignedIntValue & 0xFFFF) != 0;
                }]];
}

- (MTPStorageInfo *)storageInfo:(uint32_t)storageID error:(NSError **)error {
    NSMutableData *d = [NSMutableData data];
    if (![self run:kOpGetStorageInfo params:&storageID count:1 data:d error:error]) return nil;
    Reader r = {d.bytes, d.length, 0, false};
    MTPStorageInfo *s = [MTPStorageInfo new];
    s.storageID = storageID;
    s.storageType = rd16(&r);
    s.filesystemType = rd16(&r);
    s.accessCapability = rd16(&r);
    s.maxCapacity = rd64(&r);
    s.freeSpace = rd64(&r);
    rd32(&r);  // free space in objects
    s.storageDescription = rdstr(&r);
    s.volumeLabel = rdstr(&r);
    if (r.bad) {
        if (error) *error = mtp_error(5, @"malformed StorageInfo");
        return nil;
    }
    return s;
}

- (NSArray<NSNumber *> *)objectHandlesInStorage:(uint32_t)storageID parent:(uint32_t)parent error:(NSError **)error {
    uint32_t params[3] = {storageID, 0, parent};
    NSMutableData *d = [NSMutableData data];
    if (![self run:kOpGetObjectHandles params:params count:3 data:d error:error]) return nil;
    Reader r = {d.bytes, d.length, 0, false};
    return rd32array(&r);
}

- (MTPObjectInfo *)objectInfo:(uint32_t)handle error:(NSError **)error {
    NSMutableData *d = [NSMutableData data];
    if (![self run:kOpGetObjectInfo params:&handle count:1 data:d error:error]) return nil;
    Reader r = {d.bytes, d.length, 0, false};
    MTPObjectInfo *o = [MTPObjectInfo new];
    o.handle = handle;
    o.storageID = rd32(&r);
    o.format = rd16(&r);
    rd16(&r);  // protection status
    uint32_t size32 = rd32(&r);
    rd16(&r);  // thumb format
    for (int i = 0; i < 6; i++) rd32(&r);  // thumb size and dimensions, image dimensions, bit depth
    o.parent = rd32(&r);
    rd16(&r);  // association type
    rd32(&r);  // association description
    rd32(&r);  // sequence number
    o.filename = rdstr(&r);
    o.created = parse_date(rdstr(&r));
    o.modified = parse_date(rdstr(&r));
    if (r.bad) {
        if (error) *error = mtp_error(5, @"malformed ObjectInfo");
        return nil;
    }
    o.size = size32;
    if (size32 == 0xFFFFFFFF) {
        // Over 4 GiB: the 32-bit field saturates; ask for the 64-bit property.
        uint32_t params[2] = {handle, kPropObjectSize};
        NSMutableData *v = [NSMutableData data];
        if ([self run:kOpGetObjectPropValue params:params count:2 data:v error:nil] && v.length >= 8) {
            Reader vr = {v.bytes, v.length, 0, false};
            o.size = rd64(&vr);
        }
    }
    return o;
}

- (NSArray<MTPObjectInfo *> *)objectsInStorage:(uint32_t)storageID parent:(uint32_t)parent error:(NSError **)error {
    // A GetObjectPropList for the whole folder (depth 1) beats an ObjectInfo
    // round trip per entry: 1 s instead of 11 s for 6,000 photos. Android
    // rejects "all properties", so ask for the few we use one at a time.
    if (parent != MTPRootParent && !_noPropList && [_deviceInfo supportsOperation:kOpGetObjectPropList]) {
        static const uint16_t props[] = {kPropFileName, kPropObjectFormat, kPropObjectSize, kPropDateModified};
        NSMutableDictionary<NSNumber *, MTPObjectInfo *> *byHandle = [NSMutableDictionary dictionary];
        NSMutableArray<MTPObjectInfo *> *order = [NSMutableArray array];
        BOOL ok = YES;
        for (size_t i = 0; ok && i < sizeof props / sizeof props[0]; i++) {
            uint32_t params[5] = {parent, 0, props[i], 0, 1};
            NSMutableData *d = [NSMutableData data];
            NSError *err = nil;
            ok = [self run:kOpGetObjectPropList params:params count:5 data:d error:&err] &&
                 [self decodePropList:d into:byHandle order:order];
            if (!ok && err.code != kRespInvalidObjectPropCode && err.code != kRespOperationNotSupported &&
                err.code != kRespSpecificationByDepthUnsupported) {
                // A real failure (the folder vanished, the phone went away), not a capability gap.
                if (error) *error = err;
                return nil;
            }
        }
        if (ok) {
            NSMutableArray *out = [NSMutableArray arrayWithCapacity:order.count];
            for (MTPObjectInfo *o in order) {
                if (o.handle == parent || !o.filename) continue;  // depth 1 includes the folder itself
                o.storageID = storageID;
                o.parent = parent;
                [out addObject:o];
            }
            return out;
        }
        _noPropList = YES;
    }
    NSArray *handles = [self objectHandlesInStorage:storageID parent:parent error:error];
    if (!handles) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:handles.count];
    for (NSNumber *h in handles) {
        MTPObjectInfo *o = [self objectInfo:h.unsignedIntValue error:error];
        if (!o) return nil;
        [out addObject:o];
    }
    return out;
}

- (BOOL)decodePropList:(NSData *)d
                  into:(NSMutableDictionary<NSNumber *, MTPObjectInfo *> *)byHandle
                 order:(NSMutableArray<MTPObjectInfo *> *)order {
    Reader r = {d.bytes, d.length, 0, false};
    uint32_t n = rd32(&r);
    for (uint32_t i = 0; i < n && !r.bad; i++) {
        uint32_t handle = rd32(&r);
        uint16_t prop = rd16(&r), type = rd16(&r);
        uint64_t num = 0;
        NSString *str = nil;
        if (!rdvalue(&r, type, &num, &str)) return NO;
        MTPObjectInfo *o = byHandle[@(handle)];
        if (!o) {
            o = [MTPObjectInfo new];
            o.handle = handle;
            byHandle[@(handle)] = o;
            [order addObject:o];
        }
        switch (prop) {
            case kPropObjectFormat: o.format = (uint16_t)num; break;
            case kPropObjectSize: o.size = num; break;
            case kPropFileName: o.filename = str; break;
            case kPropDateCreated: o.created = parse_date(str); break;
            case kPropDateModified: o.modified = parse_date(str); break;
        }
    }
    return !r.bad;
}

- (NSData *)readObject:(uint32_t)handle offset:(uint64_t)offset length:(uint32_t)length error:(NSError **)error {
    NSMutableData *d = [NSMutableData dataWithCapacity:length];
    if ([_deviceInfo supportsOperation:kOpAndroidGetPartialObject64]) {
        uint32_t params[4] = {handle, (uint32_t)offset, (uint32_t)(offset >> 32), length};
        if (![self run:kOpAndroidGetPartialObject64 params:params count:4 data:d error:error]) return nil;
    } else {
        if (offset > UINT32_MAX) {
            if (error) *error = mtp_error(EFBIG, @"phone cannot read past 4 GiB");
            return nil;
        }
        uint32_t params[3] = {handle, (uint32_t)offset, length};
        if (![self run:kOpGetPartialObject params:params count:3 data:d error:error]) return nil;
    }
    return d;
}

@end
