//
//  PairManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpManager.h"

@protocol PairCallback <NSObject>

- (void) startPairing:(NSString*)PIN;
- (void) pairSuccessful:(NSData*)serverCert;
- (void) pairFailed:(NSString*)message;
- (void) alreadyPaired;

@end

@interface PairManager : NSOperation
/// Omodachi (PAIR-1): pair again for a certificate the host already holds.
///
/// `PairStatus` is the *host's* view of this certificate, not of the Omodachi
/// device that carries it. When core has no binding for this device the host
/// refuses the session with `media_pairing_required`, and stopping at
/// `alreadyPaired` would leave nothing for anyone to approve — the fork only
/// registers a request when `getservercert` lands. Setting this asks for the
/// exchange anyway, which is what makes the request appear on the host.
@property(nonatomic) BOOL renewing;
- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert callback:(id<PairCallback>)callback;
@end
