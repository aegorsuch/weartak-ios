#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WearTAKGarmin;

@protocol WearTAKGarminDelegate <NSObject>
- (void)garmin:(WearTAKGarmin *)client receivedData:(NSData *)data token:(NSString *)token
    NS_SWIFT_NAME(garmin(_:received:token:));
- (void)garmin:(WearTAKGarmin *)client status:(NSString *)status ready:(BOOL)ready token:(NSString *)token
    NS_SWIFT_NAME(garmin(_:status:ready:token:));
@end

@interface WearTAKGarmin : NSObject
@property (nonatomic, weak, nullable) id<WearTAKGarminDelegate> delegate;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *devices;
@property (nonatomic, readonly, nullable) NSString *selectedDeviceID;
@property (nonatomic, readonly) NSString *connectionToken;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)chooseDevices;
- (BOOL)handleURL:(NSURL *)url NS_SWIFT_NAME(handle(_:));
- (void)selectDevice:(NSString *)deviceID NS_SWIFT_NAME(selectDevice(_:));
- (void)stop;
- (void)sendData:(NSData *)data completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(send(_:completion:));
@end

NS_ASSUME_NONNULL_END
