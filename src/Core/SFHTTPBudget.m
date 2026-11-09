#import "SFHTTPBudget.h"
@implementation SFHTTPBudget
static NSMutableDictionary *gBudgets, *gSourceBudgets;
+ (NSString *)open:(NSUInteger)bytes {
    @synchronized(self) {
        if(!gBudgets) { gBudgets=[NSMutableDictionary new]; gSourceBudgets=[NSMutableDictionary new]; }
        NSString *token=[[NSUUID UUID] UUIDString];gBudgets[token]=@(bytes);gSourceBudgets[token]=@(bytes<=NSUIntegerMax/2 ? bytes*2 : NSUIntegerMax);return token;
    }
}
+ (BOOL)take:(NSUInteger)bytes token:(NSString *)token {
    if(!token) return YES;
    @synchronized(self) {
        NSNumber *left=gBudgets[token];
        if(!left) return NO;
        if(bytes>left.unsignedLongLongValue) { gBudgets[token]=@0; return NO; }
        gBudgets[token]=@(left.unsignedLongLongValue-bytes);return YES;
    }
}
+ (BOOL)takeSource:(NSUInteger)bytes token:(NSString *)token {
    if(!token) return YES;
    @synchronized(self) {
        NSNumber *left=gSourceBudgets[token];
        if(!left) return NO;
        if(!left.unsignedLongLongValue) { gBudgets[token]=@0; return NO; }
        if(bytes>left.unsignedLongLongValue) { gSourceBudgets[token]=@0; gBudgets[token]=@0; return NO; }
        gSourceBudgets[token]=@(left.unsignedLongLongValue-bytes);return YES;
    }
}
+ (NSUInteger)remaining:(NSString *)token { if(!token) return NSUIntegerMax; @synchronized(self) { return [gBudgets[token] unsignedIntegerValue]; } }
+ (void)close:(NSString *)token { if(token) @synchronized(self) { [gBudgets removeObjectForKey:token]; [gSourceBudgets removeObjectForKey:token]; } }
@end
