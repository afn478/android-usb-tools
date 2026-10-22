#import "MTPVolume.h"

#import <os/log.h>

// Item IDs: 2 is the root, storages and objects get their own ranges so a
// storage ID can't collide with an object handle.
static const uint64_t kStorageBase = 1ULL << 32;
static const uint64_t kObjectBase = 2ULL << 32;
// How long a directory listing is reused before asking the phone again.
static const NSTimeInterval kListingTTL = 2;
static const uint32_t kMaxRead = 4 << 20;

static os_log_t vlog;

static NSError *posix(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

typedef NS_ENUM(NSInteger, MTPItemKind) {
    MTPItemKindRoot,
    MTPItemKindStorage,
    MTPItemKindObject,
};

@interface MTPItem : FSItem
@property MTPItemKind kind;
@property FSItemID itemID, parentID;
@property uint32_t storageID, handle;
@property BOOL isDirectory;
@property uint64_t size;
@property (copy) NSString *name;
@property (nullable, copy) NSDate *created, *modified;
// Directory listing cache.
@property (nullable, copy) NSArray<MTPItem *> *children;
@property NSTimeInterval listedAt;
@property uint64_t generation;
@end

@implementation MTPItem
@end

@implementation MTPVolume {
    MTPDevice *_device;
    MTPItem *_root;
    NSMutableDictionary<NSNumber *, MTPItem *> *_items;
    NSLock *_lock;
    uint64_t _totalBytes, _freeBytes;
}

- (instancetype)initWithDevice:(MTPDevice *)device name:(NSString *)name {
    NSString *serial = device.deviceInfo.serialNumber;
    // Same phone, same volume ID, so Finder keeps its view settings.
    uint8_t uuid[16] = {0};
    NSData *s = [serial dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger i = 0; i < s.length; i++) uuid[i % 16] ^= ((const uint8_t *)s.bytes)[i];
    uuid[6] = (uuid[6] & 0x0F) | 0x80;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;
    FSVolumeIdentifier *vid = [[FSVolumeIdentifier alloc] initWithUUID:[[NSUUID alloc] initWithUUIDBytes:uuid]];
    if (!(self = [super initWithVolumeID:vid volumeName:[FSFileName nameWithString:name]])) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ vlog = os_log_create("io.github.afn478.AndroidUSBTools.mtpfs", "volume"); });
    _device = device;
    _lock = [NSLock new];
    _items = [NSMutableDictionary dictionary];
    _root = [MTPItem new];
    _root.kind = MTPItemKindRoot;
    _root.itemID = FSItemIDRootDirectory;
    _root.parentID = FSItemIDParentOfRoot;
    _root.isDirectory = YES;
    _root.name = name;
    _items[@(_root.itemID)] = _root;
    return self;
}

#pragma mark - Listings

- (MTPItem *)itemForID:(FSItemID)itemID {
    MTPItem *item = _items[@(itemID)];
    if (!item) {
        item = [MTPItem new];
        item.itemID = itemID;
        _items[@(itemID)] = item;
    }
    return item;
}

// Reads a directory from the phone, reusing item objects so FSKit sees stable
// identities. Call with _lock held.
- (NSArray<MTPItem *> *)fetchChildrenOf:(MTPItem *)dir error:(NSError **)error {
    NSMutableArray<MTPItem *> *out = [NSMutableArray array];
    if (dir.kind == MTPItemKindRoot) {
        NSArray *ids = [_device storageIDs:error];
        if (!ids) return nil;
        uint64_t total = 0, free = 0;
        for (NSNumber *sid in ids) {
            MTPStorageInfo *info = [_device storageInfo:sid.unsignedIntValue error:error];
            if (!info) return nil;
            MTPItem *item = [self itemForID:kStorageBase + info.storageID];
            item.kind = MTPItemKindStorage;
            item.parentID = dir.itemID;
            item.storageID = info.storageID;
            item.isDirectory = YES;
            item.name = info.storageDescription.length ? info.storageDescription
                                                       : [NSString stringWithFormat:@"Storage %08x", info.storageID];
            [out addObject:item];
            total += info.maxCapacity;
            free += info.freeSpace;
        }
        _totalBytes = total;
        _freeBytes = free;
    } else {
        uint32_t parent = dir.kind == MTPItemKindStorage ? MTPRootParent : dir.handle;
        NSArray<MTPObjectInfo *> *objs = [_device objectsInStorage:dir.storageID parent:parent error:error];
        if (!objs) return nil;
        for (MTPObjectInfo *info in objs) {
            // A name with "/" can't be represented; skip it rather than fail the listing.
            if (!info.filename.length || [info.filename containsString:@"/"]) continue;
            MTPItem *item = [self itemForID:kObjectBase + info.handle];
            item.kind = MTPItemKindObject;
            item.parentID = dir.itemID;
            item.storageID = dir.storageID;
            item.handle = info.handle;
            item.isDirectory = info.isDirectory;
            item.size = info.size;
            item.name = info.filename;
            item.created = info.created;
            item.modified = info.modified;
            [out addObject:item];
        }
    }
    return out;
}

- (NSArray<MTPItem *> *)childrenOf:(MTPItem *)dir refresh:(BOOL)refresh error:(NSError **)error {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (dir.children && !(refresh && now - dir.listedAt > kListingTTL)) return dir.children;
    NSArray *children = [self fetchChildrenOf:dir error:error];
    if (!children) {
        os_log_error(vlog, "listing %{public}@ failed: %{public}@", dir.name, (*error).localizedDescription);
        if (error) *error = posix(_device.disconnected ? ENXIO : EIO);
        return nil;
    }
    dir.children = children;
    dir.listedAt = now;
    dir.generation++;
    return children;
}

- (FSItemAttributes *)attributesOf:(MTPItem *)item {
    FSItemAttributes *a = [FSItemAttributes new];
    a.type = item.isDirectory ? FSItemTypeDirectory : FSItemTypeFile;
    a.mode = item.isDirectory ? (S_IFDIR | 0555) : (S_IFREG | 0444);
    a.linkCount = item.isDirectory ? 2 : 1;
    // 99 is "unknown", which macOS shows as the logged-in user.
    a.uid = 99;
    a.gid = 99;
    a.flags = 0;
    a.size = item.isDirectory ? 0 : item.size;
    a.allocSize = (a.size + 4095) / 4096 * 4096;
    a.fileID = item.itemID;
    a.parentID = item.parentID;
    NSDate *m = item.modified ?: item.created ?: [NSDate dateWithTimeIntervalSince1970:0];
    NSDate *b = item.created ?: m;
    struct timespec mt = {(time_t)m.timeIntervalSince1970, 0};
    struct timespec bt = {(time_t)b.timeIntervalSince1970, 0};
    a.modifyTime = mt;
    a.changeTime = mt;
    a.accessTime = mt;
    a.birthTime = bt;
    return a;
}

#pragma mark - FSVolumePathConfOperations

- (NSInteger)maximumLinkCount { return 1; }
- (NSInteger)maximumNameLength { return 255; }
- (BOOL)restrictsOwnershipChanges { return YES; }
- (BOOL)truncatesLongNames { return NO; }
- (uint64_t)maximumFileSize { return UINT64_MAX; }

#pragma mark - FSVolumeOperations

- (FSVolumeSupportedCapabilities *)supportedVolumeCapabilities {
    FSVolumeSupportedCapabilities *c = [FSVolumeSupportedCapabilities new];
    c.supports64BitObjectIDs = YES;
    c.supports2TBFiles = YES;
    c.supportsFastStatFS = YES;
    c.doesNotSupportSettingFilePermissions = YES;
    c.doesNotSupportImmutableFiles = YES;
    // Android's shared storage ignores case.
    c.caseFormat = FSVolumeCaseFormatInsensitive;
    return c;
}

- (FSStatFSResult *)volumeStatistics {
    FSStatFSResult *r = [[FSStatFSResult alloc] initWithFileSystemTypeName:@"mtpfs"];
    r.blockSize = 4096;
    r.ioSize = kMaxRead;
    r.totalBytes = _totalBytes;
    r.freeBytes = _freeBytes;
    r.availableBytes = _freeBytes;
    r.usedBytes = _totalBytes - _freeBytes;
    r.totalBlocks = _totalBytes / 4096;
    r.freeBlocks = _freeBytes / 4096;
    r.availableBlocks = _freeBytes / 4096;
    r.usedBlocks = (_totalBytes - _freeBytes) / 4096;
    return r;
}

- (void)activateWithOptions:(FSTaskOptions *)options replyHandler:(void (^)(FSItem *, NSError *))reply {
    // Read the storages now so free space shows right after mounting.
    [_lock lock];
    NSError *err = nil;
    [self childrenOf:_root refresh:YES error:&err];
    [_lock unlock];
    reply(_root, nil);
}

- (void)deactivateWithOptions:(FSDeactivateOptions)options replyHandler:(void (^)(NSError *))reply {
    [_device close];
    reply(nil);
}

- (void)mountWithOptions:(FSTaskOptions *)options replyHandler:(void (^)(NSError *))reply {
    reply(nil);
}

- (void)unmountWithReplyHandler:(void (^)(void))reply {
    reply();
}

- (void)synchronizeWithFlags:(FSSyncFlags)flags replyHandler:(void (^)(NSError *))reply {
    reply(nil);
}

- (void)reclaimItem:(FSItem *)item replyHandler:(void (^)(NSError *))reply {
    MTPItem *it = (MTPItem *)item;
    [_lock lock];
    if (it.kind != MTPItemKindRoot) [_items removeObjectForKey:@(it.itemID)];
    [_lock unlock];
    reply(nil);
}

- (void)lookupItemNamed:(FSFileName *)name
            inDirectory:(FSItem *)directory
           replyHandler:(void (^)(FSItem *, FSFileName *, NSError *))reply {
    MTPItem *dir = (MTPItem *)directory;
    NSString *want = name.string;
    [_lock lock];
    NSError *err = nil;
    NSArray *children = [self childrenOf:dir refresh:NO error:&err];
    MTPItem *found = nil;
    for (MTPItem *c in children) {
        if ([c.name compare:want options:NSCaseInsensitiveSearch] == NSOrderedSame) {
            found = c;
            break;
        }
    }
    // Not in the cached listing: the phone may have added it since.
    if (children && !found && [NSDate timeIntervalSinceReferenceDate] - dir.listedAt > kListingTTL) {
        dir.listedAt = 0;
        children = [self childrenOf:dir refresh:YES error:&err];
        for (MTPItem *c in children) {
            if ([c.name compare:want options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                found = c;
                break;
            }
        }
    }
    [_lock unlock];
    if (!children) return reply(nil, nil, err);
    if (!found) return reply(nil, nil, posix(ENOENT));
    reply(found, [FSFileName nameWithString:found.name], nil);
}

- (void)getAttributes:(FSItemGetAttributesRequest *)desiredAttributes
               ofItem:(FSItem *)item
         replyHandler:(void (^)(FSItemAttributes *, NSError *))reply {
    [_lock lock];
    FSItemAttributes *a = [self attributesOf:(MTPItem *)item];
    [_lock unlock];
    reply(a, nil);
}

- (void)setAttributes:(FSItemSetAttributesRequest *)newAttributes
               onItem:(FSItem *)item
         replyHandler:(void (^)(FSItemAttributes *, NSError *))reply {
    reply(nil, posix(EROFS));
}

- (void)enumerateDirectory:(FSItem *)directory
          startingAtCookie:(FSDirectoryCookie)cookie
                  verifier:(FSDirectoryVerifier)verifier
       providingAttributes:(FSItemGetAttributesRequest *)attributes
               usingPacker:(FSDirectoryEntryPacker *)packer
              replyHandler:(void (^)(FSDirectoryVerifier, NSError *))reply {
    MTPItem *dir = (MTPItem *)directory;
    [_lock lock];
    NSError *err = nil;
    NSArray<MTPItem *> *children = [self childrenOf:dir refresh:cookie == FSDirectoryCookieInitial error:&err];
    if (!children) {
        [_lock unlock];
        return reply(0, err);
    }
    // Verifiers must be nonzero.
    FSDirectoryVerifier current = dir.generation;
    if (cookie != FSDirectoryCookieInitial && verifier != current) {
        [_lock unlock];
        return reply(0, [NSError errorWithDomain:FSKitErrorDomain code:FSErrorInvalidDirectoryCookie userInfo:nil]);
    }
    // Without attributes the listing starts with "." and "..". The cookie is
    // the index of the next entry to pack.
    NSUInteger dots = attributes ? 0 : 2;
    NSUInteger count = dots + children.count;
    for (NSUInteger i = cookie; i < count; i++) {
        BOOL ok;
        if (i < dots) {
            ok = [packer packEntryWithName:[FSFileName nameWithString:i ? @".." : @"."]
                                  itemType:FSItemTypeDirectory
                                    itemID:i ? dir.parentID : dir.itemID
                                nextCookie:i + 1
                                attributes:nil];
        } else {
            MTPItem *c = children[i - dots];
            ok = [packer packEntryWithName:[FSFileName nameWithString:c.name]
                                  itemType:c.isDirectory ? FSItemTypeDirectory : FSItemTypeFile
                                    itemID:c.itemID
                                nextCookie:i + 1
                                attributes:attributes ? [self attributesOf:c] : nil];
        }
        if (!ok) break;
    }
    [_lock unlock];
    reply(current, nil);
}

- (void)readSymbolicLink:(FSItem *)item replyHandler:(void (^)(FSFileName *, NSError *))reply {
    reply(nil, posix(EINVAL));
}

- (void)createItemNamed:(FSFileName *)name
                   type:(FSItemType)type
            inDirectory:(FSItem *)directory
             attributes:(FSItemSetAttributesRequest *)newAttributes
           replyHandler:(void (^)(FSItem *, FSFileName *, NSError *))reply {
    reply(nil, nil, posix(EROFS));
}

- (void)createSymbolicLinkNamed:(FSFileName *)name
                    inDirectory:(FSItem *)directory
                     attributes:(FSItemSetAttributesRequest *)newAttributes
                   linkContents:(FSFileName *)contents
                   replyHandler:(void (^)(FSItem *, FSFileName *, NSError *))reply {
    reply(nil, nil, posix(EROFS));
}

- (void)createLinkToItem:(FSItem *)item
                   named:(FSFileName *)name
             inDirectory:(FSItem *)directory
            replyHandler:(void (^)(FSFileName *, NSError *))reply {
    reply(nil, posix(EROFS));
}

- (void)renameItem:(FSItem *)item
       inDirectory:(FSItem *)sourceDirectory
             named:(FSFileName *)sourceName
         toNewName:(FSFileName *)destinationName
       inDirectory:(FSItem *)destinationDirectory
          overItem:(FSItem *)overItem
      replyHandler:(void (^)(FSFileName *, NSError *))reply {
    reply(nil, posix(EROFS));
}

- (void)removeItem:(FSItem *)item
             named:(FSFileName *)name
     fromDirectory:(FSItem *)directory
      replyHandler:(void (^)(NSError *))reply {
    reply(posix(EROFS));
}

#pragma mark - FSVolumeOpenCloseOperations

- (void)openItem:(FSItem *)item withModes:(FSVolumeOpenModes)modes replyHandler:(void (^)(NSError *))reply {
    reply(modes & FSVolumeOpenModesWrite ? posix(EROFS) : nil);
}

- (void)closeItem:(FSItem *)item keepingModes:(FSVolumeOpenModes)modes replyHandler:(void (^)(NSError *))reply {
    reply(nil);
}

#pragma mark - FSVolumeReadWriteOperations

- (void)readFromFile:(FSItem *)item
              offset:(off_t)offset
              length:(size_t)length
          intoBuffer:(FSMutableFileDataBuffer *)buffer
        replyHandler:(void (^)(size_t, NSError *))reply {
    MTPItem *file = (MTPItem *)item;
    if (file.isDirectory) return reply(0, posix(EISDIR));
    if (offset < 0) return reply(0, posix(EINVAL));
    uint64_t end = MIN(file.size, (uint64_t)offset + MIN(length, buffer.length));
    uint8_t *dst = buffer.mutableBytes;
    size_t done = 0;
    for (uint64_t off = (uint64_t)offset; off < end;) {
        uint32_t len = (uint32_t)MIN(end - off, kMaxRead);
        NSError *err = nil;
        NSData *d = [_device readObject:file.handle offset:off length:len error:&err];
        if (!d) {
            os_log_error(vlog, "read %{public}@ at %llu failed: %{public}@", file.name, off, err.localizedDescription);
            return reply(done, posix(_device.disconnected ? ENXIO : EIO));
        }
        if (!d.length) break;
        size_t n = MIN(d.length, (size_t)(end - off));
        memcpy(dst + done, d.bytes, n);
        done += n;
        off += n;
    }
    reply(done, nil);
}

- (void)writeContents:(NSData *)contents
               toFile:(FSItem *)item
             atOffset:(off_t)offset
         replyHandler:(void (^)(size_t, NSError *))reply {
    reply(0, posix(EROFS));
}

@end
