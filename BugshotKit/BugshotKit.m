//  BugshotKit.m
//  See included LICENSE file for the (MIT) license.
//  Created by Marco Arment on 1/15/14.

#import "BugshotKit.h"
#import "TargetConditionals.h"
#import "BSKNavigationController.h"
#import <asl.h>
#import "MABGTimer.h"
@import CoreText;

@interface UIViewController ()
- (void)attentionClassDumpUser:(id)fp8 yesItsUsAgain:(id)fp12 althoughSwizzlingAndOverridingPrivateMethodsIsFun:(id)fp16 itWasntMuchFunWhenYourAppStoppedWorking:(id)fp20 pleaseRefrainFromDoingSoInTheFutureOkayThanksBye:(id)fp24;
@end

NSString * const BSKNewLogMessageNotification = @"BSKNewLogMessageNotification";

UIImage *BSKImageWithDrawing(CGSize size, void (^drawingCommands)(void))
{
    UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
    drawingCommands();
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return finalImage;
}


@interface BSKLogMessage : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic, copy) NSString *message;
@end

@implementation BSKLogMessage
@end


@interface BugshotKit () {
    dispatch_source_t source;
}
@property (nonatomic) BOOL isShowing;
@property (nonatomic) BOOL isDisabled;
@property (nonatomic, weak) BSKNavigationController *presentedNavigationController;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) NSMapTable *windowsWithGesturesAttached;

@property (nonatomic) NSMutableSet *collectedASLMessageIDs;
@property (nonatomic) NSMutableArray *consoleMessages;

@property (nonatomic) dispatch_queue_t logQueue;
@property (nonatomic) BSK_MABGTimer *consoleRefreshThrottler;

@property (nonatomic) BSKInvocationGestureMask invocationGestures;
@property (nonatomic) NSUInteger invocationGesturesTouchCount;

@end

@implementation BugshotKit

+ (instancetype)sharedManager
{
    static dispatch_once_t onceToken;
    static BugshotKit *sharedManager;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

+ (void)enableWithNumberOfTouches:(NSUInteger)fingerCount performingGestures:(BSKInvocationGestureMask)invocationGestures feedbackEmailAddress:(NSString *)toEmailAddress
{
    if (BugshotKit.sharedManager.isDisabled) return;
    BugshotKit.sharedManager.invocationGestures = invocationGestures;
    BugshotKit.sharedManager.invocationGesturesTouchCount = fingerCount;
    BugshotKit.sharedManager.destinationEmailAddress = toEmailAddress;

    // dispatched to next main-thread loop so the app delegate has a chance to set up its window
    dispatch_async(dispatch_get_main_queue(), ^{
        [BugshotKit.sharedManager ensureWindow];
        [BugshotKit.sharedManager attachToWindow:BugshotKit.sharedManager.window];
    });
}

+ (void)show
{
    [BugshotKit.sharedManager ensureWindow];
    [BugshotKit.sharedManager handleOpenGesture:nil];
}

+ (void)setExtraInfoBlock:(NSDictionary *(^)(void))extraInfoBlock
{
    BugshotKit.sharedManager.extraInfoBlock = extraInfoBlock;
}

+ (void)setEmailSubjectBlock:(NSString *(^)(NSDictionary *))emailSubjectBlock
{
    BugshotKit.sharedManager.emailSubjectBlock = emailSubjectBlock;
}

+ (void)setEmailBodyBlock:(NSString *(^)(NSDictionary *))emailBodyBlock;
{
    BugshotKit.sharedManager.emailBodyBlock = emailBodyBlock;
}

+ (void)setMailComposeCustomizeBlock:(void (^)(MFMailComposeViewController *mailComposer))mailComposeCustomizeBlock
{
    BugshotKit.sharedManager.mailComposeCustomizeBlock = mailComposeCustomizeBlock;
}

+ (UIFont *)consoleFontWithSize:(CGFloat)size
{
    static dispatch_once_t onceToken;
    static NSString *consoleFontName;
    dispatch_once(&onceToken, ^{
        consoleFontName = nil;

        NSData *inData = [NSData dataWithContentsOfFile:[[NSBundle bundleForClass:[self class]].resourcePath stringByAppendingPathComponent:@"Inconsolata.otf"]];
        if (inData) {
            CFErrorRef error;
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)inData);
            CGFontRef font = CGFontCreateWithDataProvider(provider);
            if (CTFontManagerRegisterGraphicsFont(font, &error)) {
                if ([UIFont fontWithName:@"Inconsolata" size:size]) consoleFontName = @"Inconsolata";
                else NSLog(@"[BugshotKit] failed to instantiate console font");
            } else {
                CFStringRef errorDescription = CFErrorCopyDescription(error);
                NSLog(@"[BugshotKit] failed to load console font: %@", errorDescription);
                CFRelease(errorDescription);
            }
            CFRelease(font);
            CFRelease(provider);
        } else {
            NSLog(@"[BugshotKit] Console font not found. Please add Inconsolata.otf to your Resources.");
        }

        if (! consoleFontName) consoleFontName = @"CourierNewPSMT";
    });

    return [UIFont fontWithName:consoleFontName size:size];
}

- (instancetype)init
{
    if ( (self = [super init]) ) {
        if ([self.class isProbablyAppStoreBuild]) {
            self.isDisabled = YES;
            NSLog(@"[BugshotKit] App Store build detected. BugshotKit is disabled.");
            return self;
        }

        self.windowsWithGesturesAttached = [NSMapTable weakToWeakObjectsMapTable];

        self.annotationFillColor = [UIColor colorWithRed:1.0f green:0.2196f blue:0.03922f alpha:1.0f]; // Bugshot red-orange
        self.annotationStrokeColor = [UIColor whiteColor];

        self.toggleOnColor = [UIColor colorWithRed:0.533f green:0.835f blue:0.412f alpha:1.0f]; // iOS 7 green
        self.toggleOffColor = [UIColor colorWithRed:184/255.0f green:184/255.0f blue:191/255.0f alpha:1.0f]; // iOS 7ish light gray

        self.collectedASLMessageIDs = [NSMutableSet set];
        self.consoleMessages = [NSMutableArray array];
        self.logQueue = dispatch_queue_create("BugshotKit console", NULL);

        self.consoleLogMaxLines = 500;

        self.consoleRefreshThrottler = [[BSK_MABGTimer alloc] initWithObject:self behavior:BSK_MABGTimerCoalesce queueLabel:"BugshotKit console throttler"];
        [self.consoleRefreshThrottler setTargetQueue:self.logQueue];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(newWindowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIWindowDidBecomeVisibleNotification object:nil];
    if (! self.isDisabled) {
        dispatch_source_cancel(source);
    }
}

- (void)ensureWindow
{
    if (self.window) return;

    self.window = UIApplication.sharedApplication.keyWindow;
    if (! self.window) self.window = UIApplication.sharedApplication.windows.lastObject;
    if (! self.window) [[NSException exceptionWithName:NSGenericException reason:@"BugshotKit cannot find any application windows" userInfo:nil] raise];
    if (! self.window.rootViewController) [[NSException exceptionWithName:NSGenericException reason:@"BugshotKit requires a rootViewController set on the window" userInfo:nil] raise];

    // The purpose of this is to immediately get rejected from App Store submissions in case you accidentally submit an app with BugshotKit.
    // BugshotKit is only meant to be used during development and beta testing. Do not ship it in App Store builds.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    if ([UIEvent.class instancesRespondToSelector:@selector(_gsEvent)] &&
        [UIViewController.class instancesRespondToSelector:@selector(attentionClassDumpUser:yesItsUsAgain:althoughSwizzlingAndOverridingPrivateMethodsIsFun:itWasntMuchFunWhenYourAppStoppedWorking:pleaseRefrainFromDoingSoInTheFutureOkayThanksBye:)]) {
        // I can't believe I actually had a reason to call this method.
        [self.window.rootViewController attentionClassDumpUser:nil yesItsUsAgain:nil althoughSwizzlingAndOverridingPrivateMethodsIsFun:nil itWasntMuchFunWhenYourAppStoppedWorking:nil pleaseRefrainFromDoingSoInTheFutureOkayThanksBye:nil];
    }
#pragma clang diagnostic pop
}

- (void)newWindowDidBecomeVisible:(NSNotification *)n
{
    UIWindow *newWindow = (UIWindow *) n.object;
    if (! newWindow || ! [newWindow isKindOfClass:UIWindow.class]) return;
    [self attachToWindow:newWindow];
}

- (void)attachToWindow:(UIWindow *)window
{
    if (self.isDisabled) return;

    if ([self.windowsWithGesturesAttached objectForKey:window]) return;
    [self.windowsWithGesturesAttached setObject:window forKey:window];

    BSKInvocationGestureMask invocationGestures = self.invocationGestures;
    NSUInteger fingerCount = self.invocationGesturesTouchCount;

    if (invocationGestures & (BSKInvocationGestureSwipeUp | BSKInvocationGestureSwipeDown)) {
        // Need to actually handle all four directions to work with rotation, since we're attaching right to the window (which doesn't autorotate).
        // Making four different GRs, rather than one with all four directions set, so it's possible to distinguish which direction was swiped in the action method.
        //
        // (dealing with rotation is awesome)

        UISwipeGestureRecognizer *sgr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        sgr.numberOfTouchesRequired = fingerCount;
        sgr.direction = UISwipeGestureRecognizerDirectionUp;
        sgr.delegate = self;
        [window addGestureRecognizer:sgr];

        sgr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        sgr.numberOfTouchesRequired = fingerCount;
        sgr.direction = UISwipeGestureRecognizerDirectionDown;
        sgr.delegate = self;
        [window addGestureRecognizer:sgr];

        sgr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        sgr.numberOfTouchesRequired = fingerCount;
        sgr.direction = UISwipeGestureRecognizerDirectionLeft;
        sgr.delegate = self;
        [window addGestureRecognizer:sgr];

        sgr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        sgr.numberOfTouchesRequired = fingerCount;
        sgr.direction = UISwipeGestureRecognizerDirectionRight;
        sgr.delegate = self;
        [window addGestureRecognizer:sgr];

        if (invocationGestures & BSKInvocationGestureSwipeUp) NSLog(@"[BugshotKit] Enabled for %d-finger swipe up.", (int) fingerCount);
        if (invocationGestures & BSKInvocationGestureSwipeDown) NSLog(@"[BugshotKit] Enabled for %d-finger swipe down.", (int) fingerCount);
    }

    if (invocationGestures & BSKInvocationGestureSwipeFromRightEdge) {
        // Similar deal with these (see swipe recognizers above), but screen-edge gesture recognizers always return 0 upon reading the .edges property.
        // I guess it's write-only. So we actually need four different action methods to know which one was invoked.

        UIScreenEdgePanGestureRecognizer *egr = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(topEdgePanGesture:)];
        egr.edges = UIRectEdgeTop;
        egr.minimumNumberOfTouches = fingerCount;
        egr.maximumNumberOfTouches = fingerCount;
        egr.delegate = self;
        [window addGestureRecognizer:egr];

        egr = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(bottomEdgePanGesture:)];
        egr.edges = UIRectEdgeBottom;
        egr.minimumNumberOfTouches = fingerCount;
        egr.maximumNumberOfTouches = fingerCount;
        egr.delegate = self;
        [window addGestureRecognizer:egr];

        egr = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(leftEdgePanGesture:)];
        egr.edges = UIRectEdgeLeft;
        egr.minimumNumberOfTouches = fingerCount;
        egr.maximumNumberOfTouches = fingerCount;
        egr.delegate = self;
        [window addGestureRecognizer:egr];

        egr = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(rightEdgePanGesture:)];
        egr.edges = UIRectEdgeRight;
        egr.minimumNumberOfTouches = fingerCount;
        egr.maximumNumberOfTouches = fingerCount;
        egr.delegate = self;
        [window addGestureRecognizer:egr];

        NSLog(@"[BugshotKit] Enabled for swipe from right edge.");
    }

    if (invocationGestures & BSKInvocationGestureDoubleTap) {
        UITapGestureRecognizer *tgr = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        tgr.numberOfTouchesRequired = fingerCount;
        tgr.numberOfTapsRequired = 2;
        tgr.delegate = self;
        [window addGestureRecognizer:tgr];
        NSLog(@"[BugshotKit] Enabled for %d-finger double-tap.", (int) fingerCount);
    }

    if (invocationGestures & BSKInvocationGestureTripleTap) {
        UITapGestureRecognizer *tgr = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        tgr.numberOfTouchesRequired = fingerCount;
        tgr.numberOfTapsRequired = 3;
        tgr.delegate = self;
        [window addGestureRecognizer:tgr];
        NSLog(@"[BugshotKit] Enabled for %d-finger triple-tap.", (int) fingerCount);
    }

    if (invocationGestures & BSKInvocationGestureLongPress) {
        UILongPressGestureRecognizer *tgr = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleOpenGesture:)];
        tgr.numberOfTouchesRequired = fingerCount;
        tgr.delegate = self;
        [window addGestureRecognizer:tgr];
        NSLog(@"[BugshotKit] Enabled for %d-finger long press.", (int) fingerCount);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return YES; }

- (void)leftEdgePanGesture:(UIScreenEdgePanGestureRecognizer *)egr
{
    if ([egr translationInView:self.window].x < 60) return;
    if ([UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationPortraitUpsideDown) [self handleOpenGesture:egr];
}

- (void)rightEdgePanGesture:(UIScreenEdgePanGestureRecognizer *)egr
{
    if ([egr translationInView:self.window].x > -60) return;
    if ([UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationPortrait) [self handleOpenGesture:egr];
}

- (void)topEdgePanGesture:(UIScreenEdgePanGestureRecognizer *)egr
{
    if ([egr translationInView:self.window].y < 60) return;
    if ([UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationLandscapeLeft) [self handleOpenGesture:egr];
}

- (void)bottomEdgePanGesture:(UIScreenEdgePanGestureRecognizer *)egr
{
    if ([egr translationInView:self.window].y > -60) return;
    if ([UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationLandscapeRight) [self handleOpenGesture:egr];
}

- (void)handleOpenGesture:(UIGestureRecognizer *)sender
{
    if (self.isShowing) return;

    UIInterfaceOrientation interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    
    if (sender && [sender isKindOfClass:UISwipeGestureRecognizer.class]) {
        UISwipeGestureRecognizer *sgr = (UISwipeGestureRecognizer *)sender;

        BOOL validSwipe = NO;
        if (self.invocationGestures & BSKInvocationGestureSwipeUp) {
            if      (interfaceOrientation == UIInterfaceOrientationPortrait && sgr.direction == UISwipeGestureRecognizerDirectionUp) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown && sgr.direction == UISwipeGestureRecognizerDirectionDown) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationLandscapeLeft && sgr.direction == UISwipeGestureRecognizerDirectionLeft) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationLandscapeRight && sgr.direction == UISwipeGestureRecognizerDirectionRight) validSwipe = YES;
        }

        if (! validSwipe && (self.invocationGestures & BSKInvocationGestureSwipeDown)) {
            if      (interfaceOrientation == UIInterfaceOrientationPortrait && sgr.direction == UISwipeGestureRecognizerDirectionDown) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown && sgr.direction == UISwipeGestureRecognizerDirectionUp) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationLandscapeLeft && sgr.direction == UISwipeGestureRecognizerDirectionRight) validSwipe = YES;
            else if (interfaceOrientation == UIInterfaceOrientationLandscapeRight && sgr.direction == UISwipeGestureRecognizerDirectionLeft) validSwipe = YES;
        }

        if (! validSwipe) return;
    }

    self.isShowing = YES;

    UIGraphicsBeginImageContextWithOptions(self.window.bounds.size, NO, UIScreen.mainScreen.scale);

    NSMutableSet *drawnWindows = [NSMutableSet set];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [drawnWindows addObject:window];
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }

    // Must iterate through all windows we know about because UIAlertViews, etc. don't add themselves to UIApplication.windows
    for (UIWindow *window in self.windowsWithGesturesAttached) {
        if ([drawnWindows containsObject:window]) continue;
        [drawnWindows addObject:window];

        [window.layer renderInContext:UIGraphicsGetCurrentContext()]; // drawViewHierarchyInRect: doesn't capture UIAlertView opacity properly
    }

    self.snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if ([UIDevice currentDevice].systemVersion.floatValue < 8.0f && interfaceOrientation != UIInterfaceOrientationPortrait) {
        self.snapshotImage = [[UIImage alloc] initWithCGImage:self.snapshotImage.CGImage scale:UIScreen.mainScreen.scale orientation:(
            interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown ? UIImageOrientationDown : (
                interfaceOrientation == UIInterfaceOrientationLandscapeLeft ? UIImageOrientationRight : UIImageOrientationLeft
            )
        )];
    }

    UIViewController *presentingViewController = self.window.rootViewController;
    while (presentingViewController.presentedViewController) presentingViewController = presentingViewController.presentedViewController;

    BSKMainViewController *mvc = [[BSKMainViewController alloc] init];
    mvc.delegate = self;
    BSKNavigationController *nc = [[BSKNavigationController alloc] initWithRootViewController:mvc lockedToRotation:[UIApplication sharedApplication].statusBarOrientation];
    self.presentedNavigationController = nc;
    nc.navigationBar.tintColor = BugshotKit.sharedManager.annotationFillColor;
    nc.navigationBar.titleTextAttributes = @{ NSForegroundColorAttributeName:BugshotKit.sharedManager.annotationFillColor };
    [presentingViewController presentViewController:nc animated:YES completion:NULL];
}

+ (void)dismissAnimated:(BOOL)animated completion:(void(^)())completion {
    UIViewController *presentingVC = BugshotKit.sharedManager.presentedNavigationController.presentingViewController;
    if (presentingVC) {
        [presentingVC dismissViewControllerAnimated:animated completion:completion];
        [BugshotKit.sharedManager mainViewControllerDidClose:nil];
    } else {
        if (completion) completion();
    }
}

- (void)mainViewControllerDidClose:(BSKMainViewController *)mainViewController
{
    self.isShowing = NO;
    self.snapshotImage = nil;
    self.annotatedImage = nil;
    self.annotations = nil;
}

#pragma mark - App Store build detection

+ (BOOL)isProbablyAppStoreBuild
{
#if TARGET_IPHONE_SIMULATOR
    return NO;
#else
    // Adapted from https://github.com/blindsightcorp/BSMobileProvision

    NSString *binaryMobileProvision = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"] encoding:NSISOLatin1StringEncoding error:NULL];
    if (! binaryMobileProvision) return YES; // no provision

    NSScanner *scanner = [NSScanner scannerWithString:binaryMobileProvision];
    NSString *plistString;
    if (! [scanner scanUpToString:@"<plist" intoString:nil] || ! [scanner scanUpToString:@"</plist>" intoString:&plistString]) return YES; // no XML plist found in provision
    plistString = [plistString stringByAppendingString:@"</plist>"];

    NSData *plistdata_latin1 = [plistString dataUsingEncoding:NSISOLatin1StringEncoding];
    NSError *error = nil;
    NSDictionary *mobileProvision = [NSPropertyListSerialization propertyListWithData:plistdata_latin1 options:NSPropertyListImmutable format:NULL error:&error];
    if (error) return YES; // unknown plist format

    if (! mobileProvision || ! mobileProvision.count) return YES; // no entitlements

    if (mobileProvision[@"ProvisionsAllDevices"]) return NO; // enterprise provisioning

    if (mobileProvision[@"ProvisionedDevices"] && ((NSDictionary *)mobileProvision[@"ProvisionedDevices"]).count) return NO; // development or ad-hoc

    return YES; // expected development/enterprise/ad-hoc entitlements not found
#endif
}


@end
