#import <UIKit/UIKit.h>

#import "SFRootViewController.h"

@interface SFIOSAppDelegate : UIResponder <UIApplicationDelegate>
@end

@interface SFIOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SFIOSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;
    return YES;
}

@end

@implementation SFIOSSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    (void)session;
    if (![scene isKindOfClass:UIWindowScene.class]) {
        return;
    }

    SFRootViewController *rootViewController =
        [[SFRootViewController alloc] init];

    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = rootViewController;
    [self.window makeKeyAndVisible];

    if (connectionOptions.URLContexts.count > 0U) {
        [rootViewController requestDiscFolderForIncomingCUE];
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    (void)scene;
    if (URLContexts.count == 0U) {
        return;
    }
    SFRootViewController *rootViewController =
        (SFRootViewController *)self.window.rootViewController;
    [rootViewController requestDiscFolderForIncomingCUE];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SFIOSAppDelegate.class));
    }
}
