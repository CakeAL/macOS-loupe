#import "PreviewLoupePackage.h"
#import <dlfcn.h>
#import <objc/message.h>

@implementation PreviewLoupePackage {
    id _package;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    Class packageClass = NSClassFromString(@"CAPackage");
    SEL load = NSSelectorFromString(@"packageWithContentsOfURL:type:options:error:");
    NSString *const *bundleType = (NSString *const *)dlsym(RTLD_DEFAULT, "kCAPackageTypeCAMLBundle");
    NSError *loadError = nil;
    if (bundleType && [packageClass respondsToSelector:load]) {
        _package = ((id (*)(id, SEL, NSURL *, NSString *, NSDictionary *, NSError **))objc_msgSend)(
            packageClass, load, url, *bundleType, nil, &loadError);
        _rootLayer = ((id (*)(id, SEL))objc_msgSend)(_package, NSSelectorFromString(@"rootLayer"));
    }
    if (!_rootLayer && error) {
        *error = loadError ?: [NSError errorWithDomain:@"macOS Loupe" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"当前系统无法加载原版观片镜图层。"
        }];
    }
    return _rootLayer ? self : nil;
}

@end
