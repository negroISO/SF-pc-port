#import "SFRootViewController.h"

#import "SFDiscLibrary.h"
#import "SFGameControllerBridge.h"

#include "sf/game/supported_games.hpp"

@interface SFRootViewController ()
@property(nonatomic, strong) SFDiscLibrary *discLibrary;
@property(nonatomic, strong) SFGameControllerBridge *controllerBridge;
@property(nonatomic, strong) UILabel *controllerStatusLabel;
@property(nonatomic, strong) UILabel *discStatusLabel;
@property(nonatomic, strong) UIButton *discButton;
@property(nonatomic, strong) UIScrollView *scrollView;
@end

@implementation SFRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    const auto supportedGames = sf::game::supportedGames();

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.text = @"Syphon Filter";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.accessibilityIdentifier = @"sf-ios-bootstrap-title";

    UILabel *runtimeStatusLabel = [[UILabel alloc] init];
    runtimeStatusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    runtimeStatusLabel.adjustsFontForContentSizeCategory = YES;
    runtimeStatusLabel.textColor = UIColor.secondaryLabelColor;
    runtimeStatusLabel.numberOfLines = 0;
    runtimeStatusLabel.textAlignment = NSTextAlignmentCenter;
    runtimeStatusLabel.text =
        [NSString stringWithFormat:@"Portable runtime linked (%lu supported "
                                    "build). Renderer is not connected yet.",
                                   static_cast<unsigned long>(supportedGames.size())];
    runtimeStatusLabel.accessibilityIdentifier = @"sf-ios-bootstrap-status";

    self.controllerStatusLabel = [[UILabel alloc] init];
    self.controllerStatusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.controllerStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.controllerStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.controllerStatusLabel.numberOfLines = 0;
    self.controllerStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.controllerStatusLabel.accessibilityIdentifier =
        @"sf-ios-controller-status";

    self.discStatusLabel = [[UILabel alloc] init];
    self.discStatusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.discStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.discStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.discStatusLabel.numberOfLines = 0;
    self.discStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.discStatusLabel.accessibilityIdentifier = @"sf-ios-disc-status";

    self.discButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.discButton setTitle:@"Choose Disc Folder" forState:UIControlStateNormal];
    self.discButton.titleLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.discButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.discButton.accessibilityIdentifier = @"sf-ios-choose-disc-folder";
    [self.discButton addTarget:self
                        action:@selector(chooseDiscFolder:)
              forControlEvents:UIControlEventTouchUpInside];

    UILabel *persistenceLabel = [[UILabel alloc] init];
    persistenceLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    persistenceLabel.adjustsFontForContentSizeCategory = YES;
    persistenceLabel.textColor = UIColor.tertiaryLabelColor;
    persistenceLabel.numberOfLines = 0;
    persistenceLabel.textAlignment = NSTextAlignmentCenter;
    persistenceLabel.text = @"External files survive app deletion. After a "
                             "reinstall, iOS requires choosing the folder again.";
    persistenceLabel.accessibilityIdentifier = @"sf-ios-disc-persistence-note";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel,
        runtimeStatusLabel,
        self.controllerStatusLabel,
        self.discStatusLabel,
        self.discButton,
        persistenceLabel,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.accessibilityIdentifier = @"sf-ios-bootstrap-scroll-view";
    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    [self.scrollView addSubview:contentView];
    [contentView addSubview:stack];
    NSLayoutConstraint *preferredContentHeight = [contentView.heightAnchor
        constraintEqualToAnchor:self.scrollView.frameLayoutGuide.heightAnchor];
    preferredContentHeight.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.scrollView.trailingAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.scrollView.topAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [contentView.leadingAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [contentView.trailingAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [contentView.topAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [contentView.bottomAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [contentView.widthAnchor
            constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
        [contentView.heightAnchor
            constraintGreaterThanOrEqualToAnchor:self.scrollView.frameLayoutGuide.heightAnchor],
        preferredContentHeight,
        [stack.centerXAnchor
            constraintEqualToAnchor:contentView.centerXAnchor],
        [stack.centerYAnchor
            constraintEqualToAnchor:contentView.centerYAnchor],
        [stack.topAnchor
            constraintGreaterThanOrEqualToAnchor:contentView.topAnchor
                                         constant:24.0],
        [stack.bottomAnchor
            constraintLessThanOrEqualToAnchor:contentView.bottomAnchor
                                      constant:-24.0],
        [stack.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:contentView.leadingAnchor
                                         constant:24.0],
        [stack.trailingAnchor
            constraintLessThanOrEqualToAnchor:contentView.trailingAnchor
                                      constant:-24.0],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:620.0],
    ]];

    self.discLibrary = [[SFDiscLibrary alloc] init];
    __weak SFRootViewController *weakSelf = self;
    self.discLibrary.statusHandler = ^(NSString *status, BOOL ready) {
        SFRootViewController *strongSelf = weakSelf;
        strongSelf.discStatusLabel.text = status;
        strongSelf.discStatusLabel.textColor =
            ready ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        [strongSelf.discButton
            setTitle:(ready ? @"Change Disc Folder" : @"Choose Disc Folder")
            forState:UIControlStateNormal];
    };
    [self.discLibrary restoreSelectedFolder];

    self.controllerBridge = [[SFGameControllerBridge alloc] init];
    self.controllerBridge.statusHandler = ^(NSString *status, BOOL ready) {
        SFRootViewController *strongSelf = weakSelf;
        strongSelf.controllerStatusLabel.text = status;
        strongSelf.controllerStatusLabel.textColor =
            ready ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    };
    [self.controllerBridge startMonitoring];
}

- (void)chooseDiscFolder:(UIButton *)sender {
    (void)sender;
    [self.discLibrary presentFolderPickerFromViewController:self];
}

- (void)requestDiscFolderForIncomingCUE {
    [self loadViewIfNeeded];
    self.discStatusLabel.text = @"Disc: To access the BIN beside that CUE, "
                                "select their containing folder.";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.presentedViewController == nil) {
            [self.discLibrary presentFolderPickerFromViewController:self];
        }
    });
}

@end
