#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SFGameControllerStatusHandler)(NSString *status,
                                               BOOL controllerReady);

// Bootstrap diagnostic for Apple's GameController transport. This object polls
// controller snapshots and deliberately does not install element handlers or
// change handlerQueue. Stop it before SDL2/PsyCross starts its final gameplay
// input pipeline.
@interface SFGameControllerBridge : NSObject

@property(nonatomic, copy, nullable) SFGameControllerStatusHandler statusHandler;

- (void)startMonitoring;
- (void)stopMonitoring;

@end

NS_ASSUME_NONNULL_END
