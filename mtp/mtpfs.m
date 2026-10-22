// mtpfs: mounts a phone in File transfer mode through macFUSE.
//
//   mtpfs [-s SERIAL] MOUNTPOINT [FUSE options]
//
// Each MTP storage ("Internal shared storage", an SD card) is a folder at the
// top of the volume. Writable on phones with Android's edit extensions,
// read-only otherwise. Exits and unmounts when the phone goes away.

#define FUSE_USE_VERSION 312
#import <fuse.h>
#import <fuse_lowlevel.h>  // FUSE_SET_ATTR_*

// macFUSE's fuse.h maps fuse_loop_mt to this without declaring it.
int fuse_loop_mt_312(struct fuse *f, struct fuse_loop_config *config);

#import <pthread.h>
#import <sys/mount.h>

#import "MTPDevice.h"

// How long a folder listing is reused when listing it again, and when a
// lookup misses (macOS probes for many files that don't exist).
static const NSTimeInterval kListingTTL = 2;
static const NSTimeInterval kMissTTL = 10;
// How long macOS may cache names and attributes without asking us.
static const double kAttrTTL = 30;
// Smallest amount fetched from the phone per read.
static const uint32_t kReadAhead = 1 << 20;
static const uint32_t kMaxRead = 4 << 20;

@interface Node : NSObject
@property BOOL isStorage, isDirectory;
@property uint32_t storageID, handle;
@property uint64_t size;
@property (copy) NSString *name;
@property (nullable, copy) NSDate *created, *modified;
// Setting the children also rebuilds `index`, for lookups by name.
@property (nullable, copy, nonatomic) NSArray<Node *> *children;
@property (nullable, readonly) NSDictionary<NSString *, Node *> *index;
@property NSTimeInterval listedAt;
// Open-for-writing count and whether an Android edit session is open; both
// guarded by @synchronized(node).
@property int writers;
@property BOOL editing;
// The last chunk read from the phone, so small sequential reads (Finder,
// Quick Look) don't each cost a round trip; guarded by @synchronized(node).
@property uint64_t cachedOffset;
@property (nullable) NSData *cached;
@end

// Lookups ignore case and Unicode normalization, like the phone's storage.
static NSString *index_key(NSString *name) {
    return name.precomposedStringWithCanonicalMapping.lowercaseString;
}

@implementation Node

- (void)setChildren:(NSArray<Node *> *)children {
    _children = [children copy];
    NSMutableDictionary *index = [NSMutableDictionary dictionaryWithCapacity:children.count];
    for (Node *c in children) index[index_key(c.name)] = c;
    _index = index;
}

@end

static MTPDevice *g_dev;
static Node *g_root;
static NSLock *g_lock;  // guards the node tree
static BOOL g_writable;
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

// The entry called `name` in `dir`, from a listing no older than maxAge;
// sets *failed when the listing can't be read.
static Node *child_named(Node *dir, NSString *name, NSTimeInterval maxAge, BOOL *failed) {
    if (!children_of(dir, maxAge)) {
        if (failed) *failed = YES;
        return nil;
    }
    return dir.index[index_key(name)];
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
        BOOL failed = NO;
        for (int pass = 0; pass < 2 && !next && !failed; pass++)
            next = child_named(n, part, pass ? kMissTTL : INFINITY, &failed);
        if (failed) {
            *err = errno_for_device();
            return nil;
        }
        if (!next) {
            *err = -ENOENT;
            return nil;
        }
        n = next;
    }
    return n;
}

// Resolves the folder a new or renamed entry goes into, and its name.
static Node *resolve_parent(const char *path, NSString **name, int *err) {
    NSString *p = @(path);
    *name = p.lastPathComponent;
    Node *dir = resolve(p.stringByDeletingLastPathComponent.fileSystemRepresentation, err);
    if (dir && !dir.isDirectory) {
        *err = -ENOTDIR;
        return nil;
    }
    if (dir == g_root) {
        *err = -EACCES;  // only storages live at the top
        return nil;
    }
    return dir;
}

static Node *node_for(MTPObjectInfo *info, Node *dir) {
    Node *n = [Node new];
    n.storageID = dir.storageID;
    n.handle = info.handle;
    n.isDirectory = info.isDirectory;
    n.size = info.size;
    n.name = info.filename;
    n.created = info.created;
    n.modified = info.modified;
    return n;
}

static void add_child(Node *dir, Node *n) {
    if (dir.children) dir.children = [dir.children arrayByAddingObject:n];
}

static void remove_child(Node *dir, Node *n) {
    NSMutableArray *a = [dir.children mutableCopy];
    [a removeObjectIdenticalTo:n];
    dir.children = a;
}

static uint32_t parent_handle(Node *dir) {
    return dir.isStorage ? MTPRootParent : dir.handle;
}

// Finder's metadata files would clutter the phone; refuse them.
static BOOL is_mac_metadata(NSString *name) {
    return [name hasPrefix:@"._"] || [name isEqualToString:@".DS_Store"];
}

static struct timespec ts(NSDate *d) {
    return (struct timespec){(time_t)d.timeIntervalSince1970, 0};
}

static void fill_attr(Node *n, struct fuse_darwin_attr *a) {
    memset(a, 0, sizeof *a);
    // The top level holds only the storages, so it stays read-only.
    BOOL rw = g_writable && n != g_root;
    a->mode = n.isDirectory ? (S_IFDIR | (rw ? 0755 : 0555)) : (S_IFREG | (rw ? 0644 : 0444));
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
    // Let macOS keep names and attributes for a while: Finder looks up every
    // entry of a folder it shows, and each lookup that reaches us crosses
    // macFUSE's FSKit layer. Listing a folder still asks the phone again.
    cfg->entry_timeout = kAttrTTL;
    cfg->attr_timeout = kAttrTTL;
    cfg->negative_timeout = 2;
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

static BOOL wants_write(struct fuse_file_info *fi) {
    return (fi->flags & O_ACCMODE) != O_RDONLY;
}

static void attach(Node *n, struct fuse_file_info *fi) {
    if (wants_write(fi)) @synchronized(n) { n.writers++; }
    fi->fh = (uint64_t)(uintptr_t)CFBridgingRetain(n);
}

static int op_open(const char *path, struct fuse_file_info *fi) {
    if (wants_write(fi) && !g_writable) return -EROFS;
    [g_lock lock];
    int err = 0;
    Node *n = resolve(path, &err);
    if (n && n.isDirectory) err = -EISDIR;
    if (n && !n.isDirectory) attach(n, fi);
    [g_lock unlock];
    return err;
}

// Commits an Android edit session, which makes the phone index the new contents.
static int end_editing(Node *n) {
    @synchronized(n) {
        if (!n.editing) return 0;
        n.editing = NO;
        NSError *err = nil;
        if (![g_dev endEditing:n.handle error:&err]) {
            logmsg(@"finishing %@: %@", n.name, err.localizedDescription);
            return errno_for_device();
        }
        n.modified = [NSDate date];
    }
    return 0;
}

static int op_release(const char *path, struct fuse_file_info *fi) {
    Node *n = CFBridgingRelease((CFTypeRef)(uintptr_t)fi->fh);
    if (!n || !wants_write(fi)) return 0;
    BOOL last;
    @synchronized(n) { last = --n.writers == 0; }
    return last ? end_editing(n) : 0;
}

static int op_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
    Node *n = (__bridge Node *)(void *)(uintptr_t)fi->fh;
    return n ? end_editing(n) : 0;
}

static int begin_editing(Node *n) {
    @synchronized(n) {
        if (n.editing) return 0;
        NSError *err = nil;
        if (![g_dev beginEditing:n.handle error:&err]) {
            logmsg(@"editing %@: %@", n.name, err.localizedDescription);
            return errno_for_device();
        }
        n.editing = YES;
    }
    return 0;
}

static int op_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    Node *n = (__bridge Node *)(void *)(uintptr_t)fi->fh;
    if (!n || offset < 0) return -EINVAL;
    int rc = begin_editing(n);
    if (rc) return rc;
    NSError *err = nil;
    NSData *data = [NSData dataWithBytesNoCopy:(void *)buf length:size freeWhenDone:NO];
    if (![g_dev writeObject:n.handle offset:(uint64_t)offset data:data error:&err]) {
        logmsg(@"write %@ at %lld: %@", n.name, offset, err.localizedDescription);
        return errno_for_device();
    }
    @synchronized(n) {
        n.size = MAX(n.size, (uint64_t)offset + size);
        n.cached = nil;
    }
    return (int)size;
}

static int op_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    if (!g_writable) return -EROFS;
    [g_lock lock];
    int err = 0;
    NSString *name = nil;
    Node *dir = resolve_parent(path, &name, &err);
    if (dir && is_mac_metadata(name)) err = -EACCES;
    if (dir && !err) {
        Node *existing = child_named(dir, name, INFINITY, NULL);
        if (existing) {
            if (existing.isDirectory) err = -EISDIR;
            else attach(existing, fi);
        } else {
            NSError *e = nil;
            MTPObjectInfo *info = [g_dev createObjectNamed:name directory:NO inStorage:dir.storageID
                                                    parent:parent_handle(dir) error:&e];
            if (info) {
                Node *n = node_for(info, dir);
                add_child(dir, n);
                attach(n, fi);
            } else {
                logmsg(@"create %@: %@", name, e.localizedDescription);
                err = errno_for_device();
            }
        }
    }
    [g_lock unlock];
    return err;
}

static int op_mkdir(const char *path, mode_t mode) {
    if (!g_writable) return -EROFS;
    [g_lock lock];
    int err = 0;
    NSString *name = nil;
    Node *dir = resolve_parent(path, &name, &err);
    if (dir && child_named(dir, name, INFINITY, NULL)) err = -EEXIST;
    if (dir && !err) {
        NSError *e = nil;
        MTPObjectInfo *info = [g_dev createObjectNamed:name directory:YES inStorage:dir.storageID
                                                parent:parent_handle(dir) error:&e];
        if (info) {
            Node *n = node_for(info, dir);
            n.children = @[];
            n.listedAt = [NSDate timeIntervalSinceReferenceDate];
            add_child(dir, n);
        } else {
            logmsg(@"mkdir %@: %@", name, e.localizedDescription);
            err = errno_for_device();
        }
    }
    [g_lock unlock];
    return err;
}

static int remove_entry(const char *path, BOOL directory) {
    if (!g_writable) return -EROFS;
    [g_lock lock];
    int err = 0;
    NSString *name = nil;
    Node *dir = resolve_parent(path, &name, &err);
    Node *n = dir ? child_named(dir, name, INFINITY, NULL) : nil;
    if (dir && !n) err = -ENOENT;
    if (n && n.isDirectory != directory) err = directory ? -ENOTDIR : -EISDIR;
    if (n && !err && directory) {
        NSArray *inside = children_of(n, 0);
        if (!inside) err = errno_for_device();
        else if (inside.count) err = -ENOTEMPTY;
    }
    if (n && !err) {
        NSError *e = nil;
        if ([g_dev deleteObject:n.handle error:&e]) {
            remove_child(dir, n);
        } else {
            logmsg(@"delete %@: %@", name, e.localizedDescription);
            err = errno_for_device();
        }
    }
    [g_lock unlock];
    return err;
}

static int op_unlink(const char *path) { return remove_entry(path, NO); }
static int op_rmdir(const char *path) { return remove_entry(path, YES); }

static int op_rename(const char *from, const char *to, unsigned int flags) {
    if (!g_writable) return -EROFS;
    if (flags & RENAME_EXCHANGE) return -ENOTSUP;
    [g_lock lock];
    int err = 0;
    NSString *fromName = nil, *toName = nil;
    Node *fromDir = resolve_parent(from, &fromName, &err);
    Node *toDir = fromDir ? resolve_parent(to, &toName, &err) : nil;
    Node *n = toDir ? child_named(fromDir, fromName, INFINITY, NULL) : nil;
    Node *target = n ? child_named(toDir, toName, INFINITY, NULL) : nil;
    if (toDir && !n) err = -ENOENT;
    if (target == n) target = nil;  // a change of case only
    if (target && (flags & RENAME_NOREPLACE)) err = -EEXIST;
    if (target && !err) {
        if (target.isDirectory != n.isDirectory) err = target.isDirectory ? -EISDIR : -ENOTDIR;
        else if (target.isDirectory && [children_of(target, 0) count]) err = -ENOTEMPTY;
    }
    if (fromDir != toDir && !err && !g_dev.canMoveObjects) err = -EXDEV;  // callers fall back to copying

    NSError *e = nil;
    if (n && !err && target) {
        if ([g_dev deleteObject:target.handle error:&e]) remove_child(toDir, target);
        else err = errno_for_device();
    }
    if (n && !err && fromDir != toDir) {
        if ([g_dev moveObject:n.handle toStorage:toDir.storageID parent:parent_handle(toDir) error:&e]) {
            remove_child(fromDir, n);
            n.storageID = toDir.storageID;
            add_child(toDir, n);
        } else {
            err = errno_for_device();
        }
    }
    if (n && !err && ![fromName isEqualToString:toName]) {
        if ([g_dev renameObject:n.handle to:toName error:&e]) {
            n.name = toName;
            toDir.children = toDir.children;  // re-index under the new name
        } else {
            err = errno_for_device();
        }
    }
    if (e) logmsg(@"rename %@ to %@: %@", fromName, toName, e.localizedDescription);
    [g_lock unlock];
    return err;
}

static int op_setattr(const char *path, struct fuse_darwin_attr *attr, int to_set, struct fuse_file_info *fi) {
    // Permissions, owners and times aren't stored over MTP; accept and ignore
    // them so copies don't fail. Only the size matters.
    if (!(to_set & FUSE_SET_ATTR_SIZE)) return 0;
    if (!g_writable) return -EROFS;
    Node *n = fi ? (__bridge Node *)(void *)(uintptr_t)fi->fh : nil;
    if (!n) {
        [g_lock lock];
        int err = 0;
        n = resolve(path, &err);
        [g_lock unlock];
        if (!n) return err;
    }
    if (n.isDirectory) return -EISDIR;
    BOOL open;
    @synchronized(n) { open = n.writers > 0; }
    int rc = begin_editing(n);
    if (rc) return rc;
    NSError *err = nil;
    if (![g_dev truncateObject:n.handle length:(uint64_t)attr->size error:&err]) {
        logmsg(@"truncate %@: %@", n.name, err.localizedDescription);
        rc = errno_for_device();
    } else {
        @synchronized(n) {
            n.size = (uint64_t)attr->size;
            n.cached = nil;
        }
    }
    // Not open: commit now rather than at release.
    if (!open) {
        int end = end_editing(n);
        if (!rc) rc = end;
    }
    return rc;
}

static int op_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    Node *n = (__bridge Node *)(void *)(uintptr_t)fi->fh;
    if (!n || offset < 0) return -EINVAL;
    uint64_t fileSize;
    @synchronized(n) { fileSize = n.size; }
    uint64_t end = MIN(fileSize, (uint64_t)offset + size);
    size_t done = 0;
    for (uint64_t off = (uint64_t)offset; off < end;) {
        NSData *chunk = nil;
        uint64_t chunkOffset = 0;
        @synchronized(n) {
            if (n.cached && off >= n.cachedOffset && off < n.cachedOffset + n.cached.length) {
                chunk = n.cached;
                chunkOffset = n.cachedOffset;
            }
        }
        if (!chunk) {
            // Small reads fetch a whole read-ahead chunk; big ones go straight through.
            uint32_t len = (uint32_t)MIN(fileSize - off, MAX(MIN(end - off, kMaxRead), kReadAhead));
            NSError *err = nil;
            chunk = [g_dev readObject:n.handle offset:off length:len error:&err];
            if (!chunk) {
                logmsg(@"read %@ at %llu: %@", n.name, off, err.localizedDescription);
                return done ? (int)done : errno_for_device();
            }
            if (!chunk.length) break;
            chunkOffset = off;
            @synchronized(n) {
                n.cached = chunk;
                n.cachedOffset = off;
            }
        }
        size_t skip = (size_t)(off - chunkOffset);
        size_t take = MIN(chunk.length - skip, (size_t)(end - off));
        memcpy(buf + done, (const uint8_t *)chunk.bytes + skip, take);
        done += take;
        off += take;
    }
    return (int)done;
}

static int op_statfs(const char *path, struct statfs *st) {
    [g_lock lock];
    children_of(g_root, 5);  // refreshes free space
    [g_lock unlock];
    memset(st, 0, sizeof *st);
    st->f_bsize = 4096;
    st->f_iosize = kMaxRead;
    st->f_blocks = g_total / 4096;
    st->f_bfree = st->f_bavail = g_free / 4096;
    return 0;
}

#pragma mark - Main

static struct fuse *g_fuse;
static const char *g_mountPoint;

static BOOL still_mounted(void) {
    struct statfs fs;
    return statfs(g_mountPoint, &fs) == 0 && strcmp(fs.f_mntonname, g_mountPoint) == 0;
}

// macFUSE's FSKit backend doesn't end the FUSE loop when the volume is
// ejected from Finder, and the loop doesn't notice an unplugged phone, so
// watch for both and exit.
static void *watch_mount(void *arg) {
    // The FSKit mount finishes asynchronously; only an unmount after it has
    // appeared counts as an eject.
    BOOL seen = NO;
    pid_t parent = getppid();
    for (int waited = 0;; waited++) {
        sleep(1);
        [g_dev pauseImageCapture];
        if (!seen) {
            seen = still_mounted();
            if (!seen && waited >= 30) {
                logmsg(@"volume never appeared");
                break;
            }
            if (!seen) continue;
        }
        if (g_dev.disconnected) {
            logmsg(@"phone disconnected; unmounting");
            unmount(g_mountPoint, MNT_FORCE);
            break;
        }
        // Whoever started us (the app) is gone; don't outlive it.
        if (getppid() != parent) {
            logmsg(@"parent exited; unmounting");
            unmount(g_mountPoint, 0);
            break;
        }
        if (!still_mounted()) {
            logmsg(@"volume was ejected");
            break;
        }
    }
    [g_dev close];
    logmsg(@"unmounted");
    exit(0);
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
            .write = op_write,
            .create = op_create,
            .mkdir = op_mkdir,
            .unlink = op_unlink,
            .rmdir = op_rmdir,
            .rename = op_rename,
            .setattr = op_setattr,
            .fsync = op_fsync,
        };

        struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
        fuse_opt_add_arg(&args, argv[0]);
        g_writable = g_dev.canEditObjects;
        if (!g_writable) logmsg(@"phone lacks Android's edit operations; mounting read-only");
        NSString *opts = [NSString stringWithFormat:@"backend=fskit,%@volname=%@,fsname=mtp:%@",
                                                    g_writable ? @"" : @"rdonly,", product,
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
        g_mountPoint = realpath(argv[optind], NULL) ?: argv[optind];
        pthread_t t;
        pthread_create(&t, NULL, watch_mount, NULL);
        pthread_detach(t);
        struct fuse_loop_config *loop = fuse_loop_cfg_create();
        int rc = fuse_loop_mt(g_fuse, loop);
        // The loop reports an error when the volume goes away under it; an
        // eject is still a clean exit.
        if (!still_mounted()) rc = 0;
        fuse_loop_cfg_destroy(loop);
        fuse_remove_signal_handlers(fuse_get_session(g_fuse));
        fuse_unmount(g_fuse);
        fuse_destroy(g_fuse);
        [g_dev close];
        logmsg(@"unmounted");
        return rc ? 1 : 0;
    }
}
