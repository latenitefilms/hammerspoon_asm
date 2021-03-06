@import Cocoa ;
@import Carbon ;
@import LuaSkin ;

#define USERDATA_TAG "hs.hotkey"
static int refTable = LUA_NOREF ;

@interface HSKeyRepeatManager : NSObject- (void)startTimer:(int)theEventID eventKind:(UInt32)theEventKind;
- (void)stopTimer;
- (void)delayTimerFired:(NSTimer *)timer;
- (void)repeatTimerFired:(NSTimer *)timer;
@end

static NSMutableIndexSet* handlers;
static HSKeyRepeatManager* keyRepeatManager;
static OSStatus trigger_hotkey_callback(int eventUID, UInt32 eventKind, BOOL isRepeat);

@implementation HSKeyRepeatManager {
    NSTimer *keyRepeatTimer;
    int eventID;
    UInt32 eventType;
}

- (void)startTimer:(int)theEventID eventKind:(UInt32)theEventKind {
    //NSLog(@"startTimer");
    if (keyRepeatTimer) {
        LuaSkin *skin = [LuaSkin shared];
        [skin logWarn:@"hs.timer:startTimer() called while an existing timer is running. Stopping existing timer and refusing to proceed."];
        [self stopTimer];
        return;
    }
    keyRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:[NSEvent keyRepeatDelay]
                                                      target:self
                                                    selector:@selector(delayTimerFired:)
                                                    userInfo:nil
                                                     repeats:NO];

    eventID = theEventID;
    eventType = theEventKind;
}

- (void)stopTimer {
    //NSLog(@"stopTimer");
    [keyRepeatTimer invalidate];
    keyRepeatTimer = nil;
    eventID = 0;
    eventType = 0;
}

- (void)delayTimerFired:(NSTimer * __unused)timer {
    //NSLog(@"delayTimerFired");

    trigger_hotkey_callback(eventID, eventType, true);

    [keyRepeatTimer invalidate];
    keyRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:[NSEvent keyRepeatInterval]
                                                      target:self
                                                    selector:@selector(repeatTimerFired:)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)repeatTimerFired:(NSTimer * __unused)timer {
    //NSLog(@"repeatTimerFired");

    trigger_hotkey_callback(eventID, eventType, true);
}

@end

static int store_hotkey(lua_State* L, int idx) {
    LuaSkin *skin = [LuaSkin shared];
    lua_pushvalue(L, idx);
    int x = [skin luaRef:refTable];
    [handlers addIndex:(NSUInteger)x];
    return x;
}

static int remove_hotkey(__unused lua_State* L, int x) {
    LuaSkin *skin = [LuaSkin shared];
    [skin luaUnref:refTable ref:x];
    [handlers removeIndex:(NSUInteger)x];
    return LUA_NOREF;
}

static void* push_hotkey(lua_State* L, int x) {
    LuaSkin *skin = [LuaSkin shared];
    [skin pushLuaRef:refTable ref:x];
    return lua_touserdata(L, -1);
}

typedef struct _hotkey_t {
    UInt32 mods;
    UInt32 keycode;
    int uid;
    int pressedfn;
    int releasedfn;
    int repeatfn;
    BOOL enabled;
    EventHotKeyRef carbonHotKey;
} hotkey_t;


static int hotkey_new(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared];

    luaL_checktype(L, 1, LUA_TTABLE);
    UInt32 keycode = (UInt32)luaL_checkinteger(L, 2);
    BOOL hasDown = NO;
    BOOL hasUp = NO;
    BOOL hasRepeat = NO;

    if (!lua_isnoneornil(L, 3)) {
        hasDown = YES;
    }

    if (!lua_isnoneornil(L, 4)) {
        hasUp = YES;
    }

    if (!lua_isnoneornil(L, 5)) {
        hasRepeat = YES;
    }

    if (!hasDown && !hasUp && !hasRepeat) {
        [skin logError:@"hs.hotkey: new hotkeys must have at least one callback function"];

        lua_pushnil(L);
        return 1;
    }
    lua_settop(L, 5);

    hotkey_t* hotkey = lua_newuserdata(L, sizeof(hotkey_t));
    memset(hotkey, 0, sizeof(hotkey_t));

    hotkey->carbonHotKey = nil;
    hotkey->keycode = keycode;

    // use 'hs.hotkey' metatable
    luaL_getmetatable(L, USERDATA_TAG);
    lua_setmetatable(L, -2);

    // store pressedfn
    if (hasDown) {
        lua_pushvalue(L, 3);
        hotkey->pressedfn = [skin luaRef:refTable];
    } else {
        hotkey->pressedfn = LUA_NOREF;
    }

    // store releasedfn
    if (hasUp) {
        lua_pushvalue(L, 4);
        hotkey->releasedfn = [skin luaRef:refTable];
    } else {
        hotkey->releasedfn = LUA_NOREF;
    }

    // store repeatfn
    if (hasRepeat) {
        lua_pushvalue(L, 5);
        hotkey->repeatfn = [skin luaRef:refTable];
    } else {
        hotkey->repeatfn = LUA_NOREF;
    }

    // save mods
    lua_pushnil(L);
    while (lua_next(L, 1) != 0) {
        NSString* mod = [[NSString stringWithUTF8String:luaL_checkstring(L, -1)] lowercaseString];
        if ([mod isEqualToString: @"cmd"] || [mod isEqualToString: @"⌘"]) hotkey->mods |= cmdKey;
        else if ([mod isEqualToString: @"ctrl"] || [mod isEqualToString: @"⌃"]) hotkey->mods |= controlKey;
        else if ([mod isEqualToString: @"alt"] || [mod isEqualToString: @"⌥"]) hotkey->mods |= optionKey;
        else if ([mod isEqualToString: @"shift"] || [mod isEqualToString: @"⇧"]) hotkey->mods |= shiftKey;
        else if ([mod isEqualToString: @"fn"] || [mod isEqualToString: @"ƒ"]) {
            [LuaSkin logWarn:@"using kEventKeyModifierFnBit"] ;
            hotkey->mods |= (1 << kEventKeyModifierFnBit);
        }
        lua_pop(L, 1);
    }

    return 1;
}

static int hotkey_enable(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];

    hotkey_t* hotkey = lua_touserdata(L, 1);
    lua_settop(L, 1);

    if (hotkey->enabled)
        return 1;

    if (hotkey->carbonHotKey) {
        [skin logBreadcrumb:@"hs.hotkey:enable() we think the hotkey is disabled, but it has a Carbon event. Proceeding, but this is a leak."];
    }

    hotkey->uid = store_hotkey(L, 1);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfour-char-constants"
    EventHotKeyID hotKeyID = { .signature = 'HMSP', .id = (UInt32)hotkey->uid };
#pragma clang diagnostic pop
    OSStatus result = RegisterEventHotKey(hotkey->keycode, hotkey->mods, hotKeyID, GetEventDispatcherTarget(), kEventHotKeyExclusive, &hotkey->carbonHotKey);

    if (result == noErr) {
        hotkey->enabled = YES;
        lua_pushvalue(L, 1);
    } else {
        [skin logError:[NSString stringWithFormat:@"%s:enable() keycode: %d, mods: 0x%04x, RegisterEventHotKey failed: %d", USERDATA_TAG, hotkey->keycode, hotkey->mods, (int)result]];

        hotkey->uid = remove_hotkey(L, hotkey->uid);

        lua_pushnil(L) ;
    }

    return 1;
}

static void stop(lua_State* L, hotkey_t* hotkey) {
    LuaSkin *skin = [LuaSkin shared];

    if (!hotkey->enabled)
        return;

    hotkey->enabled = NO;
    hotkey->uid = remove_hotkey(L, hotkey->uid);

    if (!hotkey->carbonHotKey) {
        [skin logBreadcrumb:@"hs.hotkey stop() we think the hotkey is enabled, but it has no Carbon event. Refusing to unregister."];
    } else {
        OSStatus result = UnregisterEventHotKey(hotkey->carbonHotKey);
        hotkey->carbonHotKey = nil;
        if (result != noErr) {
            [skin logError:[NSString stringWithFormat:@"%s:stop() keycode: %d, mods: 0x%04x, UnregisterEventHotKey failed: %d", USERDATA_TAG, hotkey->keycode, hotkey->mods, (int)result]];
        }
    }

    [keyRepeatManager stopTimer];
}

static int hotkey_disable(lua_State* L) {
    hotkey_t* hotkey = luaL_checkudata(L, 1, USERDATA_TAG);
    stop(L, hotkey);
    lua_pushvalue(L, 1);
    return 1;
}

static int hotkey_gc(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared];

    hotkey_t* hotkey = luaL_checkudata(L, 1, USERDATA_TAG);

    stop(L, hotkey);

    hotkey->pressedfn = [skin luaUnref:refTable ref:hotkey->pressedfn];
    hotkey->releasedfn = [skin luaUnref:refTable ref:hotkey->releasedfn];
    hotkey->repeatfn = [skin luaUnref:refTable ref:hotkey->repeatfn];

    return 0;
}

static EventHandlerRef eventhandler;

static OSStatus hotkey_callback(EventHandlerCallRef __unused inHandlerCallRef, EventRef inEvent, __unused void *inUserData) {
    LuaSkin *skin = [LuaSkin shared];
    EventHotKeyID eventID;
    UInt32 eventKind;
    int eventUID;

    //NSLog(@"hotkey_callback");
    OSStatus result = GetEventParameter(inEvent, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(eventID), NULL, &eventID);
    if (result != noErr) {
        [skin logBreadcrumb:[NSString stringWithFormat:@"Error handling hotkey: %d", result]];
        return noErr;
    }

    eventKind = GetEventKind(inEvent);
    eventUID = (int)eventID.id;

    return trigger_hotkey_callback(eventUID, eventKind, false);
}

static OSStatus trigger_hotkey_callback(int eventUID, UInt32 eventKind, BOOL isRepeat) {
    //NSLog(@"trigger_hotkey_callback: isDown: %s, isUp: %s, isRepeat: %s", (eventKind == kEventHotKeyPressed) ? "YES" : "NO", (eventKind == kEventHotKeyReleased) ? "YES" : "NO", isRepeat ? "YES" : "NO");
    LuaSkin *skin = [LuaSkin shared];
    lua_State *L = skin.L;

    hotkey_t* hotkey = push_hotkey(L, eventUID);
    lua_pop(L, 1);

    if (!isRepeat) {
        //NSLog(@"trigger_hotkey_callback: not a repeat, killing the timer if it's running");
        [keyRepeatManager stopTimer];
    }

    if (hotkey) {
        int ref = 0;
        if (isRepeat) {
            ref = hotkey->repeatfn;
        } else if (eventKind == kEventHotKeyPressed) {
           ref = hotkey->pressedfn;
        } else if (eventKind == kEventHotKeyReleased) {
           ref = hotkey->releasedfn;
        } else {
            [skin logWarn:[NSString stringWithFormat:@"Unknown event kind (%i) in hs.hotkey trigger_hotkey_callback", eventKind]];
            return noErr;
        }

        if (ref != LUA_NOREF) {
            [skin pushLuaRef:refTable ref:ref];

            if (![skin protectedCallAndTraceback:0 nresults:0]) {
                // For the sake of safety, we'll invalidate any repeat timer that's running, so we don't ruin the user's day by spamming them with errors
                [keyRepeatManager stopTimer];
                const char *errorMsg = lua_tostring(L, -1);
                [skin logError:[NSString stringWithFormat:@"hs.hotkey callback error: %s", errorMsg]];
                lua_pop(L, 1) ; // remove error message
                return noErr;
            }
        }
        if (!isRepeat && eventKind == kEventHotKeyPressed && hotkey->repeatfn != LUA_NOREF) {
            //NSLog(@"trigger_hotkey_callback: not a repeat, but it is a keydown, starting the timer");
            [keyRepeatManager startTimer:eventUID eventKind:eventKind];
        }
    }

    return noErr;
}

static int meta_gc(lua_State* L __unused) {
    RemoveEventHandler(eventhandler);
    [keyRepeatManager stopTimer];
    keyRepeatManager = nil;

    return 0;
}

static int userdata_tostring(lua_State* L) {
    hotkey_t* hotkey = luaL_checkudata(L, 1, USERDATA_TAG);

    lua_pushstring(L, [[NSString stringWithFormat:@"%s: keycode: %d, mods: 0x%04x (%p)", USERDATA_TAG, hotkey->keycode, hotkey->mods, lua_topointer(L, 1)] UTF8String]) ;
    return 1 ;
}

static const luaL_Reg hotkeylib[] = {
    {"_new", hotkey_new},

    {NULL, NULL}
};

static const luaL_Reg metalib[] = {
    {"__gc", meta_gc},
    {NULL, NULL}
};

static const luaL_Reg hotkey_objectlib[] = {
    {"enable", hotkey_enable},
    {"disable", hotkey_disable},
    {"__tostring", userdata_tostring},
    {"__gc", hotkey_gc},
    {NULL, NULL}
};

int luaopen_hs_hotkey_internal(lua_State* L __unused) {
    LuaSkin *skin = [LuaSkin shared];

    handlers = [NSMutableIndexSet indexSet];
    keyRepeatManager = [[HSKeyRepeatManager alloc] init];

    refTable = [skin registerLibraryWithObject:USERDATA_TAG functions:hotkeylib metaFunctions:metalib objectFunctions:hotkey_objectlib];

    // watch for hotkey events
    EventTypeSpec hotKeyPressedSpec[] = {
        {kEventClassKeyboard, kEventHotKeyPressed},
        {kEventClassKeyboard, kEventHotKeyReleased},
    };

    InstallEventHandler(GetEventDispatcherTarget(),
                        hotkey_callback,
                        sizeof(hotKeyPressedSpec) / sizeof(EventTypeSpec),
                        hotKeyPressedSpec,
                        nil,
                        &eventhandler);

    return 1;
}
