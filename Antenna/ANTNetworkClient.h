/*
 * Author: Landon Fuller <landonf@plausible.coop>
 *
 * Copyright (c) 2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import <Foundation/Foundation.h>
#import "ANTRadarSummaryResponse.h"
#import "ANTPreferences.h"

#import "ANTNetworkClientAuthDelegate.h"

extern NSString *RATNetworkClientDidLoginNotification;

@interface ANTNetworkClientAuthResult : NSObject

- (instancetype) initWithCSRFToken: (NSString *) csrfToken;

/** The CSRF token provided by the server. */
@property(nonatomic, readonly) NSString *csrfToken;

@end

@interface ANTNetworkClient : NSObject

+ (NSURL *) bugreporterURL;

- (instancetype) initWithPreferences: (ANTPreferences *) preferences;

- (void) login;
- (void) requestSummariesForSection: (NSString *) sectionName completionHandler: (void (^)(NSArray *summaries, NSError *error)) handler;


/** YES if the client has successfully authenticated, NO otherwise. */
@property(nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;

@end
