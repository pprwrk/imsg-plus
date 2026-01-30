//
//  main.m
//  IMsgHelper - Objective-C helper for IMCore private API access
//
//  This helper binary provides access to IMCore functionality that
//  cannot be accessed directly from Swift due to NSInvocation limitations.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Forward declarations for IMCore classes
@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (id)messageForGUID:(NSString *)guid;
- (void)sendTapback:(NSInteger)type forMessage:(id)message;
@end

// JSON response helpers
NSDictionary* successResponse(NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

NSDictionary* errorResponse(NSString *error) {
    return @{
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

// Load IMCore framework
BOOL loadIMCore() {
    static BOOL loaded = NO;
    static BOOL attempted = NO;
    
    if (attempted) return loaded;
    attempted = YES;
    
    void *handle = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW);
    if (handle) {
        loaded = YES;
        NSLog(@"IMCore framework loaded successfully");
    } else {
        NSLog(@"Failed to load IMCore framework: %s", dlerror());
    }
    
    return loaded;
}

// Command handlers
NSDictionary* handleTyping(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"];
    
    if (!handle || !state) {
        return errorResponse(@"Missing required parameters: handle, typing");
    }
    
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(@"IMChatRegistry not available");
    }
    
    IMChatRegistry *registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(@"Could not get IMChatRegistry instance");
    }
    
    IMChat *chat = [registry existingChatWithChatIdentifier:handle];
    if (!chat) {
        return errorResponse([NSString stringWithFormat:@"Chat not found: %@", handle]);
    }
    
    @try {
        [chat setLocalUserIsTyping:[state boolValue]];
        return successResponse(@{
            @"handle": handle,
            @"typing": state
        });
    } @catch (NSException *exception) {
        return errorResponse([NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

NSDictionary* handleRead(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    
    if (!handle) {
        return errorResponse(@"Missing required parameter: handle");
    }
    
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(@"IMChatRegistry not available");
    }
    
    IMChatRegistry *registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(@"Could not get IMChatRegistry instance");
    }
    
    IMChat *chat = [registry existingChatWithChatIdentifier:handle];
    if (!chat) {
        return errorResponse([NSString stringWithFormat:@"Chat not found: %@", handle]);
    }
    
    @try {
        [chat markAllMessagesAsRead];
        return successResponse(@{
            @"handle": handle,
            @"marked_as_read": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse([NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

NSDictionary* handleReact(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];
    
    if (!handle || !messageGUID || !type) {
        return errorResponse(@"Missing required parameters: handle, guid, type");
    }
    
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(@"IMChatRegistry not available");
    }
    
    IMChatRegistry *registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(@"Could not get IMChatRegistry instance");
    }
    
    IMChat *chat = [registry existingChatWithChatIdentifier:handle];
    if (!chat) {
        return errorResponse([NSString stringWithFormat:@"Chat not found: %@", handle]);
    }
    
    @try {
        id message = [chat messageForGUID:messageGUID];
        if (!message) {
            return errorResponse([NSString stringWithFormat:@"Message not found: %@", messageGUID]);
        }
        
        // Note: sendTapback implementation may vary based on IMCore version
        SEL tapbackSelector = NSSelectorFromString(@"sendTapback:forMessage:");
        if ([chat respondsToSelector:tapbackSelector]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:tapbackSelector];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:tapbackSelector];
            [inv setTarget:chat];
            NSInteger typeValue = [type integerValue];
            [inv setArgument:&typeValue atIndex:2];
            [inv setArgument:&message atIndex:3];
            [inv invoke];
        } else {
            return errorResponse(@"Tapback method not available on this macOS version");
        }
        
        return successResponse(@{
            @"handle": handle,
            @"guid": messageGUID,
            @"type": type,
            @"action": [type integerValue] >= 3000 ? @"removed" : @"added"
        });
    } @catch (NSException *exception) {
        return errorResponse([NSString stringWithFormat:@"Failed to send tapback: %@", exception.reason]);
    }
}

NSDictionary* handleStatus(NSDictionary *params) {
    BOOL imcoreAvailable = loadIMCore();
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    
    return successResponse(@{
        @"imcore_loaded": @(imcoreAvailable),
        @"registry_available": @(hasRegistry),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"tapback_available": @(hasRegistry)
    });
}

// Main entry point
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Load IMCore on startup
        if (!loadIMCore()) {
            NSDictionary *error = errorResponse(@"Failed to load IMCore framework. Ensure SIP is disabled and Full Disk Access is granted.");
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            printf("%s\n", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
            return 1;
        }
        
        // Read JSON command from stdin
        NSFileHandle *stdin = [NSFileHandle fileHandleWithStandardInput];
        NSData *inputData = [stdin readDataToEndOfFile];
        
        if (inputData.length == 0) {
            NSDictionary *error = errorResponse(@"No input provided");
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            printf("%s\n", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
            return 1;
        }
        
        NSError *jsonError = nil;
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:&jsonError];
        
        if (jsonError || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *error = errorResponse(@"Invalid JSON input");
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            printf("%s\n", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
            return 1;
        }
        
        NSString *action = command[@"action"];
        NSDictionary *params = command[@"params"] ?: @{};
        NSDictionary *response = nil;
        
        // Route to appropriate handler
        if ([action isEqualToString:@"typing"]) {
            response = handleTyping(params);
        } else if ([action isEqualToString:@"read"]) {
            response = handleRead(params);
        } else if ([action isEqualToString:@"react"]) {
            response = handleReact(params);
        } else if ([action isEqualToString:@"status"]) {
            response = handleStatus(params);
        } else {
            response = errorResponse([NSString stringWithFormat:@"Unknown action: %@", action]);
        }
        
        // Output JSON response
        NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        printf("%s\n", [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding].UTF8String);
        
        return response[@"success"] ? 0 : 1;
    }
}