#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

typedef void (^SFDiscLibraryStatusHandler)(NSString *status,
                                           BOOL discPairReady);

// Owns the security-scoped directory lease for the selected external folder.
// cueURL remains valid only while this object is alive and until another folder
// is successfully selected. The URL does not provide an ongoing coordinated
// read: a future runtime must coordinate each CUE/BIN operation and finish using
// the old URL before changing the selection or releasing this object.
@interface SFDiscLibrary : NSObject

@property(nonatomic, copy, nullable) SFDiscLibraryStatusHandler statusHandler;
@property(nonatomic, strong, readonly, nullable) NSURL *cueURL;

- (void)restoreSelectedFolder;
- (void)presentFolderPickerFromViewController:(UIViewController *)viewController;

@end

NS_ASSUME_NONNULL_END
