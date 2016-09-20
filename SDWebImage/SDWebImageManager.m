/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import <objc/message.h>

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic) SDWebImageNoParamsBlock cancelBlock;

// 根据cacheType获取到image，这里虽然名字用的是cache，但是如果cache没有获取到图片
// 还是要把image下载下来的。此处只是把通过cache获取image和通过download获取image封装起来
@property (strong, nonatomic) NSOperation *cacheOperation;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic) NSMutableSet *failedURLs;                 /**< 一组下载失败的图片URL */
@property (strong, nonatomic) NSMutableArray *runningOperations;

@end

@implementation SDWebImageManager

+ (id)sharedManager {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (id)init {
    if ((self = [super init])) {
        _imageCache = [self createCache];
        _imageDownloader = [SDWebImageDownloader sharedDownloader];
        _failedURLs = [NSMutableSet new];
        _runningOperations = [NSMutableArray new];
    }
    return self;
}

- (SDImageCache *)createCache {
    return [SDImageCache sharedImageCache];
}

- (NSString *)cacheKeyForURL:(NSURL *)url {
    if (self.cacheKeyFilter) {
        return self.cacheKeyFilter(url);
    }
    else {
        return [url absoluteString];
    }
}

- (BOOL)cachedImageExistsForURL:(NSURL *)url {
    NSString *key = [self cacheKeyForURL:url];
    if ([self.imageCache imageFromMemoryCacheForKey:key] != nil) return YES;
    return [self.imageCache diskImageExistsWithKey:key];
}

- (BOOL)diskImageExistsForURL:(NSURL *)url {
    NSString *key = [self cacheKeyForURL:url];
    return [self.imageCache diskImageExistsWithKey:key];
}

- (void)cachedImageExistsForURL:(NSURL *)url
                     completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    BOOL isInMemoryCache = ([self.imageCache imageFromMemoryCacheForKey:key] != nil);
    
    if (isInMemoryCache) {
        // making sure we call the completion block on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(YES);
            }
        });
        return;
    }
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

- (void)diskImageExistsForURL:(NSURL *)url
                   completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

/**
 * 如果图片不在缓存中，根据指定的URL下载图片，否则使用缓存中的图片。
 *
 * @param url            图片的URL
 * @param options        该请求所要遵循的选项。（前面已经介绍了两个）
 * @param progressBlock  当图片正在下载时调用该block。
 * @param completedBlock 当操作完成后调用该block。
 *   ---------------------------------------
 *   该参数是必须的。（指的是completedBlock）
 *
 *   该block没有返回值并且用请求的UIImage作为第一个参数。
 *   如果请求出错，那么image参数为nil，而第二参数将包含一个NSError对象。
 *
 *   第三个参数是'SDImageCacheType'枚举，表明该图片重新获取方式是从本地缓存（硬盘）或者
 *   从内存缓存，还是从网络端重新获取image一遍。
 *   ---------------------------------------
 *   当这个方法的 options 参数设为 SDWebImageProgressiveDownload 并且此时图片正在下载，finished 将设为 NO
 *   因此这个 block 会不停地调用直到图片下载完成，此时才会设置finished为YES.
 *
 * @return 返回一个遵循SDWebImageOperation协议的NSObject. 应该是一个SDWebImageDownloaderOperation的实例
 */
- (id <SDWebImageOperation>)downloadImageWithURL:(NSURL *)url
                                         options:(SDWebImageOptions)options
                                        progress:(SDWebImageDownloaderProgressBlock)progressBlock
                                       completed:(SDWebImageCompletionWithFinishedBlock)completedBlock {
    // Invoking this method without a completedBlock is pointless
    /**
     *  如果调用此方法，而没有传completedBlock，那将是无意义的.
        不要将completedBlock参数设为nil，因为这样做是毫无意义的。如果你是想使用downloadImageWithURL来预先获取image，那就应该使用[SDWebImagePrefetcher prefetchURLs]，而不是直接调用SDWebImageManager中的downloadImageWithURL函数。
     */
    NSAssert(completedBlock != nil, @"If you mean to prefetch the image, use -[SDWebImagePrefetcher prefetchURLs] instead");

    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    /**
     *  使用NSString对象而非NSURL作为url是常见的错误. 因为某些奇怪的原因，Xcode不会报任何类型不匹配的警告，这里允许传NSString对象给URL。
     */
    if ([url isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)url];
    }

    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    /**
     *  防止传了一个NSNull值给NSURL
     */
    if (![url isKindOfClass:NSURL.class]) {
        url = nil;
    }

    __block SDWebImageCombinedOperation *operation = [SDWebImageCombinedOperation new];
    /** 避免循环引用，使用了weak */
    __weak SDWebImageCombinedOperation *weakOperation = operation;

    BOOL isFailedUrl = NO;
    @synchronized (self.failedURLs) {
        isFailedUrl = [self.failedURLs containsObject:url];
    }

    /**
     *  如果这个图片url无法下载，那就使用completedBlock进行错误处理。那什么情况下算这个图片url无法下载呢？
            第一种情况是该url为空
            另一种情况就是如果是failedUrl也无法下载，但是要避免无法下载就放入failedUrl的情况，就要设置options为SDWebImageRetryFailed。
        一般默认image无法下载，这个url就会加入黑名单，但是设置了SDWebImageRetryFailed会禁止添加到黑名单，不停重新下载。
     */
    if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
        dispatch_main_sync_safe(^{
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
            completedBlock(nil, error, SDImageCacheTypeNone, YES, url);
        });
        return operation;
    }

    /** 如果该url可以下载，那么就添加一个新的operation到runningOperations中 */
    @synchronized (self.runningOperations) {
        [self.runningOperations addObject:operation];
    }
    
    /** 剩下的100多行就是为了生成一个cacheOperation。它是一个NSOperation，所以加入NSOperationQueue会自动执行。 */
    /* >>>>>>>>>>>>>>>>>>  生成cacheOperation  >>>>>>>>>>>>>>>>>> */
    
    /** 用图片的url来获取cache对应的key，也就是说cache中如果已经有了该图片，那就返回该图片在cache中对应的key，你可以根据这个key去cache中获取图片 */
    NSString *key = [self cacheKeyForURL:url];
    operation.cacheOperation = [self.imageCache queryDiskCacheForKey:key done:^(UIImage *image, SDImageCacheType cacheType) {
        
        /** 随时判断该operation是否已经cancel了 */
        if (operation.isCancelled) {
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }
            return;
        }

        /**
         *  注意在if里面最后一组||表达式，使用了短路判断(A||B，只要A为真，就不用判断B了)，也就是说:
                如果delegate没有实现imageManager:shouldDownloadImageForURL:函数，整个表达式就为真，相当于该函数返回了YES
                如果delegate实现了该函数，那就执行该函数，并且判断该函数执行结果。如果函数返回NO，那么整个if表达式都为NO，那么当图片缓存未命中时，图片下载反而被阻止
         
            目前我看的源码中并没有地方实现了该函数，所以就当if后半段恒为YES。我们主要还是看前面那个||表达式，如果没有缓存到image，或者options中有SDWebImageRefreshCached选项，就执行if语句。
         */
        if ((!image || options & SDWebImageRefreshCached) &&
            (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url])) {
            
            /**
             *  如果图片在缓存中找到，但是options中有SDWebImageRefreshCached，那么就尝试重新下载该图片，这样是NSURLCache有机会从服务器端刷新自身缓存
             */
            if (image && options & SDWebImageRefreshCached) {
                dispatch_main_sync_safe(^{
                    // If image was found in the cache but SDWebImageRefreshCached is provided, notify about the cached image
                    // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                    completedBlock(image, nil, cacheType, YES, url);
                });
            }

            // download if no image or requested to refresh anyway, and download allowed by delegate
            /**
             *  首先定义了一个SDWebImageDownloaderOptions枚举值downloaderOptions，并根据options来设置downloaderOptions。基本上SDWebImageOptions和SDWebImageDownloaderOptions是一一对应的。
             */
            SDWebImageDownloaderOptions downloaderOptions = 0;
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
            if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
            if (options & SDWebImageHandleCookies) downloaderOptions |= SDWebImageDownloaderHandleCookies;
            if (options & SDWebImageAllowInvalidSSLCertificates) downloaderOptions |= SDWebImageDownloaderAllowInvalidSSLCertificates;
            if (options & SDWebImageHighPriority) downloaderOptions |= SDWebImageDownloaderHighPriority;
            
            if (image && options & SDWebImageRefreshCached) {
                // force progressive off if image already cached but forced refreshing
                /**
                 *  相当于downloaderOptions =  downloaderOption & ~SDWebImageDownloaderProgressiveDownload);
                 */
                downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                
                // ignore image read from NSURLCache if image if cached but force refreshing
                /**
                 *  相当于 downloaderOptions = (downloaderOptions | SDWebImageDownloaderIgnoreCachedResponse);
                 */
                downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
            }
            
            /** http://images2015.cnblogs.com/blog/715314/201512/715314-20151226140747781-719814073.png */
            id <SDWebImageOperation> subOperation = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *data, NSError *error, BOOL finished) {
                
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (!strongOperation || strongOperation.isCancelled) {
                    // Do nothing if the operation was cancelled
                    // See #699 for more details
                    // if we would call the completedBlock, there could be a race condition between this block and another completedBlock for the same object, so if this one is called second, we will overwrite the new data
                }
                else if (error) {
                    dispatch_main_sync_safe(^{
                        if (strongOperation && !strongOperation.isCancelled) {
                            completedBlock(nil, error, SDImageCacheTypeNone, finished, url);
                        }
                    });

                    if (   error.code != NSURLErrorNotConnectedToInternet
                        && error.code != NSURLErrorCancelled
                        && error.code != NSURLErrorTimedOut
                        && error.code != NSURLErrorInternationalRoamingOff
                        && error.code != NSURLErrorDataNotAllowed
                        && error.code != NSURLErrorCannotFindHost
                        && error.code != NSURLErrorCannotConnectToHost) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs addObject:url];
                        }
                    }
                }
                else {
                    if ((options & SDWebImageRetryFailed)) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs removeObject:url];
                        }
                    }
                    
                    BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);

                    if (options & SDWebImageRefreshCached && image && !downloadedImage) {
                        // Image refresh hit the NSURLCache cache, do not call the completion block
                    }
                    else if (downloadedImage && (!downloadedImage.images || (options & SDWebImageTransformAnimatedImage)) && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)]) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];

                            if (transformedImage && finished) {
                                BOOL imageWasTransformed = ![transformedImage isEqual:downloadedImage];
                                [self.imageCache storeImage:transformedImage recalculateFromImage:imageWasTransformed imageData:(imageWasTransformed ? nil : data) forKey:key toDisk:cacheOnDisk];
                            }

                            dispatch_main_sync_safe(^{
                                if (strongOperation && !strongOperation.isCancelled) {
                                    completedBlock(transformedImage, nil, SDImageCacheTypeNone, finished, url);
                                }
                            });
                        });
                    }
                    else {
                        if (downloadedImage && finished) {
                            [self.imageCache storeImage:downloadedImage recalculateFromImage:NO imageData:data forKey:key toDisk:cacheOnDisk];
                        }

                        dispatch_main_sync_safe(^{
                            if (strongOperation && !strongOperation.isCancelled) {
                                completedBlock(downloadedImage, nil, SDImageCacheTypeNone, finished, url);
                            }
                        });
                    }
                }

                if (finished) {
                    @synchronized (self.runningOperations) {
                        if (strongOperation) {
                            [self.runningOperations removeObject:strongOperation];
                        }
                    }
                }
            }];
            
            /**
             *  operation如果取消了，那么就会执行subOperation的cancel函数。并且从runningOperations中移除该operation，因为是block，为了避免循环引用，所以使用了weakOperation。runningOperations大概从名字也能猜到，用来存储正在运行的operation。既然当前operation被取消了，肯定要从runningOperations中移除
             */
            operation.cancelBlock = ^{
                [subOperation cancel];
                
                /**
                 *  @synchronized
                 避免多个线程执行同一段代码，主要防止当前operation会被多次remove，从而造成crash。这里括号内的self.runningOperations是用作互斥信号量。 即此时其他线程不能修改self.runningOperations中的属性。
                 */
                @synchronized (self.runningOperations) {
                    __strong __typeof(weakOperation) strongOperation = weakOperation;
                    if (strongOperation) {
                        [self.runningOperations removeObject:strongOperation];
                    }
                }
            };
            
        } else if (image) {
            /**
             *  从缓存中获取到了图片，而且不需要刷新缓存，直接执行completedBlock，其中error置为nil即可
             */
            dispatch_main_sync_safe(^{
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (strongOperation && !strongOperation.isCancelled) {
                    completedBlock(image, nil, cacheType, YES, url);
                }
            });
            /**
             *  执行完后，说明图片获取成功，可以把当前这个operation移除了
             */
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }
        } else {
            // Image not in cache and download disallowed by delegate
            /**
             *  又没有从缓存中获取到图片，shouldDownloadImageForURL又返回NO，不允许下载，悲催！所以completedBlock中image和error均传入nil
             */
            dispatch_main_sync_safe(^{
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (strongOperation && !weakOperation.isCancelled) {
                    completedBlock(nil, nil, SDImageCacheTypeNone, YES, url);
                }
            });
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }
        }
    }];
    /* <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */
    
    return operation;
}

- (void)saveImageToCache:(UIImage *)image forURL:(NSURL *)url {
    if (image && url) {
        NSString *key = [self cacheKeyForURL:url];
        [self.imageCache storeImage:image forKey:key toDisk:YES];
    }
}

- (void)cancelAll {
    @synchronized (self.runningOperations) {
        NSArray *copiedOperations = [self.runningOperations copy];
        [copiedOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeObjectsInArray:copiedOperations];
    }
}

- (BOOL)isRunning {
    BOOL isRunning = NO;
    @synchronized(self.runningOperations) {
        isRunning = (self.runningOperations.count > 0);
    }
    return isRunning;
}

@end


@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(SDWebImageNoParamsBlock)cancelBlock {
    // check if the operation is already cancelled, then we just call the cancelBlock
    // 检测self（是一个SDWebImageCombinedOperation类型的operation）是否取消了，如果取消了，就执行对应的cancelBlock函数。
    if (self.isCancelled) {
        if (cancelBlock) {
            cancelBlock();
        }
        _cancelBlock = nil; // don't forget to nil the cancelBlock, otherwise we will get crashes
    } else {
        _cancelBlock = [cancelBlock copy];
    }
}

/**
 *  注意SDWebImageCombinedOperation遵循SDWebImageOperation，所以实现了cancel方法
     在cancel方法中，主要是调用了cancelBlock，这个设计很值得琢磨
 */
- (void)cancel {
    self.cancelled = YES;
    if (self.cacheOperation) {
        [self.cacheOperation cancel];
        self.cacheOperation = nil;
    }
    if (self.cancelBlock) {
        self.cancelBlock();
        
        // TODO: this is a temporary fix to #809.
        // Until we can figure the exact cause of the crash, going with the ivar instead of the setter
//        self.cancelBlock = nil;
        _cancelBlock = nil;
    }
}

@end


@implementation SDWebImageManager (Deprecated)

// deprecated method, uses the non deprecated method
// adapter for the completion block
- (id <SDWebImageOperation>)downloadWithURL:(NSURL *)url options:(SDWebImageOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageCompletedWithFinishedBlock)completedBlock {
    return [self downloadImageWithURL:url
                              options:options
                             progress:progressBlock
                            completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                if (completedBlock) {
                                    completedBlock(image, error, cacheType, finished);
                                }
                            }];
}

@end
