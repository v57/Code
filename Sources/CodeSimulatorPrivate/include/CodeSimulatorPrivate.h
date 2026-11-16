// Xcode's simulator frameworks (CoreSimulator, SimulatorKit), loaded at run time from the installed Xcode: a booted
// simulator's framebuffer and its input, without Simulator.app. Private interfaces, so everything is looked up by
// name and every call can fail; CodeSimulator (Swift) is the API. Checked against Xcode 27.2.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CSPTouchPhase) {
  CSPTouchPhaseDown = 0,
  CSPTouchPhaseMoved = 1,
  CSPTouchPhaseUp = 2,
};

typedef NS_ENUM(NSInteger, CSPButton) {
  CSPButtonHome = 0,
  CSPButtonLock = 1,
  CSPButtonSide = 2,
  CSPButtonSiri = 3,
};

/// One simulator device. Use it from the main thread; its callbacks arrive there.
@interface CSPSimulator : NSObject

/// Loads CoreSimulator and the SimulatorKit of the Xcode at `developerDirectory` (`xcode-select -p`). Safe to call
/// again; NO with the reason when a framework or a class this file needs is missing.
+ (BOOL)loadFrameworksWithDeveloperDirectory:(NSString *)developerDirectory error:(NSError **)error;

/// The device with this UDID in the default device set, or nil.
- (nullable instancetype)initWithUDID:(NSString *)udid error:(NSError **)error;

@property(nonatomic, readonly) NSString *name;
/// "Booted", "Shutdown", "Booting"…
@property(nonatomic, readonly) NSString *stateDescription;
@property(nonatomic, readonly) BOOL isBooted;

/// Pixels per point of the device's main screen (3 on most iPhones, 2 on iPads), or 0 when it can't be asked.
@property(nonatomic, readonly) double screenScale;

/// Finds the main display and starts following it. NO while the device has none (not booted yet): call again.
- (BOOL)attachDisplay;
/// Stops following the display and closes the input session.
- (void)detach;

/// The main display's framebuffer, BGRA, in the device's native (portrait) pixels; nil until attached.
@property(nonatomic, readonly, nullable) IOSurfaceRef surface;
/// Quarter turns the picture is shown at (the device's orientation), in radians, as the display reports it.
@property(nonatomic, readonly) double displayAngle;
/// A frame was drawn into `surface`.
@property(nonatomic, copy, nullable) void (^frameHandler)(void);
/// `surface` is another surface now (the device rebooted, the display changed), or `displayAngle` changed.
@property(nonatomic, copy, nullable) void (^displayChangedHandler)(void);

/// A finger at `point` (0…1 of the framebuffer, origin top left); `second` adds another finger. NO when the message
/// couldn't be made or the input session couldn't open (moves closer than a frame apart are dropped, also NO).
- (BOOL)sendTouch:(CSPTouchPhase)phase at:(CGPoint)point second:(nullable const CGPoint *)second;
- (BOOL)sendButton:(CSPButton)button down:(BOOL)down;
/// A key by its USB HID usage (keyboard page).
- (BOOL)sendKeyUsage:(uint32_t)usage down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
#endif
