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

    // Method 3: Iterate all chats and match by participant (exact matching only)
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        NSLog(@"[imsg-plus] Searching %lu chats for identifier: %@", (unsigned long)allChats.count, identifier);

        // Normalize the search identifier (strip non-digit chars for phone numbers)
        NSString *normalizedIdentifier = nil;
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[identifier characterAtIndex:0]]) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < identifier.length; i++) {
                unichar c = [identifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID — exact match only
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier — exact match only
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants — exact or normalized phone match
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        // Exact match
                        if ([handleID isEqualToString:identifier]) {
                            NSLog(@"[imsg-plus] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match (compare digits only)
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                [handleDigits hasSuffix:normalizedIdentifier] ||
                                [normalizedIdentifier hasSuffix:handleDigits]) {
                                NSLog(@"[imsg-plus] Found chat by normalized phone match: %@ ~ %@", handleID, identifier);
                                return aChat;
                            }
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

// Helper to write a response dictionary to the response file (for async handlers)
static void writeResponseToFile(NSDictionary *response) {
    initFilePaths();
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
    [responseData writeToFile:kResponseFile atomically:YES];
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[imsg-plus] Wrote async response to file");
}

// Map reaction type to verb string for summary text
static NSString* reactionVerb(long long reactionType) {
    // For removals (3000+), use the same verb as the base type
    long long baseType = reactionType >= 3000 ? reactionType - 1000 : reactionType;
    switch (baseType) {
        case 2000: return @"Loved ";
        case 2001: return @"Liked ";
        case 2002: return @"Disliked ";
        case 2003: return @"Laughed at ";
        case 2004: return @"Emphasized ";
        case 2005: return @"Questioned ";
        default:   return @"Reacted to ";
    }
}

// handleReact returns nil when it handles the response asynchronously
static NSDictionary* handleReact(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];
    NSNumber *partIndexNum = params[@"partIndex"];
    int partIndex = partIndexNum ? [partIndexNum intValue] : 0;

    if (!handle || !messageGUID || !type) {
        return errorResponse(requestId, @"Missing required parameters: handle, guid, type");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Get IMChatHistoryController to load the message by GUID asynchronously
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ via IMChatHistoryController (async)...", messageGUID);

    // Capture values for the completion block
    long long reactionType = [type longLongValue];

    // Build and invoke the async load call
    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    // The completion block receives the loaded IMMessage
    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] loadMessageWithGUID completion fired, message=%@, class=%@",
                  message, message ? [message class] : @"nil");

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Get IMMessageItem and chat items from the message
                id messageItem = [message valueForKey:@"_imMessageItem"];
                NSLog(@"[imsg-plus] messageItem class: %@", messageItem ? [messageItem class] : @"nil");

                id items = nil;
                if (messageItem && [messageItem respondsToSelector:@selector(_newChatItems)]) {
                    items = [messageItem performSelector:@selector(_newChatItems)];
                } else if (messageItem) {
                    items = [messageItem valueForKey:@"_newChatItems"];
                }
                NSLog(@"[imsg-plus] _newChatItems: %@ (class: %@)", items, items ? [items class] : @"nil");

                // Find the IMMessagePartChatItem at partIndex
                id partItem = nil;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *itemArray = (NSArray *)items;
                    NSLog(@"[imsg-plus] Got %lu chat items from message", (unsigned long)itemArray.count);
                    for (id item in itemArray) {
                        // Look for IMMessagePartChatItem or IMTextMessagePartChatItem
                        NSString *className = NSStringFromClass([item class]);
                        if ([className containsString:@"MessagePartChatItem"] ||
                            [className containsString:@"TextMessagePartChatItem"]) {
                            // Check if this is the right part index
                            if ([item respondsToSelector:@selector(index)]) {
                                NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                if (idx == partIndex) {
                                    partItem = item;
                                    break;
                                }
                            } else if (partIndex == 0) {
                                // Default: use first matching item
                                partItem = item;
                                break;
                            }
                        }
                    }
                    // Fallback: if no specific part found, use first item
                    if (!partItem && itemArray.count > 0) {
                        partItem = itemArray[partIndex < (int)itemArray.count ? partIndex : 0];
                    }
                } else if (items) {
                    partItem = items;
                }

                NSLog(@"[imsg-plus] partItem: %@ (class: %@)", partItem, partItem ? [partItem class] : @"nil");

                // Get text for the summary
                NSAttributedString *itemText = nil;
                if (partItem && [partItem respondsToSelector:@selector(text)]) {
                    itemText = [partItem performSelector:@selector(text)];
                }
                if (!itemText && [message respondsToSelector:@selector(text)]) {
                    itemText = [message performSelector:@selector(text)];
                }
                NSString *summaryText = itemText ? itemText.string : @"";
                if (!summaryText) summaryText = @"";
                NSLog(@"[imsg-plus] summaryText: %@", summaryText);

                // Build the associated GUID: p:PARTINDEX/MESSAGE_GUID
                NSString *associatedGuid = [NSString stringWithFormat:@"p:%d/%@", partIndex, messageGUID];
                NSLog(@"[imsg-plus] associatedGuid: %@", associatedGuid);

                // Build message summary info
                NSDictionary *messageSummary = @{@"amc": @1, @"ams": summaryText};

                // Build the reaction text: "Loved "message text""
                NSString *verb = reactionVerb(reactionType);
                NSString *reactionString = [verb stringByAppendingString:
                    [NSString stringWithFormat:@"\u201c%@\u201d", summaryText]];
                NSMutableAttributedString *reactionText =
                    [[NSMutableAttributedString alloc] initWithString:reactionString];

                // Get messagePartRange from the part item
                NSRange partRange = NSMakeRange(0, summaryText.length);
                if (partItem) {
                    SEL rangeSel = @selector(messagePartRange);
                    if ([partItem respondsToSelector:rangeSel]) {
                        NSMethodSignature *sig = [partItem methodSignatureForSelector:rangeSel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:rangeSel];
                        [inv setTarget:partItem];
                        [inv invoke];
                        [inv getReturnValue:&partRange];
                        NSLog(@"[imsg-plus] messagePartRange: {%lu, %lu}",
                              (unsigned long)partRange.location, (unsigned long)partRange.length);
                    }
                }

                // Create the IMMessage for the reaction using the long init method
                Class IMMessageClass = NSClassFromString(@"IMMessage");
                if (!IMMessageClass) {
                    writeResponseToFile(errorResponse(requestId, @"IMMessage class not found"));
                    return;
                }

                id reactionMessage = [IMMessageClass alloc];

                // The init selector with associated message fields
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);

                if (![reactionMessage respondsToSelector:initSel]) {
                    NSLog(@"[imsg-plus] Long init selector not available, dumping IMMessage init methods...");
                    unsigned int methodCount;
                    Method *methods = class_copyMethodList(IMMessageClass, &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name hasPrefix:@"initWith"]) {
                            NSLog(@"[imsg-plus]   %@", name);
                        }
                    }
                    free(methods);
                    writeResponseToFile(errorResponse(requestId,
                        @"IMMessage initWithSender:time:text:...associatedMessage... selector not found"));
                    return;
                }

                // Use objc_msgSend with the correct type signature
                // Args: self, _cmd, sender(id), time(id), text(id), messageSubject(id),
                //        fileTransferGUIDs(id), flags(unsigned long long), error(id),
                //        guid(id), subject(id), associatedMessageGUID(id),
                //        associatedMessageType(long long), associatedMessageRange(NSRange),
                //        messageSummaryInfo(id)
                typedef id (*InitMsgSendType)(id, SEL,
                    id,                  // sender
                    id,                  // time
                    id,                  // text
                    id,                  // messageSubject
                    id,                  // fileTransferGUIDs
                    unsigned long long,  // flags
                    id,                  // error
                    id,                  // guid
                    id,                  // subject
                    id,                  // associatedMessageGUID
                    long long,           // associatedMessageType
                    NSRange,             // associatedMessageRange
                    id                   // messageSummaryInfo
                );

                InitMsgSendType initMsgSend = (InitMsgSendType)objc_msgSend;
                reactionMessage = initMsgSend(reactionMessage, initSel,
                    nil,                     // sender
                    nil,                     // time
                    reactionText,            // text
                    nil,                     // messageSubject
                    nil,                     // fileTransferGUIDs
                    (unsigned long long)0x5, // flags
                    nil,                     // error
                    nil,                     // guid
                    nil,                     // subject
                    associatedGuid,          // associatedMessageGUID
                    reactionType,            // associatedMessageType
                    partRange,               // associatedMessageRange
                    messageSummary           // messageSummaryInfo
                );

                if (!reactionMessage) {
                    writeResponseToFile(errorResponse(requestId, @"Failed to create reaction IMMessage (init returned nil)"));
                    return;
                }

                NSLog(@"[imsg-plus] Created reaction message: %@ (class: %@)", reactionMessage, [reactionMessage class]);

                // Send the reaction message
                SEL sendSel = @selector(sendMessage:);
                if (![chat respondsToSelector:sendSel]) {
                    writeResponseToFile(errorResponse(requestId, @"Chat does not respond to sendMessage:"));
                    return;
                }

                [chat performSelector:sendSel withObject:reactionMessage];
                NSLog(@"[imsg-plus] ✅ Sent reaction message via sendMessage:");

                writeResponseToFile(successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"partIndex": @(partIndex),
                    @"action": reactionType >= 3000 ? @"removed" : @"added",
                    @"method": @"createMessage_BlueBubbles"
                }));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in react completion: %@\n%@", exception.reason, exception.callStackSymbols);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed in react completion: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    NSLog(@"[imsg-plus] loadMessageWithGUID invoked, waiting for async completion...");

    // Set a 5-second timeout: if the completion block never fires (e.g. invalid GUID),
    // write an error response so the CLI doesn't hang indefinitely.
    __block BOOL completionFired = NO;
    // Patch the completion block to track if it fired
    void (^originalBlock)(id) = completionBlock;
    completionBlock = nil; // Release our reference; loadInv already retained it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Check if response file has been written (completion fired)
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ React completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: message GUID not found or completion never fired: %@", messageGUID]));
        }
    });

    // Return nil to signal async handling — processCommandFile will check for this
    return nil;
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

        if (result != nil) {
            // Synchronous response — write it now
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];

            // Clear command file to indicate we processed it
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

            NSLog(@"[imsg-plus] Processed command, wrote response");
        } else {
            // Async handler (e.g., react) will write its own response
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[imsg-plus] Command dispatched async, response pending");
        }
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
