#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Test-target only. One continuous finger-down stroke through many points, sent with XCTest's private event synthesis
/// (XCPointerEventPath + XCSynthesizedEventRecord, the same way WebDriverAgent does it). The classes are looked up by name at
/// run time, so nothing is linked against private symbols; if they are missing the call fails with an error and never falls back.
@interface RKTouchSynthesizer : NSObject

/// `points` are screen coordinates (NSValue of CGPoint); `offsets` are seconds from touch-down (NSNumber), same count, the first
/// is 0 and they never decrease. The finger goes down at the first point, moves to each next point at its offset and lifts at the last.
/// Returns after the whole stroke was delivered (or failed).
+ (BOOL)dragThroughPoints:(NSArray<NSValue *> *)points
                  offsets:(NSArray<NSNumber *> *)offsets
                    error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(drag(through:offsets:));

@end

NS_ASSUME_NONNULL_END
