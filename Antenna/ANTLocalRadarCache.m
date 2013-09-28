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

#import "ANTLocalRadarCache.h"
#import <PLFoundation/PLFoundation.h>
#import <PlausibleDatabase/PlausibleDatabase.h>

#import "ANTDatabaseMigrationBuilder.h"

#import <objc/runtime.h>

/* Maximum number of Radars to be fetched; this is admitedly a completely arbitrary sanity check. */
#define MAX_RADARS 10000

@interface ANTLocalRadarCache () <ANTNetworkClientObserver>

@end

/**
 * Manages a local Radar cache.
 */
@implementation ANTLocalRadarCache {
@private
    /** Our storage directory */
    NSString *_path;

    /** Backing database connection provider */
    id<PLDatabaseConnectionProvider> _connectionPool;

    /** The backing network client */
    ANTNetworkClient *_client;
    
    /** Database migrations */
    ANTDatabaseMigrationBuilder *_migrations;
}

/**
 * Initialize a new Radar cache instance.
 *
 * @param client The Radar network client to be used for Radar synchronization.
 * @param cachePath The path at which the cache should be stored.
 * @param outError If initialization of the cache fails, an error in the ANTErrorDomain will be returned.
 *
 * @return Returns an initialized instance on success, or nil on failure.
 */
- (instancetype) initWithClient: (ANTNetworkClient *) client path: (NSString *) path error: (NSError **) outError {
    PLSuperInit();
    NSError *error;
    
    _path = path;
    _client = client;
    [_client addObserver: self dispatchContext: [PLDirectDispatchContext context]];

    /* Set up the destination directory */
    NSFileManager *fm = [NSFileManager new];
    if (![fm createDirectoryAtPath: path withIntermediateDirectories: YES attributes: @{NSFilePosixPermissions: @(0750)} error: &error]) {
        /* This should only happen on a misconfigured host */
        NSLog(@"Failed to create %s path %@", class_getName([self class]), path);
        [NSError pl_errorWithDomain: ANTErrorDomain
                               code: ANTErrorStorageFailure
               localizedDescription: [error localizedDescription]
             localizedFailureReason: [error localizedFailureReason]
                    underlyingError: error
                           userInfo: nil];
        return nil;
    }
    
    /* Set up the backing database */
    NSString *dbPath = [_path stringByAppendingPathComponent: @"radar.db"];
    PLSqliteConnectionProvider *connectionProvider;
    connectionProvider = [[PLSqliteConnectionProvider alloc] initWithPath: dbPath
                                                                    flags: SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_SHAREDCACHE|SQLITE_OPEN_FULLMUTEX];

    /* Insert a connection filter to perform one-time database connection configuration. */
    PLDatabaseFilterConnectionProvider *filterProvider = [[PLDatabaseFilterConnectionProvider alloc] initWithConnectionProvider: connectionProvider filterBlock:^(id<PLDatabase> db) {
        NSError *error;
        
        /* Set the persistent journal mode to WAL; this provides us with improved concurrency and performance.
         * While this setting is on-disk persisted, it must be set outside of a transaction, which precludes enabling it within a migration. */
        if (![db executeUpdateAndReturnError: &error statement: @"PRAGMA journal_mode = WAL"])
            NSLog(@"Failed to enable WAL journaling: %@", error);
        
        /* Enable foreign key constraints; these default to OFF, and the setting is not persistent across connections. */
        if (![db executeUpdateAndReturnError: &error statement: @"PRAGMA foreign_keys = ON"])
            NSLog(@"Failed to enable foreign key support: %@", error);
    }];
    
    /* Configure our migrations */
    _migrations = [ANTDatabaseMigrationBuilder new];
    _migrations.migration(1, ^(ANTDatabaseMigrationState *state) {
        state.update(
             @"CREATE TABLE radar ("
                 "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                 "open_radar INTEGER NOT NULL CHECK (open_radar == 0 OR open_radar == 1),"
                 "title TEXT NOT NULL,"
                 "originator TEXT,"
                 "originated_date DATETIME NOT NULL," // Originated date (as a UNIX timestamp)
                 "modified_date DATETIME NOT NULL," // Modified date (as a UNIX timestamp)
                 "resolved INTEGER NOT NULL CHECK (resolved == 0 OR resolved == 1),"
                 "state TEXT NOT NULL,"
                 "component TEXT NOT NULL,"
                 "radar_number INTEGER NOT NULL,"
                 "last_read_date DATETIME," // The last read comment's date (as a UNIX timestamp).
                 "CONSTRAINT radar_unique_number UNIQUE (open_radar, radar_number)"
             ");"
        );
        state.update(@"CREATE INDEX radar_number_idx ON radar (radar_number);");
    });
    
    PLSqliteMigrationManager *sqliteMigrationManager = [PLSqliteMigrationManager new];
    PLDatabaseMigrationManager *migrationManager = [[PLDatabaseMigrationManager alloc] initWithTransactionManager: sqliteMigrationManager
                                                                                                   versionManager: sqliteMigrationManager
                                                                                                         delegate: _migrations];
    
    /* Insert a migration provider */
    PLDatabaseMigrationConnectionProvider *migrateProvider = [[PLDatabaseMigrationConnectionProvider alloc] initWithConnectionProvider: filterProvider
                                                                                                                      migrationManager: migrationManager];
    
    
    /*
     * Insert a connection pool. This will pool connections for which migrations and one-time setup has already been completed.
     * We set an unlimited capacity; in reality, capacity will be bounded by the maximum number of concurrent threads that access
     * the pool.
     */
    _connectionPool = [[PLDatabasePoolConnectionProvider alloc] initWithConnectionProvider: migrateProvider capacity: 0];

    return self;
}

// from ANTNetworkClient protocol
- (void) networkClientDidChangeAuthState: (ANTNetworkClient *) client {
    // TODO - sync should be scheduled externally.
    if (client.authState == ANTNetworkClientAuthStateAuthenticated)
        [self performSyncWithCancelTicket: [PLCancelTicketSource new].ticket dispatchContext: [PLDirectDispatchContext context] completionBlock: ^(NSError *error) {
            if (error != nil)
                NSLog(@"Synchronization failed with %@", error);
            else
                NSLog(@"Synchronization completed successfully");
        }];
}

/**
 * @internal
 * Acquire and return a database connection, or nil on failure.
 */
- (PLSqliteDatabase *) getConnectionAndReturnError: (NSError **) outError {
    NSError *dbError;
    PLSqliteDatabase *db = [_connectionPool getConnectionAndReturnError: &dbError];
    if (db != nil)
        return db;
    
    if (outError != NULL) {
        *outError = [NSError pl_errorWithDomain: ANTErrorDomain
                                           code: ANTErrorStorageFailure
                           localizedDescription: NSLocalizedString(@"Could not acquire a connection to the backing database.", nil)
                         localizedFailureReason: nil
                                underlyingError: dbError
                                       userInfo: nil];
    }

    return nil;
}

/**
 * Return all Radars modified with the given @a state @a date, as an array of ANTCachedRadar instances.
 *
 * @param state All radars matching this state will be returned.
 * @param openRadar If YES Open Radars will be returned. If NO, Apple Radars will be returned.
 * @param outError If the query fails, an error in the ANTErrorDomain will be returned.
 */
- (NSArray *) radarsWithState: (NSString *) state openRadar: (BOOL) openRadar error: (NSError **) outError {
    PLSqliteDatabase *db = [self getConnectionAndReturnError: outError];
    if (db == nil)
        return nil;
    
    /* Enumerate the results */
    NSMutableArray *results = [NSMutableArray array];
    NSError *dbError;
    BOOL dbFailed;
    dbFailed = [[db executeQueryAndReturnError: &dbError statement: @"SELECT title, resolved, modified_date, (modified_date > last_read_date) FROM radar WHERE state = ? AND open_radar = ?", state, @(openRadar)] enumerateAndReturnError: &dbError block:^(id<PLResultSet> rs, BOOL *stop) {
        ANTCachedRadar *radar = [[ANTCachedRadar alloc] initWithTitle: rs[0]
                                                             resolved: [rs boolForColumnIndex: 1]
                                                     lastModifiedDate: [rs dateForColumnIndex: 2]
                                                               unread: [rs boolForColumnIndex: 3]];
        [results addObject: radar];
        
    }];
    
    /* Handle query failure; should never fail */
    if (dbFailed) {
        if (outError != NULL)
            *outError = [NSError pl_errorWithDomain: ANTErrorDomain code: ANTErrorStorageFailure localizedDescription: NSLocalizedString(@"Query failed.", nil) localizedFailureReason: nil underlyingError: dbError userInfo: nil];

        return nil;
    }

    return results;
}

/**
 * Return all Radars modified since @a date, as an array of ANTCachedRadar instances.
 *
 * @param dateSince All radars modified since this date will be returned.
 * @param openRadar If YES Open Radars will be returned. If NO, Apple Radars will be returned.
 * @param outError If the query fails, an error in the ANTErrorDomain will be returned.
 */
- (NSArray *) radarsUpdatedSince: (NSDate *) dateSince openRadar: (BOOL) openRadar error: (NSError **) outError {
    PLSqliteDatabase *db = [self getConnectionAndReturnError: outError];
    if (db == nil)
        return nil;
    
    /* Enumerate the results */
    NSMutableArray *results = [NSMutableArray array];
    NSError *dbError;
    BOOL dbFailed;
    dbFailed = [[db executeQueryAndReturnError: &dbError statement: @"SELECT title, resolved, modified_date, (modified_date > last_read_date) FROM radar WHERE last_modified > ? AND open_radar = ?", dateSince, @(openRadar)] enumerateAndReturnError: &dbError block:^(id<PLResultSet> rs, BOOL *stop) {
        ANTCachedRadar *radar = [[ANTCachedRadar alloc] initWithTitle: rs[0]
                                                             resolved: [rs boolForColumnIndex: 1]
                                                     lastModifiedDate: [rs dateForColumnIndex: 2]
                                                               unread: [rs boolForColumnIndex: 3]];
        [results addObject: radar];
        
    }];
    
    /* Handle query failure; should never fail */
    if (dbFailed) {
        if (outError != NULL)
            *outError = [NSError pl_errorWithDomain: ANTErrorDomain code: ANTErrorStorageFailure localizedDescription: NSLocalizedString(@"Query failed.", nil) localizedFailureReason: nil underlyingError: dbError userInfo: nil];
        
        return nil;
    }
    
    return results;
}

/**
 * Synchronize the local store with the remote database, using the authenticated backing network client. If the network client
 * is not authenticated, the synchronization will fail.
 *
 * @param ticket A request cancellation ticket.
 * @param context The dispatch context on which @a handler will be called.
 * @param completionHandler The block to call upon completion. If an error occurs, error will be non-nil.
 *
 * @todo We need to coalesce concurrent synchronization requests to prevent deletion of issues that are added by a later synchronization
 * attempt before the earlier attempt has finished.
 */
- (void) performSyncWithCancelTicket: (PLCancelTicket *) ticket dispatchContext: (id<PLDispatchContext>) context completionBlock: (void(^)(NSError *error)) completionBlock {
    PLGCDDispatchContext *concurrentContext = [[PLGCDDispatchContext alloc] initWithQueue: PL_DEFAULT_QUEUE];
    PLGCDDispatchContext *serialContext = [[PLGCDDispatchContext alloc] initWithQueue: dispatch_queue_create("coop.plausible.antenna.cache-sync", DISPATCH_QUEUE_SERIAL)];

    /* Executes the caller's completion block on the expected context */
    void (^PerformCompletion)(NSError *) = ^(NSError *error) {
        [context performWithCancelTicket: ticket block:^{
            completionBlock(error);
        }];
    };

    /* Request summaries for all supported sections */
    NSArray *sections = @[ANTNetworkClientFolderTypeOpen, ANTNetworkClientFolderTypeClosed, ANTNetworkClientFolderTypeArchive];
    [_client requestSummariesForSections: sections maximumCount: MAX_RADARS cancelTicket: ticket dispatchContext: concurrentContext completionHandler: ^(NSArray *summaries, NSError *error) {
        /* Handle network failure */
        if (error != nil) {
            PerformCompletion(error);
            return;
        }
        
        /* The radars seen during this synchronization cycle, and the remaining number of summaries to process. Access to these values is synchronized via our serialContext. */
        NSMutableArray *radarsSeen = [NSMutableArray array];
        __block NSUInteger remainingItems = [summaries count];

        /* Iterate over the summary data, fetching and caching the Radar contents. */
        for (ANTRadarSummaryResponse *summaryResponse in summaries) {
            /* The requests are all dispatched concurrently; we use an internal cancellation ticket to support cancelling all of our requests should
             * one of our requests fail */
            PLCancelTicketSource *multiRequestCancellation = [[PLCancelTicketSource alloc] initWithLinkedTickets: [NSSet setWithObjects: ticket, nil]];

            /* Fetch the radar details for each radar summary and insert into the backing database. We maintain serialization through the use of a shared serial context*/
            [_client requestRadarWithId: summaryResponse.radarId cancelTicket: multiRequestCancellation.ticket dispatchContext: serialContext completionHandler: ^(ANTRadarResponse *radarResponse, NSError *error) {
                PLSqliteDatabase *db;
                NSError *dbError;
                
                /* Mark the radar as seen */
                [radarsSeen addObject: summaryResponse.radarId];
                
                /* Mark the summary as processed */
                remainingItems--;

                /* Executes the caller's completion block on the expected context, using our own cancellation ticket on
                 * a serial queue to prevent multiple cancellations from being issued. Whichever completion block is scheduled
                 * first wins. */
                void (^PerformMultiCompletion)(NSError *) = ^(NSError *error) {
                    [serialContext performWithCancelTicket: multiRequestCancellation.ticket block: ^{
                        /* Cancel all other requests, assuming any are still active */
                        [multiRequestCancellation cancel];
                        
                        /* Issue the callback in the expected context. */
                        [context performWithCancelTicket: ticket block:^{
                            completionBlock(error);
                        }];
                    }];
                };

                /* Handle network failure */
                if (error != nil) {
                    PerformMultiCompletion(error);
                    return;
                }

                /* Fetch a connection from the pool */
                if ((db = [_connectionPool getConnectionAndReturnError: &dbError]) == nil) {
                    NSError *err = [NSError pl_errorWithDomain: ANTErrorDomain
                                                          code: ANTErrorStorageFailure
                                          localizedDescription: NSLocalizedString(@"Failed to acquire a database connection.", nil)
                                        localizedFailureReason: nil
                                               underlyingError: dbError
                                                      userInfo: nil];
                    PerformMultiCompletion(err);
                    return;
                }
                
                /* Execute our transaction */
                __block NSError *txError = nil;
                BOOL txSuccess = [db performTransactionWithRetryBlock: ^PLDatabaseTransactionResult {
                    /* Find any existing radar */
                    NSString *query = @"SELECT originator, title, originated_date, modified_date, resolved, state, component FROM radar WHERE open_radar = 0 AND radar_number = ?";
                    __block BOOL dirty = NO;
                    __block BOOL found = NO;
                    __block NSString *originatorName = nil;
                    if (![[db executeQueryAndReturnError: &txError statement: query, summaryResponse.radarId] enumerateAndReturnError: &txError block: ^(id<PLResultSet> rs, BOOL *stop) {
                        found = YES;
    
                        /*
                         * Determine whether the record requires updating. We don't make use of the modified date for this
                         * test, as it's possible (though unlikely) that the record could change without the date being bumped,
                         * or that concurrent changes could result in an identical date.
                         */
                        
                        /* Originator (The radar author can be found in the first comment) */
                        if ([radarResponse.comments count] > 0) {
                            ANTRadarCommentResponse *commentResponse = radarResponse.comments[0];
                            originatorName = commentResponse.authorName;
                            if (![rs[1] isEqual: originatorName])
                                dirty = YES;
                        } else if (rs[1] != nil) {
                            dirty = YES;
                        }

                        #define CHECK_STALE(current, val) if (current != val && ![current isEqual: val]) dirty = YES;
                        CHECK_STALE(rs[1], radarResponse.title);
                        CHECK_STALE(rs[2], summaryResponse.originatedDate);
                        CHECK_STALE(rs[3], radarResponse.lastModifiedDate);
                        CHECK_STALE(rs[4], ((NSNumber *) @(radarResponse.isResolved)));
                        CHECK_STALE(rs[5], summaryResponse.stateName);
                        CHECK_STALE(rs[6], summaryResponse.componentName);

                        #undef CHECK_STALE
                    }]) {
                        /* Query failed */
                        return PLDatabaseTransactionRollback;
                    }
                    
                    /* INSERT or UPDATE */
                    if (found && dirty) {
                        NSString *query = @"UPDATE radar SET title = ?, originator = ?, originated_date = ?, modified_date = ?, resolved = ?, state = ?, component = ? WHERE radar_number = ? AND open_radar = 0";
                        if (![db executeUpdateAndReturnError: &txError statement: query,
                              radarResponse.title,
                              originatorName,
                              summaryResponse.originatedDate,
                              radarResponse.lastModifiedDate,
                              @(radarResponse.isResolved),
                              summaryResponse.stateName,
                              summaryResponse.componentName,
                              summaryResponse.radarId])
                        {
                            return PLDatabaseTransactionRollback;
                        }
                    } else if (!found) {
                        NSString *query = @"INSERT INTO radar (radar_number, title, originator, originated_date, modified_date, resolved, state, component, open_radar) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)";
                        if (![db executeUpdateAndReturnError: &txError statement: query,
                              summaryResponse.radarId,
                              radarResponse.title,
                              originatorName,
                              summaryResponse.originatedDate,
                              radarResponse.lastModifiedDate,
                              @(radarResponse.isResolved),
                              summaryResponse.stateName,
                              summaryResponse.componentName])
                        {
                            return PLDatabaseTransactionRollback;
                        }
                    }
                    
                    /* If this is the last lookup, clean up any Radars that were not seen during synchronization */
                    if (remainingItems == 0) {
                        /* Set up the temporary memory tabel */
                        if (![db executeUpdateAndReturnError: &txError statement: @"DROP TABLE IF EXISTS radar_seen_temp"])
                          return PLDatabaseTransactionRollback;
                        
                        if (![db executeUpdateAndReturnError: &txError statement: @"CREATE TEMP TABLE radar_seen_temp ( radar_number INTEGER NOT NULL )"])
                            return PLDatabaseTransactionRollback;
                        
                        /* Insert all known radar identifiers */
                        for (NSNumber *radarNumber in radarsSeen) {
                            if (![db executeUpdateAndReturnError: &txError statement: @"INSERT INTO radar_seen_temp (radar_number) VALUES (?)", radarNumber])
                                return PLDatabaseTransactionRollback;
                        }
                        
                        /* Delete all stale radar values */
                        if (![db executeUpdateAndReturnError: &txError statement: @"DELETE FROM radar WHERE radar_number NOT IN (SELECT radar_number FROM radar_seen_temp)"])
                            return PLDatabaseTransactionRollback;
                        
                        /* Drop the temporary table */
                        if (![db executeUpdateAndReturnError: &txError statement: @"DROP TABLE radar_seen_temp"])
                            return PLDatabaseTransactionRollback;
                    }
                    
                    /* Mark as complete and commit */
                    txError = nil;
                    return PLDatabaseTransactionCommit;
                } error: &dbError];
                
                /* Return the connection */
                [_connectionPool closeConnection: db];

                /* Check for a COMMIT failure; this should never happen. */
                if (!txSuccess) {
                    NSError *err = [NSError pl_errorWithDomain: ANTErrorDomain
                                                          code: ANTErrorStorageFailure
                                          localizedDescription: NSLocalizedString(@"Failed to commit transaction to backing database.", nil)
                                        localizedFailureReason: nil
                                               underlyingError: dbError
                                                      userInfo: nil];
                    PerformMultiCompletion(err);
                    return;
                }
                
                /* Report any query errors; this should never happen. */
                if (txError) {
                    NSError *err = [NSError pl_errorWithDomain: ANTErrorDomain
                                                          code: ANTErrorStorageFailure
                                          localizedDescription: NSLocalizedString(@"Could not update the radar cache.", nil)
                                        localizedFailureReason: nil
                                               underlyingError: txError
                                                      userInfo: nil];
                    PerformMultiCompletion(err);
                    return;
                }
                
                /* Check for completion */
                if (remainingItems == 0)
                    PerformMultiCompletion(nil);

                
                return;
            }];
        }
    }];
}

@end
