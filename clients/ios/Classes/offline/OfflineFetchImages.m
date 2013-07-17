//
//  OfflineFetchImages.m
//  NewsBlur
//
//  Created by Samuel Clay on 7/15/13.
//  Copyright (c) 2013 NewsBlur. All rights reserved.
//

#import "OfflineFetchImages.h"
#import "NewsBlurAppDelegate.h"
#import "NewsBlurViewController.h"
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"
#import "Utilities.h"

@implementation OfflineFetchImages
@synthesize imageDownloadOperationQueue;
@synthesize appDelegate;

- (void)main {
    appDelegate = [NewsBlurAppDelegate sharedAppDelegate];

    while (YES) {
        BOOL fetched = [self fetchImages];
        NSLog(@"Fetched: %d", fetched);
        if (!fetched) break;
    }
}

- (BOOL)fetchImages {
    if (self.isCancelled) {
        NSLog(@"Images cancelled.");
        [imageDownloadOperationQueue cancelAllOperations];
        return NO;
    }

    NSLog(@"Fetching images...");
    NSArray *urls = [self uncachedImageUrls];

    imageDownloadOperationQueue = [[ASINetworkQueue alloc] init];
    imageDownloadOperationQueue.maxConcurrentOperationCount = [[NSUserDefaults standardUserDefaults]
                                                  integerForKey:@"offline_image_concurrency"];
    imageDownloadOperationQueue.delegate = self;
    
    if (![[[NSUserDefaults standardUserDefaults]
           objectForKey:@"offline_image_download"] boolValue] ||
        ![[[NSUserDefaults standardUserDefaults]
           objectForKey:@"offline_allowed"] boolValue] ||
        [urls count] == 0) {
        NSLog(@"Finished caching images. %d total", appDelegate.totalUncachedImagesCount);
        dispatch_async(dispatch_get_main_queue(), ^{
            [appDelegate.feedsViewController showDoneNotifier];
            [appDelegate.feedsViewController hideNotifier];
        });
        return NO;
    }
    
    NSMutableArray *downloadRequests = [NSMutableArray array];
    for (NSArray *urlArray in urls) {
        NSURL *url = [NSURL URLWithString:[urlArray objectAtIndex:0]];
        NSString *storyHash = [urlArray objectAtIndex:1];
        
        ASIHTTPRequest *request = [ASIHTTPRequest requestWithURL:url];
        [request setUserInfo:@{@"story_hash": storyHash}];
        [request setDelegate:self];
        [request setDidFinishSelector:@selector(storeCachedImage:)];
        [request setDidFailSelector:@selector(storeFailedImage:)];
        [request setTimeOutSeconds:5];
        [downloadRequests addObject:request];
    }
    [imageDownloadOperationQueue setQueueDidFinishSelector:@selector(cachedImageQueueFinished:)];
    [imageDownloadOperationQueue setShouldCancelAllRequestsOnFailure:NO];
    [imageDownloadOperationQueue go];
    [imageDownloadOperationQueue addOperations:downloadRequests waitUntilFinished:YES];
    
    
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        [appDelegate.feedsViewController hideNotifier];
    //    });
    return YES;
}

- (NSArray *)uncachedImageUrls {
    NSMutableArray *urls = [NSMutableArray array];
    
    [appDelegate.database inDatabase:^(FMDatabase *db) {
        NSString *commonQuery = @"FROM cached_images c "
        "INNER JOIN unread_hashes u ON (c.story_hash = u.story_hash) "
        "WHERE c.image_cached is null and c.failed != 1 ";
        int count = [db intForQuery:[NSString stringWithFormat:@"SELECT COUNT(1) %@", commonQuery]];
        if (appDelegate.totalUncachedImagesCount == 0) {
            appDelegate.totalUncachedImagesCount = count;
            appDelegate.remainingUncachedImagesCount = appDelegate.totalUncachedImagesCount;
        } else {
            appDelegate.remainingUncachedImagesCount = count;
        }
        
        int limit = 96;
        NSString *order;
        if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"default_order"] isEqualToString:@"oldest"]) {
            order = @"ASC";
        } else {
            order = @"DESC";
        }
        NSString *sql = [NSString stringWithFormat:@"SELECT c.image_url, c.story_hash, u.story_timestamp %@ ORDER BY u.story_timestamp %@ LIMIT %d", commonQuery, order, limit];
        FMResultSet *cursor = [db executeQuery:sql];
        
        while ([cursor next]) {
            [urls addObject:@[[cursor objectForColumnName:@"image_url"],
             [cursor objectForColumnName:@"story_hash"],
             [cursor objectForColumnName:@"story_timestamp"]]];
        }
        int start = (int)[[NSDate date] timeIntervalSince1970];
        int end = [[[urls lastObject] objectAtIndex:2] intValue];
        int seconds = start - (end ? end : start);
        __block int hours = (int)round(seconds / 60.f / 60.f);
        
        __block float progress = 0.f;
        if (appDelegate.totalUncachedImagesCount) {
            progress = 1.f - ((float)appDelegate.remainingUncachedImagesCount /
                              (float)appDelegate.totalUncachedImagesCount);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [appDelegate.feedsViewController showCachingNotifier:progress hoursBack:hours];
        });
    }];
    
    return urls;
}

- (void)storeCachedImage:(ASIHTTPRequest *)request {
    if (self.isCancelled) {
        NSLog(@"Image cancelled.");
        [request clearDelegatesAndCancel];
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,
                                             (unsigned long)NULL), ^{
        
        NSString *storyHash = [[request userInfo] objectForKey:@"story_hash"];
        
        if ([request responseStatusCode] == 200) {
            NSData *responseData = [request responseData];
            NSString *md5Url = [Utilities md5:[[request originalURL] absoluteString]];
            NSLog(@"Storing image: %@ (%d bytes - %d in queue)", storyHash, [responseData length], [imageDownloadOperationQueue requestsCount]);
            if ([responseData length] <= 43) {
                NSLog(@" ---> Image url: %@", [request url]);
            }
            
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            NSString *cacheDirectory = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"story_images"];
            NSString *fullPath = [cacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@", md5Url]];
            
            [fileManager createFileAtPath:fullPath contents:responseData attributes:nil];
        } else {
            NSLog(@"Failed to fetch: %@ / %@", [[request originalURL] absoluteString], storyHash);
        }
        
        [appDelegate.database inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"UPDATE cached_images SET "
             "image_cached = 1 WHERE story_hash = ?",
             storyHash];
        }];
    });
}

- (void)storeFailedImage:(ASIHTTPRequest *)request {
    NSString *storyHash = [[request userInfo] objectForKey:@"story_hash"];
    
    [appDelegate.database inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"UPDATE cached_images SET "
         "image_cached = 1, failed = 1 WHERE story_hash = ?",
         storyHash];
    }];
}

- (void)cachedImageQueueFinished:(ASINetworkQueue *)queue {
    NSLog(@"Queue finished: %d total (%d remaining)", appDelegate.totalUncachedImagesCount, appDelegate.remainingUncachedImagesCount);
    [self fetchImages];
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        [self.feedsViewController hideNotifier];
    //    });
}

@end
