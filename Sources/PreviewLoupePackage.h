#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface PreviewLoupePackage : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
@property (nonatomic, readonly) CALayer *rootLayer;

@end

NS_ASSUME_NONNULL_END
