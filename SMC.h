#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

typedef enum {
    FanModeAutomatic = 0,
    FanModeForced = 1,
    FanModeAuto3 = 3
} FanMode;

@interface SMC : NSObject

+ (instancetype)shared;

- (double)getValue:(NSString *)key;
- (NSString *)getStringValue:(NSString *)key;
- (NSArray<NSString *> *)getAllKeys;
- (double)getCPUTemp;
- (double)getGPUTemp;
- (kern_return_t)writeValue:(NSString *)key value:(int)value;
- (void)setFanMode:(int)fanId mode:(FanMode)mode;
- (void)setFanSpeed:(int)fanId speed:(int)speed;
- (BOOL)resetMacFanAutoCtrl;
- (NSString *)fanModeKey:(int)fanId;

@end
