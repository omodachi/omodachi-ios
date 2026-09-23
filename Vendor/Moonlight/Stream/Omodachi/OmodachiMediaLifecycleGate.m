//
//  OmodachiMediaLifecycleGate.m
//  Moonlight
//
//  Copyright (c) 2026 Omodachi contributors. All rights reserved.
//

#import "OmodachiMediaLifecycleGate.h"

NSString * const OmodachiMediaLifecycleErrorDomain = @"org.omodachi.media.lifecycle";

@implementation OmodachiMediaLifecycleGate {
    NSLock *_lock;
    OmodachiMediaLifecycleState _state;
    uint64_t _generation;
}

@synthesize state = _state;
@synthesize generation = _generation;

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _state = OmodachiMediaLifecycleStateIdle;
        _generation = 0;
    }
    return self;
}

- (BOOL)fail:(NSError **)error code:(NSInteger)code description:(NSString *)description {
    if (error != NULL) {
        *error = [NSError errorWithDomain:OmodachiMediaLifecycleErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

- (BOOL)beginStartForGeneration:(uint64_t)generation error:(NSError **)error {
    [_lock lock];
    if (_state != OmodachiMediaLifecycleStateIdle) {
        BOOL result = [self fail:error code:1 description:@"media owner is not idle"]; 
        [_lock unlock];
        return result;
    }
    _generation = generation;
    _state = OmodachiMediaLifecycleStateStarting;
    [_lock unlock];
    return YES;
}

- (BOOL)markRunningForGeneration:(uint64_t)generation error:(NSError **)error {
    [_lock lock];
    if (_generation != generation || _state != OmodachiMediaLifecycleStateStarting) {
        BOOL result = [self fail:error code:2 description:@"start callback has stale generation or phase"]; 
        [_lock unlock];
        return result;
    }
    _state = OmodachiMediaLifecycleStateRunning;
    [_lock unlock];
    return YES;
}

- (BOOL)beginStopForGeneration:(uint64_t)generation error:(NSError **)error {
    [_lock lock];
    if (_generation != generation || (_state != OmodachiMediaLifecycleStateStarting && _state != OmodachiMediaLifecycleStateRunning)) {
        BOOL result = [self fail:error code:3 description:@"stop request has stale generation or phase"]; 
        [_lock unlock];
        return result;
    }
    _state = OmodachiMediaLifecycleStateStopping;
    [_lock unlock];
    return YES;
}

- (BOOL)completeStopForGeneration:(uint64_t)generation inputReleased:(BOOL)inputReleased error:(NSError **)error {
    [_lock lock];
    if (_generation != generation || _state != OmodachiMediaLifecycleStateStopping) {
        BOOL result = [self fail:error code:4 description:@"stop completion has stale generation or phase"]; 
        [_lock unlock];
        return result;
    }
    if (!inputReleased) {
        BOOL result = [self fail:error code:5 description:@"stop completion did not prove input release"]; 
        [_lock unlock];
        return result;
    }
    _state = OmodachiMediaLifecycleStateIdle;
    [_lock unlock];
    return YES;
}

- (BOOL)abortForGeneration:(uint64_t)generation error:(NSError **)error {
    [_lock lock];
    if (_generation != generation || _state == OmodachiMediaLifecycleStateIdle) {
        BOOL result = [self fail:error code:6 description:@"abort has stale generation or idle phase"]; 
        [_lock unlock];
        return result;
    }
    _state = OmodachiMediaLifecycleStateIdle;
    [_lock unlock];
    return YES;
}

@end
