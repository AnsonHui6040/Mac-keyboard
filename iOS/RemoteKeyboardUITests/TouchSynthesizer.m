#import "TouchSynthesizer.h"
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <objc/message.h>

static NSString *const RKTouchSynthesizerDomain = @"RKTouchSynthesizer";

static NSError *RKSynthError(NSString *message) {
    return [NSError errorWithDomain:RKTouchSynthesizerDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RKTouchSynthesizer

+ (BOOL)dragThroughPoints:(NSArray<NSValue *> *)points offsets:(NSArray<NSNumber *> *)offsets error:(NSError **)error {
    if (points.count < 2 || points.count != offsets.count) {
        if (error) *error = RKSynthError(@"need at least two points and one offset per point");
        return NO;
    }
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!pathClass || !recordClass) {
        if (error) *error = RKSynthError(@"XCPointerEventPath / XCSynthesizedEventRecord are not available in this XCTest");
        return NO;
    }

    SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    SEL moveTo = NSSelectorFromString(@"moveToPoint:atOffset:");
    SEL liftUp = NSSelectorFromString(@"liftUpAtOffset:");
    SEL initRecord = NSSelectorFromString(@"initWithName:interfaceOrientation:");
    SEL addPath = NSSelectorFromString(@"addPointerEventPath:");
    if (![pathClass instancesRespondToSelector:initPath] || ![pathClass instancesRespondToSelector:moveTo]
        || ![pathClass instancesRespondToSelector:liftUp] || ![recordClass instancesRespondToSelector:initRecord]
        || ![recordClass instancesRespondToSelector:addPath]) {
        if (error) *error = RKSynthError(@"the XCTest event-synthesis selectors changed in this Xcode");
        return NO;
    }

    CGPoint first = points.firstObject.CGPointValue;
    id path = ((id (*)(id, SEL, CGPoint, NSTimeInterval))objc_msgSend)([pathClass alloc], initPath, first, offsets.firstObject.doubleValue);
    for (NSUInteger i = 1; i < points.count; i++) {
        ((void (*)(id, SEL, CGPoint, NSTimeInterval))objc_msgSend)(path, moveTo, points[i].CGPointValue, offsets[i].doubleValue);
    }
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(path, liftUp, offsets.lastObject.doubleValue);

    id record = ((id (*)(id, SEL, NSString *, UIInterfaceOrientation))objc_msgSend)(
        [recordClass alloc], initRecord, @"RKTurnStroke", UIInterfaceOrientationPortrait);
    ((void (*)(id, SEL, id))objc_msgSend)(record, addPath, path);

    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    NSTimeInterval limit = offsets.lastObject.doubleValue + 10.0;

    SEL synthesizer = NSSelectorFromString(@"eventSynthesizer");
    SEL synth = NSSelectorFromString(@"synthesizeEvent:completion:");
    id device = [XCUIDevice sharedDevice];
    id eventSynthesizer = [device respondsToSelector:synthesizer] ? ((id (*)(id, SEL))objc_msgSend)(device, synthesizer) : nil;
    if (eventSynthesizer && [eventSynthesizer respondsToSelector:synth]) {
        void (^completion)(BOOL, NSError *) = ^(BOOL result, NSError *err) {
            ok = result; failure = err; done = YES;
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(eventSynthesizer, synth, record, completion);
    } else {
        // Newer Xcode: the runner's daemon session takes the record.
        Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
        SEL shared = NSSelectorFromString(@"sharedSession");
        id session = (sessionClass && [sessionClass respondsToSelector:shared]) ? ((id (*)(id, SEL))objc_msgSend)(sessionClass, shared) : nil;
        if (!session || ![session respondsToSelector:synth]) {
            if (error) *error = RKSynthError(@"no event synthesizer in this XCTest (XCUIDevice.eventSynthesizer and XCTRunnerDaemonSession are missing)");
            return NO;
        }
        void (^completion)(NSError *) = ^(NSError *err) {
            ok = (err == nil); failure = err; done = YES;
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(session, synth, record, completion);
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    }
    if (!done) {
        if (error) *error = RKSynthError(@"the synthesized stroke did not complete in time");
        return NO;
    }
    if (!ok && error) *error = failure ?: RKSynthError(@"the synthesized stroke failed");
    return ok;
}

@end
