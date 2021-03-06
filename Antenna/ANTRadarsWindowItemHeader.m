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

#import "ANTRadarsWindowItemHeader.h"

/**
 * A single header item in the Radars Window source list.
 */
@implementation ANTRadarsWindowItemHeader

@synthesize title = _title;
@synthesize icon = _icon;
@synthesize children = _children;

/**
 * Return a new instance.
 *
 * @param title The instance's title.
 * @param children Child elements.
 */
+ (instancetype) itemWithTitle: (NSString *) title children: (NSArray *) children {
    return [[self alloc] initWithTitle: title children: children];
}


/**
 * Initialize a new instance.
 *
 * @param title Title of the source item.
 * @param children Child elements.
 */
- (instancetype) initWithTitle: (NSString *) title children: (NSArray *) children {
    PLSuperInit();
    
    _title = title;
    _children = children;
    
    return self;
}

// from NSCopying protocol
- (instancetype) copyWithZone:(NSZone *)zone {
    return self;
}

// from NSCopying protocol
- (instancetype) copy {
    return [self copyWithZone: nil];
}


@end
