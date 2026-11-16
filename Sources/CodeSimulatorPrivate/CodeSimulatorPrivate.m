#import "CodeSimulatorPrivate.h"

#if TARGET_OS_OSX
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// The message SimulatorKit builds for the device's HID system; only ever handed back to SimulatorKit.
typedef struct IndigoHIDMessageStruct IndigoHIDMessage;
// IndigoHIDMessage *IndigoHIDMessageForMouseNSEvent(CGPoint *, CGPoint *, IndigoHIDTarget, NSEventType, NSSize, IndigoHIDEdge)
// (the name in SimulatorKit's own assertion): a point and a second finger's or NULL, in the size given.
typedef IndigoHIDMessage *(*MouseMessageFunction)(const CGPoint *, const CGPoint *, uint32_t, NSUInteger, CGSize, NSUInteger);
typedef IndigoHIDMessage *(*ButtonMessageFunction)(uint32_t source, uint32_t direction, uint32_t target);
typedef IndigoHIDMessage *(*KeyboardMessageFunction)(uint32_t usage, uint32_t direction);

static MouseMessageFunction mouseMessage;
static ButtonMessageFunction buttonMessage;
static KeyboardMessageFunction keyboardMessage;
static Class serviceContextClass;
static Class hidClientClass;
static NSString *loadedDeveloperDirectory;

static const uint32_t touchTarget = 0x32;
static const uint32_t buttonTarget = 0x33;
static const uint32_t directionDown = 1;
static const uint32_t directionUp = 2;

static NSError *CSPError(NSString *message) {
  return [NSError errorWithDomain:@"CodeSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id CSPSend(id target, const char *selector) {
  SEL sel = sel_registerName(selector);
  if (![target respondsToSelector:sel]) return nil;
  return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

@implementation CSPSimulator {
  id _device;
  id _display;        // the main display's descriptor (a proxy)
  NSUUID *_callbackID;
  id _hidClient;
  IOSurfaceRef _surface;
  BOOL _usesScreenCallbacks;
}

+ (BOOL)loadFrameworksWithDeveloperDirectory:(NSString *)developerDirectory error:(NSError **)error {
  if (loadedDeveloperDirectory) return YES;
  NSString *core = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
  NSString *kit = [[developerDirectory stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
  if (!dlopen(core.fileSystemRepresentation, RTLD_NOW)) {
    if (error) *error = CSPError(@"CoreSimulator isn't installed. It comes with Xcode.");
    return NO;
  }
  void *handle = dlopen(kit.fileSystemRepresentation, RTLD_NOW);
  if (!handle) {
    if (error) *error = CSPError([NSString stringWithFormat:@"Xcode's SimulatorKit isn't at %@.", kit]);
    return NO;
  }
  mouseMessage = (MouseMessageFunction)dlsym(handle, "IndigoHIDMessageForMouseNSEvent");
  buttonMessage = (ButtonMessageFunction)dlsym(handle, "IndigoHIDMessageForButton");
  keyboardMessage = (KeyboardMessageFunction)dlsym(handle, "IndigoHIDMessageForKeyboardArbitrary");
  serviceContextClass = NSClassFromString(@"SimServiceContext");
  hidClientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
  if (!serviceContextClass ||
      ![serviceContextClass respondsToSelector:sel_registerName("sharedServiceContextForDeveloperDir:error:")]) {
    if (error) *error = CSPError(@"This Xcode's CoreSimulator has no service context Code knows.");
    return NO;
  }
  loadedDeveloperDirectory = [developerDirectory copy];
  return YES;
}

- (nullable instancetype)initWithUDID:(NSString *)udid error:(NSError **)error {
  if (!(self = [super init])) return nil;
  if (!loadedDeveloperDirectory) {
    if (error) *error = CSPError(@"The simulator frameworks aren't loaded.");
    return nil;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
  NSError *underlying = nil;
  id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
      serviceContextClass, sel_registerName("sharedServiceContextForDeveloperDir:error:"), loadedDeveloperDirectory,
      &underlying);
  id set = nil;
  if ([context respondsToSelector:sel_registerName("defaultDeviceSetWithError:")]) {
    set = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, sel_registerName("defaultDeviceSetWithError:"), &underlying);
  }
  NSDictionary *devices = CSPSend(set, "devicesByUDID");
  _device = uuid && [devices isKindOfClass:NSDictionary.class] ? devices[uuid] : nil;
  if (!_device) {
    if (error) *error = underlying ?: CSPError([NSString stringWithFormat:@"No simulator with the identifier %@.", udid]);
    return nil;
  }
  _callbackID = [NSUUID UUID];
  return self;
}

- (void)dealloc {
  [self detach];
}

- (NSString *)name {
  id name = CSPSend(_device, "name");
  return [name isKindOfClass:NSString.class] ? name : @"";
}

- (NSString *)stateDescription {
  id state = CSPSend(_device, "stateString");
  return [state isKindOfClass:NSString.class] ? state : @"";
}

- (BOOL)isBooted {
  SEL sel = sel_registerName("state");
  if (![_device respondsToSelector:sel]) return NO;
  return ((NSUInteger (*)(id, SEL))objc_msgSend)(_device, sel) == 3;
}

- (double)screenScale {
  id type = CSPSend(_device, "deviceType");
  SEL sel = sel_registerName("mainScreenScale");
  if (![type respondsToSelector:sel]) return 0;
  return ((float (*)(id, SEL))objc_msgSend)(type, sel);
}

- (IOSurfaceRef)surface {
  return _surface;
}

- (void)setSurfaceObject:(id)surface {
  IOSurfaceRef next = surface ? (__bridge IOSurfaceRef)surface : NULL;
  if (next == _surface) return;
  if (next) CFRetain(next);
  if (_surface) CFRelease(_surface);
  _surface = next;
}

- (double)displayAngle {
  SEL sel = sel_registerName("displayAngle");
  if (![_display respondsToSelector:sel]) return 0;
  return ((double (*)(id, SEL))objc_msgSend)(_display, sel);
}

- (BOOL)attachDisplay {
  if (_display && _surface) return YES;
  [self detachDisplay];
  id io = CSPSend(_device, "io");
  id ports = CSPSend(io, "ioPorts");
  if (![ports isKindOfClass:NSArray.class]) return NO;
  SEL surfaceSel = sel_registerName("framebufferSurface");
  SEL classSel = sel_registerName("displayClass");
  id found = nil;
  for (id port in (NSArray *)ports) {
    id descriptor = CSPSend(port, "descriptor");
    if (![descriptor respondsToSelector:surfaceSel]) continue;
    // The main display is class 0; external and CarPlay displays have their own ports.
    id state = CSPSend(descriptor, "state");
    if ([state respondsToSelector:classSel] && ((unsigned short (*)(id, SEL))objc_msgSend)(state, classSel) != 0) continue;
    id surface = ((id (*)(id, SEL))objc_msgSend)(descriptor, surfaceSel);
    if (!surface) continue;
    found = descriptor;
    [self setSurfaceObject:surface];
    break;
  }
  if (!found) return NO;
  _display = found;

  __weak CSPSimulator *weak = self;
  void (^frame)(void) = ^{
    CSPSimulator *me = weak;
    if (me.frameHandler) me.frameHandler();
  };
  void (^surfaces)(id, id) = ^(id framebuffer, id masked) {
    dispatch_async(dispatch_get_main_queue(), ^{
      CSPSimulator *me = weak;
      if (!me) return;
      [me setSurfaceObject:framebuffer];
      if (me.displayChangedHandler) me.displayChangedHandler();
    });
  };
  SEL screenSel = sel_registerName("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:");
  SEL surfacesSel = sel_registerName("registerCallbackWithUUID:ioSurfacesChangeCallback:");
  SEL damageSel = sel_registerName("registerCallbackWithUUID:damageRectanglesCallback:");
  if ([_display respondsToSelector:screenSel]) {
    _usesScreenCallbacks = YES;
    ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
        _display, screenSel, _callbackID, dispatch_get_main_queue(), frame, surfaces, ^(id properties) {});
  } else {
    _usesScreenCallbacks = NO;
    if ([_display respondsToSelector:surfacesSel]) {
      ((void (*)(id, SEL, id, id))objc_msgSend)(_display, surfacesSel, _callbackID, surfaces);
    }
    if ([_display respondsToSelector:damageSel]) {
      ((void (*)(id, SEL, id, id))objc_msgSend)(_display, damageSel, _callbackID, ^(NSArray *rectangles) {
        dispatch_async(dispatch_get_main_queue(), frame);
      });
    }
  }
  SEL angleSel = sel_registerName("registerCallbackWithUUID:rotationAngleCallback:");
  if ([_display respondsToSelector:angleSel]) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(_display, angleSel, _callbackID, ^(double angle) {
      dispatch_async(dispatch_get_main_queue(), ^{
        CSPSimulator *me = weak;
        if (me.displayChangedHandler) me.displayChangedHandler();
      });
    });
  }
  return YES;
}

- (void)detachDisplay {
  if (_display) {
    const char *selectors[] = {
      _usesScreenCallbacks ? "unregisterScreenCallbacksWithUUID:" : "unregisterIOSurfacesChangeCallbackWithUUID:",
      _usesScreenCallbacks ? NULL : "unregisterDamageRectanglesCallbackWithUUID:",
      "unregisterRotationAngleCallbackWithUUID:",
    };
    for (int i = 0; i < 3; i++) {
      if (!selectors[i]) continue;
      SEL sel = sel_registerName(selectors[i]);
      if ([_display respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(_display, sel, _callbackID);
    }
  }
  _display = nil;
  [self setSurfaceObject:nil];
}

- (void)detach {
  [self detachDisplay];
  _hidClient = nil;
}

- (id)hidClient {
  if (_hidClient) return _hidClient;
  SEL sel = sel_registerName("initWithDevice:error:");
  if (!hidClientClass || ![hidClientClass instancesRespondToSelector:sel]) return nil;
  NSError *error = nil;
  _hidClient = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([hidClientClass alloc], sel, _device, &error);
  return _hidClient;
}

- (BOOL)send:(IndigoHIDMessage *)message {
  if (!message) return NO;
  id client = [self hidClient];
  SEL sel = sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:");
  if (![client respondsToSelector:sel]) {
    free(message);
    return NO;
  }
  ((void (*)(id, SEL, IndigoHIDMessage *, BOOL, id, id))objc_msgSend)(
      client, sel, message, YES, dispatch_get_main_queue(), ^(NSError *error) {});
  return YES;
}

- (BOOL)sendTouch:(CSPTouchPhase)phase at:(CGPoint)point second:(const CGPoint *)second {
  if (!mouseMessage) return NO;
  // NSEventType: left mouse down 1, up 2, dragged 6.
  NSUInteger type = phase == CSPTouchPhaseDown ? 1 : phase == CSPTouchPhaseUp ? 2 : 6;
  return [self send:mouseMessage(&point, second, touchTarget, type, CGSizeMake(1, 1), 0)];
}

- (BOOL)sendButton:(CSPButton)button down:(BOOL)down {
  if (!buttonMessage) return NO;
  uint32_t source = 0;
  switch (button) {
    case CSPButtonHome: source = 0x0; break;
    case CSPButtonLock: source = 0x1; break;
    case CSPButtonSide: source = 0xbb8; break;
    case CSPButtonSiri: source = 0x400002; break;
  }
  return [self send:buttonMessage(source, down ? directionDown : directionUp, buttonTarget)];
}

- (BOOL)sendKeyUsage:(uint32_t)usage down:(BOOL)down {
  if (!keyboardMessage) return NO;
  return [self send:keyboardMessage(usage, down ? directionDown : directionUp)];
}

@end
#endif
