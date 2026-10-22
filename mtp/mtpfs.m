// mtpfs: mounts a phone in File transfer mode through macFUSE.
//
//   mtpfs [-s SERIAL] MOUNTPOINT [FUSE options]
//
// Each MTP storage ("Internal shared storage", an SD card) is a folder at the
// top of the volume. Read-only for now. Exits and unmounts when the phone goes
// away.

#define FUSE_USE_VERSION 312
#import <fuse.h>

// macFUSE's fuse.h maps fuse_loop_mt to this without declaring it.
int fuse_loop_mt_312(struct fuse *f, struct fuse_loop_config *config);

#import <pthread.h>

#import "MTPDevice.h"

// How long a folder listing is reused when listing it again, and when a
// lookup misses (macOS probes for many files that don't exist).
static const NSTimeInterval kListingTTL = 2;
static const NSTimeInterval kMissTTL = 10;
static const uint32_t kMaxRead = 4 << 20;

@interface Node : NSObject
@property BOOL isStorage, isDirectory;
@property uint32_t storageID, handle;
@property uint64_t size;
@property (copy) NSString *name;
@property (nullable, copy) NSDate *created, *modified;
@property (nullable, copy) NSArray<Node *> *children;
@property NSTimeInterval listedAt;
@end

@implementation Node
@end

static MTPDevice *g_dev;
static Node *g_root;
static NSLock *g_lock;  // guards the node tree
static uint64_t g_total, g_free;
static NSDateFormatter *g_logTime;

static void logmsg(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logmsg(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "%s mtpfs: %s\n", [g_logTime stringFromDate:[NSDate date]].UTF8String, msg.UTF8String);
}

static int errno_for_device(void) {
    return g_dev.disconnected ? -ENXIO : -EIO;
}

#pragma mark - Tree

// Reads a directory from the phone. Call with g_lock held.
static NSArray<Node *> *fetch_children(Node *dir) {
    NSError *err = nil;
    NSMutableArray<Node *> *out = [NSMutableArray array];
    if (dir == g_root) {
        NSArray *ids = [g_dev storageIDs:&err];
        uint64_t total = 0, free = 0;
        for (NSNumber *sid in ids) {
            MTPStorageInfo *info = [g_dev storageInfo:sid.unsignedIntValue error:&err];
            if (!info) return nil;
            Node *n = [Node new];
            n.isStorage = n.isDirectory = YES;
            n.storageID = info.storageID;
            n.name = info.storageDescription.length ? info.storageDescription
                                                    : [NSString stringWithFormat:@"Storage %08x", info.storageID];
            [out addObject:n];
            total += info.maxCapacity;
            free += info.freeSpace;
        }
        if (!ids) {
            logmsg(@"listing storages: %@", err.localizedDescription);
            return nil;
        }
        g_total = total;
        g_free = free;
        return out;
    }
    uint32_t parent = dir.isStorage ? MTPRootParent : dir.handle;
    NSArray<MTPObjectInfo *> *objs = [g_dev objectsInStorage:dir.storageID parent:parent error:&err];
    if (!objs) {
        logmsg(@"listing %@: %@", dir.name, err.localizedDescription);
        return nil;
    }
    for (MTPObjectInfo *info in objs) {
        // A name with "/" can't be represented; skip it rather than fail the listing.
        if (!info.filename.length || [info.filename containsString:@"/"]) continue;
        Node *n = [Node new];
        n.storageID = dir.storageID;
        n.handle = info.handle;
        n.isDirectory = info.isDirectory;
        n.size = info.size;
        n.name = info.filename;
        n.created = info.created;
        n.modified = info.modified;
        [out addObject:n];
    }
    return out;
}

// Listing of a directory; fetched again only when older than maxAge.
static NSArray<Node *> *children_of(Node *dir, NSTimeInterval maxAge) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (dir.children && now - dir.listedAt <= maxAge) return dir.children;
    NSArray *fresh = fetch_children(dir);
    if (!fresh) return nil;
    // Keep existing nodes so open files and cached subdirectories survive.
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (Node *n in dir.children) old[n.name] = n;
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:fresh.count];
    for (Node *n in fresh) {
        Node *o = old[n.name];
        if (o && o.handle == n.handle && o.isDirectory == n.isDirectory) {
            o.size = n.size;
            o.modified = n.modified;
            [merged addObject:o];
        } else {
            [merged addObject:n];
        }
    }
    dir.children = merged;
    dir.listedAt = now;
    return merged;
}

static Node *child_named(NSArray<Node *> *children, NSString *name) {
    for (Node *c in children)
        if ([c.name compare:name options:NSCaseInsensitiveSearch] == NSOrderedSame) return c;
    return nil;
}

// Resolves a FUSE path; sets *err to a negative errno on failure.
static Node *resolve(const char *path, int *err) {
    Node *n = g_root;
    for (NSString *part in [@(path) componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if (!n.isDirectory) {
            *err = -ENOTDIR;
            return nil;
        }
        // Lookups reuse the listing however old it is: Finder stats every
        // entry right after listing a folder. Only a miss asks the phone
        // again, and not more often than kMissTTL.
        Node *next = nil;
        for (int pass = 0; pass < 2 && !next; pass++) {
            NSArray *children = children_of(n, pass ? kMissTTL : INFINITY);
            if (!children) {
                *err = errno_for_device();
                return nil;
            }
            next = child_named(children, part);
        }
        if (!next) {
            *err = -ENOENT;
            return nil;
        }
        n = next;
    }
    return n;
}

static struct timespec ts(NSDate *d) {
    return (struct timespec){(time_t)d.timeIntervalSince1970, 0};
}

static void fill_attr(Node *n, struct fuse_darwin_attr *a) {
    memset(a, 0, sizeof *a);
    a->mode = n.isDirectory ? (S_IFDIR | 0555) : (S_IFREG | 0444);
    a->nlink = n.isDirectory ? 2 : 1;
    a->uid = getuid();
    a->gid = getgid();
    a->size = n.isDirectory ? 0 : (off_t)n.size;
    a->blksize = 4096;
    a->blocks = (a->size + 511) / 512;
    NSDate *m = n.modified ?: n.created ?: [NSDate dateWithTimeIntervalSince1970:0];
    a->mtimespec = a->ctimespec = a->atimespec = ts(m);
    a->btimespec = ts(n.created ?: m);
}

#pragma mark - FUSE operations

static void *op_init(struct fuse_conn_info *conn, struct fuse_config *cfg) {
    // MTP has no inode numbers worth exposing and the phone can change behind
    // our back, so keep the kernel's caches short.
    cfg->entry_timeout = kListingTTL;
    cfg->attr_timeout = kListingTTL;
    cfg->negative_timeout = 1;
    return NULL;
}

static int op_getattr(const char *path, struct fuse_darwin_attr *attr, struct fuse_file_info *fi) {
    [g_lock lock];
    int err = 0;
    Node *n = resolve(path, &err);
    if (n) fill_attr(n, attr);
    [g_lock unlock];
    return n ? 0 : err;
}

static int op_readdir(const char *path, void *buf, fuse_darwin_fill_dir_t filler, off_t off,
                      struct fuse_file_info *fi, enum fuse_readdir_flags flags) {
    [g_lock lock];
    int err = 0;
    Node *dir = resolve(path, &err);
    NSArray *children = nil;
    if (dir && !dir.isDirectory) err = -ENOTDIR;
    if (dir && dir.isDirectory) {
        // Listing a folder is the cue to ask the phone again.
        children = children_of(dir, kListingTTL);
        if (!children) err = errno_for_device();
    }
    if (children) {
        filler(buf, ".", NULL, 0, 0);
        filler(buf, "..", NULL, 0, 0);
        for (Node *c in children) {
            struct fuse_darwin_attr a;
            fill_attr(c, &a);
            if (filler(buf, c.name.UTF8String, &a, 0, FUSE_FILL_DIR_PLUS)) break;
        }
    }
    [g_lock unlock];
    return children ? 0 : err;
}

static int op_open(const char *path, struct fuse_file_info *fi) {
    if ((fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    [g_lock lock];
    int err = 0;
    Node *n = resolve(path, &err);
    if (n && n.isDirectory) err = -EISDIR;
    if (n && !n.isDirectory) fi->fh = (uint64_t)(uintptr_t)CFBridgingRetain(n);
    [g_lock unlock];
    return err;
}

static int op_release(const char *path, struct fuse_file_info *fi) {
    if (fi->fh) CFBridgingRelease((CFTypeRef)(uintptr_t)fi->fh);
    return 0;
}

static int op_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    Node *n = (__bridge Node *)(void *)(uintptr_t)fi->fh;
    if (!n || offset < 0) return -EINVAL;
    uint64_t end = MIN(n.size, (uint64_t)offset + size);
    size_t done = 0;
    for (uint64_t off = (uint64_t)offset; off < end;) {
        uint32_t len = (uint32_t)MIN(end - off, kMaxRead);
        NSError *err = nil;
        NSData *d = [g_dev readObject:n.handle offset:off length:len error:&err];
        if (!d) {
            logmsg(@"read %@ at %llu: %@", n.name, off, err.localizedDescription);
            return done ? (int)done : errno_for_device();
        }
        if (!d.length) break;
        size_t take = MIN(d.length, (size_t)(end - off));
        memcpy(buf + done, d.bytes, take);
        done += take;
        off += take;
    }
    return (int)done;
}

static int op_statfs(const char *path, struct statfs *st) {
    memset(st, 0, sizeof *st);
    st->f_bsize = 4096;
    st->f_iosize = kMaxRead;
    st->f_blocks = g_total / 4096;
    st->f_bfree = st->f_bavail = g_free / 4096;
    return 0;
}

#pragma mark - Main

static struct fuse *g_fuse;

// Ends the FUSE loop once the phone is unplugged, which unmounts the volume.
static void *watch_unplug(void *arg) {
    while (!g_dev.disconnected) sleep(1);
    logmsg(@"phone disconnected; unmounting");
    if (g_fuse) fuse_exit(g_fuse);
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        g_logTime = [NSDateFormatter new];
        g_logTime.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *serial = nil;
        int ch;
        while ((ch = getopt(argc, argv, "+s:")) != -1) {
            if (ch == 's') serial = @(optarg);
            else return 2;
        }
        if (optind >= argc) {
            fprintf(stderr, "usage: mtpfs [-s SERIAL] MOUNTPOINT [FUSE options]\n");
            return 2;
        }

        io_service_t svc = 0;
        for (NSNumber *n in [MTPDevice copyInterfaceServices]) {
            io_service_t s = n.unsignedIntValue;
            if (!svc && (!serial || [[MTPDevice serialForInterfaceService:s] isEqualToString:serial]))
                svc = s;
            else
                IOObjectRelease(s);
        }
        if (!svc) {
            fprintf(stderr, "mtpfs: no phone in File transfer mode found\n");
            return 1;
        }
        NSString *product = [MTPDevice productNameForInterfaceService:svc] ?: @"Android";
        NSError *err = nil;
        g_dev = [[MTPDevice alloc] initWithService:svc error:&err];
        IOObjectRelease(svc);
        if (!g_dev) {
            fprintf(stderr, "mtpfs: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        logmsg(@"opened %@ (%@)", product, g_dev.deviceInfo.serialNumber);

        g_lock = [NSLock new];
        g_root = [Node new];
        g_root.isDirectory = YES;
        g_root.name = product;
        [g_lock lock];
        children_of(g_root, 0);  // so free space is known at mount time
        [g_lock unlock];

        static struct fuse_operations ops = {
            .init = op_init,
            .getattr = op_getattr,
            .readdir = op_readdir,
            .open = op_open,
            .release = op_release,
            .read = op_read,
            .statfs = op_statfs,
        };

        struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
        fuse_opt_add_arg(&args, argv[0]);
        NSString *opts = [NSString stringWithFormat:@"backend=fskit,rdonly,volname=%@,fsname=mtp:%@", product,
                                                    g_dev.deviceInfo.serialNumber];
        fuse_opt_add_arg(&args, "-o");
        fuse_opt_add_arg(&args, opts.UTF8String);
        for (int i = optind + 1; i < argc; i++) fuse_opt_add_arg(&args, argv[i]);

        g_fuse = fuse_new(&args, &ops, sizeof ops, NULL);
        if (!g_fuse) return 1;
        if (fuse_mount(g_fuse, argv[optind]) != 0) {
            fuse_destroy(g_fuse);
            return 1;
        }
        // SIGINT/SIGTERM end the loop and unmount, instead of leaving a dead mount.
        fuse_set_signal_handlers(fuse_get_session(g_fuse));
        pthread_t t;
        pthread_create(&t, NULL, watch_unplug, NULL);
        pthread_detach(t);
        struct fuse_loop_config *loop = fuse_loop_cfg_create();
        int rc = fuse_loop_mt(g_fuse, loop);
        fuse_loop_cfg_destroy(loop);
        fuse_remove_signal_handlers(fuse_get_session(g_fuse));
        fuse_unmount(g_fuse);
        fuse_destroy(g_fuse);
        [g_dev close];
        logmsg(@"unmounted");
        return rc ? 1 : 0;
    }
}
