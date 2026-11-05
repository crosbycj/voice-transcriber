#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch Objective-C exceptions, and AVAudioEngine raises them for conditions that can
/// appear between checking a format and using it, such as a device changing mid-restart.
@interface VTExceptionCatcher : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
