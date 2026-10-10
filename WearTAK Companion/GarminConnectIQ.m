#import "GarminConnectIQ.h"
#import <ConnectIQ/ConnectIQ.h>

static NSString * const DeviceCacheKey = @"WearTAK.Garmin.authorizedDevices";
static NSString * const SelectedDeviceKey = @"WearTAK.Garmin.selectedDevice";
static NSString * const URLScheme = @"weartak-garmin";
static NSString * const WatchAppID = @"5721f67e-bcc4-47e8-b337-2ad96ee77c0a";

@interface WearTAKGarmin () <IQDeviceEventDelegate, IQAppMessageDelegate>
@property (nonatomic) NSUserDefaults *defaults;
@property (nonatomic) NSArray<IQDevice *> *authorizedDevices;
@property (nonatomic, nullable) IQApp *app;
@property (nonatomic, readwrite, nullable) NSString *selectedDeviceID;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger statusGeneration;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL stopped;
@end

@implementation WearTAKGarmin

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) {
        _defaults = defaults;
        _authorizedDevices = @[];
        [[ConnectIQ sharedInstance] initializeWithUrlScheme:URLScheme uiOverrideDelegate:nil
                               stateRestorationIdentifier:@"com.aegorsuch.weartak.garmin"];
        NSData *data = [defaults dataForKey:DeviceCacheKey];
        if (data) {
            NSError *error = nil;
            NSSet *classes = [NSSet setWithObjects:[NSArray class], [IQDevice class], [NSString class], [NSUUID class], nil];
            NSArray *devices = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&error];
            if (devices) { _authorizedDevices = devices; }
            else { NSLog(@"WearTAK Garmin device cache unavailable: %@", error.localizedDescription); }
        }
        _selectedDeviceID = [defaults stringForKey:SelectedDeviceKey];
    }
    return self;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)devices {
    NSMutableArray *result = [NSMutableArray array];
    for (IQDevice *device in self.authorizedDevices) {
        [result addObject:@{@"id": device.uuid.UUIDString, @"name": device.friendlyName ?: device.modelName ?: @"Garmin"}];
    }
    return result;
}

- (void)chooseDevices { [[ConnectIQ sharedInstance] showConnectIQDeviceSelection]; }

- (NSString *)connectionToken {
    return [NSString stringWithFormat:@"%lu:%lu", (unsigned long)self.generation, (unsigned long)self.statusGeneration];
}

- (void)notifyStatus:(NSString *)status ready:(BOOL)ready {
    [self.delegate garmin:self status:status ready:ready token:self.connectionToken];
}

- (BOOL)handleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:URLScheme] || self.stopped) { return NO; }
    NSArray *devices = [[ConnectIQ sharedInstance] parseDeviceSelectionResponseFromURL:url];
    if (!devices) {
        [self notifyStatus:@"Garmin returned an invalid device selection." ready:NO];
        return YES;
    }
    [self unregister];
    self.authorizedDevices = devices;
    self.selectedDeviceID = nil;
    [self.defaults removeObjectForKey:SelectedDeviceKey];
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:devices requiringSecureCoding:YES error:&error];
    if (data) { [self.defaults setObject:data forKey:DeviceCacheKey]; }
    else {
        [self.defaults removeObjectForKey:DeviceCacheKey];
        [self notifyStatus:error.localizedDescription ?: @"Unable to save Garmin device selection." ready:NO];
        return YES;
    }
    if (devices.count == 1) { [self selectDevice:((IQDevice *)devices.firstObject).uuid.UUIDString]; }
    else { [self notifyStatus:@"Select an authorized Garmin watch." ready:NO]; }
    return YES;
}

- (void)unregister {
    self.generation++;
    self.statusGeneration++;
    self.ready = NO;
    [[ConnectIQ sharedInstance] unregisterForAllAppMessages:self];
    [[ConnectIQ sharedInstance] unregisterForAllDeviceEvents:self];
    self.app = nil;
}

- (void)selectDevice:(NSString *)deviceID {
    if (self.stopped) { return; }
    [self unregister];
    IQDevice *selected = nil;
    for (IQDevice *device in self.authorizedDevices) {
        if ([device.uuid.UUIDString isEqualToString:deviceID]) { selected = device; break; }
    }
    if (!selected) {
        self.selectedDeviceID = nil;
        [self.defaults removeObjectForKey:SelectedDeviceKey];
        [self notifyStatus:@"Choose your Garmin watch in Garmin Connect." ready:NO];
        return;
    }
    self.selectedDeviceID = deviceID;
    [self.defaults setObject:deviceID forKey:SelectedDeviceKey];
    NSUUID *appID = [[NSUUID alloc] initWithUUIDString:WatchAppID];
    self.app = [IQApp appWithUUID:appID storeUuid:appID device:selected];
    [[ConnectIQ sharedInstance] registerForDeviceEvents:selected delegate:self];
    [[ConnectIQ sharedInstance] registerForAppMessages:self.app delegate:self];
    [self deviceStatusChanged:selected status:[[ConnectIQ sharedInstance] getDeviceStatus:selected]];
}

- (void)deviceStatusChanged:(IQDevice *)device status:(IQDeviceStatus)status {
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped || generation != self.generation ||
            ![device.uuid.UUIDString isEqualToString:self.selectedDeviceID]) { return; }
        self.statusGeneration++;
        self.ready = NO;
        if (status != IQDeviceStatus_Connected) {
            [self notifyStatus:status == IQDeviceStatus_BluetoothNotReady ?
             @"Enable Bluetooth to connect Garmin." : @"Waiting for Garmin watch connection." ready:NO];
            return;
        }
        NSUInteger connectionGeneration = self.statusGeneration;
        IQApp *app = self.app;
        [[ConnectIQ sharedInstance] getAppStatus:app completion:^(IQAppStatus *appStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.stopped || self.generation != generation ||
                    self.statusGeneration != connectionGeneration || self.app != app) { return; }
                self.ready = appStatus != nil && appStatus.isInstalled;
                [self notifyStatus:self.ready ? @"Garmin connected; open WearTAK and enable phone relay." :
                 @"WearTAK is not installed, or the Garmin app-status request timed out." ready:self.ready];
            });
        }];
    });
}

- (void)receivedMessage:(id)message fromApp:(IQApp *)app {
    NSUInteger generation = self.generation;
    NSUInteger statusGeneration = self.statusGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped || generation != self.generation || statusGeneration != self.statusGeneration || !self.ready ||
            ![app.device.uuid.UUIDString isEqualToString:self.selectedDeviceID] ||
            ![app.uuid.UUIDString isEqualToString:WatchAppID.uppercaseString]) { return; }
        NSError *error = nil;
        if (![message isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:message]) {
            [self notifyStatus:@"Garmin sent an invalid message." ready:self.ready];
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
        if (!data || data.length > 6000) {
            [self notifyStatus:error.localizedDescription ?: @"Garmin message exceeds the supported size." ready:self.ready];
            return;
        }
        [self.delegate garmin:self receivedData:data token:self.connectionToken];
    });
}

- (void)sendData:(NSData *)data completion:(void (^)(NSError * _Nullable))completion {
    NSError *error = nil;
    id object = data.length <= 6000 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (!self.ready || self.stopped || !self.app || !object) {
        completion(error ?: [NSError errorWithDomain:@"WearTAK.Garmin" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Garmin is unavailable or the message is invalid."}]);
        return;
    }
    NSUInteger generation = self.generation;
    NSUInteger statusGeneration = self.statusGeneration;
    [[ConnectIQ sharedInstance] sendMessage:object toApp:self.app progress:nil completion:^(IQSendMessageResult result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.stopped || self.generation != generation || self.statusGeneration != statusGeneration) {
                completion([NSError errorWithDomain:@"WearTAK.Garmin" code:2
                    userInfo:@{NSLocalizedDescriptionKey: @"Garmin connection changed during transmission."}]);
            } else if (result == IQSendMessageResult_Success) { completion(nil); }
            else { completion([NSError errorWithDomain:@"WearTAK.Garmin" code:result
                userInfo:@{NSLocalizedDescriptionKey: NSStringFromSendMessageResult(result)}]); }
        });
    }];
}

- (void)stop {
    self.stopped = YES;
    [self unregister];
    self.delegate = nil;
}
@end
