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

#import "AntennaAppDelegate.h"

#import "ANTLoginWindowController.h"
#import "ANTPreferencesWindowController.h"

#import "ANTRadarsWindowController.h"
#import "AntennaApp.h"

#import "ANTPreferences.h"

@interface AntennaAppDelegate () <ANTNetworkClientAuthDelegate, LoginWindowControllerDelegate, AntennaAppDelegate>

/** The primary viewer window. */
@property(nonatomic, readonly) ANTRadarsWindowController *radarsWindowController;

/** The application preferences window controller. */
@property(nonatomic, readonly) ANTPreferencesWindowController *preferencesWindowController;

@end

@implementation AntennaAppDelegate {
@private
    /** Application preferences */
    ANTPreferences *_preferences;
    
    /** Viewer window controllers (lazy loaded; nil if not yet instantiated). */
    ANTRadarsWindowController *_radarsWindowController;

    /** The login window controller (nil if login is not pending). */
    ANTLoginWindowController *_loginWindowController;

    /** Preferences window controller (lazy loaded; nil if not yet instantiated). */
    ANTPreferencesWindowController *_prefsWindowController;
    
    /**
     * All pending authentication blocks; these should be dispatched when the login
     * window controller succeeds/fails.
     */
    NSMutableArray *_authCallbacks;
}

// from NSApplicationDelegate protocol; sent prior to window restoration.
- (void) applicationWillFinishLaunching: (NSNotification *) notification {
    /* Fetch preferences */
    _preferences = [[ANTPreferences alloc] init];
    
    /* Set up client */
    _networkClient = [[ANTNetworkClient alloc] initWithAuthDelegate: self];
    
    /* Configure authentication state */
    _authCallbacks = [NSMutableArray array];
}

// from NSApplicationDelegate protocol; sent after window restoration.
- (void) applicationDidFinishLaunching: (NSNotification *) aNotification {
    /* Try to login by default */
    [_networkClient loginWithAccount: nil cancelTicket: [PLCancelTicketSource new].ticket andCall: ^(NSError *error) {
        // TODO - Do we need to display an error here?
    }];

    /* Display the viewer window */
    [self.radarsWindowController showWindow: nil];    
}

// from AntennaAppDelegate protocol
- (BOOL) restoreWindowWithIdentifier: (NSString *) identifier state: (NSCoder *) state completionHandler: (void (^)(NSWindow *, NSError *)) completionHandler {
    if ([identifier isEqual: [ANTPreferencesWindowController restorationIdentifier]]) {
        [self.preferencesWindowController restoreWindowState: state completionHandler: completionHandler];
        return YES;
    }
    return NO;
}

// Radars menu item action
- (IBAction) openRadarsView: (id) sender {
    if (self.radarsWindowController.window.isVisible)
        [self.radarsWindowController close];
    else
        [self.radarsWindowController showWindow: nil];
}

// Preferences menu item action
- (IBAction) openPreferences: (id) sender {
    [self.preferencesWindowController showWindow: nil];
}

// from ANTLoginWindowControllerDelegate protocol
- (void) loginWindowController: (ANTLoginWindowController *) sender didFinishWithToken: (NSString *) csrfToken {
    [_loginWindowController close];
    _loginWindowController = nil;

    ANTNetworkClientAuthResult *result = [[ANTNetworkClientAuthResult alloc] initWithCSRFToken: csrfToken];
    for (ANTNetworkClientAuthDelegateCallback cb in _authCallbacks) {
        cb(result, nil);
    }
}

// from ANTLoginWindowControllerDelegate protocol
- (void) loginWindowController: (ANTLoginWindowController *) sender didFailWithError: (NSError *) error {
    [_loginWindowController close];
    _loginWindowController = nil;

    for (ANTNetworkClientAuthDelegateCallback cb in _authCallbacks) {
        cb(nil, error);
    }
}

// from ANTNetworkClientAuthDelegate protocol
- (void) networkClient: (ANTNetworkClient *) sender authRequiredWithAccount: (ANTNetworkClientAccount *) account cancelTicket: (PLCancelTicket *) ticket andCall: (ANTNetworkClientAuthDelegateCallback) callback {
    if (_loginWindowController != nil) {
        if (!ticket.isCancelled)
            callback(nil, [NSError pl_errorWithDomain: ANTErrorDomain
                                                 code: ANTErrorRequestConflict
                                 localizedDescription: NSLocalizedString(@"An sign in request is already in progress", nil)
                               localizedFailureReason: nil
                                      underlyingError: nil
                                             userInfo: nil]);
        return;
    }

    /* Set up the new controller */
    _loginWindowController = [[ANTLoginWindowController alloc] initWithAccount: account preferences: _preferences];
    _loginWindowController.delegate = self;
    [_loginWindowController start];

    /* Register the callback block and the cancellation handler */
    void (^copied)(NSError *error) = [callback copy];
    [_authCallbacks addObject: copied];
    [ticket addCancelHandler: ^(PLCancelTicketReason reason) {
        [_authCallbacks removeObject: copied];
        
        /* If no more callbacks remain, cancel the login process */
        if ([_authCallbacks count] == 0) {
            _loginWindowController.delegate = nil;
            [_loginWindowController close];
            _loginWindowController = nil;
        }
    } dispatchContext: [PLGCDDispatchContext mainQueueContext]];
}

#pragma mark Properties

// property getter
- (ANTRadarsWindowController *) radarsWindowController {
    if (_radarsWindowController == nil)
        _radarsWindowController = [[ANTRadarsWindowController alloc] initWithClient: _networkClient];
    return _radarsWindowController;
}

// property getter
- (ANTPreferencesWindowController *) preferencesWindowController {
    if (_prefsWindowController == nil)
        _prefsWindowController = [[ANTPreferencesWindowController alloc] initWithClient: _networkClient preferences: _preferences];
        
        return _prefsWindowController;
}

@end
