#import "SMC.h"
#import <mach/mach.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

@implementation SMC {
    io_connect_t _conn;
    NSNumber *_fanModeKeyIsLower;
}

+ (instancetype)shared {
    static SMC *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        kern_return_t result;
        io_iterator_t iterator;
        io_object_t device;
        
        CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
        // Using kIOMainPortDefault for macOS 12.0+ compatibility
#if defined(MAC_OS_X_VERSION_12_0) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_12_0
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator);
#else
        result = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDictionary, &iterator);
#endif
        if (result != kIOReturnSuccess) {
            return nil;
        }
        
        device = IOIteratorNext(iterator);
        IOObjectRelease(iterator);
        if (device == 0) {
            return nil;
        }
        
        result = IOServiceOpen(device, mach_task_self(), 0, &_conn);
        IOObjectRelease(device);
        if (result != kIOReturnSuccess) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_conn) {
        IOServiceClose(_conn);
    }
}

- (uint32_t)fourCharCode:(NSString *)str {
    uint32_t code = 0;
    if (str.length != 4) {
        // Pad with spaces if less than 4
        NSString *padded = [str stringByPaddingToLength:4 withString:@" " startingAtIndex:0];
        for (int i = 0; i < 4; i++) {
            code = (code << 8) | [padded characterAtIndex:i];
        }
        return code;
    }
    for (int i = 0; i < 4; i++) {
        code = (code << 8) | [str characterAtIndex:i];
    }
    return code;
}

- (NSString *)stringFromFourCharCode:(uint32_t)code {
    char str[5];
    str[0] = (code >> 24) & 0xFF;
    str[1] = (code >> 16) & 0xFF;
    str[2] = (code >> 8) & 0xFF;
    str[3] = code & 0xFF;
    str[4] = '\0';
    return [NSString stringWithUTF8String:str];
}

- (NSArray<NSString *> *)getAllKeys {
    NSMutableArray *keys = [NSMutableArray array];
    double count = [self getValue:@"#KEY"];
    if (count == -1) return keys;
    
    for (int i = 0; i < (int)count; i++) {
        SMCKeyData input = {0};
        SMCKeyData output = {0};
        
        input.data8 = 8; // SMC_CMD_READ_INDEX
        input.data32 = i;
        
        kern_return_t result = [self callSMCWithIndex:KERNEL_INDEX_SMC input:&input output:&output];
        if (result == kIOReturnSuccess) {
            [keys addObject:[self stringFromFourCharCode:output.key]];
        } else {
            fprintf(stderr, "Error READ_INDEX(%d): 0x%x\n", i, result);
        }
    }
    return keys;
}

- (double)getAverageTemp:(NSArray<NSString *> *)keys {
    double total = 0;
    int count = 0;
    for (NSString *key in keys) {
        double val = [self getValue:key];
        if (val > 0 && val < 150) {
            total += val;
            count++;
        }
    }
    return count > 0 ? total / count : -1;
}

- (double)getCPUTemp {
    // Common CPU temperature keys for Intel and Apple Silicon
    NSArray *keys = @[
        @"TC0D", @"TC0E", @"TC0F", @"TC0H", @"TC0P", // Intel diode/heatsink/proximity
        @"TC0c", @"TC1c", @"TC2c", @"TC3c", @"TC4c", @"TC5c", @"TC6c", @"TC7c", // Intel Cores
        @"Tp09", @"Tp0T", @"Tp01", @"Tp05", // Apple Silicon efficiency/performance cores
        @"TCGC", @"TC0c", @"TC0g", @"TC0p"  // Others
    ];
    return [self getAverageTemp:keys];
}

- (double)getGPUTemp {
    // Common GPU temperature keys
    NSArray *keys = @[
        @"TG0D", @"TG0H", @"TG0P", // Intel
        @"Tg05", @"Tg0D", @"Tg0L", @"Tg0T", // Apple Silicon
        @"TGDD"
    ];
    return [self getAverageTemp:keys];
}

- (kern_return_t)callSMCWithIndex:(uint8_t)index input:(SMCKeyData *)input output:(SMCKeyData *)output {
    size_t inputSize = sizeof(SMCKeyData);
    size_t outputSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(_conn, index, input, inputSize, output, &outputSize);
}

- (kern_return_t)readSMCValue:(NSString *)key data:(uint8_t *)bytes size:(uint32_t *)size type:(NSString **)type {
    if (!_conn) return kIOReturnNotAttached;
    
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    kern_return_t result;
    
    input.key = [self fourCharCode:key];
    input.data8 = SMC_CMD_READ_KEYINFO;
    
    result = [self callSMCWithIndex:KERNEL_INDEX_SMC input:&input output:&output];
    if (result != kIOReturnSuccess) return result;
    
    *size = output.keyInfo.dataSize;
    if (type) *type = [self stringFromFourCharCode:output.keyInfo.dataType];
    
    input.keyInfo.dataSize = output.keyInfo.dataSize;
    input.data8 = SMC_CMD_READ_BYTES;
    
    result = [self callSMCWithIndex:KERNEL_INDEX_SMC input:&input output:&output];
    if (result != kIOReturnSuccess) return result;
    
    memcpy(bytes, output.bytes, *size);
    return kIOReturnSuccess;
}

- (double)getValue:(NSString *)key {
    uint8_t bytes[32] = {0};
    uint32_t size = 0;
    NSString *type = nil;
    kern_return_t result = [self readSMCValue:key data:bytes size:&size type:&type];
    
    if (result != kIOReturnSuccess || size == 0) return -1;
    
    // Check if all bytes are zero for specific keys
    BOOL allZero = YES;
    for (int i = 0; i < size; i++) if (bytes[i] != 0) { allZero = NO; break; }
    if (allZero && ![key hasPrefix:@"F"] && ![key isEqualToString:@"FS! "]) return -1;

    if ([type isEqualToString:@"ui8 "]) return (double)bytes[0];
    if ([type isEqualToString:@"ui16"]) return (double)((bytes[0] << 8) | bytes[1]);
    if ([type isEqualToString:@"ui32"]) return (double)((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]);
    if ([type isEqualToString:@"fpe2"]) return (double)((bytes[0] << 6) | (bytes[1] >> 2));
    if ([type isEqualToString:@"flt "]) {
        float f;
        memcpy(&f, bytes, 4);
        return (double)f;
    }
    
    if ([type isEqualToString:@"sp1e"]) return (double)((bytes[0] << 8) | bytes[1]) / 16384.0;
    if ([type isEqualToString:@"sp3c"]) return (double)((bytes[0] << 8) | bytes[1]) / 4096.0;
    if ([type isEqualToString:@"sp4b"]) return (double)((bytes[0] << 8) | bytes[1]) / 2048.0;
    if ([type isEqualToString:@"sp5a"]) return (double)((bytes[0] << 8) | bytes[1]) / 1024.0;
    if ([type isEqualToString:@"sp69"]) return (double)((bytes[0] << 8) | bytes[1]) / 512.0;
    if ([type isEqualToString:@"sp78"]) return (double)((int16_t)((bytes[0] << 8) | bytes[1])) / 256.0;
    if ([type isEqualToString:@"sp87"]) return (double)((int16_t)((bytes[0] << 8) | bytes[1])) / 128.0;
    if ([type isEqualToString:@"sp96"]) return (double)((int16_t)((bytes[0] << 8) | bytes[1])) / 64.0;
    if ([type isEqualToString:@"spa5"]) return (double)((bytes[0] << 8) | bytes[1]) / 32.0;
    if ([type isEqualToString:@"spb4"]) return (double)((int16_t)((bytes[0] << 8) | bytes[1])) / 16.0;
    if ([type isEqualToString:@"spf0"]) return (double)((int16_t)((bytes[0] << 8) | bytes[1]));

    return -1;
}

- (NSString *)getStringValue:(NSString *)key {
    uint8_t bytes[32] = {0};
    uint32_t size = 0;
    NSString *type = nil;
    kern_return_t result = [self readSMCValue:key data:bytes size:&size type:&type];
    if (result != kIOReturnSuccess || size == 0) return nil;
    
    if ([type isEqualToString:@"{fds"]) {
        return [[NSString alloc] initWithBytes:bytes + 4 length:size - 4 encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (kern_return_t)writeValue:(NSString *)key bytes:(uint8_t *)bytes size:(uint32_t)size {
    if (!_conn) return kIOReturnNotAttached;
    
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    
    input.key = [self fourCharCode:key];
    input.data8 = SMC_CMD_WRITE_BYTES;
    input.keyInfo.dataSize = size;
    memcpy(input.bytes, bytes, size);
    
    kern_return_t result = [self callSMCWithIndex:KERNEL_INDEX_SMC input:&input output:&output];
    if (result != kIOReturnSuccess) {
        // Only log if it's not a common 'Not Privileged' error when not using sudo
        if (result != 0xe00002c1) {
            fprintf(stderr, "Error callSMC(%s): 0x%x\n", [key UTF8String], result);
        }
        return result;
    }
    
    // SMC Result 0x84 often means Key Not Found on some models.
    // We ignore it here to allow trying multiple keys for compatibility.
    if (output.result != 0x00 && output.result != 0x84) {
        fprintf(stderr, "SMC Write Error (%s): 0x%x\n", [key UTF8String], output.result);
        return kIOReturnError;
    }
    
    return kIOReturnSuccess;
}

- (kern_return_t)writeValue:(NSString *)key value:(int)value {
    uint8_t bytes[32] = {0};
    bytes[0] = (value >> 6) & 0xFF;
    bytes[1] = ((value << 2) ^ ((value >> 6) << 8)) & 0xFF;
    return [self writeValue:key bytes:bytes size:2];
}

- (NSString *)fanModeKey:(int)fanId {
#if defined(__arm64__)
    if (!_fanModeKeyIsLower) {
        uint8_t bytes[32];
        uint32_t size;
        NSString *key = [NSString stringWithFormat:@"F%dmd", fanId];
        if ([self readSMCValue:key data:bytes size:&size type:NULL] == kIOReturnSuccess && size > 0) {
            _fanModeKeyIsLower = @YES;
        } else {
            _fanModeKeyIsLower = @NO;
        }
    }
    return [_fanModeKeyIsLower boolValue] ? [NSString stringWithFormat:@"F%dmd", fanId] : [NSString stringWithFormat:@"F%dMd", fanId];
#else
    return [NSString stringWithFormat:@"F%dMd", fanId];
#endif
}

- (void)setFanMode:(int)fanId mode:(FanMode)mode {
#if defined(__arm64__)
    // Apple Silicon implementation remains unchanged
    if (mode == FanModeForced) {
        [self unlockMacFanAutoCtrl:fanId];
    } else {
        NSString *modeKey = [self fanModeKey:fanId];
        NSString *targetKey = [NSString stringWithFormat:@"F%dTg", fanId];
        
        double currentMode = [self getValue:modeKey];
        if (currentMode != -1 && (int)currentMode != 0) {
            uint8_t bytes[32] = {0};
            [self writeValue:modeKey bytes:bytes size:1];
        }
        
        float zero = 0.0f;
        uint8_t targetBytes[4];
        memcpy(targetBytes, &zero, 4);
        [self writeWithRetry:targetKey bytes:targetBytes size:4 maxAttempts:10];
    }
#else
    // Intel: Use FS! bitmask
    // FS! is ui16, 2 bytes. Bits represent manual control for each fan.
    // Bit 0: Fan 0, Bit 1: Fan 1, etc.
    double currentFS = [self getValue:@"FS! "];
    if (currentFS == -1) currentFS = 0;
    
    uint16_t fsMask = (uint16_t)currentFS;
    if (mode == FanModeForced) {
        fsMask |= (1 << fanId);
    } else {
        fsMask &= ~(1 << fanId);
    }
    
    uint8_t fsBytes[2];
    fsBytes[0] = (fsMask >> 8) & 0xFF;
    fsBytes[1] = fsMask & 0xFF;
    
    [self writeValue:@"FS! " bytes:fsBytes size:2];
    
    // Also try writing to the individual mode key if it exists
    NSString *modeKey = [NSString stringWithFormat:@"F%dMd", fanId];
    uint8_t mBytes[1];
    mBytes[0] = (mode == FanModeForced ? 1 : 0);
    [self writeValue:modeKey bytes:mBytes size:1];
#endif
}

- (void)setFanSpeed:(int)fanId speed:(int)speed {
    double maxSpeed = [self getValue:[NSString stringWithFormat:@"F%dMx", fanId]];
    if (maxSpeed != -1 && speed > (int)maxSpeed) {
        speed = (int)maxSpeed;
    }
    
#if defined(__arm64__)
    NSString *modeKey = [self fanModeKey:fanId];
    double currentMode = [self getValue:modeKey];
    if (currentMode != 1) {
        if (![self unlockMacFanAutoCtrl:fanId]) return;
    }
#endif

    NSString *targetKey = [NSString stringWithFormat:@"F%dTg", fanId];
    uint8_t bytes[32] = {0};
    uint32_t size = 0;
    NSString *type = nil;
    [self readSMCValue:targetKey data:bytes size:&size type:&type];
    
    if ([type isEqualToString:@"flt "]) {
        float fSpeed = (float)speed;
        memcpy(bytes, &fSpeed, 4);
        size = 4;
    } else if ([type isEqualToString:@"fpe2"]) {
        bytes[0] = (speed >> 6) & 0xFF;
        bytes[1] = ((speed << 2) ^ ((speed >> 6) << 8)) & 0xFF;
        size = 2;
    }
    
#if defined(__arm64__)
    [self writeWithRetry:targetKey bytes:bytes size:size maxAttempts:10];
#else
    [self writeValue:targetKey bytes:bytes size:size];
#endif
}

#if defined(__arm64__)
- (BOOL)writeWithRetry:(NSString *)key bytes:(uint8_t *)bytes size:(uint32_t)size maxAttempts:(int)maxAttempts {
    for (int i = 0; i < maxAttempts; i++) {
        if ([self writeValue:key bytes:bytes size:size] == kIOReturnSuccess) return YES;
        usleep(50000);
    }
    return NO;
}

- (BOOL)unlockMacFanAutoCtrl:(int)fanId {
    NSString *modeKey = [self fanModeKey:fanId];
    uint8_t bytes[1] = {1};
    if ([self writeValue:modeKey bytes:bytes size:1] == kIOReturnSuccess) return YES;
    
    // Try Ftst unlock
    uint8_t ftstBytes[32] = {0};
    uint32_t ftstSize = 0;
    if ([self readSMCValue:@"Ftst" data:ftstBytes size:&ftstSize type:NULL] == kIOReturnSuccess && ftstSize > 0) {
        if (ftstBytes[0] == 1) return [self retryModeWrite:fanId maxAttempts:20];
        
        ftstBytes[0] = 1;
        if (![self writeWithRetry:@"Ftst" bytes:ftstBytes size:1 maxAttempts:100]) return NO;
        
        usleep(3000000);
        return [self retryModeWrite:fanId maxAttempts:300];
    }
    return NO;
}

- (BOOL)retryModeWrite:(int)fanId maxAttempts:(int)maxAttempts {
    NSString *modeKey = [self fanModeKey:fanId];
    uint8_t bytes[1] = {1};
    return [self writeWithRetry:modeKey bytes:bytes size:1 maxAttempts:maxAttempts];
}

- (BOOL)resetMacFanAutoCtrl {
    uint8_t bytes[32] = {0};
    uint32_t size = 0;
    if ([self readSMCValue:@"Ftst" data:bytes size:&size type:NULL] == kIOReturnSuccess && size > 0) {
        if (bytes[0] == 0) return YES;
        bytes[0] = 0;
        return [self writeWithRetry:@"Ftst" bytes:bytes size:1 maxAttempts:10];
    }
    
    double count = [self getValue:@"FNum"];
    if (count == -1) return NO;
    BOOL success = YES;
    for (int i = 0; i < (int)count; i++) {
        NSString *modeKey = [self fanModeKey:i];
        if ([self getValue:modeKey] != 0) {
            uint8_t zero[1] = {0};
            if (![self writeWithRetry:modeKey bytes:zero size:1 maxAttempts:10]) success = NO;
        }
    }
    return success;
}
#else
- (BOOL)resetMacFanAutoCtrl { return YES; }
#endif

@end
