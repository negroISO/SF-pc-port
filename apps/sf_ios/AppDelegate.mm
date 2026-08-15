#import <UIKit/UIKit.h>

#include "sf/game/supported_games.hpp"

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
    (void)connectionOptions;

    if (![scene isKindOfClass:UIWindowScene.class]) {
        return;
    }

    const auto supportedGames = sf::game::supportedGames();

    UIViewController *rootViewController = [[UIViewController alloc] init];
    rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.text = @"Syphon Filter";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.accessibilityIdentifier = @"sf-ios-bootstrap-title";

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    statusLabel.adjustsFontForContentSizeCategory = YES;
    statusLabel.textColor = UIColor.secondaryLabelColor;
    statusLabel.numberOfLines = 0;
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.text = [NSString
        stringWithFormat:@"Portable runtime linked (%lu supported build).\nRenderer and disc import are not connected yet.",
                         static_cast<unsigned long>(supportedGames.size())];
    statusLabel.accessibilityIdentifier = @"sf-ios-bootstrap-status";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel,
        statusLabel,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;

    [rootViewController.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:rootViewController.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:rootViewController.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:rootViewController.view.safeAreaLayoutGuide.leadingAnchor
                                                            constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:rootViewController.view.safeAreaLayoutGuide.trailingAnchor
                                                             constant:-24.0],
    ]];

    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = rootViewController;
    [self.window makeKeyAndVisible];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SFIOSAppDelegate.class));
    }
}
