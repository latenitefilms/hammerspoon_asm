#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <LuaSkin/LuaSkin.h>

#define USERDATA_TAG  "hs._asm.panels"
static int refTable = LUA_NOREF ;

// #define get_objectFromUserdata(objType, L, idx, tag) (objType*)*((void**)luaL_checkudata(L, idx, tag))
// #define get_structFromUserdata(objType, L, idx, tag) ((objType *)luaL_checkudata(L, idx, tag))
// #define get_cfobjectFromUserdata(objType, L, idx, tag) *((objType *)luaL_checkudata(L, idx, tag))

#pragma mark - Support Functions and Classes

@interface HSColorPanel : NSObject
@property int callbackRef ;
@end

@implementation HSColorPanel
- (instancetype)init {
    self = [super init] ;
    if (self) {
        _callbackRef = LUA_NOREF ;
        NSColorPanel *cp = [NSColorPanel sharedColorPanel];
        [cp setTarget:self];
        [cp setAction:@selector(colorCallback:)];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(colorClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:cp] ;
    }
    return self ;
}

- (void)colorClose:(__unused NSNotification*)note {
    if (_callbackRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LuaSkin   *skin = [LuaSkin shared] ;
            lua_State *L    = [skin L] ;
            NSColorPanel *cp = [NSColorPanel sharedColorPanel];
            [skin pushLuaRef:refTable ref:_callbackRef] ;
            [skin pushNSObject:cp.color] ;
            lua_pushboolean(L, YES) ;
            if (![skin protectedCallAndTraceback:2 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: color callback error, %s",
                                                          USERDATA_TAG,
                                                          lua_tostring(L, -1)]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

- (void)colorCallback:(NSColorPanel*)colorPanel {
    if (_callbackRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LuaSkin   *skin = [LuaSkin shared] ;
            lua_State *L    = [skin L] ;
            [skin pushLuaRef:refTable ref:_callbackRef] ;
            [skin pushNSObject:colorPanel.color] ;
            lua_pushboolean(L, NO) ;
            if (![skin protectedCallAndTraceback:2 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: color callback error, %s",
                                                          USERDATA_TAG,
                                                          lua_tostring(L, -1)]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}
@end

@interface HSFontPanel : NSObject
@property int callbackRef ;
@end

@implementation HSFontPanel
- (instancetype)init {
    self = [super init] ;
    if (self) {
        _callbackRef = LUA_NOREF ;
        NSFontPanel *fp = [NSFontPanel sharedFontPanel];
        NSFontManager *fm = [NSFontManager sharedFontManager];
        [fm setTarget:self];
        [fm setSelectedFont:[NSFont systemFontOfSize: 27] isMultiple:NO] ;
        [fm setSelectedAttributes:@{} isMultiple:NO] ;

//         [fp setAction:@selector(fontCallback:)];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(fontClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:fp] ;
    }
    return self ;
}

- (void)fontClose:(__unused NSNotification*)note {
    if (_callbackRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LuaSkin   *skin = [LuaSkin shared] ;
            lua_State *L    = [skin L] ;
            [skin pushLuaRef:refTable ref:_callbackRef] ;
            [skin pushNSObject:[[NSFontManager sharedFontManager] selectedFont]] ;
            lua_pushboolean(L, YES) ;
            if (![skin protectedCallAndTraceback:2 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: font callback error, %s",
                                                          USERDATA_TAG,
                                                          lua_tostring(L, -1)]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

- (void)changeFont:(id)obj {
    if (_callbackRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LuaSkin   *skin = [LuaSkin shared] ;
            lua_State *L    = [skin L] ;
            [skin pushLuaRef:refTable ref:_callbackRef] ;
            [skin pushNSObject:[obj selectedFont]] ;
            lua_pushboolean(L, NO) ;
            if (![skin protectedCallAndTraceback:2 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: font callback error, %s",
                                                          USERDATA_TAG,
                                                          lua_tostring(L, -1)]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

- (void)changeAttributes:(id)obj {
    if (_callbackRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LuaSkin   *skin = [LuaSkin shared] ;
            lua_State *L    = [skin L] ;
            [skin pushLuaRef:refTable ref:_callbackRef] ;
            [skin pushNSObject:[obj convertAttributes:@{}]] ;
            lua_pushboolean(L, NO) ;
            if (![skin protectedCallAndTraceback:2 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: font callback error, %s",
                                                          USERDATA_TAG,
                                                          lua_tostring(L, -1)]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

@end

#pragma mark - Color Panel Functions

static HSColorPanel *cpReceiverObject ;

static int colorPanelCallback(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK] ;

    if (cpReceiverObject.callbackRef != LUA_NOREF) {
        [skin pushLuaRef:refTable ref:cpReceiverObject.callbackRef] ;
    } else {
        lua_pushnil(L) ;
    }
    if (lua_gettop(L) == 2) { // we just added to it...
        // in either case, we need to remove an existing callback, so...
        cpReceiverObject.callbackRef = [skin luaUnref:refTable ref:cpReceiverObject.callbackRef] ;
        if (lua_type(L, 1) == LUA_TFUNCTION) {
            lua_pushvalue(L, 1) ;
            cpReceiverObject.callbackRef = [skin luaRef:refTable] ;
        }
    }
    // return the *last* fn (or nil) so you can save it and re-attach it if something needs to
    // temporarily take the callbacks
    return 1 ;
}

static int colorPanelContinuous(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    if (lua_gettop(L) == 1) {
        [cp setContinuous:(BOOL)lua_toboolean(L, 1)] ;
    }
    lua_pushboolean(L, cp.continuous) ;
    return 1 ;
}

static int colorPanelShowsAlpha(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    if (lua_gettop(L) == 1) {
        [cp setShowsAlpha:(BOOL)lua_toboolean(L, 1)] ;
    }
    lua_pushboolean(L, cp.showsAlpha) ;
    return 1 ;
}

static int colorPanelColor(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TTABLE | LS_TOPTIONAL, LS_TBREAK] ;
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    if (lua_gettop(L) == 1) {
        NSColor *theColor = [[LuaSkin shared] luaObjectAtIndex:1 toClass:"NSColor"] ;
        [cp setColor:theColor] ;
    }
    [skin pushNSObject:[cp color]] ;
    return 1 ;
}

static int colorPanelMode(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TSTRING | LS_TOPTIONAL, LS_TBREAK] ;
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    if (lua_gettop(L) == 1) {
        NSString *theMode = [skin toNSObjectAtIndex:1] ;
        if ([theMode isEqualToString:@"none"]) {
            [cp setMode:NSNoModeColorPanel];
        } else if ([theMode isEqualToString:@"gray"]) {
            [cp setMode:NSGrayModeColorPanel];
        } else if ([theMode isEqualToString:@"RGB"]) {
            [cp setMode:NSRGBModeColorPanel];
        } else if ([theMode isEqualToString:@"CMYK"]) {
            [cp setMode:NSCMYKModeColorPanel];
        } else if ([theMode isEqualToString:@"HSB"]) {
            [cp setMode:NSHSBModeColorPanel];
        } else if ([theMode isEqualToString:@"custom"]) {
            [cp setMode:NSCustomPaletteModeColorPanel];
        } else if ([theMode isEqualToString:@"list"]) {
            [cp setMode:NSColorListModeColorPanel];
        } else if ([theMode isEqualToString:@"wheel"]) {
            [cp setMode:NSWheelModeColorPanel];
        } else if ([theMode isEqualToString:@"crayon"]) {
            [cp setMode:NSCrayonModeColorPanel];
        } else {
            return luaL_error(L, "unknown color panel mode") ;
        }
    }
    switch([cp mode]) {
        case NSNoModeColorPanel:            [skin pushNSObject:@"none"] ; break ;
        case NSGrayModeColorPanel:          [skin pushNSObject:@"gray"] ; break ;
        case NSRGBModeColorPanel:           [skin pushNSObject:@"RGB"] ; break ;
        case NSCMYKModeColorPanel:          [skin pushNSObject:@"CMYK"] ; break ;
        case NSHSBModeColorPanel:           [skin pushNSObject:@"HSB"] ; break ;
        case NSCustomPaletteModeColorPanel: [skin pushNSObject:@"custom"] ; break ;
        case NSColorListModeColorPanel:     [skin pushNSObject:@"list"] ; break ;
        case NSWheelModeColorPanel:         [skin pushNSObject:@"wheel"] ; break ;
        case NSCrayonModeColorPanel:        [skin pushNSObject:@"crayon"] ; break ;
        default:
            [skin pushNSObject:[NSString stringWithFormat:@"** unrecognized mode:%ld", [cp mode]]] ;
            break ;
    }
    return 1;
}

static int colorPanelAlpha(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    lua_pushnumber(L, [[NSColorPanel sharedColorPanel] alpha]) ;
    return 1 ;
}

static int colorPanelShow(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    [NSApp orderFrontColorPanel:nil] ;
    return 0 ;
}

static int colorPanelHide(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    [[NSColorPanel sharedColorPanel] close] ;
    return 0 ;
}

#pragma mark - Font Panel Functions

static HSFontPanel *fpReceiverObject ;

static int fontPanelCallback(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK] ;

    if (fpReceiverObject.callbackRef != LUA_NOREF) {
        [skin pushLuaRef:refTable ref:fpReceiverObject.callbackRef] ;
    } else {
        lua_pushnil(L) ;
    }
    if (lua_gettop(L) == 2) { // we just added to it...
        // in either case, we need to remove an existing callback, so...
        fpReceiverObject.callbackRef = [skin luaUnref:refTable ref:fpReceiverObject.callbackRef] ;
        if (lua_type(L, 1) == LUA_TFUNCTION) {
            lua_pushvalue(L, 1) ;
            fpReceiverObject.callbackRef = [skin luaRef:refTable] ;
        }
    }
    // return the *last* fn (or nil) so you can save it and re-attach it if something needs to
    // temporarily take the callbacks
    return 1 ;
}

static int fontPanelShow(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    [NSApp orderFrontFontPanel:nil] ;
    return 0 ;
}

static int fontPanelHide(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TBREAK] ;
    [[NSFontPanel sharedFontPanel] close] ;
    return 0 ;
}

#pragma mark - Hammerspoon/Lua Infrastructure

static int releaseReceivers(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    [[NSNotificationCenter defaultCenter] removeObserver:cpReceiverObject
                                                    name:NSWindowWillCloseNotification
                                                  object:cp] ;
    [cp setTarget:nil];
    [cp setAction:nil];
    if (cpReceiverObject.callbackRef != LUA_NOREF) [skin luaUnref:refTable ref:cpReceiverObject.callbackRef] ;
    [cp close];
    cpReceiverObject = nil ;

    NSFontPanel *fp = [NSFontPanel sharedFontPanel];
    NSFontManager *fm = [NSFontManager sharedFontManager];
    [[NSNotificationCenter defaultCenter] removeObserver:fpReceiverObject
                                                    name:NSWindowWillCloseNotification
                                                  object:fp] ;
    if (fpReceiverObject.callbackRef != LUA_NOREF) [skin luaUnref:refTable ref:fpReceiverObject.callbackRef] ;
    [fm setTarget:nil] ;
    fpReceiverObject = nil ;
    return 0 ;
}

static luaL_Reg moduleLib[] = {
    {NULL,    NULL}
};

static luaL_Reg colorPanelLib[] = {
    {"alpha",      colorPanelAlpha},
    {"callback",   colorPanelCallback},
    {"color",      colorPanelColor},
    {"continuous", colorPanelContinuous},
    {"mode",       colorPanelMode},
    {"showsAlpha", colorPanelShowsAlpha},
    {"show",       colorPanelShow},
    {"hide",       colorPanelHide},
    {NULL,         NULL}
};

static luaL_Reg fontPanelLib[] = {
    {"show",     fontPanelShow},
    {"hide",     fontPanelHide},
    {"callback", fontPanelCallback},

    {NULL,   NULL}
};

static luaL_Reg module_metaLib[] = {
    {"__gc", releaseReceivers},
    {NULL,   NULL}
};

int luaopen_hs__asm_panels_internal(lua_State* __unused L) {
    LuaSkin *skin = [LuaSkin shared];
    refTable = [skin registerLibrary:moduleLib metaFunctions:module_metaLib] ;

    luaL_newlib(L, colorPanelLib) ; lua_setfield(L, -2, "color") ;
    [NSColorPanel setPickerMask:NSColorPanelAllModesMask] ;
    cpReceiverObject = [[HSColorPanel alloc] init] ;
    fpReceiverObject = [[HSFontPanel alloc] init] ;
    luaL_newlib(L, fontPanelLib) ;  lua_setfield(L, -2, "font") ;

    return 1;
}
