//
//  OmodachiMediaLifecycleGate.h
//  Moonlight
//
//  Copyright (c) 2026 Omodachi contributors. All rights reserved.
//  Derived integration helper for the Moonlight Stream client; keep the
//  upstream Moonlight license and attribution when redistributing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OmodachiMediaLifecycleState) {
    OmodachiMediaLifecycleStateIdle = 0,
    OmodachiMediaLifecycleStateStarting,
    OmodachiMediaLifecycleStateRunning,
    OmodachiMediaLifecycleStateStopping,
};

FOUNDATION_EXPORT NSString * const OmodachiMediaLifecycleErrorDomain;

/// Small, thread-safe phase gate used by the facade and by its boundary tests.
/// It does not perform media I/O. A real LiStopConnection-returned ACK must be
/// supplied to completeStopForGeneration:inputReleased:.
@interface OmodachiMediaLifecycleGate : NSObject

@property(nonatomic, readonly) OmodachiMediaLifecycleState state;
@property(nonatomic, readonly) uint64_t generation;

- (BOOL)beginStartForGeneration:(uint64_t)generation error:(NSError * _Nullable * _Nullable)error;
- (BOOL)markRunningForGeneration:(uint64_t)generation error:(NSError * _Nullable * _Nullable)error;
- (BOOL)beginStopForGeneration:(uint64_t)generation error:(NSError * _Nullable * _Nullable)error;
- (BOOL)completeStopForGeneration:(uint64_t)generation
                   inputReleased:(BOOL)inputReleased
                            error:(NSError * _Nullable * _Nullable)error;
- (BOOL)abortForGeneration:(uint64_t)generation error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
