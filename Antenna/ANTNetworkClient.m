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

#import "ANTNetworkClient.h"
#import "ANTLoginWindowController.h"

#import "MAErrorReportingDictionary.h"
#import "NSObject+MAErrorReporting.h"

/**
 * Notification dispatched on successful login. The notification object will
 * be the authenticated network client instance.
 */
NSString *RATNetworkClientDidLoginNotification = @"RATNetworkClientDidLoginNotification";


@interface ANTNetworkClient () <RATLoginWindowControllerDelegate>
- (void) postJSON: (id) json toPath: (NSString *) resourcePath completionHandler: (void (^)(id jsonData, NSError *error)) handler;
@end

@implementation ANTNetworkClient {
@private
    /** User preferences */
    ANTPreferences *_preferences;

    /** The login window controller (nil if login is not pending). */
    ANTLoginWindowController *_loginWindowController;
    
    /** YES if authenticated, NO otherwise */
    BOOL _isAuthenticated;

    /** CSRF token extracted from the webview */
    NSString *_csrfToken;
    

    /** Date formatter to use for report dates (DD-MON-YYYY HH:MM) */
    NSDateFormatter *_dateFormatter;
}

/**
 * Initialize a new instance.
 */
- (instancetype) initWithPreferences: (ANTPreferences *) preferences {
    if ((self = [super init]) == nil)
        return nil;
    
    _preferences = preferences;
    
    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setDateFormat:@"dd-MMM-yyyy HH:mm"];
    [_dateFormatter setLocale: [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]];

    return self;
}

/**
 * Return the default bug reporter URL.
 */
+ (NSURL *) bugreporterURL {
    return [NSURL URLWithString: @"https://bugreport.apple.com"];
}

/**
 * Request all radar issue summaries for @a sectionName.
 *
 * @param sectionName The section name.
 * @param completionHandler The block to call upon completion. If an error occurs, error will be non-nil. The summaries
 * will be provided as an ordered array of ANTRadarSummaryResponse values.
 *
 * @todo Define constants for supported sections ('Open', etc).
 * @todo Implement paging support.
 * @todo Allow for specifying the sort order.
 * @todo Implement cancellation support (return a cancellation ticket?).
 */
- (void) requestSummariesForSection: (NSString *) sectionName completionHandler: (void (^)(NSArray *summaries, NSError *error)) handler {
    NSDictionary *req = @{@"reportID" : sectionName, @"orderBy" : @"DateOriginated,Descending", @"rowStartString":@"1" };
    [self postJSON: req toPath: @"/developer/problem/getSectionProblems" completionHandler:^(id jsonData, NSError *error) {
        /* Verify the response type */
        if (![jsonData isKindOfClass: [NSDictionary class]]) {
            handler(nil, [NSError errorWithDomain: NSCocoaErrorDomain code: NSURLErrorCannotParseResponse userInfo: nil]);
            return;
        }
    
        /* Parse out the data */
        MAErrorReportingDictionary *jsonDict = [[MAErrorReportingDictionary alloc] initWithDictionary: jsonData];
        id (^Check)(id) = ^(id value) {
            if (value == nil) {
                handler(nil, [jsonDict error]);
                return (id) nil;
            }
            
            return value;
        };
        
#define GetValue(_varname, _type, _source) \
    _type *_varname = Check([_type ma_castRequiredObject: _source]); \
    if (_varname == nil) { \
        NSLog(@"Missing required var " # _source " in %@", jsonDict); \
        return; \
    }

        /* It's called a list, but it's actually a dictionary. Go figure */
        GetValue(list, NSDictionary, jsonDict[@"List"]);
        GetValue(issues, NSArray, list[@"RDRGetMyOrignatedProblems"]);
        
        /* Regex to match radar attribution lines, eg, '<GMT09-Aug-2013 21:14:47GMT> Landon Fuller:' */
        NSRegularExpression *attributionLineRegex;
        attributionLineRegex = [NSRegularExpression regularExpressionWithPattern: @"<[A-Z0-9+]+-[A-Za-z]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+[A-Z0-9+]+> .*:[ \t\n]*"
                                                                         options: NSRegularExpressionAnchorsMatchLines
                                                                           error: &error];
        NSAssert(attributionLineRegex != nil, @"Failed to compile regex");

        NSMutableArray *results = [NSMutableArray arrayWithCapacity: [issues count]];
        for (id issueVal in issues) {
            GetValue(issue, NSDictionary, issueVal);
            GetValue(radarId,           NSNumber,   issue[@"problemID"]);
            GetValue(stateName,         NSString,   issue[@"probstatename"]);
            GetValue(title,             NSString,   issue[@"problemTitle"]);
            GetValue(componentName,     NSString,   issue[@"compNameForWeb"]);
            GetValue(hidden,            NSNumber,   issue[@"hide"]);
            GetValue(description,       NSString,   issue[@"problemDescription"]);
            GetValue(origDateString,    NSString,   issue[@"whenOriginatedDate"]);

            /* Format the date */
            NSDate *origDate = [_dateFormatter dateFromString: origDateString];
            if (origDate == nil) {
                NSLog(@"Could not format date: %@", origDateString);
                handler(nil, [NSError errorWithDomain: NSCocoaErrorDomain code: NSURLErrorCannotParseResponse userInfo: nil]);
                return;
            }
            
            /* Clean up the summary; the first line is a radar comment attributeion, eg, '<GMT09-Aug-2013 21:14:47GMT> Landon Fuller:' */
            NSRange descriptionStart = [attributionLineRegex rangeOfFirstMatchInString: description options: 0 range: NSMakeRange(0, [description length])];
            if (descriptionStart.location != NSNotFound)
                description = [description substringFromIndex: NSMaxRange(descriptionStart)];

            ANTRadarSummaryResponse *summaryEntry;
            summaryEntry = [[ANTRadarSummaryResponse alloc] initWithRadarId: [radarId stringValue]
                                                                  stateName: stateName
                                                                      title: title
                                                              componentName: componentName
                                                                     hidden: [hidden boolValue]
                                                                description: description
                                                             originatedDate: origDate];
            [results addObject: summaryEntry];
        }
        
        handler(results, error);
    }];
}

/**
 * Issue a login request. This will display an embedded WebKit window.
 */
- (void) login {
    if (_loginWindowController == nil) {
        _loginWindowController = [[ANTLoginWindowController alloc] initWithPreferences: _preferences];
        _loginWindowController.delegate = self;
        [_loginWindowController showWindow: nil];
    }
}

// property getter
- (BOOL) isAuthenticated {
    return _isAuthenticated;
}

// from ANTLoginWindowControllerDelegate protocol
- (void) loginWindowController: (ANTLoginWindowController *) sender didFinishWithToken: (NSString *) csrfToken {
    [_loginWindowController close];
    _loginWindowController = nil;
    _csrfToken = csrfToken;
    _isAuthenticated = YES;

    [[NSNotificationCenter defaultCenter] postNotificationName: RATNetworkClientDidLoginNotification object: self];
}

/**
 * Post JSON request data @a json to @a resourcePath, calling @a completionHandler on finish.
 *
 * @param json A foundation instance that may be represented as JSON
 * @param resourcePath The resource path to which the JSON data will be POSTed.
 * @param handler The block to call upon completion. If an error occurs, error will be non-nil. On success, the JSON response data
 * will be provided via jsonData.
 *
 * @todo Implement handling of the standard JSON error results.
 */
- (void) postJSON: (id) json toPath: (NSString *) resourcePath completionHandler: (void (^)(id jsonData, NSError *error)) handler {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject: json options: 0 error: &error];
    if (jsonData == nil)
        handler(nil, error);

    /* Formulate the POST */
    NSURL *url = [NSURL URLWithString: resourcePath relativeToURL: [ANTNetworkClient bugreporterURL]];
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL: url];
    [req setHTTPMethod: @"POST"];
    [req setHTTPBody: jsonData];
    [req setValue: @"application/json; charset=UTF-8" forHTTPHeaderField: @"Content-Type"];

    /* CSRF handling */
    [req addValue: _csrfToken forHTTPHeaderField:@"csrftokencheck"];

    /* Try to make the headers look more like the browser */
    [req setValue: [[ANTNetworkClient bugreporterURL] absoluteString] forHTTPHeaderField: @"Origin"];
    [req setValue: @"XMLHTTPRequest" forHTTPHeaderField: @"X-Requested-With"];
    
    /* Disable caching */
    [req setCachePolicy: NSURLCacheStorageNotAllowed];
    [req addValue: @"no-cache" forHTTPHeaderField: @"Cache-Control"];

    /* We need cookies for session and authentication verification done by the server */
    [req setHTTPShouldHandleCookies: YES];
    
    /* Issue the request */
    [NSURLConnection sendAsynchronousRequest: req queue: [NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *resp, NSData *data, NSError *error) {
        if (error != nil) {
            handler(nil, error);
            return;
        }
        
        /* Parse the result. TODO: Generic handling of JSON isError results */
        NSError *jsonError;
        id jsonResult = [NSJSONSerialization JSONObjectWithData: data options:0 error: &jsonError];
        if (jsonResult == nil) {
            handler(nil, jsonError);
            return;
        }
    
         handler(jsonResult, nil);
    }];
}

@end

/**
 * ANT client authentication result.
 */
@implementation ANTNetworkClientAuthResult

/**
 * Initialize a new instance with the given CSRF token.
 *
 * @param csrfToken The CSRF token provided by the server.
 */
- (instancetype) initWithCSRFToken: (NSString *) csrfToken {
    PLSuperInit();
    
    _csrfToken = csrfToken;
    
    return self;
}

@end
