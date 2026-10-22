#import <FSKit/FSKit.h>

NS_ASSUME_NONNULL_BEGIN

// Mounts mtp://<USB serial number> as the phone with that serial.
@interface MTPFileSystem : FSUnaryFileSystem <FSUnaryFileSystemOperations>
@end

NS_ASSUME_NONNULL_END
