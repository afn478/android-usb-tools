// mtp-probe: talks to a phone in File transfer mode and lists what it sees.
//
//   mtp-probe            device info, storages and their top-level folders
//   mtp-probe PATH       list PATH (e.g. "Internal shared storage/DCIM")
//   mtp-probe -c PATH    read a file and print its size and a checksum

#import <CommonCrypto/CommonDigest.h>
#import "MTPDevice.h"

static void fail(NSString *what, NSError *err) {
    fprintf(stderr, "%s: %s\n", what.UTF8String, err.localizedDescription.UTF8String);
    exit(1);
}

static NSString *size_str(uint64_t n) {
    return [NSByteCountFormatter stringFromByteCount:(long long)n countStyle:NSByteCountFormatterCountStyleFile];
}

// Resolves "Storage name/dir/file" to a handle; returns NO when not found.
static BOOL resolve(MTPDevice *dev, NSString *path, MTPStorageInfo **storageOut, MTPObjectInfo **objOut) {
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    NSError *err = nil;
    NSArray *ids = [dev storageIDs:&err];
    if (!ids) fail(@"GetStorageIDs", err);
    for (NSNumber *sid in ids) {
        MTPStorageInfo *s = [dev storageInfo:sid.unsignedIntValue error:&err];
        if (!s) fail(@"GetStorageInfo", err);
        if (![s.storageDescription isEqualToString:parts[0]]) continue;
        *storageOut = s;
        *objOut = nil;
        uint32_t parent = MTPRootParent;
        for (NSUInteger i = 1; i < parts.count; i++) {
            if (![parts[i] length]) continue;
            NSArray *handles = [dev objectHandlesInStorage:s.storageID parent:parent error:&err];
            if (!handles) fail(@"GetObjectHandles", err);
            MTPObjectInfo *match = nil;
            for (NSNumber *h in handles) {
                MTPObjectInfo *o = [dev objectInfo:h.unsignedIntValue error:&err];
                if ([o.filename isEqualToString:parts[i]]) { match = o; break; }
            }
            if (!match) return NO;
            *objOut = match;
            parent = match.handle;
        }
        return YES;
    }
    return NO;
}

static void list(MTPDevice *dev, uint32_t storageID, uint32_t parent, NSString *indent) {
    NSError *err = nil;
    double t0 = CFAbsoluteTimeGetCurrent();
    NSArray<MTPObjectInfo *> *objs = [dev objectsInStorage:storageID parent:parent error:&err];
    if (!objs) fail(@"listing", err);
    for (MTPObjectInfo *o in objs)
        printf("%s%s%s  %s\n", indent.UTF8String, o.filename.UTF8String, o.isDirectory ? "/" : "",
               o.isDirectory ? "" : size_str(o.size).UTF8String);
    printf("%s(%lu entries in %.0f ms)\n", indent.UTF8String, (unsigned long)objs.count,
           (CFAbsoluteTimeGetCurrent() - t0) * 1000);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL checksum = argc > 2 && !strcmp(argv[1], "-c");
        NSString *path = argc > 1 ? @(argv[argc - 1]) : nil;
        if (argc > 1 && !strcmp(argv[1], "-c") && argc < 3) {
            fprintf(stderr, "usage: mtp-probe [-c] [PATH]\n");
            return 2;
        }

        NSArray<NSNumber *> *services = [MTPDevice copyInterfaceServices];
        if (!services.count) {
            fprintf(stderr, "no phone in File transfer mode found\n");
            return 1;
        }
        io_service_t svc = services[0].unsignedIntValue;
        printf("phone: %s (serial %s)\n", [MTPDevice productNameForInterfaceService:svc].UTF8String,
               [MTPDevice serialForInterfaceService:svc].UTF8String);

        NSError *err = nil;
        MTPDevice *dev = [[MTPDevice alloc] initWithService:svc error:&err];
        for (NSNumber *s in services) IOObjectRelease(s.unsignedIntValue);
        if (!dev) fail(@"open", err);
        MTPDeviceInfo *info = dev.deviceInfo;
        printf("MTP: %s %s, version %s, extension \"%s\"\n", info.manufacturer.UTF8String, info.model.UTF8String,
               info.deviceVersion.UTF8String, info.vendorExtension.UTF8String);

        if (path && checksum) {
            MTPStorageInfo *s = nil;
            MTPObjectInfo *o = nil;
            if (!resolve(dev, path, &s, &o) || !o || o.isDirectory) {
                fprintf(stderr, "%s: no such file\n", path.UTF8String);
                return 1;
            }
            CC_SHA256_CTX ctx;
            CC_SHA256_Init(&ctx);
            double t0 = CFAbsoluteTimeGetCurrent();
            for (uint64_t off = 0; off < o.size;) {
                uint32_t len = (uint32_t)MIN(o.size - off, 4u << 20);
                NSData *d = [dev readObject:o.handle offset:off length:len error:&err];
                if (!d) fail(@"read", err);
                if (!d.length) break;
                CC_SHA256_Update(&ctx, d.bytes, (CC_LONG)d.length);
                off += d.length;
            }
            double dt = CFAbsoluteTimeGetCurrent() - t0;
            uint8_t md[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(md, &ctx);
            printf("%s: %s in %.2f s (%.1f MB/s)\nsha256 ", o.filename.UTF8String, size_str(o.size).UTF8String, dt,
                   o.size / dt / 1e6);
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) printf("%02x", md[i]);
            printf("\n");
            return 0;
        }

        if (path) {
            MTPStorageInfo *s = nil;
            MTPObjectInfo *o = nil;
            if (!resolve(dev, path, &s, &o) || (o && !o.isDirectory)) {
                fprintf(stderr, "%s: no such folder\n", path.UTF8String);
                return 1;
            }
            list(dev, s.storageID, o ? o.handle : MTPRootParent, @"");
            return 0;
        }

        NSArray *ids = [dev storageIDs:&err];
        if (!ids) fail(@"GetStorageIDs", err);
        if (!ids.count) printf("no storages visible; unlock the phone and run again\n");
        for (NSNumber *sid in ids) {
            MTPStorageInfo *s = [dev storageInfo:sid.unsignedIntValue error:&err];
            if (!s) fail(@"GetStorageInfo", err);
            printf("\nstorage 0x%08x \"%s\": %s free of %s%s\n", s.storageID, s.storageDescription.UTF8String,
                   size_str(s.freeSpace).UTF8String, size_str(s.maxCapacity).UTF8String,
                   s.isReadOnly ? " (read-only)" : "");
            list(dev, s.storageID, MTPRootParent, @"  ");
        }
    }
    return 0;
}
