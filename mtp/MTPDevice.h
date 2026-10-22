// MTP over USB on IOUSBHost. Shared by the FSKit module and mtp-probe.
//
// The protocol handling follows the mtp package of github.com/hanwen/go-mtpfs
// (BSD-3), rewritten for IOUSBHost.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MTPErrorDomain;

// Parent value that lists the top level of a storage.
static const uint32_t MTPRootParent = 0xFFFFFFFF;

typedef NS_ENUM(uint16_t, MTPObjectFormat) {
    MTPObjectFormatAssociation = 0x3001,  // a folder
};

@interface MTPDeviceInfo : NSObject
@property (copy) NSString *manufacturer, *model, *deviceVersion, *serialNumber, *vendorExtension;
@property (copy) NSArray<NSNumber *> *operationsSupported;
- (BOOL)supportsOperation:(uint16_t)code;
@end

@interface MTPStorageInfo : NSObject
@property uint32_t storageID;
@property uint16_t storageType, filesystemType, accessCapability;
@property uint64_t maxCapacity, freeSpace;
@property (copy) NSString *storageDescription, *volumeLabel;
@property (readonly) BOOL isReadOnly;
@end

@interface MTPObjectInfo : NSObject
@property uint32_t handle, storageID, parent;
@property uint16_t format;
@property uint64_t size;
@property (copy) NSString *filename;
@property (nullable, copy) NSDate *created, *modified;
@property (readonly) BOOL isDirectory;
@end

@interface MTPDevice : NSObject

// MTP interfaces currently attached, one per phone in File transfer mode.
+ (NSArray<NSNumber *> *)copyInterfaceServices;
// USB serial number of the phone an interface belongs to.
+ (nullable NSString *)serialForInterfaceService:(io_service_t)service;
+ (nullable NSString *)productNameForInterfaceService:(io_service_t)service;

// Claims the interface and opens an MTP session.
- (nullable instancetype)initWithService:(io_service_t)service error:(NSError **)error;
- (void)close;

@property (readonly) BOOL disconnected;
@property (readonly) MTPDeviceInfo *deviceInfo;

- (nullable NSArray<NSNumber *> *)storageIDs:(NSError **)error;
- (nullable MTPStorageInfo *)storageInfo:(uint32_t)storageID error:(NSError **)error;
- (nullable NSArray<NSNumber *> *)objectHandlesInStorage:(uint32_t)storageID
                                                  parent:(uint32_t)parent
                                                   error:(NSError **)error;
// Everything in a folder (or a storage's top level with MTPRootParent).
- (nullable NSArray<MTPObjectInfo *> *)objectsInStorage:(uint32_t)storageID
                                                  parent:(uint32_t)parent
                                                   error:(NSError **)error;
- (nullable MTPObjectInfo *)objectInfo:(uint32_t)handle error:(NSError **)error;
- (nullable NSData *)readObject:(uint32_t)handle
                         offset:(uint64_t)offset
                         length:(uint32_t)length
                          error:(NSError **)error;

// Writing. Files are created empty and filled with Android's edit
// extensions: begin, write/truncate at any offset, end.
- (nullable MTPObjectInfo *)createObjectNamed:(NSString *)name
                                    directory:(BOOL)directory
                                    inStorage:(uint32_t)storageID
                                       parent:(uint32_t)parent
                                        error:(NSError **)error;
- (BOOL)deleteObject:(uint32_t)handle error:(NSError **)error;
- (BOOL)renameObject:(uint32_t)handle to:(NSString *)name error:(NSError **)error;
@property (readonly) BOOL canMoveObjects, canEditObjects;
- (BOOL)moveObject:(uint32_t)handle toStorage:(uint32_t)storageID parent:(uint32_t)parent error:(NSError **)error;
- (BOOL)beginEditing:(uint32_t)handle error:(NSError **)error;
- (BOOL)endEditing:(uint32_t)handle error:(NSError **)error;
- (BOOL)writeObject:(uint32_t)handle offset:(uint64_t)offset data:(NSData *)data error:(NSError **)error;
- (BOOL)truncateObject:(uint32_t)handle length:(uint64_t)length error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
