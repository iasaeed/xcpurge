#import <UIKit/UIKit.h>

@interface Legacy : NSObject
@end

@implementation Legacy
- (UIImage *)icon {
    return [UIImage imageNamed:@"objc_icon"];
}
- (UIColor *)tint {
    return [UIColor colorNamed:ACColorNameObjcTint];
}
@end
