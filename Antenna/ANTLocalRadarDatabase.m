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

#import "ANTLocalRadarDatabase.h"

#import <PLFoundation/PLFoundation.h>
#import <PlausibleDatabase/PlausibleDatabase.h>

/**
 * @internal
 *
 * Manages persistent state for the ANTLocalRadarCache
 *
 * @par Thread Safety
 *
 * Thread-safe. May be used from any thread.
 */
@implementation ANTLocalRadarDatabase


/**
 * Initialize with an SQLite connection provider.
 *
 * @param connectionProvider A connection provider to be used to store local Radar data. Must return
 * instances of PLSqliteDatabase.
 */
- (id) initWithConnectionProvider: (id<PLDatabaseConnectionProvider>) connectionProvider {
    PLSuperInit();
    
    

    return self;
}


@end
