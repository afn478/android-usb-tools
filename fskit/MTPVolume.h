#import <FSKit/FSKit.h>

#import "MTPDevice.h"

NS_ASSUME_NONNULL_BEGIN

// The phone as one volume: each MTP storage ("Internal shared storage", an SD
// card) is a folder at the top level. Read-only for now.
@interface MTPVolume : FSVolume <FSVolumeOperations, FSVolumePathConfOperations, FSVolumeOpenCloseOperations,
                                 FSVolumeReadWriteOperations>
- (instancetype)initWithDevice:(MTPDevice *)device name:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
