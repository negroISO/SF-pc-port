#import "SFGameControllerBridge.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace {

constexpr std::uint16_t ps1_select = 0x0001U;
constexpr std::uint16_t ps1_l3 = 0x0002U;
constexpr std::uint16_t ps1_r3 = 0x0004U;
constexpr std::uint16_t ps1_start = 0x0008U;
constexpr std::uint16_t ps1_up = 0x0010U;
constexpr std::uint16_t ps1_right = 0x0020U;
constexpr std::uint16_t ps1_down = 0x0040U;
constexpr std::uint16_t ps1_left = 0x0080U;
constexpr std::uint16_t ps1_l2 = 0x0100U;
constexpr std::uint16_t ps1_r2 = 0x0200U;
constexpr std::uint16_t ps1_l1 = 0x0400U;
constexpr std::uint16_t ps1_r1 = 0x0800U;
constexpr std::uint16_t ps1_triangle = 0x1000U;
constexpr std::uint16_t ps1_circle = 0x2000U;
constexpr std::uint16_t ps1_cross = 0x4000U;
constexpr std::uint16_t ps1_square = 0x8000U;

os_log_t controllerLog() {
    static os_log_t log = os_log_create("com.syphonfilter.port", "controller");
    return log;
}

void setPressed(std::uint16_t& buttons, std::uint16_t mask, BOOL pressed) {
    if (pressed) {
        buttons = static_cast<std::uint16_t>(buttons | mask);
    }
}

std::uint16_t ps1Buttons(GCExtendedGamepad *gamepad) {
    std::uint16_t buttons = 0U;
    setPressed(buttons, ps1_cross, gamepad.buttonA.isPressed);
    setPressed(buttons, ps1_circle, gamepad.buttonB.isPressed);
    setPressed(buttons, ps1_square, gamepad.buttonX.isPressed);
    setPressed(buttons, ps1_triangle, gamepad.buttonY.isPressed);
    setPressed(buttons, ps1_l1, gamepad.leftShoulder.isPressed);
    setPressed(buttons, ps1_r1, gamepad.rightShoulder.isPressed);
    setPressed(buttons, ps1_l2, gamepad.leftTrigger.isPressed);
    setPressed(buttons, ps1_r2, gamepad.rightTrigger.isPressed);
    setPressed(buttons, ps1_l3, gamepad.leftThumbstickButton.isPressed);
    setPressed(buttons, ps1_r3, gamepad.rightThumbstickButton.isPressed);
    setPressed(buttons, ps1_up, gamepad.dpad.up.isPressed);
    setPressed(buttons, ps1_right, gamepad.dpad.right.isPressed);
    setPressed(buttons, ps1_down, gamepad.dpad.down.isPressed);
    setPressed(buttons, ps1_left, gamepad.dpad.left.isPressed);
    setPressed(buttons, ps1_select, gamepad.buttonOptions.isPressed);
    setPressed(buttons, ps1_start, gamepad.buttonMenu.isPressed);
    return buttons;
}

std::uint8_t quantizedAxis(float value) {
    const auto clamped = std::clamp(value, -1.0F, 1.0F);
    return static_cast<std::uint8_t>(
        std::lround((static_cast<double>(clamped) + 1.0) * 127.5));
}

std::array<std::uint8_t, 4U> quantizedAxes(GCExtendedGamepad *gamepad) {
    return {
        quantizedAxis(gamepad.rightThumbstick.xAxis.value),
        quantizedAxis(-gamepad.rightThumbstick.yAxis.value),
        quantizedAxis(gamepad.leftThumbstick.xAxis.value),
        quantizedAxis(-gamepad.leftThumbstick.yAxis.value),
    };
}

NSString *controllerFamily(GCController *controller) {
    NSString *category = controller.productCategory;
    if ([category isEqualToString:GCProductCategoryXboxOne]) {
        return @"Xbox";
    }
    if ([category isEqualToString:GCProductCategoryDualShock4]) {
        return @"DualShock 4";
    }
    if ([category isEqualToString:GCProductCategoryDualSense]) {
        return @"DualSense";
    }
    if ([category isEqualToString:GCProductCategoryMFi]) {
        return @"MFi";
    }
    return @"GameController";
}

NSString *noControllerStatus() {
    return @"Controller: No extended gamepad detected. Connect a supported "
            "Xbox, DualShock 4, DualSense, or MFi controller by USB-C or "
            "pair it in Bluetooth Settings.";
}

} // namespace

@interface SFGameControllerBridge ()
@property(nonatomic, strong) NSMutableArray<id> *observerTokens;
@property(nonatomic, strong, nullable) GCController *activeController;
@property(nonatomic, strong, nullable) NSTimer *pollTimer;
@property(nonatomic) BOOL monitoring;
@property(nonatomic) BOOL suspended;
@property(nonatomic) std::uint16_t lastLoggedButtons;
@property(nonatomic) std::array<std::uint8_t, 4U> lastLoggedAxes;
@end

@implementation SFGameControllerBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _observerTokens = [[NSMutableArray alloc] init];
        _lastLoggedButtons = 0xffffU;
        _lastLoggedAxes = {0U, 0U, 0U, 0U};
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
}

- (void)emitStatus:(NSString *)status ready:(BOOL)ready {
    if (self.statusHandler != nil) {
        self.statusHandler(status, ready);
    }
}

- (void)startMonitoring {
    if (self.monitoring) {
        return;
    }
    self.monitoring = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak SFGameControllerBridge *weakSelf = self;
    [self.observerTokens addObject:
        [center addObserverForName:GCControllerDidConnectNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
        [weakSelf controllerDidConnect:notification];
    }]];
    [self.observerTokens addObject:
        [center addObserverForName:GCControllerDidDisconnectNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
        [weakSelf controllerDidDisconnect:notification];
    }]];
    [self.observerTokens addObject:
        [center addObserverForName:GCControllerDidBecomeCurrentNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
        GCController *controller = (GCController *)notification.object;
        if (controller.extendedGamepad != nil) {
            weakSelf.lastLoggedButtons = 0xffffU;
            weakSelf.lastLoggedAxes = {0U, 0U, 0U, 0U};
            weakSelf.activeController = controller;
            [weakSelf publishController:controller inputChanged:NO];
        }
    }]];
    [self.observerTokens addObject:
        [center addObserverForName:UIApplicationWillResignActiveNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
        (void)notification;
        weakSelf.suspended = YES;
        [weakSelf emitStatus:@"Controller: Diagnostic monitoring is paused "
                             "while the app is inactive."
                        ready:NO];
    }]];
    [self.observerTokens addObject:
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
        (void)notification;
        weakSelf.suspended = NO;
        [weakSelf rescanControllers];
    }]];

    [self rescanControllers];
    [self runSyntheticSmokeIfRequested];
    self.pollTimer = [NSTimer timerWithTimeInterval:(1.0 / 15.0)
                                            repeats:YES
                                              block:^(NSTimer *timer) {
        [weakSelf pollController:timer];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopMonitoring {
    if (!self.monitoring) {
        return;
    }
    self.monitoring = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    for (id token in self.observerTokens) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
    }
    [self.observerTokens removeAllObjects];
    self.activeController = nil;
}

- (void)pollController:(NSTimer *)timer {
    (void)timer;
    if (!self.monitoring || self.suspended || self.activeController == nil) {
        return;
    }
    [self publishController:self.activeController inputChanged:YES];
}

- (void)rescanControllers {
    GCController *candidate = GCController.current;
    if (candidate.extendedGamepad == nil) {
        candidate = nil;
        for (GCController *controller in GCController.controllers) {
            if (controller.extendedGamepad != nil) {
                candidate = controller;
                break;
            }
        }
    }
    if (candidate != self.activeController) {
        self.lastLoggedButtons = 0xffffU;
        self.lastLoggedAxes = {0U, 0U, 0U, 0U};
    }
    self.activeController = candidate;
    if (candidate == nil) {
        os_log_info(controllerLog(), "no extended controller detected");
        [self emitStatus:noControllerStatus() ready:NO];
    } else {
        [self publishController:candidate inputChanged:NO];
    }
}

- (void)controllerDidConnect:(NSNotification *)notification {
    GCController *controller = (GCController *)notification.object;
    if (controller.extendedGamepad == nil) {
        return;
    }
    if (self.activeController == nil) {
        self.lastLoggedButtons = 0xffffU;
        self.lastLoggedAxes = {0U, 0U, 0U, 0U};
        self.activeController = controller;
    }
    os_log_info(controllerLog(), "extended controller connected family=%{public}s",
                controllerFamily(controller).UTF8String);
    [self publishController:self.activeController inputChanged:NO];
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    GCController *controller = (GCController *)notification.object;
    os_log_info(controllerLog(), "extended controller disconnected");
    if (self.activeController == controller) {
        self.activeController = nil;
        self.lastLoggedButtons = 0xffffU;
        self.lastLoggedAxes = {0U, 0U, 0U, 0U};
        [self rescanControllers];
    }
}

- (void)publishController:(GCController *)controller
              inputChanged:(BOOL)inputChanged {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (gamepad == nil) {
        [self emitStatus:noControllerStatus() ready:NO];
        return;
    }
    const auto buttons = ps1Buttons(gamepad);
    const auto axes = quantizedAxes(gamepad);
    const auto shouldLog = buttons != self.lastLoggedButtons ||
                           axes != self.lastLoggedAxes;
    if (inputChanged && !shouldLog) {
        return;
    }
    if (shouldLog) {
        self.lastLoggedButtons = buttons;
        self.lastLoggedAxes = axes;
        os_log_info(controllerLog(),
                    "input family=%{public}s mask=0x%04x axes=%u,%u,%u,%u",
                    controllerFamily(controller).UTF8String, buttons, axes[0],
                    axes[1], axes[2], axes[3]);
    }
    NSString *state = inputChanged
        ? [NSString stringWithFormat:
              @"Controller: %@ diagnostic input observed (PS1 mask 0x%04x; axes "
               "%u,%u,%u,%u).",
              controllerFamily(controller), buttons, axes[0], axes[1], axes[2],
              axes[3]]
        : [NSString stringWithFormat:
              @"Controller: %@ detected by Apple GameController for wired or "
               "Bluetooth input (diagnostic only; gameplay handoff pending).",
              controllerFamily(controller)];
    [self emitStatus:state ready:YES];
}

- (void)runSyntheticSmokeIfRequested {
#if !defined(NDEBUG)
    NSString *enabled = NSProcessInfo.processInfo.environment[
        @"SF_CONTROLLER_PROBE_SELF_TEST"];
    if (![enabled isEqualToString:@"1"]) {
        return;
    }
    GCController *controller = [GCController controllerWithExtendedGamepad];
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    [gamepad.buttonA setValue:1.0F];
    [gamepad.leftTrigger setValue:1.0F];
    [gamepad.dpad.yAxis setValue:1.0F];
    [gamepad.leftThumbstick.xAxis setValue:0.5F];
    [gamepad.leftThumbstick.yAxis setValue:-0.25F];
    const auto buttons = ps1Buttons(gamepad);
    const auto axes = quantizedAxes(gamepad);
    constexpr auto expected =
        static_cast<std::uint16_t>(ps1_cross | ps1_l2 | ps1_up);
    const auto passed = buttons == expected && axes[2] == 191U && axes[3] == 159U;
    os_log_info(controllerLog(),
                "synthetic mapping smoke %{public}s mask=0x%04x axes=%u,%u,%u,%u",
                passed ? "passed" : "failed", buttons, axes[0], axes[1], axes[2],
                axes[3]);
    if (!passed) {
        os_log_error(controllerLog(),
                     "synthetic mapping smoke failed; physical readiness unchanged");
    }
#endif
}

@end
