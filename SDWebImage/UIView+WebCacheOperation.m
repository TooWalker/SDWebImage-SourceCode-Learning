/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCacheOperation.h"
#import "objc/runtime.h"

static char loadOperationKey;

@implementation UIView (WebCacheOperation)

/**
 *  既然叫operationDictionary，那么存放的一定是各种operation的序列了（当然也就包括SDWebImageOperation类型的operation），而且这些operation是根据key来索引的
 */
- (NSMutableDictionary *)operationDictionary {
    NSMutableDictionary *operations = objc_getAssociatedObject(self, &loadOperationKey);
    if (operations) {
        return operations;
    }
    operations = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(self, &loadOperationKey, operations, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return operations;
}

- (void)sd_setImageLoadOperation:(id)operation forKey:(NSString *)key {
    
    /**
     *  一进函数，先取消索引为key的operation的操作，如果之前正在进行索引为key的操作，那不就取消了嘛？是这样的，如果该operation存在，就取消掉了，还要删除这个key对应的object（operation）。然后重新设置key对应的operation
     */
    [self sd_cancelImageLoadOperationWithKey:key];
    NSMutableDictionary *operationDictionary = [self operationDictionary];
    [operationDictionary setObject:operation forKey:key];
}

/**
 *  Cancel in progress downloader from queue
 */
- (void)sd_cancelImageLoadOperationWithKey:(NSString *)key {
    
    /** 先获取到operation的序列，即[self operationDictionary] */
    NSMutableDictionary *operationDictionary = [self operationDictionary];
    
    /** 然后根据key来索引到对应的operations */
    id operations = [operationDictionary objectForKey:key];
    
    /** 如果operations存在的话 */
    if (operations) {
        
        /** 索引到的operations假如是一组operation的集合，那么就需要来个遍历，一个个取消掉operations序列中的operation了 */
        /** operation表示一个数组(NSArray)时，主要是考虑到gif这种动态图。因为gif是多张图片集合，所以需要NSArray类型来表示 */
        if ([operations isKindOfClass:[NSArray class]]) {
            for (id <SDWebImageOperation> operation in operations) {
                if (operation) {
                    [operation cancel];
                }
            }
        } else if ([operations conformsToProtocol:@protocol(SDWebImageOperation)]){
            [(id <SDWebImageOperation>) operations cancel];
        }
        
        /** 最后移除key对应的object */
        [operationDictionary removeObjectForKey:key];
    }
}

- (void)sd_removeImageLoadOperationWithKey:(NSString *)key {
    NSMutableDictionary *operationDictionary = [self operationDictionary];
    [operationDictionary removeObjectForKey:key];
}

@end
