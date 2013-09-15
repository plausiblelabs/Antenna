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

#import "ANTRadarsWindowController.h"
#import <PLFoundation/PLFoundation.h>

#import "PXSourceList.h"

@interface ANTRadarsWindowController () <PXSourceListDelegate, PXSourceListDataSource, NSTableViewDataSource, NSTableViewDelegate>
@end

@interface ANTRadarsWindowSourceItem : NSObject <NSCopying>

+ (instancetype) itemWithTitle: (NSString *) title
                      children: (NSArray *) children;

+ (instancetype) itemWithTitle: (NSString *) title
                          icon: (NSImage *) icon;

- (instancetype) initWithTitle: (NSString *) title icon: (NSImage *) icon children: (NSArray *) children;

/** The source item's title. */
@property(nonatomic, readonly) NSString *title;

/** The item's icon, if any. */
@property(nonatomic, readonly) NSImage *icon;

/** Child elements, if any. */
@property(nonatomic, readonly) NSArray *children;

@end

/**
 * Manages the primary 'viewer' window.
 */
@implementation ANTRadarsWindowController {
@private
    /** Backing network client */
    ANTNetworkClient *_client;

    /** Left-side source tree */
    __weak IBOutlet PXSourceList *_sourceList;

    /** Items listed in the left-hand source view */
    NSArray *_sourceItems;

    /** Summary table table view */
    __weak IBOutlet NSTableView *_summaryTableView;
    
    /** Summary table's title menu */
    __weak IBOutlet NSMenu *_summaryTableHeaderMenu;
    
    /** Backing ANTRadarSummaryResponse values, if any. Nil if none have been loaded. */
    NSMutableArray *_summaries;
}

/**
 * Initialize a new ANTRadarsWindowController instance.
 *
 * @param client The backing network Radar client.
 */
- (id) initWithClient: (ANTNetworkClient *) client {
    if ((self = [super initWithWindowNibName: [self className] owner: self]) == nil)
        return nil;
    
    _client = client;
    
    NSImage *folderIcon = [NSImage imageNamed: NSImageNameFolder];
    NSImage *smartFolderIcon = [NSImage imageNamed: NSImageNameFolderSmart];
    ANTRadarsWindowSourceItem *radarItem = [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"My Radars", nil) children: @[
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Open", nil) icon: folderIcon],
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Closed", nil) icon: folderIcon],
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Recently Updated", nil) icon: smartFolderIcon]
    ]];

    ANTRadarsWindowSourceItem *openRadarItem = [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"My Public Radars", nil) children: @[
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Open", nil) icon: folderIcon],
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Closed", nil) icon: folderIcon],
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Watching", nil) icon: smartFolderIcon],
        [ANTRadarsWindowSourceItem itemWithTitle: NSLocalizedString(@"Recently Updated", nil) icon: smartFolderIcon]
    ]];

    _sourceItems = @[radarItem, openRadarItem];
    
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(didChangeAuthState:) name: ANTNetworkClientDidChangeAuthState object: _client];

    return self;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}

// ANTNetworkClientDidChangeAuthState notification
- (void) didChangeAuthState: (NSNotification *) notification {
    if (_client.authState != ANTNetworkClientAuthStateAuthenticated)
        return;
    
    /* Load all summaries */
    [_client requestSummariesForSection: @"Open" completionHandler: ^(NSArray *summaries, NSError *error) {
        if (error != nil) {
            [[NSAlert alertWithError: error] beginSheetModalForWindow: self.window modalDelegate: self didEndSelector: @selector(summaryAlertDidEnd:returnCode:contextInfo:) contextInfo: nil];
            return;
        }
        
        _summaries = [summaries mutableCopy];
        [_summaryTableView reloadData];
    }];
}

- (void) windowDidLoad {
    [super windowDidLoad];

    /* Disallow column selection */
    [_summaryTableView setAllowsColumnSelection: NO];

    /* Expand all by default. TODO: Should we save/restore the user's preferences here? */
    [_sourceList expandItem: nil expandChildren: YES];
}

// Enable/disable columns
- (void) toggleColumn: (NSMenuItem *) sender {
    NSTableColumn *column = [sender representedObject];
    if ([sender state] == NSOnState) {
        [column setHidden: YES];
    } else {
        [column setHidden: NO];
    }
}

// from NSMenuDelegate protocol
- (void) menuWillOpen: (NSMenu *) menu {
    assert(menu == _summaryTableHeaderMenu);
    
    [menu removeAllItems];
    for (NSTableColumn *column in [_summaryTableView tableColumns]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: [column.headerCell stringValue]
                                                      action: @selector(toggleColumn:)
                                               keyEquivalent: @""];
        
        if ([column isHidden]) {
            [item setState: NSOffState];
        } else {
            [item setState: NSOnState];
        }
        
        item.target = self;
        item.representedObject = column;
        [menu addItem: item];
    }
}


// Delegate method for a failed summary network fetch.
- (void) summaryAlertDidEnd: (NSAlert *) alert returnCode: (NSInteger) returnCode contextInfo: (void *) contextInfo {
    // TODO - recovery support
}

// from NSTableViewDataSource protocol
- (id) tableView: (NSTableView *) aTableView objectValueForTableColumn: (NSTableColumn *) aTableColumn row: (NSInteger) rowIndex {
    BOOL (^Check)(NSString *) = ^(NSString *ident) {
        return [[aTableColumn identifier] isEqualToString: ident];
    };
    
    ANTRadarSummaryResponse *summary = [_summaries objectAtIndex: rowIndex];
    
#define RetVal(_ident, _data) if (Check(_ident)) return _data;
    RetVal(@"id", summary.radarId);
    RetVal(@"state", summary.stateName);
    RetVal(@"title", summary.title);
    RetVal(@"date", summary.originatedDate);
    RetVal(@"component", summary.componentName);
#undef RetVal
    
    return nil;
}

// from NSTableViewDataSource protocol
- (void) tableView: (NSTableView *) tableView sortDescriptorsDidChange: (NSArray *) oldDescriptors {
    [_summaries sortUsingDescriptors: [tableView sortDescriptors]];
    [tableView reloadData];
}

// from NSTableViewDataSource protocol
- (NSInteger) numberOfRowsInTableView: (NSTableView *) aTableView {
    return [_summaries count];
}

// from PXSourceListDataSource protocol
- (NSUInteger) sourceList: (PXSourceList*) sourceList numberOfChildrenOfItem: (id) item {
	if (item == nil)
		return [_sourceItems count];

    ANTRadarsWindowSourceItem *radarItem = item;
    return [radarItem.children count];
}

// from PXSourceListDataSource protocol
- (id) sourceList: (PXSourceList *) aSourceList child: (NSUInteger) index ofItem: (id) item {
	if(item == nil)
		return [_sourceItems objectAtIndex: index];

    ANTRadarsWindowSourceItem *radarItem = item;
    return [radarItem.children objectAtIndex:index];
}

// from PXSourceListDataSource protocol
- (id) sourceList: (PXSourceList *) aSourceList objectValueForItem: (id) item {
	return ((ANTRadarsWindowSourceItem *)item).title;
}

// from PXSourceListDataSource protocol
- (void) sourceList: (PXSourceList *) aSourceList setObjectValue: (id) object forItem: (id) item {
    // TODO
	// [item setTitle:object];
}

// from PXSourceListDataSource protocol
- (BOOL) sourceList: (PXSourceList *) aSourceList isItemExpandable: (id) item {
    if ([((ANTRadarsWindowSourceItem *)item).children count] > 0)
        return YES;
    
    return NO;
}

// from PXSourceListDataSource protocol
- (BOOL) sourceList: (PXSourceList*) aSourceList itemHasBadge: (id) item {
    // TODO
	return NO;
}

// from PXSourceListDataSource protocol
- (NSInteger) sourceList: (PXSourceList*) aSourceList badgeValueForItem: (id) item {
    // TODO
	return 0;
}

// from PXSourceListDataSource protocol
- (BOOL) sourceList: (PXSourceList*) aSourceList itemHasIcon: (id) item {
    ANTRadarsWindowSourceItem *radarItem = item;
    if (radarItem.icon != nil)
        return YES;
    
    return NO;
}

// from PXSourceListDataSource protocol
- (NSImage *) sourceList: (PXSourceList *) aSourceList iconForItem: (id) item {
    ANTRadarsWindowSourceItem *radarItem = item;
    return radarItem.icon;
}

// from PXSourceListDataSource protocol
- (NSMenu *) sourceList: (PXSourceList *) aSourceList menuForEvent:(NSEvent*)theEvent item:(id)item {
	if ([theEvent type] == NSRightMouseDown || ([theEvent type] == NSLeftMouseDown && ([theEvent modifierFlags] & NSControlKeyMask) == NSControlKeyMask)) {
		NSMenu * m = [[NSMenu alloc] init];
		if (item != nil) {
			[m addItemWithTitle:[item title] action:nil keyEquivalent:@""];
		} else {
			[m addItemWithTitle:@"clicked outside" action:nil keyEquivalent:@""];
		}
		return m;
	}
	return nil;
}

// from PXSourceListDelegate protocol
- (BOOL) sourceList: (PXSourceList *) aSourceList isGroupAlwaysExpanded: (id) group {
    return NO;
}


- (void) sourceListSelectionDidChange: (NSNotification *) notification {
#if 0
	NSIndexSet *selectedIndexes = [sourceList selectedRowIndexes];
	
	//Set the label text to represent the new selection
	if([selectedIndexes count]>1)
		[selectedItemLabel setStringValue:@"(multiple)"];
	else if([selectedIndexes count]==1) {
		NSString *identifier = [[sourceList itemAtRow:[selectedIndexes firstIndex]] identifier];
		
		[selectedItemLabel setStringValue:identifier];
	}
	else {
		[selectedItemLabel setStringValue:@"(none)"];
	}
#endif
}


- (void) sourceListDeleteKeyPressedOnRows: (NSNotification *) notification {
	NSIndexSet *rows = [[notification userInfo] objectForKey:@"rows"];
	
	NSLog(@"Delete key pressed on rows %@", rows);
	
	//Do something here
}

@end

/**
 * A single source window item.
 */
@implementation ANTRadarsWindowSourceItem

/**
 * Return a new instance.
 *
 * @param title The instance's title.
 * @param children Child elements.
 */
+ (instancetype) itemWithTitle: (NSString *) title children: (NSArray *) children {
    return [[self alloc] initWithTitle: title icon: nil children: children];
}

/**
 * Return a new instance.
 *
 * @param title The instance's title.
 * @param icon The instance's custom icon, or nil to use the default.
 */
+ (instancetype) itemWithTitle: (NSString *) title icon: (NSImage *) icon {
    return [[self alloc] initWithTitle: title icon: icon children: nil];
}


/**
 * Initialize a new instance.
 *
 * @param title Title of the source item.
 * @param children Child elements.
 */
- (instancetype) initWithTitle: (NSString *) title icon: (NSImage *) icon children: (NSArray *) children {
    PLSuperInit();
    
    _title = title;
    _children = children;
    _icon = icon;

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