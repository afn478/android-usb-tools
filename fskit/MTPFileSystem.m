#import "MTPFileSystem.h"

#import <os/log.h>

#import "MTPDevice.h"
#import "MTPVolume.h"

static os_log_t fslog;

@implementation MTPFileSystem {
    MTPVolume *_volume;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    fslog = os_log_create("io.github.afn478.AndroidUSBTools.mtpfs", "fs");
    return self;
}

static NSString *serial_from_resource(FSResource *resource) {
    if (![resource isKindOfClass:[FSGenericURLResource class]]) return nil;
    NSURL *url = ((FSGenericURLResource *)resource).url;
    if ([url.scheme caseInsensitiveCompare:@"mtp"] != NSOrderedSame) return nil;
    return url.host.length ? url.host : nil;
}

// Finds the MTP interface of the phone with this serial; the caller releases it.
static io_service_t find_interface(NSString *serial, NSString **product) {
    io_service_t match = 0;
    for (NSNumber *n in [MTPDevice copyInterfaceServices]) {
        io_service_t svc = n.unsignedIntValue;
        if (!match && [[MTPDevice serialForInterfaceService:svc] isEqualToString:serial]) {
            match = svc;
            if (product) *product = [MTPDevice productNameForInterfaceService:svc];
        } else {
            IOObjectRelease(svc);
        }
    }
    return match;
}

static FSContainerIdentifier *container_id(NSString *serial) {
    uint8_t uuid[16] = {0};
    NSData *s = [serial dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger i = 0; i < s.length; i++) uuid[(i + 7) % 16] ^= ((const uint8_t *)s.bytes)[i];
    uuid[6] = (uuid[6] & 0x0F) | 0x80;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;
    return [[FSContainerIdentifier alloc] initWithUUID:[[NSUUID alloc] initWithUUIDBytes:uuid]];
}

- (void)probeResource:(FSResource *)resource replyHandler:(void (^)(FSProbeResult *, NSError *))reply {
    NSString *serial = serial_from_resource(resource);
    NSString *product = nil;
    io_service_t svc = serial ? find_interface(serial, &product) : 0;
    os_log(fslog, "probe %{public}@: %{public}s", serial, svc ? "found" : "not found");
    if (!svc) return reply(FSProbeResult.notRecognizedProbeResult, nil);
    IOObjectRelease(svc);
    reply([FSProbeResult usableProbeResultWithName:product ?: @"Android" containerID:container_id(serial)], nil);
}

- (void)loadResource:(FSResource *)resource
             options:(FSTaskOptions *)options
        replyHandler:(void (^)(FSVolume *, NSError *))reply {
    NSString *serial = serial_from_resource(resource);
    NSString *product = nil;
    io_service_t svc = serial ? find_interface(serial, &product) : 0;
    if (!svc) {
        self.containerStatus = [FSContainerStatus notReadyWithStatus:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENODEV userInfo:nil]];
        return reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENODEV userInfo:nil]);
    }
    NSError *err = nil;
    MTPDevice *device = [[MTPDevice alloc] initWithService:svc error:&err];
    IOObjectRelease(svc);
    if (!device) {
        os_log_error(fslog, "open %{public}@: %{public}@", serial, err.localizedDescription);
        self.containerStatus = [FSContainerStatus notReadyWithStatus:err];
        return reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil]);
    }
    os_log(fslog, "opened %{public}@ (%{public}@ %{public}@)", serial, device.deviceInfo.manufacturer,
           device.deviceInfo.model);
    _volume = [[MTPVolume alloc] initWithDevice:device name:product ?: device.deviceInfo.model];
    self.containerStatus = FSContainerStatus.ready;
    reply(_volume, nil);
}

- (void)unloadResource:(FSResource *)resource options:(FSTaskOptions *)options replyHandler:(void (^)(NSError *))reply {
    _volume = nil;
    self.containerStatus = [FSContainerStatus notReadyWithStatus:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENODEV userInfo:nil]];
    reply(nil);
}

@end
