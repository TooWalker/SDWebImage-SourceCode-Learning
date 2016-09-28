/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <CommonCrypto/CommonDigest.h>

// See https://github.com/rs/SDWebImage/pull/1141 for discussion
/**
 这个类负责--自动清空缓存
 */
@interface AutoPurgeCache : NSCache
@end

@implementation AutoPurgeCache

- (id)init
{
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];

}

@end

/**
 *  默认最大缓存时间：一个星期
 */
static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24 * 7; // 1 week
// PNG signature bytes and data (below)
static unsigned char kPNGSignatureBytes[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
static NSData *kPNGSignatureData = nil;             /**< 大小为 8 bytes */

BOOL ImageDataHasPNGPreffix(NSData *data);

BOOL ImageDataHasPNGPreffix(NSData *data) {
    NSUInteger pngSignatureLength = [kPNGSignatureData length];
    if ([data length] >= pngSignatureLength) {
        if ([[data subdataWithRange:NSMakeRange(0, pngSignatureLength)] isEqualToData:kPNGSignatureData]) {
            return YES;
        }
    }

    return NO;
}

/**
 *  计算缓存一个图片需要多少空间的开销
    C语言函数
    FOUNDATION_STATIC_INLINE 表示 static __inline__，属于 runtime 范畴
 */
FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
    /**
     *  这里我觉得这样写不是很好，如果这样写就更直观了
        return (height * scale) * (width * scale)
     */
    return image.size.height * image.size.width * image.scale * image.scale;
}


@interface SDImageCache ()

@property (strong, nonatomic) NSCache *memCache;        /**< SDWebImage的缓存分为两个部分，一个内存缓存，使用 NSCache 实现(自带的setObject:forKey:及其衍生方法)，另一个就是硬盘缓存（disk），使用 NSFileManager 实现 */
@property (strong, nonatomic) NSString *diskCachePath;  /**< 图片缓存到磁盘上的路径 */
@property (strong, nonatomic) NSMutableArray *customPaths;
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t ioQueue;     /**< 这个ioQueue,我们从字面上理解,就是一个磁盘io的dispatch_queue_t。说简单点，就是每个下载来的图片，需要进行磁盘io的过程都放在ioQueue中执行。 */

@end


@implementation SDImageCache {
    NSFileManager *_fileManager;        /**< SDWebImage的缓存分为两个部分，一个内存缓存，使用 NSCache 实现(自带的setObject:forKey:及其衍生方法)，另一个就是硬盘缓存（disk），使用 NSFileManager 实现。 */
}

+ (SDImageCache *)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (id)init {
    return [self initWithNamespace:@"default"];
}

- (id)initWithNamespace:(NSString *)ns {
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (id)initWithNamespace:(NSString *)ns diskCacheDirectory:(NSString *)directory {
    if ((self = [super init])) {
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];

        // initialise PNG signature data
        kPNGSignatureData = [NSData dataWithBytes:kPNGSignatureBytes length:8];

        // Create IO serial queue
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);

        // Init default values
        _maxCacheAge = kDefaultCacheMaxCacheAge;

        // Init the memory cache
        _memCache = [[AutoPurgeCache alloc] init];
        _memCache.name = fullNamespace;

        // Init the disk cache
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }

        // Set decompression to YES
        _shouldDecompressImages = YES;

        // memory cache enabled
        _shouldCacheImagesInMemory = YES;

        // Disable iCloud
        _shouldDisableiCloud = YES;

        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if TARGET_OS_IPHONE
        // Subscribe to app events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cleanDisk)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundCleanDisk)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SDDispatchQueueRelease(_ioQueue);
}

- (void)addReadOnlyCachePath:(NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

- (NSString *)cachePathForKey:(NSString *)key inPath:(NSString *)path {
    // 根据传入的key创建最终要存储时的文件名
    NSString *filename = [self cachedFileNameForKey:key];
    // 将存储的文件路径和文件名绑定在一起，作为最终的存储路径
    return [path stringByAppendingPathComponent:filename];
}

- (NSString *)defaultCachePathForKey:(NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

#pragma mark SDImageCache (private)

- (NSString *)cachedFileNameForKey:(NSString *)key {
    const char *str = [key UTF8String];
    if (str == NULL) {
        str = "";
    }
    // 使用了MD5进行加密处理
    // 开辟一个16字节（128位：md5加密出来就是128bit）的空间
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    // 官方封装好的加密方法
    // 把str字符串转换成了32位的16进制数列（这个过程不可逆转） 存储到了r这个空间中
    CC_MD5(str, (CC_LONG)strlen(str), r);
    // 最终生成的文件名就是 "md5码"+".文件类型"
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15],
                          [[key pathExtension] isEqualToString:@""] ? @"" : [NSString stringWithFormat:@".%@", [key pathExtension]]];

    return filename;
}

#pragma mark ImageCache

// Init the disk cache
-(NSString *)makeDiskCachePath:(NSString*)fullNamespace{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

/**
 *  在SDWebImageManager中的downloadImageWithURL中，成功下载到图片downloadedImage后（或者进行了transform）使用该函数对image进行缓存
 */
- (void)storeImage:(UIImage *)image recalculateFromImage:(BOOL)recalculate imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk {
    
    if (!image || !key) {
        return;
    }
    
    // if memory cache is enabled----如果可以使用内存缓存
    if (self.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(image);
        [self.memCache setObject:image forKey:key cost:cost];
    }
    
    /**
     *  toDisk为YES表示应该是要往disk memory中存储
     */
    if (toDisk) {
        dispatch_async(self.ioQueue, ^{
            /** 构建一个data，用来存储到disk中，默认值为imageData */
            NSData *data = imageData;

            /**
             *  如果image存在，但是需要重新计算(recalculate)或者data为空，那就要根据image重新生成新的data。不过要是连image也为空的话，那就别存了
                这个 if 语句就是为了得到最真实的 data
             */
            if (image && (recalculate || !data)) {
#if TARGET_OS_IPHONE
                // We need to determine if the image is a PNG or a JPEG
                // PNGs are easier to detect because they have a unique signature (http://www.w3.org/TR/PNG-Structure.html)
                // The first eight bytes of a PNG file always contain the following (decimal) values:
                // 137 80 78 71 13 10 26 10

                // If the imageData is nil (i.e. if trying to save a UIImage directly or the image was transformed on download)
                // 如果imageData为空 (举个例子，比如[直接保存一个 UIImage 对象]或者[image在下载后需要transform]，那么就imageData就会为空)
                // and the image has an alpha channel, we will consider it PNG to avoid losing the transparency
                // 并且image有一个alpha通道, 我们将该image看做PNG以避免透明度(alpha)的丢失（因为JPEG没有透明色）
                int alphaInfo = CGImageGetAlphaInfo(image.CGImage);     /**< 获取image中的透明信息 */
                BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                                  alphaInfo == kCGImageAlphaNoneSkipFirst ||
                                  alphaInfo == kCGImageAlphaNoneSkipLast);
                BOOL imageIsPng = hasAlpha;     /**< 如果有 alpha，就是 png；否则是 jpeg */

                // But if we have an image data, we will look at the preffix
                // 但是如果我们已经有了imageData，我们就可以直接根据data中前几个字节判断是不是PNG
                if ([imageData length] >= [kPNGSignatureData length]) {
                    
                    //ImageDataHasPNGPreffix就是为了判断imageData前8个字节是不是符合PNG标志
                    imageIsPng = ImageDataHasPNGPreffix(imageData);
                    
                }
                
                /**
                 *  如果image是PNG格式，就是用 UIImagePNGRepresentation 将其转化为NSData，否则按照JPEG格式转化，并且压缩质量为1，即无压缩
                 */
                if (imageIsPng) {
                    data = UIImagePNGRepresentation(image);
                } else {
                    data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
                }
#else
                /**
                 *  如果不是在iPhone平台上，就使用下面这个方法。不过不在我们研究范围之内
                 */
                data = [NSBitmapImageRep representationOfImageRepsInArray:image.representations usingType: NSJPEGFileType properties:nil];
#endif
            }
            
            /**
             *  获取到需要存储的data后，下面就要用fileManager进行存储了
             */
            if (data) {
                /**
                 *  首先判断 disk cache 的文件路径是否存在，不存在的话就创建一个，disk cache 的文件路径是存储在 _diskCachePath 中的
                 */
                if (![_fileManager fileExistsAtPath:_diskCachePath]) {
                    [_fileManager createDirectoryAtPath:_diskCachePath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
                }

                /**
                    get cache Path for image key
                 *  根据image的key(一般情况下理解为image的url)组合成最终的文件路径
                    上面那个生成的文件路径只是一个文件目录，就跟 /cache/images/img1.png 和 cache/images/ 的区别一样
                 */
                NSString *cachePathForKey = [self defaultCachePathForKey:key];
                /**
                    transform to NSUrl
                 *  这个url可不是网络端的url，而是file在系统路径下的url，比如/foo/bar/baz --------> file:///foo/bar/baz
                 */
                NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
                /**
                 *  根据存储的路径(cachePathForKey)和存储的数据(data)将其存放到iOS的文件系统
                 */
                [_fileManager createFileAtPath:cachePathForKey contents:data attributes:nil];

                /**
                    disable iCloud backup
                 *  如果不使用iCloud进行备份，就使用 NSURLIsExcludedFromBackupKey
                 */
                if (self.shouldDisableiCloud) {
                    [fileURL setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:nil];
                }
            }
        });
    }
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:YES];
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key toDisk:(BOOL)toDisk {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:toDisk];
}

- (BOOL)diskImageExistsWithKey:(NSString *)key {
    BOOL exists = NO;
    
    // this is an exception to access the filemanager on another queue than ioQueue, but we are using the shared instance
    // from apple docs on NSFileManager: The methods of the shared NSFileManager object can be called from multiple threads safely.
    exists = [[NSFileManager defaultManager] fileExistsAtPath:[self defaultCachePathForKey:key]];

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        exists = [[NSFileManager defaultManager] fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
    }
    
    return exists;
}

- (void)diskImageExistsWithKey:(NSString *)key completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    dispatch_async(_ioQueue, ^{
        BOOL exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        if (!exists) {
            exists = [_fileManager fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

/**
    从内存中取图片
 *  简单的封装了 NSCache 的 objectForKey 方法
 */
- (UIImage *)imageFromMemoryCacheForKey:(NSString *)key {
    return [self.memCache objectForKey:key];
}

/**
 *  从disk中获取的image，还需更新到内存缓存中
    尽管该方法的名字是“romDiskCache”，但是它在里面也是先去内存中看看有没有图片，而且从 disk cache 中取出来后还要把图片放到内存缓存中去
 */
- (UIImage *)imageFromDiskCacheForKey:(NSString *)key {

    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }

    // Second check the disk cache...
    UIImage *diskImage = [self diskImageForKey:key];
    if (diskImage && self.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(diskImage);
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}

- (NSData *)diskImageDataBySearchingAllPathsForKey:(NSString *)key {
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    data = [NSData dataWithContentsOfFile:[defaultPath stringByDeletingPathExtension]];
    if (data) {
        return data;
    }

    NSArray *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath];
        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:[filePath stringByDeletingPathExtension]];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
}

- (UIImage *)diskImageForKey:(NSString *)key {
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    if (data) {
        UIImage *image = [UIImage sd_imageWithData:data];
        image = [self scaledImageForKey:key image:image];
        if (self.shouldDecompressImages) {
            image = [UIImage decodedImageWithImage:image];
        }
        return image;
    }
    else {
        return nil;
    }
}

- (UIImage *)scaledImageForKey:(NSString *)key image:(UIImage *)image {
    return SDScaledImageForKey(key, image);
}

- (NSOperation *)queryDiskCacheForKey:(NSString *)key done:(SDWebImageQueryCompletedBlock)doneBlock {
    
    /**
     *  如果 doneBlock 不存在。那么就return nil。这个处理和 downloadImageWithURL 的 completedBlock 很类似
        试着想一想，这一步是为了在内存中根据图片的 key（一般是指图片的 url）取出图片，然后进行后续的操作（doneBlock）。但假如后续操作都没有的话，也就没有必要去内存中取图片了，所以直接返回 nil
     */
    if (!doneBlock) {
        return nil;
    }
    
    /**
     *  如果 key 为 nil，说明 cache 中没有该 image。所以 doneBlock 中传入 SDImageCacheTypeNone，表示 cache 中没有图片，要从网络重新获取
     */
    if (!key) {
        doneBlock(nil, SDImageCacheTypeNone);
        return nil;
    }

    // First check the in-memory cache...
    /**
     *  如果key不为nil
        首先根据key（一般指的是图片的url）去内存 cache 获取 image
     */
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    /**
     *  找到了，就传入SDImageCacheTypeMemory，说是在内存cache中获取的
     */
    if (image) {
        doneBlock(image, SDImageCacheTypeMemory);
        return nil;
    }

    /**
     *  否则，说明图片就在磁盘 cache 中
     */
    NSOperation *operation = [NSOperation new];
    dispatch_async(self.ioQueue, ^{
        if (operation.isCancelled) {
            return;
        }

        @autoreleasepool {
            /**
             *  获取到磁盘(disk)上缓存的 image
             */
            UIImage *diskImage = [self diskImageForKey:key];
            /**
             *  如果磁盘中得到了该image，并且还需要缓存到内存中(为了同步最新数据)，那么就将 diskImage 缓存到 memory cache 中
             */
            if (diskImage && self.shouldCacheImagesInMemory) {
                /**
                 *  cost 被用来计算缓存中所有对象的代价。当内存受限或者所有缓存对象的总代价超过了最大允许的值时，缓存会移除其中的一些对象
                    通常，精确的 cost 应该是对象占用的字节数
                 */
                NSUInteger cost = SDCacheCostForImage(diskImage);
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }
            
            /**
             *  传入SDImageCacheTypeDisk，说明是从磁盘中获取的
             */
            dispatch_async(dispatch_get_main_queue(), ^{
                doneBlock(diskImage, SDImageCacheTypeDisk);
            });
        }
    });

    return operation;
}

- (void)removeImageForKey:(NSString *)key {
    [self removeImageForKey:key withCompletion:nil];
}

- (void)removeImageForKey:(NSString *)key withCompletion:(SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}

- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk {
    [self removeImageForKey:key fromDisk:fromDisk withCompletion:nil];
}

/**
 *  异步地将 image 从缓存(内存缓存以及可选的磁盘缓存)中移除
    主要是根据key来删除对应缓存image
 */
- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(SDWebImageNoParamsBlock)completion {
    
    if (key == nil) {
        return;
    }
    
    /**
     *  shouldCacheImagesInMemory为YES表示该图片会缓存到了内存，既然缓存到了内存，就要先将内存缓存中的image移除。
        使用的是NSCache的removeObjectForKey:
     */
    if (self.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }
    
    /**
     *  如果要删除磁盘缓存中的image
     */
    if (fromDisk) {
        // 有关io的部分，都要放在ioQueue中
        dispatch_async(self.ioQueue, ^{
            // 磁盘缓存移除使用的是NSFileManager的removeItemAtPath:error
            [_fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            
            // 如果用户实现了completion了，就在主线程调用completion()
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){     // 如果用户实现了completion了，就在主线程调用completion()
        completion();
    }
    
}

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

/**
 *  清楚内存缓存上的所有image
 */
- (void)clearMemory {
    [self.memCache removeAllObjects];
}

/**
 *  清除磁盘缓存上的所有image
 */
- (void)clearDisk {
    [self clearDiskOnCompletion:nil];
}

- (void)clearDiskOnCompletion:(SDWebImageNoParamsBlock)completion {
    
    dispatch_async(self.ioQueue, ^{
        
        // 先将存储在diskCachePath中缓存全部移除，然后新建一个空的diskCachePath
        [_fileManager removeItemAtPath:self.diskCachePath error:nil];
        [_fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];
        // 如果实现了completion，就在主线程中调用
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
        
    });
    
}

/**
 *  清除磁盘缓存上过期的image
 */
- (void)cleanDisk {
    [self cleanDiskWithCompletionBlock:nil];
}

/**
 *  实现了一个简单的缓存清除策略：清除修改时间最早的file
 */
- (void)cleanDiskWithCompletionBlock:(SDWebImageNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        /**
         *  这两个变量主要是为了下面生成 NSDirectoryEnumerator 准备的
            一个是记录遍历的文件目录，一个是记录遍历需要预先获取文件的哪些属性
         */
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        NSArray *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];

        // This enumerator prefetches useful properties for our cache files.
        /**
         *  递归地遍历 diskCachePath 这个文件夹中的所有目录，此处不是直接使用 diskCachePath，而是使用其生成的 NSURL
            此处使用 includingPropertiesForKeys:resourceKeys，这样每个 file 的 resourceKeys 对应的属性也会在遍历时预先获取到
            NSDirectoryEnumerationSkipsHiddenFiles 表示不遍历隐藏文件
         */
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];
        /**
         *  获取文件的过期时间，SDWebImage中默认是一个星期，不过这里虽然称*expirationDate为过期时间，但是实质上并不是这样。
            其实是这样的，比如在2015/12/12/00:00:00最后一次修改文件，对应的过期时间应该是
         */
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.maxCacheAge];
        NSMutableDictionary *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        NSMutableArray *urlsToDelete = [[NSMutableArray alloc] init];
        for (NSURL *fileURL in fileEnumerator) {
            NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];

            // Skip directories.
            if ([resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // Remove files that are older than the expiration date;
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // Store a reference to this file and account for its total size.
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
            [cacheFiles setObject:resourceValues forKey:fileURL];
        }
        
        for (NSURL *fileURL in urlsToDelete) {
            [_fileManager removeItemAtURL:fileURL error:nil];
        }

        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        if (self.maxCacheSize > 0 && currentCacheSize > self.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
            const NSUInteger desiredCacheSize = self.maxCacheSize / 2;

            // Sort the remaining cache files by their last modification time (oldest first).
            NSArray *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                            usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                            }];

            // Delete files until we fall below our desired cache size.
            for (NSURL *fileURL in sortedFiles) {
                if ([_fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= [totalAllocatedSize unsignedIntegerValue];

                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

- (void)backgroundCleanDisk {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // Start the long-running task and return immediately.
    [self cleanDiskWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}

- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        count = [[fileEnumerator allObjects] count];
    });
    return count;
}

- (void)calculateSizeWithCompletionBlock:(SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += [fileSize unsignedIntegerValue];
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end
