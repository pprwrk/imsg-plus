//
//  IMsgInjected.m
//  IMsgHelper - Injectable dylib for Messages.app
//
//  This dylib is injected into Messages.app via DYLD_INSERT_LIBRARIES
//  to gain access to IMCore's chat registry and messaging functions.
//  It provides a Unix socket server for IPC with the CLI.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

#pragma mark - Constants

// File-based IPC paths (in container for sandbox compatibility)
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
static dispatch_source_t fileWatchSource = nil;
static NSTimer *fileWatchTimer = nil;
static int lockFd = -1;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Use container path which Messages.app can write to
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-ready"];
    }
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (id)messageForGUID:(NSString *)guid;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
@end

#pragma mark - Runtime Method Injection

// Provide missing isEditedMessageHistory method for IMMessageItem compatibility
static BOOL IMMessageItem_isEditedMessageHistory(id self, SEL _cmd) {
    // Return NO as default - this message is not an edited message history item
    return NO;
}

static void injectCompatibilityMethods(void) {
    SEL selector = @selector(isEditedMessageHistory);

    // Add isEditedMessageHistory to IMMessageItem if it doesn't exist
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (IMMessageItemClass) {
        if (![IMMessageItemClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageItemClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessageItem");
        }
    }

    // Also add to IMMessage class (different from IMMessageItem)
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    if (IMMessageClass) {
        if (![IMMessageClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessage");
        }
    }
}

#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Chat Resolution

// Try multiple methods to find a chat, similar to BlueBubbles approach
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-plus] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-plus] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;

    // Method 1: Try existingChatWithGUID: (BlueBubbles approach)
    // This expects full GUID like "iMessage;-;email@example.com"
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        // If identifier already looks like a GUID, use it directly
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes
        NSArray *prefixes = @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;"];
        for (NSString *prefix in prefixes) {
            NSString *fullGUID = [prefix stringByAppendingString:identifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-plus] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
    }

    // Method 3: Iterate all chats and match by participant
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        NSLog(@"[imsg-plus] Searching %lu chats for identifier: %@", (unsigned long)allChats.count, identifier);

        for (id aChat in allChats) {
            // Check GUID
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID containsString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by GUID match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier] || [chatId containsString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by chatIdentifier match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        if ([handleID isEqualToString:identifier] || [handleID containsString:identifier]) {
                            NSLog(@"[imsg-plus] Found chat by participant: %@", handleID);
                            return aChat;
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-plus] Chat not found for identifier: %@", identifier);
    return nil;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Check if chat supports typing indicators
        BOOL supportsTyping = YES;
        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
            NSLog(@"[imsg-plus] Chat supports typing indicators: %@", supportsTyping ? @"YES" : @"NO");
        }

        // Use setLocalUserIsTyping: (simpler and more reliable)
        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            NSLog(@"[imsg-plus] Called setLocalUserIsTyping:%@ for %@", typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing),
                @"supports_typing": @(supportsTyping)
            });
        }

        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSLog(@"[imsg-plus] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

static NSDictionary* handleReact(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];

    if (!handle || !messageGUID || !type) {
        return errorResponse(requestId, @"Missing required parameters: handle, guid, type");
    }

    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Search through chatItems to find the chat item (IMChatItem subclass)
        // Don't use messageForGUID - it returns IMMessage which doesn't work with tapback methods
        id chatItem = nil;
        SEL chatItemsSel = @selector(chatItems);
        if ([chat respondsToSelector:chatItemsSel]) {
            NSArray *chatItems = [chat performSelector:chatItemsSel];
            NSLog(@"[imsg-plus] Searching %lu chat items for GUID: %@", (unsigned long)chatItems.count, messageGUID);

            for (id item in chatItems) {
                // Check if this item has a matching GUID (may be prefixed like "p:0/GUID")
                if ([item respondsToSelector:@selector(guid)]) {
                    NSString *itemGUID = [item performSelector:@selector(guid)];
                    // Match exact GUID or GUID with prefix (e.g., "p:0/GUID")
                    if ([itemGUID isEqualToString:messageGUID] || [itemGUID hasSuffix:messageGUID]) {
                        chatItem = item;
                        NSLog(@"[imsg-plus] Found chat item: %@ (class: %@)", itemGUID, [item class]);
                        break;
                    }
                }

                // Also check the underlying _item (IMMessage) property
                if (!chatItem && [item respondsToSelector:@selector(_item)]) {
                    id innerItem = [item performSelector:@selector(_item)];
                    if ([innerItem respondsToSelector:@selector(guid)]) {
                        NSString *innerGUID = [innerItem performSelector:@selector(guid)];
                        if ([innerGUID isEqualToString:messageGUID] || [innerGUID hasSuffix:messageGUID]) {
                            chatItem = item;
                            NSLog(@"[imsg-plus] Found chat item via _item: %@ (class: %@)", innerGUID, [item class]);
                            break;
                        }
                    }
                }
            }
        }

        if (!chatItem) {
            return errorResponse(requestId, [NSString stringWithFormat:@"Chat item not found for GUID: %@", messageGUID]);
        }

        // Use the chatItem directly — sendMessageAcknowledgment:forChatItem: expects
        // an IMChatItem subclass (e.g., IMTextMessagePartChatItem), NOT an IMMessageItem.
        id targetItem = chatItem;
        NSLog(@"[imsg-plus] Using chat item: %@ (class: %@)", [targetItem respondsToSelector:@selector(guid)] ? [targetItem performSelector:@selector(guid)] : @"?", [targetItem class]);

        long long typeValue = [type longLongValue];

        // Define all possible selectors (in order of preference)
        SEL modernSel = @selector(sendMessageAcknowledgment:forChatItem:withAssociatedMessageInfo:);
        SEL legacySel = @selector(sendMessageAcknowledgment:forChatItem:withMessageSummaryInfo:);
        SEL twoParamSel = @selector(sendMessageAcknowledgment:forChatItem:);
        SEL tapbackSel = @selector(sendTapback:forChatItem:);

        // Log which methods are available
        NSLog(@"[imsg-plus] Chat class: %@", [chat class]);
        NSLog(@"[imsg-plus] Has modernSel: %@", [chat respondsToSelector:modernSel] ? @"YES" : @"NO");
        NSLog(@"[imsg-plus] Has legacySel: %@", [chat respondsToSelector:legacySel] ? @"YES" : @"NO");
        NSLog(@"[imsg-plus] Has twoParamSel: %@", [chat respondsToSelector:twoParamSel] ? @"YES" : @"NO");
        NSLog(@"[imsg-plus] Has tapbackSel: %@", [chat respondsToSelector:tapbackSel] ? @"YES" : @"NO");

        // Dump the method signature
        if ([chat respondsToSelector:twoParamSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:twoParamSel];
            NSLog(@"[imsg-plus] 2-param signature: return=%s, args=%lu", sig.methodReturnType, (unsigned long)sig.numberOfArguments);
            for (NSUInteger i = 0; i < sig.numberOfArguments; i++) {
                NSLog(@"[imsg-plus]   arg[%lu]: %s", (unsigned long)i, [sig getArgumentTypeAtIndex:i]);
            }
        }

        // Try modern 3-param method (macOS 10.15+) using objc_msgSend
        if ([chat respondsToSelector:modernSel]) {
            @try {
                NSLog(@"[imsg-plus] Trying modern 3-param with chat item using objc_msgSend");
                void (*msgSend)(id, SEL, long long, id, id) = (void *)objc_msgSend;
                msgSend(chat, modernSel, typeValue, targetItem, nil);
                NSLog(@"[imsg-plus] ✅ Success via modern 3-param method");
                return successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"action": [type integerValue] >= 3000 ? @"removed" : @"added",
                    @"method": @"withAssociatedMessageInfo"
                });
            } @catch (NSException *ex) {
                NSLog(@"[imsg-plus] Failed modern 3-param: %@", ex.reason);
            }
        }

        // Try legacy 3-param method (macOS 10.14 and earlier) using objc_msgSend
        if ([chat respondsToSelector:legacySel]) {
            @try {
                NSLog(@"[imsg-plus] Trying legacy 3-param with chat item using objc_msgSend");
                void (*msgSend)(id, SEL, long long, id, id) = (void *)objc_msgSend;
                msgSend(chat, legacySel, typeValue, targetItem, nil);
                NSLog(@"[imsg-plus] ✅ Success via legacy 3-param method");
                return successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"action": [type integerValue] >= 3000 ? @"removed" : @"added",
                    @"method": @"withMessageSummaryInfo"
                });
            } @catch (NSException *ex) {
                NSLog(@"[imsg-plus] Failed legacy 3-param: %@", ex.reason);
            }
        }

        // Try 2-param method using objc_msgSend directly
        if ([chat respondsToSelector:twoParamSel]) {
            @try {
                NSLog(@"[imsg-plus] Trying 2-param with chat item using objc_msgSend");
                void (*msgSend)(id, SEL, long long, id) = (void *)objc_msgSend;
                msgSend(chat, twoParamSel, typeValue, targetItem);
                NSLog(@"[imsg-plus] ✅ Success via 2-param method");
                return successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"action": [type integerValue] >= 3000 ? @"removed" : @"added",
                    @"method": @"2-param"
                });
            } @catch (NSException *ex) {
                NSLog(@"[imsg-plus] Failed 2-param: %@", ex.reason);
            }
        }

        // Try alternative sendTapback:forChatItem: method using objc_msgSend
        if ([chat respondsToSelector:tapbackSel]) {
            @try {
                NSLog(@"[imsg-plus] Trying sendTapback with chat item using objc_msgSend");
                void (*msgSend)(id, SEL, long long, id) = (void *)objc_msgSend;
                msgSend(chat, tapbackSel, typeValue, targetItem);
                NSLog(@"[imsg-plus] ✅ Success via sendTapback method");
                return successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"action": [type integerValue] >= 3000 ? @"removed" : @"added",
                    @"method": @"sendTapback"
                });
            } @catch (NSException *ex) {
                NSLog(@"[imsg-plus] Failed sendTapback: %@", ex.reason);
            }
        }

        // Log available methods for debugging
        NSLog(@"[imsg-plus] ❌ No tapback method available or all methods failed. Chat class: %@", [chat class]);
        unsigned int methodCount;
        Method *methods = class_copyMethodList([chat class], &methodCount);
        NSLog(@"[imsg-plus] All methods containing 'ack', 'tapback', or 'message':");
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL selector = method_getName(methods[i]);
            NSString *methodName = NSStringFromSelector(selector);
            NSString *lowerName = [methodName lowercaseString];
            if ([lowerName containsString:@"ack"] || [lowerName containsString:@"tapback"] || [lowerName containsString:@"message"]) {
                // Get method signature
                Method method = methods[i];
                char *returnType = method_copyReturnType(method);
                unsigned int argCount = method_getNumberOfArguments(method);
                NSMutableString *sig = [NSMutableString stringWithFormat:@"%s %@(", returnType, methodName];
                for (unsigned int j = 2; j < argCount; j++) {  // Skip self and _cmd
                    char *argType = method_copyArgumentType(method, j);
                    [sig appendFormat:@"%s%s", argType, (j < argCount - 1) ? ", " : ""];
                    free(argType);
                }
                [sig appendString:@")"];
                free(returnType);
                NSLog(@"[imsg-plus]   - %@", sig);
            }
        }
        free(methods);

        return errorResponse(requestId, @"All tapback methods failed or none available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to send tapback: %@", exception.reason]);
    }
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    return successResponse(requestId, @{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"tapback_available": @(hasRegistry)
    });
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

#pragma mark - Command Router

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-plus] Processing command: %@ (id=%ld)", action, (long)requestId);

    if ([action isEqualToString:@"typing"]) {
        return handleTyping(requestId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(requestId, params);
    } else if ([action isEqualToString:@"react"]) {
        return handleReact(requestId, params);
    } else if ([action isEqualToString:@"status"]) {
        return handleStatus(requestId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(requestId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(requestId, @{@"pong": @YES});
    } else {
        return errorResponse(requestId, [NSString stringWithFormat:@"Unknown action: %@", action]);
    }
}

#pragma mark - Socket Server

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        // Read command file
        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        // Parse JSON
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData options:0 error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        // Timer runs on main run loop, so we're already on the main thread for IMCore access
        NSDictionary *result = processCommand(command);

        // Write response
        NSData *responseData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        [responseData writeToFile:kResponseFile atomically:YES];

        // Clear command file to indicate we processed it
        [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSLog(@"[imsg-plus] Processed command, wrote response");
    }
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-plus] Starting file-based IPC");
    NSLog(@"[imsg-plus] Command file: %@", kCommandFile);
    NSLog(@"[imsg-plus] Response file: %@", kResponseFile);

    // Create/clear command and response files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file to indicate we're ready
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY, 0644);
    if (lockFd >= 0) {
        // Write PID to lock file
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }

    // Watch command file for changes using NSTimer on the main run loop.
    // dispatch_source timers get deallocated in injected dylib contexts,
    // but NSTimer tied to the main run loop survives reliably.
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                // Check if file has content
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {  // More than just "{}"
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;  // Prevent deallocation
    fileWatchSource = nil;   // No longer using dispatch_source

    NSLog(@"[imsg-plus] File watcher started, ready for commands");
}

#pragma mark - Dylib Entry Point

__attribute__((constructor))
static void injectedInit(void) {
    NSLog(@"[imsg-plus] Dylib injected into %@", [[NSProcessInfo processInfo] processName]);

    // Inject compatibility methods for IMCore
    injectCompatibilityMethods();

    // Connect to IMDaemon for full IMCore access
    Class daemonClass = NSClassFromString(@"IMDaemonController");
    if (daemonClass) {
        id daemon = [daemonClass performSelector:@selector(sharedInstance)];
        if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
            [daemon performSelector:@selector(connectToDaemon)];
            NSLog(@"[imsg-plus] ✅ Connected to IMDaemon");
        } else {
            NSLog(@"[imsg-plus] ⚠️ IMDaemonController available but couldn't connect");
        }
    } else {
        NSLog(@"[imsg-plus] ⚠️ IMDaemonController class not found");
    }

    // Delay initialization to let Messages.app fully start
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSLog(@"[imsg-plus] Initializing after delay...");

        // Log IMCore status
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass) {
            id registry = [registryClass performSelector:@selector(sharedInstance)];
            if ([registry respondsToSelector:@selector(allExistingChats)]) {
                NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                NSLog(@"[imsg-plus] IMChatRegistry available with %lu chats", (unsigned long)chats.count);
            }
        } else {
            NSLog(@"[imsg-plus] IMChatRegistry NOT available");
        }

        // Start file watcher for IPC
        startFileWatcher();
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    NSLog(@"[imsg-plus] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (fileWatchSource) {
        dispatch_source_cancel(fileWatchSource);
        fileWatchSource = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    // Clean up files
    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
