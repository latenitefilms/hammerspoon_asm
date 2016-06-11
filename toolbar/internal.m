// Max Width at 327?
@import Cocoa ;
@import LuaSkin ;

#define USERDATA_TAG  "hs._asm.toolbar"
static int            refTable = LUA_NOREF;
static NSMutableArray *identifiersInUse ;

// Can't have "static" or "constant" dynamic NSObjects like NSArray, so define in lua_open
static NSArray *builtinToolbarItems;
static NSArray *automaticallyIncluded ;
static NSArray *keysToKeepFromDefinitionDictionary ;
static NSArray *keysToKeepFromGroupDefinition ;

#define get_objectFromUserdata(objType, L, idx, tag) (objType*)*((void**)luaL_checkudata(L, idx, tag))
// #define get_structFromUserdata(objType, L, idx, tag) ((objType *)luaL_checkudata(L, idx, tag))
// #define get_cfobjectFromUserdata(objType, L, idx, tag) *((objType *)luaL_checkudata(L, idx, tag))

@interface MJConsoleWindowController : NSWindowController
+ (instancetype)singleton;
- (void)setup;
@end

@interface ASMToolbarSearchField : NSSearchField
@property (weak)     NSToolbarItem *toolbarItem ;

- (instancetype)init ;
- (void)searchCallback:(NSMenuItem *)sender ;
@end

@interface HSToolbar : NSToolbar <NSToolbarDelegate>
@property            int                 selfRef;
@property            int                 callbackRef;
@property            BOOL                notifyToolbarChanges ;
@property (weak)     NSWindow            *windowUsingToolbar ;
@property (readonly) NSMutableOrderedSet *allowedIdentifiers ;
@property (readonly) NSMutableOrderedSet *defaultIdentifiers ;
@property (readonly) NSMutableOrderedSet *selectableIdentifiers ;
@property (readonly) NSMutableDictionary *itemDefDictionary ;
// This can differ if the toolbar is in multiple windows
@property (readonly) NSMutableDictionary *fnRefDictionary ;
@property (readonly) NSMutableDictionary *enabledDictionary ;
@end

// *id                 *default       *selectable
//  enabled             fn             searchfield
//  label               tooltip        priority
//  tag                 image         -searchMinWidth
// *searchMaxWidth      searchText     searchPredefinedSearches
//  searchHistoryLimit  searchHistory  searchHistoryAutoSaveName

#pragma mark - Support Functions and Classes

// Create the default searchField menu: Recent Searches, Clear, etc.
static NSMenu *createCoreSearchFieldMenu() {
    NSMenu *searchMenu = [[NSMenu alloc] initWithTitle:@"Search Menu"];
    searchMenu.autoenablesItems = YES;

    NSMenuItem *recentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"Recent Searches" action:nil keyEquivalent:@""];
    recentsTitleItem.tag         = NSSearchFieldRecentsTitleMenuItemTag;
    [searchMenu insertItem:recentsTitleItem atIndex:0];

    NSMenuItem *norecentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"No recent searches" action:nil keyEquivalent:@""];
    norecentsTitleItem.tag         = NSSearchFieldNoRecentsMenuItemTag;
    [searchMenu insertItem:norecentsTitleItem atIndex:1];

    NSMenuItem *recentsItem = [[NSMenuItem alloc] initWithTitle:@"Recents" action:nil keyEquivalent:@""];
    recentsItem.tag         = NSSearchFieldRecentsMenuItemTag;
    [searchMenu insertItem:recentsItem atIndex:2];

    NSMenuItem *separatorItem = (NSMenuItem*)[NSMenuItem separatorItem];
    [searchMenu insertItem:separatorItem atIndex:3];

    NSMenuItem *clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear" action:nil keyEquivalent:@""];
    clearItem.tag         = NSSearchFieldClearRecentsMenuItemTag;
    [searchMenu insertItem:clearItem atIndex:4];
    return searchMenu ;
}

@implementation HSToolbar
- (instancetype)initWithIdentifier:(NSString *)identifier itemTableIndex:(int)idx {
    self = [super initWithIdentifier:identifier] ;
    if (self) {
        _allowedIdentifiers    = [[NSMutableOrderedSet alloc] init] ;
        _defaultIdentifiers    = [[NSMutableOrderedSet alloc] init] ;
        _selectableIdentifiers = [[NSMutableOrderedSet alloc] init] ;
        _itemDefDictionary     = [[NSMutableDictionary alloc] init] ;
        _fnRefDictionary       = [[NSMutableDictionary alloc] init] ;
        _enabledDictionary     = [[NSMutableDictionary alloc] init] ;

        _callbackRef           = LUA_NOREF;
        _selfRef               = LUA_NOREF;
        _windowUsingToolbar    = nil ;
        _notifyToolbarChanges  = NO ;

        [_allowedIdentifiers addObjectsFromArray:automaticallyIncluded] ;

        LuaSkin     *skin      = [LuaSkin shared] ;
        lua_State   *L         = [skin L] ;
        lua_Integer count      = luaL_len(L, idx) ;
        lua_Integer index      = 0 ;
        BOOL        isGood     = YES ;

        idx = lua_absindex(L, idx) ;
        while (isGood && (index < count)) {
            if (lua_rawgeti(L, idx, index + 1) == LUA_TTABLE) {
                isGood = [self addToolbarDefinitionAtIndex:-1] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:not a table at index %lld in toolbar %@", USERDATA_TAG, index + 1, identifier]] ;
                isGood = NO ;
            }
            lua_pop(L, 1) ;
            index++ ;
        }

        if (!isGood) {
            [skin logError:[NSString stringWithFormat:@"%s:malformed toolbar items encountered", USERDATA_TAG]] ;
            return nil ;
        }

        self.allowsUserCustomization = NO ;
        self.allowsExtensionItems    = NO ;
        self.autosavesConfiguration  = NO ;
        self.delegate                = self ;
    }
    return self ;
}

- (instancetype)initWithCopy:(HSToolbar *)original {
    LuaSkin *skin = [LuaSkin shared] ;
    if (original) self = [super initWithIdentifier:original.identifier] ;
    if (self) {
        _selfRef               = LUA_NOREF;
        _callbackRef           = LUA_NOREF ;
        if (original.callbackRef != LUA_NOREF) {
            [skin pushLuaRef:refTable ref:original.callbackRef] ;
            _callbackRef = [skin luaRef:refTable] ;
        }
        _allowedIdentifiers    = original.allowedIdentifiers ;
        _defaultIdentifiers    = original.defaultIdentifiers ;
        _selectableIdentifiers = original.selectableIdentifiers ;
        _notifyToolbarChanges  = original.notifyToolbarChanges ;
        _windowUsingToolbar    = nil ;

        self.allowsUserCustomization = original.allowsUserCustomization ;
        self.allowsExtensionItems    = original.allowsExtensionItems ;
        self.autosavesConfiguration  = original.autosavesConfiguration ;

        _itemDefDictionary = original.itemDefDictionary ;
        _enabledDictionary = [[NSMutableDictionary alloc] initWithDictionary:original.enabledDictionary
                                                                   copyItems:YES] ;
        _fnRefDictionary   = [[NSMutableDictionary alloc] init] ;
        for (NSString *key in [original.fnRefDictionary allKeys]) {
            int theRef = [[original.fnRefDictionary objectForKey:key] intValue] ;
            if (theRef != LUA_NOREF) {
                [skin pushLuaRef:refTable ref:theRef] ;
                theRef = [skin luaRef:refTable] ;
            }
            _fnRefDictionary[key] = @(theRef) ;
        }

        self.delegate = self ;
    }
    return self ;
}

- (void)performCallback:(id)sender{
    NSString      *searchText = nil ;
    NSToolbarItem *item       = nil ;
    int           argCount    = 3 ;

    if ([sender isKindOfClass:[NSToolbarItem class]]) {
        item = sender ;
    } else if ([sender isKindOfClass:[ASMToolbarSearchField class]]) {
        searchText = [sender stringValue] ;
        item       = [sender toolbarItem] ;
        argCount++ ;
    } else {
        [LuaSkin logError:[NSString stringWithFormat:@"%s:Unknown object sent to callback:%@", USERDATA_TAG, [sender debugDescription]]] ;
        return ;
    }

    NSNumber *theFnRef = [_fnRefDictionary objectForKey:[item itemIdentifier]] ;
    int itemFnRef = theFnRef ? [theFnRef intValue] : LUA_NOREF ;
    int fnRef = (itemFnRef != LUA_NOREF) ? itemFnRef : _callbackRef ;
    if (fnRef != LUA_NOREF) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow  *ourWindow = self.windowUsingToolbar ;
            LuaSkin   *skin      = [LuaSkin shared] ;
            lua_State *L         = [skin L] ;
            [skin pushLuaRef:refTable ref:fnRef] ;
            [skin pushNSObject:self] ;
            if (ourWindow) {
                if ([ourWindow isEqualTo:[[MJConsoleWindowController singleton] window]]) {
                    lua_pushstring(L, "console") ;
                } else {
                    [skin pushNSObject:ourWindow withOptions:LS_NSDescribeUnknownTypes] ;
                }
            } else {
                // shouldn't be possible, but just in case...
                lua_pushstring(L, "** no window attached") ;
            }
            [skin pushNSObject:[item itemIdentifier]] ;
            if (argCount == 4) [skin pushNSObject:searchText] ;
            if (![skin protectedCallAndTraceback:argCount nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: item callback error, %s, for toolbar item %@", USERDATA_TAG, lua_tostring(L, -1), [item itemIdentifier]]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem {
    return [_enabledDictionary[theItem.itemIdentifier] boolValue] ;
}

- (BOOL)isAttachedToWindow {
    NSWindow *ourWindow = _windowUsingToolbar ;
    BOOL attached       = ourWindow && [self isEqualTo:[ourWindow toolbar]] ;
    if (!attached) ourWindow = nil ; // just to keep it correct
    return attached ;
}

// TODO ? if validate of data method added, use here during construction

- (BOOL)addToolbarDefinitionAtIndex:(int)idx {
    LuaSkin   *skin      = [LuaSkin shared] ;
    lua_State *L         = [skin L] ;
    idx = lua_absindex(L, idx) ;

    NSString *identifier = (lua_getfield(L, -1, "id") == LUA_TSTRING) ?
                                          [skin toNSObjectAtIndex:-1] : nil ;
    lua_pop(L, 1) ;

    // Make sure unique
    if (!identifier) {
        [skin  logWarn:[NSString stringWithFormat:@"%s:id must be present, and it must be a string",
                                                   USERDATA_TAG]] ;
        return NO ;
    } else if ([_itemDefDictionary objectForKey:identifier]) {
        [skin  logWarn:[NSString stringWithFormat:@"%s:identifier %@ must be unique or a system defined item",
                                                   USERDATA_TAG, identifier]] ;
        return NO ;
    }

    // Get fields that aren't modifiable after construction
    BOOL included   = (lua_getfield(L, idx, "default") == LUA_TBOOLEAN) ? (BOOL)lua_toboolean(L, -1) : YES ;
    BOOL selectable = (lua_getfield(L, idx, "selectable") == LUA_TBOOLEAN) ? (BOOL)lua_toboolean(L, -1) : NO ;
    lua_pop(L, 2) ;

    // default to enabled
    _enabledDictionary[identifier] = @(YES) ;

    // default to allowedAlone
    BOOL allowedAlone = YES ;

    // If it's built-in, we already have what we need, and if it isn't...
    if (![builtinToolbarItems containsObject:identifier]) {
        NSMutableDictionary *toolbarItem     = [[NSMutableDictionary alloc] init] ;

        lua_pushnil(L);  /* first key */
        while (lua_next(L, idx) != 0) { /* uses 'key' (at index -2) and 'value' (at index -1) */
            if (lua_type(L, -2) == LUA_TSTRING) {
                NSString *keyName = [skin toNSObjectAtIndex:-2] ;
//                 NSLog(@"%@:%@", identifier, keyName) ;
                if (![keysToKeepFromDefinitionDictionary containsObject:keyName]) {
                    if (lua_type(L, -1) != LUA_TFUNCTION) {
                        toolbarItem[keyName] = [skin toNSObjectAtIndex:-1] ;
                    } else if ([keyName isEqualToString:@"fn"]) {
                        lua_pushvalue(L, -1) ;
                        _fnRefDictionary[identifier] = @([skin luaRef:refTable]) ;
                    }
                }
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:non-string keys not allowed for toolbar item %@ definition", USERDATA_TAG, identifier]] ;
                lua_pop(L, 2) ;
                return NO ;
            }
            /* removes 'value'; keeps 'key' for next iteration */
            lua_pop(L, 1);
        }

        if (!toolbarItem[@"label"]) toolbarItem[@"label"] = identifier ;
        if (toolbarItem[@"allowedAlone"]) {
            if ([toolbarItem[@"allowedAlone"] isKindOfClass:[NSNumber class]] && ![toolbarItem[@"allowedAlone"] boolValue]) {
                allowedAlone = NO ;
            }
            [toolbarItem removeObjectForKey:@"allowedAlone"] ;
        }
        if (selectable) [_selectableIdentifiers addObject:identifier] ;
        _itemDefDictionary[identifier] = toolbarItem ;
    }
    // by adjusting _allowedIdentifiers out here, we allow builtin items, even if we don't exactly
    // advertise them, plus we may add support for duplicate id's at some point if someone comes up with
    // a reason...
    if (![_allowedIdentifiers containsObject:identifier] && allowedAlone)
        [_allowedIdentifiers addObject:identifier] ;
    if (included)
        [_defaultIdentifiers addObject:identifier] ;

    return YES ;
}

// called from addToolbarDefinitionAtIndex:, so item dictionary is the initial definition, and view resizing is held off until item added to group, if any
- (void)fillinNewToolbarItem:(NSToolbarItem *)item {
    [self updateToolbarItem:item
             withDictionary:_itemDefDictionary[item.itemIdentifier]
             withViewResize:NO] ;
}

// called from modifyToolbarItem, so item dictionary should only be updates, and view should be resize should occur normally
- (void)updateToolbarItem:(NSToolbarItem *)item
           withDictionary:(NSMutableDictionary *)itemDefinition {
    [self updateToolbarItem:item
             withDictionary:itemDefinition
             withViewResize:YES] ;
}

// TODO ? separate validation of data from apply to live/create new item ? may be cleaner...

- (void)updateToolbarItem:(NSToolbarItem *)item
           withDictionary:(NSMutableDictionary *)itemDefinition
           withViewResize:(BOOL)resizeView {
    if ([itemDefinition count] == 0) return ;

    LuaSkin               *skin       = [LuaSkin shared] ;
    ASMToolbarSearchField *itemView   = (ASMToolbarSearchField *)item.view ;
    NSString              *identifier = item.itemIdentifier ;

    NSSize minSearchSize = [itemView isKindOfClass:[ASMToolbarSearchField class]] ? item.minSize : NSZeroSize ;

// NSLog(@"enter updateToolbarItem with %@", itemDefinition) ;
    // need to take care of this first in case we need to create the searchfield view...
    id keyValue = itemDefinition[@"searchfield"] ;
    if (keyValue) {
        if ([keyValue isKindOfClass:[NSNumber class]] && !strcmp(@encode(BOOL), [keyValue objCType])) {
            if ([keyValue boolValue]) {
                if (![itemView isKindOfClass:[ASMToolbarSearchField class]]) {
                    if (!itemView) {
                        itemView             = [[ASMToolbarSearchField alloc] init];
                        itemView.toolbarItem = item ;
                        itemView.target      = self ;
                        itemView.action      = @selector(performCallback:) ;
                        item.view            = itemView ;
                        minSearchSize        = itemView.frame.size ;
                    } else {
                        [skin logWarn:[NSString stringWithFormat:@"%s:view for toolbar item %@ is not our searchfield... cowardly avoiding replacement", USERDATA_TAG, identifier]] ;
                    }
                } // else it already exists, so don't re-create it
            } else {
                if (itemView) {
                    if (![itemView isKindOfClass:[ASMToolbarSearchField class]]) {
                        [skin logWarn:[NSString stringWithFormat:@"%s:view for toolbar item %@ is not our searchfield... cowardly avoiding removal", USERDATA_TAG, identifier]] ;
                    } else {
                        item.view = nil ;
                        itemView  = nil ;
                    }
                } // else it doesn't exist, so nothing to remove
            }

        } else {
            [skin logWarn:[NSString stringWithFormat:@"%s:searchfield for %@ must be a boolean", USERDATA_TAG, identifier]] ;
            [itemDefinition removeObjectForKey:@"searchfield"] ;
        }
    }

// NSLog(@"past searchField") ;
    for (NSString *keyName in [itemDefinition allKeys]) {
// NSLog(@"in keyLoop") ;
        keyValue = itemDefinition[keyName] ;

        if ([keyName isEqualToString:@"enable"]) {
            if ([keyValue isKindOfClass:[NSNumber class]] && !strcmp(@encode(BOOL), [keyValue objCType])) {
                _enabledDictionary[identifier] = itemDefinition[keyName] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a boolean", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"fn"]) {
            if (_fnRefDictionary[identifier] && [_fnRefDictionary[identifier] intValue] != LUA_NOREF) {
                [skin luaUnref:refTable ref:[_fnRefDictionary[identifier] intValue]] ;
            }
            [skin pushLuaRef:refTable ref:[itemDefinition[keyName] intValue]] ;
            _fnRefDictionary[identifier] = @([skin luaRef:refTable]) ;
        } else if ([keyName isEqualToString:@"label"]) {
            if ([keyValue isKindOfClass:[NSString class]]) {
// for grouped sets, the palette label *must* be set or unset in sync with label, otherwise it only shows some of the individual labels... so simpler to just forget that there are actually two labels. Very few will likely care/notice anyways.
                    item.label        = keyValue ;
                    item.paletteLabel = keyValue ;
            } else {
                if ([keyValue isKindOfClass:[NSNumber class]] && ![keyValue boolValue]) {
                    if ([item isKindOfClass:[NSToolbarItemGroup class]]) {
// this is the only way to switch a grouped set's individual labels back on after turning them off by setting a group label...
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
                        ((NSToolbarItemGroup *)item).label        = nil ;
                        ((NSToolbarItemGroup *)item).paletteLabel = nil ;
#pragma clang diagnostic pop
                    } else {
                        item.label        = @"" ;
                        item.paletteLabel = identifier ;
                    }
                } else {
                    [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a string, or false to clear", USERDATA_TAG, keyName, identifier]] ;
                }
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"tooltip"]) {
            if ([keyValue isKindOfClass:[NSString class]]) {
                item.toolTip = keyValue ;
            } else {
                if ([keyValue isKindOfClass:[NSNumber class]] && ![keyValue boolValue]) {
                    item.toolTip = nil ;
                } else {
                    [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a string, or false to clear", USERDATA_TAG, keyName, identifier]] ;
                }
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"priority"]) {
            if ([keyValue isKindOfClass:[NSNumber class]]) {
                item.visibilityPriority = [keyValue intValue] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an integer", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"tag"]) {
            if ([keyValue isKindOfClass:[NSNumber class]]) {
                item.tag = [keyValue intValue] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an integer", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"image"]) {
            if ([keyValue isKindOfClass:[NSImage class]]) {
                item.image = keyValue ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an hs.image obejct", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }

        } else if ([keyName isEqualToString:@"groupMembers"] && [item isKindOfClass:[NSToolbarItemGroup class]]) {
            if ([keyValue isKindOfClass:[NSArray class]]) {
                BOOL allGood = YES ;
                for (NSString *lineItem in (NSArray *)keyValue) {
                    if (![lineItem isKindOfClass:[NSString class]]) {
                        allGood = NO ;
                        break ;
                    }
                }
                if (allGood) {

// FIXME Put the following into a method so can be called from here and delegate?
// Dumb ass... the delegate calls this... won't work as stands, though... the following only works for existing NSToolbarItemGroup... which won't exist for the first call by toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar: -- this needs to handle both -- existing or new, then clean up toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:... until then, groups are totally fubar.

                    NSMutableArray *groupedItems = [[NSMutableArray alloc] init] ;
                    for (NSString *memberIdentifier in (NSArray *)keyValue) {
                        NSToolbarItem *memberItem = [[NSToolbarItem alloc] initWithItemIdentifier:memberIdentifier] ;
                        memberItem.target  = self ;
                        memberItem.action  = @selector(performCallback:) ;

                        memberItem.enabled = [_enabledDictionary[memberIdentifier] boolValue] ;
                        [self fillinNewToolbarItem:memberItem] ;
                        [groupedItems addObject:memberItem] ;
                    }
                    ((NSToolbarItemGroup *)item).subitems = groupedItems ;
                    // see "NSToolbarItemGroup is dumb" below... size of item views needs to be adjusted *after* adding them to the group...
                    for (NSToolbarItem* tmpItem in ((NSToolbarItemGroup *)item).subitems) {
                        if ([tmpItem.view isKindOfClass:[ASMToolbarSearchField class]]) {
                            NSDictionary *tmpItemDictionary = _itemDefDictionary[tmpItem.itemIdentifier] ;
                            ASMToolbarSearchField *searchView = (ASMToolbarSearchField *)tmpItem.view ;
                            NSRect searchFieldFrame = searchView.frame ;
                            tmpItem.minSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
                            if (tmpItemDictionary[@"searchMaxWidth"]) {
                                searchFieldFrame.size.width = [tmpItemDictionary[@"searchMaxWidth"] doubleValue] ;
                                searchView.frame            = searchFieldFrame ;
                            }
                            tmpItem.maxSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
                        }
                    }
                    // NSToolbarItemGroup is dumb...
                    // see http://stackoverflow.com/questions/15949835/nstoolbaritemgroup-doesnt-work
                    NSSize minSize = NSZeroSize;
                    NSSize maxSize = NSZeroSize;
                    for (NSToolbarItem* tmpItem in ((NSToolbarItemGroup *)item).subitems) {
                        minSize.width += tmpItem.minSize.width;
                        minSize.height = fmax(minSize.height, tmpItem.minSize.height);
                        maxSize.width += tmpItem.maxSize.width;
                        maxSize.height = fmax(maxSize.height, tmpItem.maxSize.height);
                    }
                    item.minSize = minSize;
                    item.maxSize = maxSize;


                } else {
                    [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array of strings", USERDATA_TAG, keyName, identifier]] ;
                    [itemDefinition removeObjectForKey:keyName] ;
                }
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }


        } else if ([keyName isEqualToString:@"searchMaxWidth"] && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSNumber class]]) {
                // we only actually resize if this is a modify request... but the above test at least makes sure that what reaches the right code in toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar: is a number and not garbage
                if (resizeView) {
                    NSRect fieldFrame     = itemView.frame ;
                    fieldFrame.size.width = [keyValue doubleValue] ;
                    itemView.frame        = fieldFrame ;
                    item.minSize          = minSearchSize ;
                    item.maxSize          = NSMakeSize([keyValue doubleValue], minSearchSize.height) ;
                }
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a number", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"searchText"] && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSString class]]) {
                itemView.stringValue = keyValue ;
            } else if ([keyValue isKindOfClass:[NSNumber class]]) {
                itemView.stringValue = [keyValue stringValue] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a string", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"searchPredefinedSearches"]  && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSArray class]]) {
                BOOL allGood = YES ;
                for (NSString *lineItem in (NSArray *)keyValue) {
                    if (![lineItem isKindOfClass:[NSString class]]) {
                        allGood = NO ;
                        break ;
                    }
                }
                if (allGood) {
                    NSMenu *searchMenu = createCoreSearchFieldMenu() ;
                    NSMenu *predefinedSearchMenu = [[NSMenu alloc] initWithTitle:@"Predefined Search Menu"] ;
                    for (NSString *menuItemText in (NSArray *)keyValue) {
                        NSMenuItem* newMenuItem = [[NSMenuItem alloc] initWithTitle:menuItemText
                                                                             action:@selector(searchCallback:)
                                                                      keyEquivalent:@""] ;
                        newMenuItem.target = itemView ;
                        [predefinedSearchMenu addItem:newMenuItem];
                    }

                    NSMenuItem *predefinedSearches = [[NSMenuItem alloc] initWithTitle:@"Predefined Searches" action:nil keyEquivalent:@""] ;
                    predefinedSearches.submenu     = predefinedSearchMenu ;
                    [searchMenu insertItem:predefinedSearches atIndex:0] ;
                    [searchMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
                    ((NSSearchFieldCell *)itemView.cell).searchMenuTemplate = searchMenu ;
                } else {
                    [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array of strings", USERDATA_TAG, keyName, identifier]] ;
                    [itemDefinition removeObjectForKey:keyName] ;
                }
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"searchHistoryLimit"] && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSNumber class]]) {
                ((NSSearchFieldCell *)itemView.cell).maximumRecents = [keyValue intValue] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an integer", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"searchHistory"] && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSArray class]]) {
                BOOL allGood = YES ;
                for (NSString *lineItem in (NSArray *)keyValue) {
                    if (![lineItem isKindOfClass:[NSString class]]) {
                        allGood = NO ;
                        break ;
                    }
                }
                if (allGood) {
                    ((NSSearchFieldCell *)itemView.cell).recentSearches = keyValue ;
                } else {
                    [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array of strings", USERDATA_TAG, keyName, identifier]] ;
                    [itemDefinition removeObjectForKey:keyName] ;
                }
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be an array", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if ([keyName isEqualToString:@"searchHistoryAutoSaveName"] && [itemView isKindOfClass:[ASMToolbarSearchField class]]) {
            if ([keyValue isKindOfClass:[NSString class]]) {
                ((NSSearchFieldCell *)itemView.cell).recentsAutosaveName = keyValue ;
            } else if ([keyValue isKindOfClass:[NSNumber class]]) {
                ((NSSearchFieldCell *)itemView.cell).recentsAutosaveName = [keyValue stringValue] ;
            } else {
                [skin logWarn:[NSString stringWithFormat:@"%s:%@ for %@ must be a string", USERDATA_TAG, keyName, identifier]] ;
                [itemDefinition removeObjectForKey:keyName] ;
            }
        } else if (![keyName isEqualToString:@"searchfield"]) { // handled before loop, but we don't want to clear it, either
            [skin logVerbose:[NSString stringWithFormat:@"%s:%@ is not a valid field for %@; ignoring", USERDATA_TAG, keyName, identifier]] ;
            [itemDefinition removeObjectForKey:keyName] ;
        }
    }
// NSLog(@"past keyLoop") ;
    // if we weren't send the actual item's full dictionary, then this must be an update... update the item's full definition so that it's available for the configuration panel and for duplicate toolbars
    if (_itemDefDictionary[identifier] != itemDefinition) {
        [_itemDefDictionary[identifier] addEntriesFromDictionary:itemDefinition] ;
    }
// NSLog(@"past dictionaryUpdate") ;
}

#pragma mark - NSToolbarDelegate stuff

// FIXME needs to be re-written with fillinNewToolbarItem: doing the heavy lifting for groups and searchfields... this should be creation of top-level items only

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSDictionary  *itemDefinition = _itemDefDictionary[identifier] ;
    NSToolbarItem *toolbarItem ;

    if (itemDefinition) {
        if (itemDefinition[@"groupMembers"]) {
            NSToolbarItemGroup *toolbarItemGroup = [[NSToolbarItemGroup alloc] initWithItemIdentifier:identifier] ;
            toolbarItemGroup.enabled = flag ? [_enabledDictionary[identifier] boolValue] : YES ;
            [self fillinNewToolbarItem:toolbarItemGroup] ;
            NSMutableArray *groupedItems = [[NSMutableArray alloc] init] ;
            for (NSString *memberIdentifier in itemDefinition[@"groupMembers"]) {
                NSToolbarItem *memberItem = [[NSToolbarItem alloc] initWithItemIdentifier:memberIdentifier] ;
                memberItem.target  = toolbar ;
                memberItem.action  = @selector(performCallback:) ;
                memberItem.enabled = flag ? [_enabledDictionary[memberIdentifier] boolValue] : YES ;
                [self fillinNewToolbarItem:memberItem] ;
                [groupedItems addObject:memberItem] ;
            }
            toolbarItemGroup.subitems = groupedItems ;
            // see "NSToolbarItemGroup is dumb" below... size of item views needs to be adjusted *after* adding them to the group...
            for (NSToolbarItem* tmpItem in toolbarItemGroup.subitems) {
                if ([tmpItem.view isKindOfClass:[ASMToolbarSearchField class]]) {
                    NSDictionary *tmpItemDictionary = _itemDefDictionary[tmpItem.itemIdentifier] ;
                    ASMToolbarSearchField *searchView = (ASMToolbarSearchField *)tmpItem.view ;
                    NSRect searchFieldFrame = searchView.frame ;
                    tmpItem.minSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
                    if (tmpItemDictionary[@"searchMaxWidth"]) {
                        searchFieldFrame.size.width = [tmpItemDictionary[@"searchMaxWidth"] doubleValue] ;
                        searchView.frame            = searchFieldFrame ;
                    }
                    tmpItem.maxSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
                }
            }
            // NSToolbarItemGroup is dumb...
            // see http://stackoverflow.com/questions/15949835/nstoolbaritemgroup-doesnt-work
            NSSize minSize = NSZeroSize;
            NSSize maxSize = NSZeroSize;
            for (NSToolbarItem* tmpItem in toolbarItemGroup.subitems) {
                minSize.width += tmpItem.minSize.width;
                minSize.height = fmax(minSize.height, tmpItem.minSize.height);
                maxSize.width += tmpItem.maxSize.width;
                maxSize.height = fmax(maxSize.height, tmpItem.maxSize.height);
            }
            toolbarItemGroup.minSize = minSize;
            toolbarItemGroup.maxSize = maxSize;

            toolbarItem = toolbarItemGroup ;
        } else {
            toolbarItem = [[NSToolbarItem alloc] initWithItemIdentifier:identifier] ;
            toolbarItem.target  = toolbar ;
            toolbarItem.action  = @selector(performCallback:) ;
            toolbarItem.enabled = flag ? [_enabledDictionary[identifier] boolValue] : YES ;
            [self fillinNewToolbarItem:toolbarItem] ;
            if ([toolbarItem.view isKindOfClass:[ASMToolbarSearchField class]]) {
                ASMToolbarSearchField *searchView = (ASMToolbarSearchField *)toolbarItem.view ;
                NSRect searchFieldFrame = searchView.frame ;
                toolbarItem.minSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
                if (itemDefinition[@"searchMaxWidth"]) {
                    searchFieldFrame.size.width = [itemDefinition[@"searchMaxWidth"] doubleValue] ;
                    searchView.frame            = searchFieldFrame ;
                }
                toolbarItem.maxSize     = NSMakeSize(searchFieldFrame.size.width, searchFieldFrame.size.height) ;
            }
        }
    } else {
        // shouldn't happen, but...
        [LuaSkin logWarn:[NSString stringWithFormat:@"%s:toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar: invoked with non-existent identifier:%@", USERDATA_TAG, identifier]] ;
    }
    return toolbarItem ;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(__unused NSToolbar *)toolbar  {
//     [LuaSkin logWarn:@"in toolbarAllowedItemIdentifiers"] ;
    return [_allowedIdentifiers array] ;
}

- (NSArray *)toolbarDefaultItemIdentifiers:(__unused NSToolbar *)toolbar {
//     [LuaSkin logWarn:@"in toolbarDefaultItemIdentifiers"] ;
    return [_defaultIdentifiers array] ;
}

- (NSArray *)toolbarSelectableItemIdentifiers:(__unused NSToolbar *)toolbar {
//     [LuaSkin logWarn:@"in toolbarSelectableItemIdentifiers"] ;
    return [_selectableIdentifiers array] ;
}

- (void)toolbarWillAddItem:(NSNotification *)notification {
    if (_notifyToolbarChanges && (_callbackRef != LUA_NOREF)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow  *ourWindow = self.windowUsingToolbar ;
            LuaSkin   *skin      = [LuaSkin shared] ;
            lua_State *L         = [skin L] ;
            [skin pushLuaRef:refTable ref:self.callbackRef] ;
            [skin pushNSObject:self] ;
            if (ourWindow) {
                if ([ourWindow isEqualTo:[[MJConsoleWindowController singleton] window]]) {
                    lua_pushstring(L, "console") ;
                } else {
                    [skin pushNSObject:ourWindow withOptions:LS_NSDescribeUnknownTypes] ;
                }
            } else {
                // shouldn't be possible, but just in case...
                lua_pushstring(L, "** no window attached") ;
            }
            [skin pushNSObject:[notification.userInfo[@"item"] itemIdentifier]] ;
            lua_pushstring(L, "add") ;
            if (![skin protectedCallAndTraceback:4 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: toolbar callback error, %s, when notifying addition of toolbar item %@", USERDATA_TAG, lua_tostring(L, -1), [notification.userInfo[@"item"] itemIdentifier]]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

- (void)toolbarDidRemoveItem:(NSNotification *)notification {
    if (_notifyToolbarChanges && (_callbackRef != LUA_NOREF)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow  *ourWindow = self.windowUsingToolbar ;
            LuaSkin   *skin      = [LuaSkin shared] ;
            lua_State *L         = [skin L] ;
            [skin pushLuaRef:refTable ref:self.callbackRef] ;
            [skin pushNSObject:self] ;
            if (ourWindow) {
                if ([ourWindow isEqualTo:[[MJConsoleWindowController singleton] window]]) {
                    lua_pushstring(L, "console") ;
                } else {
                    [skin pushNSObject:ourWindow withOptions:LS_NSDescribeUnknownTypes] ;
                }
            } else {
                // shouldn't be possible, but just in case...
                lua_pushstring(L, "** no window attached") ;
            }
            [skin pushNSObject:[notification.userInfo[@"item"] itemIdentifier]] ;
            lua_pushstring(L, "remove") ;
            if (![skin protectedCallAndTraceback:4 nresults:0]) {
                [skin logError:[NSString stringWithFormat:@"%s: toolbar callback error, %s, when notifying removal of toolbar item %@", USERDATA_TAG, lua_tostring(L, -1), [notification.userInfo[@"item"] itemIdentifier]]] ;
                lua_pop(L, 1) ;
            }
        }) ;
    }
}

@end

@implementation ASMToolbarSearchField
- (instancetype)init {
    self = [super init] ;
    if (self) {
        _toolbarItem = nil ;
        self.sendsWholeSearchString = YES ;
        self.sendsSearchStringImmediately = NO ;
        [self sizeToFit];
        ((NSSearchFieldCell *)self.cell).searchMenuTemplate = createCoreSearchFieldMenu();
    }
    return self ;
}

// - (id)copyWithZone:(NSZone *)zone
// {
//     ASMToolbarSearchField *copy = [[[self class] allocWithZone: zone] init];
//     _toolbarItem = self.toolbarItem ;
//     copy.cell    = self.cell ;
//
//     return copy;
// }

- (void)searchCallback:(NSMenuItem *)sender {
    self.stringValue = sender.title ;
    [(HSToolbar *)_toolbarItem.toolbar performCallback:self] ;
}

@end

#pragma mark - Module Functions

/// hs._asm.toolbar.new(toolbarName, toolbarTable) -> toolbarObject
/// Constructor
/// Creates a new toolbar as defined by the table provided.
///
/// Parameters:
///  * toolbarName  - a string specifying the name for this toolbar
///  * toolbarTable - a table describing the possible items for the toolbar
///
/// Table Format:
/// ```
///    {
///        -- example of a button
///        { id = "button1", ... }
///        -- example of a button group
///        { id = "button2", ..., { id = "sub-button1", ... }, { id = "sub-button2" }, ... }
///        ...
///    }
/// ```
///
/// * A button group is a collection of two or more buttons which are treated as a unit when customizing the active toolbar's look either programmatically with [hs._asm.toolbar:insertItem](#insertItem) and [hs._asm.toolbar:removeItem](#removeItem) or under user control with [hs._asm.toolbar:customizePanel](#customizePanel).
///
/// * The following keys are supported. The `id` key is the only required key for each button and button group. Unless otherwise specified below, keys can be modified per item after toolbar creation.
///    * `id`          - a unique string identifier for the button or button group within the toolbar.
///    * `label`       - a string text label, or false to remove, for the button or button group when text is displayed in the toolbar or in the customization panel.  For a button, the default is the `id`; for a button group, the default is `false`.  If a button group has a label, the group label will be displayed for the group of buttons it comprises.  If a button group does not have a label, the individual buttons which make up the group will each display their individual labels.
///    * `tooltip`     - a string label, or `false` to remove, which is displayed as a tool tip when the user hovers the mouse over the button or button group.  If a button is in a group, it's tooltip is ignored in favor of the group tooltip.
///    * `image`       - an `hs.image` object, or false to remove, specifying the image to use as the button's icon when icon's are displayed in the toolbar or customization panel.  Defaults to a round gray circle (`hs.image.systemImageNames.StatusNone`) for buttons.  This key is ignored for a button group, but not for it's individual buttons.
///    * `priority`    - an integer value used to determine button order and which buttons are displayed or put into the overflow menu when the number of buttons in the toolbar exceed the width of the window in which the toolbar is attached.  Some example values are provided in the [hs._asm.toolbar.itemPriorities](#itemPriorities) table.  If a button is in a button group, it's priority is ignored and the button group is ordered by the button group's priority.
///    * `tag`         - an integer value which can be used for custom purposes.
///    * `enabled`     - a boolean value indicating whether or not the button is active (and can be clicked on) or inactive and greyed out.
///    * `fn`          - a callback function, or false to remove, specific to the button.  This property is ignored if assigned to the button group.  This function will override the toolbar callback defined with [hs._asm.toolbar:setCallback](#setCallback) for this specific button.  The function should expect three arguments and return none: the toolbar object, "console" or the webview object the toolbar is attached to, and the toolbar item identifier that was clicked.
///    * `default`     - a boolean value, default true, indicating whether or not this button or button group should be displayed in the toolbar by default, unless overridden by user customization or a saved configuration (when such options are enabled).  This key cannot be changed after the toolbar has been created.
///    * `selectable`  - a boolean value, default false, indicating whether or not this button or button group is selectable (i.e. highlights, like a selected tab) when clicked on.  Only one selectable button will be selected at a time and can be identifier or changed with [hs._asm.toolbar:selectedItem](#selectedItem).  This key cannot be changed after the toolbar has been created.
///    * `searchfield` - a boolean value, default false, indicating whether or not this toolbar button is actually a search field.  A search toolbar item appears as a text field in the toolbar.  Text can be typed into the field and will be included as a fourth argument to the callback function when you hit the return/enter key.  If you click on the cancel button in the text field or hit the escape key, the text field will be cleared and the fourth argument sent to the callback function will be the empty string.
///
/// Returns:
///  * a toolbarObject
///
/// Notes:
///  * Toolbar names must be unique, but a toolbar may be copied with [hs._asm.toolbar:copy](#copy) if you wish to attach it to multiple windows (webview or console).
static int newHSToolbar(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TSTRING, LS_TTABLE, LS_TBREAK] ;
    NSString *identifier = [skin toNSObjectAtIndex:1] ;

    if (![identifiersInUse containsObject:identifier]) {
        HSToolbar *toolbar = [[HSToolbar alloc] initWithIdentifier:identifier
                                                    itemTableIndex:2] ;
        if (toolbar) {
            [skin pushNSObject:toolbar] ;
        } else {
            lua_pushnil(L) ;
        }
    } else {
        return luaL_argerror(L, 1, "identifier already in use") ;
    }
    return 1 ;
}

/// hs._asm.toolbar.attachToolbar(obj1, [obj2]) -> obj1
/// Function
/// Attach a toolbar to the console or webview.
///
/// Parameters:
///  * obj1 - if this is the only argument and is a toolbar object or `nil`, attaches or removes a toolbar from the Hammerspoon console window.  If this is an hs.webview object, then `obj2` is required.
///  * obj2 - if obj1 is an hs.webview object, then this argument is a toolbar object or `nil` to attach or remove the toolbar from the webview object.
///
/// Returns:
///  * obj1
///
/// Notes:
///  * If the toolbar is currently attached to a window when this function is called, it will be detached from the original window and attached to the new one specified by this function.
///  * This function is added to the hs.webview object methods so that it may be used as `hs.webview:attachToolbar(obj2)`.
static int attachToolbar(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    NSWindow *theWindow ;
    int toolbarIdx = 2 ;
    if (lua_gettop(L) == 1) {
        theWindow = [[MJConsoleWindowController singleton] window];
        toolbarIdx = 1 ;
        if (lua_type(L, 1) != LUA_TNIL) {
            [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
        }
    } else if (luaL_testudata(L, 1, "hs.webview")) {
        theWindow = get_objectFromUserdata(__bridge NSWindow, L, 1, "hs.webview") ;
        if (lua_type(L, 2) != LUA_TNIL) {
            [skin checkArgs:LS_TUSERDATA, "hs.webview", LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
        } else {
            [skin checkArgs:LS_TUSERDATA, "hs.webview", LS_TNIL, LS_TBREAK] ;
        }
    } else {
        return luaL_error(L, "toolbar can only be attached to the console or a webview") ;
    }
    HSToolbar *oldToolbar = (HSToolbar *)theWindow.toolbar ;
    HSToolbar *newToolbar = (lua_type(L, toolbarIdx) == LUA_TNIL) ? nil : [skin toNSObjectAtIndex:toolbarIdx] ;
    if (oldToolbar) {
        oldToolbar.visible = NO ;
        theWindow.toolbar = nil ;
        if ([oldToolbar isKindOfClass:[HSToolbar class]]) oldToolbar.windowUsingToolbar = nil ;
    }
    if (newToolbar) {
        NSWindow *newTBWindow = newToolbar.windowUsingToolbar ;
        if (newTBWindow) newTBWindow.toolbar = nil ;
        theWindow.toolbar             = newToolbar ;
        newToolbar.windowUsingToolbar = theWindow ;
        newToolbar.visible            = YES ;
    }
//     [skin logWarn:[NSString stringWithFormat:@"%@ %@ %@", oldToolbar, newToolbar, theWindow]] ;
    lua_pushvalue(L, 1) ;
    return 1 ;
}

#pragma mark - Module Methods

/// hs._asm.toolbar:isAttached() -> boolean
/// Method
/// Returns a boolean indicating whether or not the toolbar is currently attached to a window.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean indicating whether or not the toolbar is currently attached to a window.
static int isAttachedToWindow(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    lua_pushboolean(L, [toolbar isAttachedToWindow]) ;
    return 1;
}

/// hs._asm.toolbar:copy() -> toolbarObject
/// Method
/// Returns a copy of the toolbar object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a copy of the toolbar which can be attached to another window (webview or console).
static int copyToolbar(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *oldToolbar = [skin toNSObjectAtIndex:1] ;
    HSToolbar *newToolbar = [[HSToolbar alloc] initWithCopy:oldToolbar] ;
    if (newToolbar) {
        [skin pushNSObject:newToolbar] ;
    } else {
        lua_pushnil(L) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:setCallback(fn | nil) -> toolbarObject
/// Method
/// Sets or removes the global callback function for the toolbar.
///
/// Parameters:
///  * fn - a function to set as the global callback for the toolbar, or nil to remove the global callback.
///
///  The function should expect three arguments and return none: the toolbar object, "console" or the webview object the toolbar is attached to, and the toolbar item identifier that was clicked.
/// Returns:
///  * the toolbar object.
///
/// Notes:
///  * the global callback function is invoked for a toolbar button item that does not have a specific function assigned directly to it.
///  * if [hs._asm.toolbar:notifyOnChange](#notifyOnChange) is set to true, then this callback function will also be invoked when a toolbar item is added or removed from the toolbar either programmatically with [hs._asm.toolbar:insertItem](#insertItem) and [hs._asm.toolbar:removeItem](#removeItem) or under user control with [hs._asm.toolbar:customizePanel](#customizePanel) and the callback function will receive a string of "add" or "remove" as a fourth argument.
static int setCallback(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    // in either case, we need to remove an existing callback, so...
    toolbar.callbackRef = [skin luaUnref:refTable ref:toolbar.callbackRef] ;
    if (lua_type(L, 2) == LUA_TFUNCTION) {
        lua_pushvalue(L, 2) ;
        toolbar.callbackRef = [skin luaRef:refTable] ;
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.toolbar:savedSettings() -> table
/// Method
/// Returns a table containing the settings which will be saved for the toolbar if [hs._asm.toolbar:autosaves](#autosaves) is true.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the toolbar settings
///
/// Notes:
///  * If the toolbar is set to autosave, then a user-defaults entry is created in org.hammerspoon.Hammerspoon domain with the key "NSToolbar Configuration XXX" where XXX is the toolbar identifier specified when the toolbar was created.
///  * This method is provided if you do not wish for changes to the toolbar to be autosaved for every change, but may wish to save it programmatically under specific conditions.
static int configurationDictionary(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    [skin pushNSObject:[toolbar configurationDictionary]] ;
    return 1 ;
}

/// hs._asm.toolbar:separator([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar shows a separator between the toolbar and the main window contents.
///
/// Parameters:
///  * an optional boolean value to enable or disable the separator.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
static int showsBaselineSeparator(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    if (lua_gettop(L) != 1) {
        toolbar.showsBaselineSeparator = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    } else {
        lua_pushboolean(L, [toolbar showsBaselineSeparator]) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:visible([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar is currently visible in the window it is attached to.
///
/// Parameters:
///  * an optional boolean value to show or hide the toolbar.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
static int visible(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    if (lua_gettop(L) != 1) {
        toolbar.visible = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    } else {
        lua_pushboolean(L, [toolbar isVisible]) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:notifyOnChange([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the global callback function is invoked when a toolbar item is added or removed from the toolbar.
///
/// Parameters:
///  * an optional boolean value to enable or disable invoking the global callback for toolbar changes.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
static int notifyWhenToolbarChanges(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    if (lua_gettop(L) != 1) {
        toolbar.notifyToolbarChanges = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    } else {
        lua_pushboolean(L, toolbar.notifyToolbarChanges) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:insertItem(id, index) -> toolbarObject
/// Method
/// Insert or move the toolbar item to the index position specified
///
/// Parameters:
///  * id    - the string identifier of the toolbar item
///  * index - the numerical position where the toolbar item should be inserted/moved to.
///
/// Returns:
///  * the toolbar object
///
/// Notes:
///  * the toolbar position must be between 1 and the number of currently active toolbar items.
static int insertItemAtIndex(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    NSString  *identifier = [skin toNSObjectAtIndex:2] ;
    NSInteger index = luaL_checkinteger(L, 3) ;

    if ((index < 1) || (index > (NSInteger)(toolbar.items.count + 1))) {
        return luaL_error(L, "index out of bounds") ;
    }
    [toolbar insertItemWithItemIdentifier:identifier atIndex:(index - 1)] ;
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.toolbar:removeItem(index) -> toolbarObject
/// Method
/// Remove the toolbar item at the index position specified
///
/// Parameters:
///  * index - the numerical position of the toolbar item to remove.
///
/// Returns:
///  * the toolbar object
///
/// Notes:
///  * the toolbar position must be between 1 and the number of currently active toolbar items.
static int removeItemAtIndex(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    NSInteger index = luaL_checkinteger(L, 2) ;

    if ((index < 1) || (index > (NSInteger)(toolbar.items.count + 1))) {
        return luaL_error(L, "index out of bounds") ;
    }
    [toolbar removeItemAtIndex:(index - 1)] ;
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.toolbar:sizeMode([size]) -> toolbarObject
/// Method
/// Get or set the toolbar's size.
///
/// Parameters:
///  * size - an optional string to set the size of the toolbar to "default", "regular", or "small".
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
static int sizeMode(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 2) {
        NSString *size = [skin toNSObjectAtIndex:2] ;
        if ([size isEqualToString:@"default"]) {
            toolbar.sizeMode = NSToolbarSizeModeDefault ;
        } else if ([size isEqualToString:@"regular"]) {
            toolbar.sizeMode = NSToolbarSizeModeRegular ;
        } else if ([size isEqualToString:@"small"]) {
            toolbar.sizeMode = NSToolbarSizeModeSmall ;
        } else {
            return luaL_error(L, [[NSString stringWithFormat:@"invalid sizeMode:%@", size] UTF8String]) ;
        }
        lua_pushvalue(L, 1) ;
    } else {
        switch(toolbar.sizeMode) {
            case NSToolbarSizeModeDefault:
                [skin pushNSObject:@"default"] ;
                break ;
            case NSToolbarSizeModeRegular:
                [skin pushNSObject:@"regular"] ;
                break ;
            case NSToolbarSizeModeSmall:
                [skin pushNSObject:@"small"] ;
                break ;
// in case Apple extends this
            default:
                [skin pushNSObject:[NSString stringWithFormat:@"** unrecognized sizeMode (%tu)",
                                                              toolbar.sizeMode]] ;
                break ;
        }
    }
    return 1 ;
}

/// hs._asm.toolbar:displayMode([mode]) -> toolbarObject
/// Method
/// Get or set the toolbar's display mode.
///
/// Parameters:
///  * mode - an optional string to set the size of the toolbar to "default", "label", "icon", or "both".
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
static int displayMode(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 2) {
        NSString *type = [skin toNSObjectAtIndex:2] ;
        if ([type isEqualToString:@"default"]) {
            toolbar.displayMode = NSToolbarDisplayModeDefault ;
        } else if ([type isEqualToString:@"label"]) {
            toolbar.displayMode = NSToolbarDisplayModeLabelOnly ;
        } else if ([type isEqualToString:@"icon"]) {
            toolbar.displayMode = NSToolbarDisplayModeIconOnly ;
        } else if ([type isEqualToString:@"both"]) {
            toolbar.displayMode = NSToolbarDisplayModeIconAndLabel ;
        } else {
            return luaL_error(L, [[NSString stringWithFormat:@"invalid displayMode:%@", type] UTF8String]) ;
        }
        lua_pushvalue(L, 1) ;
    } else {
        switch(toolbar.displayMode) {
            case NSToolbarDisplayModeDefault:
                [skin pushNSObject:@"default"] ;
                break ;
            case NSToolbarDisplayModeLabelOnly:
                [skin pushNSObject:@"label"] ;
                break ;
            case NSToolbarDisplayModeIconOnly:
                [skin pushNSObject:@"icon"] ;
                break ;
            case NSToolbarDisplayModeIconAndLabel:
                [skin pushNSObject:@"both"] ;
                break ;
// in case Apple extends this
            default:
                [skin pushNSObject:[NSString stringWithFormat:@"** unrecognized displayMode (%tu)",
                                                              toolbar.displayMode]] ;
                break ;
        }
    }
    return 1 ;
}

/// hs._asm.toolbar:modifyItem(table) -> toolbarObject
/// Method
/// Modify the toolbar item specified by the "id" key in the table argument.
///
/// Parameters:
///  * a table containing an "id" key and one or more of the following keys:
///    * id         - a string containing the item identifier of the toolbar item to modify (required)
///
///    * `label`      - a string text label, or false to remove, for the button or button group when text is displayed in the toolbar or in the customization panel.
///    * `tooltip`    - a string label, or `false` to remove, which is displayed as a tool tip when the user hovers the mouse over the button or button group.
///    * `image`      - an `hs.image` object, or false to remove, specifying the image to use as the button's icon when icon's are displayed in the toolbar or customization panel.
///    * `priority`   - an integer value used to determine button order and which buttons are displayed or put into the overflow menu when the number of buttons in the toolbar exceed the width of the window in which the toolbar is attached.  Some example values are provided in the [hs._asm.toolbar.itemPriorities](#itemPriorities) table.
///    * `tag`        - an integer value which can be used for custom purposes.
///    * `enabled`    - a boolean value indicating whether or not the button is active (and can be clicked on) or inactive and greyed out.
///    * `fn`         - a callback function, or false to remove, specific to the button.  This function will override the toolbar callback defined with [hs._asm.toolbar:setCallback](#setCallback) for this specific button.  The function should expect three arguments and return none: the toolbar object, "console" or the webview object the toolbar is attached to, and the toolbar item identifier that was clicked.
///
/// Returns:
///  * the toolbarObject
static int modifyToolbarItem(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    NSString *identifier ;

    if (lua_getfield(L, 2, "id") == LUA_TSTRING) {
        identifier = [skin toNSObjectAtIndex:-1] ;
    } else {
        lua_pop(L, 1) ;
        return luaL_error(L, "id must be present, and it must be a string") ;
    }
    lua_pop(L, 1) ;
    lua_pushstring(L, "id") ;
    lua_pushnil(L) ;
    lua_rawset(L, 2) ;

    if (lua_getfield(L, 2, "fn") == LUA_TFUNCTION) {
        lua_pushvalue(L, -1) ;
        int fnRef = [skin luaRef:refTable] ;
        lua_pushstring(L, "fn") ;
        lua_pushinteger(L, fnRef) ;
        lua_rawset(L, 2) ;
    }
    lua_pop(L, 1) ;

    NSMutableDictionary *newDict = [skin toNSObjectAtIndex:2] ;
    if (toolbar.items) {
        for (NSToolbarItem *item in toolbar.items) {
            if ([item.itemIdentifier isEqualToString:identifier]) {
                [toolbar updateToolbarItem:item withDictionary:newDict] ;
                break ;
            }
        }
    } else {
        for (NSString *key in newDict) {
            toolbar.itemDefDictionary[identifier][key] = newDict[key] ;
        }
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.toolbar:itemDetails(id) -> table
/// Method
/// Returns a table containing details about the specified toolbar item
///
/// Parameters:
///  * id - a string identifier specifying the toolbar item
///
/// Returns:
///  * a table which will contain one or more of the follow key-value pairs:
///    * id         - a string containing the toolbar item's identifier
///    * label      - a string containing the toolbar item's label
///    * tooltip    - a string containing the toolbar item's tooltip
///    * image      - an hs.image object contining the toolbar item's image
///    * priority   - an integer specifying the toolbar item's visibility priority
///    * enable     - a boolean indicating whether or not the toolbar item is currently enabled
///    * tag        - an integer specifying the toolbar item's user defined tag value
///    * toolbar    - the toolbar object the toolbar item is attached to
///    * selectable - a boolean indicating whether or not the toolbar item is defined as selectable
///    * subitems   - if this item is a toolbar group, a table containing the toolbar items in the group.
static int detailsForItemIdentifier(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    NSString *identifier = [skin toNSObjectAtIndex:2] ;
    NSToolbarItem *ourItem ;
    for (NSToolbarItem *item in toolbar.items) {
        if ([identifier isEqualToString:[item itemIdentifier]]) {
            ourItem = item ;
            break ;
        } else if ([item isKindOfClass:[NSToolbarItemGroup class]]) {
            for (NSToolbarItem *subItem in [(NSToolbarItemGroup *)item subitems]) {
                if ([identifier isEqualToString:[subItem itemIdentifier]]) {
//                     [skin logDebug:@"details found an active subitem"] ;
                    ourItem = subItem ;
                    break ;
                }
            }
            if (ourItem) break ;
        }
    }
    if (!ourItem) ourItem = [toolbar.itemDefDictionary objectForKey:identifier] ;
    [skin pushNSObject:ourItem] ;
    return 1 ;
}

/// hs._asm.toolbar:allowedItems() -> array
/// Method
/// Returns an array of all toolbar item identifiers defined for this toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of all toolbar item identifiers defined for this toolbar.  See also [hs._asm.toolbar:items](#items) and [hs._asm.toolbar:visibleItems](#visibleItems).
static int allowedToolbarItems(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    [skin pushNSObject:toolbar.allowedIdentifiers] ;
    return 1 ;
}

/// hs._asm.toolbar:items() -> array
/// Method
/// Returns an array of the toolbar item identifiers currently assigned to the toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of the current toolbar item identifiers.  Toolbar items which are in the overflow menu *are* included in this array.  See also [hs._asm.toolbar:visibleItems](#visibleItems) and [hs._asm.toolbar:allowedItems](#allowedItems).
static int toolbarItems(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    lua_newtable(L) ;
    for (NSToolbarItem *item in toolbar.items) {
        [skin pushNSObject:[item itemIdentifier]] ;
        lua_rawseti(L, -2, luaL_len(L, -2) + 1) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:visibleItems() -> array
/// Method
/// Returns an array of the currently visible toolbar item identifiers.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of the currently visible toolbar item identifiers.  Toolbar items which are in the overflow menu are *not* included in this array.  See also [hs._asm.toolbar:items](#items) and [hs._asm.toolbar:allowedItems](#allowedItems).
static int visibleToolbarItems(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    lua_newtable(L) ;
    for (NSToolbarItem *item in [toolbar visibleItems]) {
        [skin pushNSObject:[item itemIdentifier]] ;
        lua_rawseti(L, -2, luaL_len(L, -2) + 1) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:selectedItem([item]) -> toolbarObject | item
/// Method
/// Get or set the selected toolbar item
///
/// Parameters:
///  * item - an optional id for the toolbar item to show as selected, or nil if you wish for no toolbar item to be selected.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * Only toolbar items which were defined as `selectable` when created with [hs._asm.toolbar.new](#new) can be selected with this method.
static int selectedToolbarItem(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    if (lua_gettop(L) == 2) {
        NSString *identifier = nil ;
        if (lua_type(L, 2) == LUA_TSTRING) identifier = [skin toNSObjectAtIndex:2] ;
        toolbar.selectedItemIdentifier = identifier ;
        lua_pushvalue(L, 1) ;
    } else {
        [skin pushNSObject:[toolbar selectedItemIdentifier]] ;
    }
    return 1 ;
}

/// hs._asm.toolbar:identifier() -> identifier
/// Method
/// The identifier for this toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The identifier for this toolbar.
static int toolbarIdentifier(__unused lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    [skin pushNSObject:toolbar.identifier] ;
    return 1 ;
}

/// hs._asm.toolbar:customizePanel() -> toolbarObject
/// Method
/// Opens the toolbar customization panel.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the toolbar object
static int customizeToolbar(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    [toolbar runCustomizationPalette:toolbar] ;
    lua_pushvalue(L, 1) ;
    return 1 ;
}

/// hs._asm.toolbar:isCustomizing() -> bool
/// Method
/// Indicates whether or not the customization panel is currently open for the toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true or false indicating whether or not the customization panel is open for the toolbar
static int toolbarIsCustomizing(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    lua_pushboolean(L, toolbar.customizationPaletteIsRunning) ;
    return 1 ;
}

/// hs._asm.toolbar:canCustomize([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the user is allowed to customize the toolbar with the Customization Panel.
///
/// Parameters:
///  * an optional boolean value indicating whether or not the user is allowed to customize the toolbar.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * the customization panel can be pulled up by right-clicking on the toolbar or by invoking [hs._asm.toolbar:customizePanel](#customizePanel).
static int toolbarCanCustomize(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        lua_pushboolean(L, toolbar.allowsUserCustomization) ;
    } else {
        toolbar.allowsUserCustomization = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:autossaves([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar autosaves changes made to the toolbar.
///
/// Parameters:
///  * an optional boolean value indicating whether or not changes made to the visible toolbar items or their order is automatically saved.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * If the toolbar is set to autosave, then a user-defaults entry is created in org.hammerspoon.Hammerspoon domain with the key "NSToolbar Configuration XXX" where XXX is the toolbar identifier specified when the toolbar was created.
///  * The information saved for the toolbar consists of the following:
///    * the default item identifiers that are displayed when the toolbar is first created or when the user drags the default set from the customization panel.
///    * the current display mode (icon, text, both)
///    * the current size mode (regular, small)
///    * whether or not the toolbar is currently visible
///    * the currently shown identifiers and their order
/// * Note that the labels, icons, callback functions, etc. are not saved -- these are determined at toolbar creation time or by the [hs._asm.toolbar:modifyItem](#modifyItem) method and can differ between invocations of toolbars with the same identifier and button identifiers.
static int toolbarCanAutosave(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    if (lua_gettop(L) == 1) {
        lua_pushboolean(L, toolbar.autosavesConfiguration) ;
    } else {
        toolbar.autosavesConfiguration = (BOOL)lua_toboolean(L, 2) ;
        lua_pushvalue(L, 1) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:infoDump() -> table
/// Method
/// Returns information useful for debugging
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing information stored in the HSToolbar object for debugging purposes.
static int infoDump(lua_State *L) {
    LuaSkin *skin     = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;

    lua_newtable(L) ;
    [skin pushNSObject:[toolbar.allowedIdentifiers set]] ;    lua_setfield(L, -2, "allowedIdentifiers") ;
    [skin pushNSObject:[toolbar.defaultIdentifiers set]] ;    lua_setfield(L, -2, "defaultIdentifiers") ;
    [skin pushNSObject:[toolbar.selectableIdentifiers set]] ; lua_setfield(L, -2, "selectableIdentifiers") ;
    [skin pushNSObject:toolbar.itemDefDictionary] ;     lua_setfield(L, -2, "itemDictionary") ;
    [skin pushNSObject:toolbar.fnRefDictionary] ;       lua_setfield(L, -2, "fnRefDictionary") ;
    [skin pushNSObject:toolbar.enabledDictionary] ;     lua_setfield(L, -2, "enabledDictionary") ;
    lua_pushinteger(L, toolbar.callbackRef) ;           lua_setfield(L, -2, "callbackRef") ;
    lua_pushinteger(L, toolbar.selfRef) ;               lua_setfield(L, -2, "selfRef") ;
    [skin pushNSObject:toolbar.items] ;                 lua_setfield(L, -2, "toolbarItems") ;
    [skin pushNSObject:toolbar.delegate] ;              lua_setfield(L, -2, "delegate") ;

    NSWindow *ourWindow = toolbar.windowUsingToolbar ;
    if (ourWindow) {
        [skin pushNSObject:ourWindow withOptions:LS_NSDescribeUnknownTypes] ;
        lua_setfield(L, -2, "windowUsingToolbar") ;
        lua_pushboolean(L, [[ourWindow toolbar] isEqualTo:toolbar]) ;
        lua_setfield(L, -2, "windowUsingToolbarIsAttached") ;
    }
    return 1 ;
}

static int injectIntoDictionary(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK] ;
    HSToolbar *toolbar = [skin toNSObjectAtIndex:1] ;
    NSString *identifier ;

    if (lua_getfield(L, 2, "id") == LUA_TSTRING) {
        identifier = [skin toNSObjectAtIndex:-1] ;
    } else {
        lua_pop(L, 1) ;
        return luaL_error(L, "id must be present, and it must be a string") ;
    }
    lua_pop(L, 1) ;
    lua_pushstring(L, "id") ;
    lua_pushnil(L) ;
    lua_rawset(L, 2) ;

    if (lua_getfield(L, 2, "fn") == LUA_TFUNCTION) {
        lua_pushvalue(L, -1) ;
        int fnRef = [skin luaRef:refTable] ;
        lua_pushstring(L, "fn") ;
        lua_pushinteger(L, fnRef) ;
        lua_rawset(L, 2) ;
    }
    lua_pop(L, 1) ;

    if (lua_getfield(L, 2, "default") == LUA_TBOOLEAN) {
        if (lua_toboolean(L, -1)) {
            [toolbar.defaultIdentifiers addObject:identifier] ;
        } else {
            [toolbar.defaultIdentifiers removeObject:identifier] ;
        }
        lua_pushstring(L, "default") ;
        lua_pushnil(L) ;
        lua_rawset(L, 2) ;
    }
    lua_pop(L, 1) ;

    if (lua_getfield(L, 2, "allowedAlone") == LUA_TBOOLEAN) {
        if (lua_toboolean(L, -1)) {
            [toolbar.allowedIdentifiers addObject:identifier] ;
        } else {
            [toolbar.allowedIdentifiers removeObject:identifier] ;
        }
        lua_pushstring(L, "allowedAlone") ;
        lua_pushnil(L) ;
        lua_rawset(L, 2) ;
    }
    lua_pop(L, 1) ;

    if (lua_getfield(L, 2, "selectable") == LUA_TBOOLEAN) {
        if (lua_toboolean(L, -1)) {
            [toolbar.selectableIdentifiers addObject:identifier] ;
        } else {
            [toolbar.selectableIdentifiers removeObject:identifier] ;
        }
        lua_pushstring(L, "selectable") ;
        lua_pushnil(L) ;
        lua_rawset(L, 2) ;
    }
    lua_pop(L, 1) ;

    NSMutableDictionary *newDict = [skin toNSObjectAtIndex:2] ;
//     [skin logWarn:[newDict debugDescription]] ;

    if (toolbar.itemDefDictionary[identifier]) {
        if (toolbar.items) {
            for (NSToolbarItem *item in toolbar.items) {
                if ([item.itemIdentifier isEqualToString:identifier]) {
                    [toolbar updateToolbarItem:item withDictionary:newDict] ;
                    break ;
                }
            }
        } else {
            for (NSString *key in newDict) {
                toolbar.itemDefDictionary[identifier][key] = newDict[key] ;
            }
        }
    } else {
        toolbar.itemDefDictionary[identifier] = newDict ;
    }
    lua_pushvalue(L, 1) ;
    return 1 ;
}

#pragma mark - Module Constants

/// hs._asm.toolbar.systemToolbarItems
/// Constant
/// An array containing string identifiers for supported system defined toolbar items.
///
/// Currently supported identifiers include:
///  * NSToolbarSpaceItem         - represents a space approximately the size of a toolbar item
///  * NSToolbarFlexibleSpaceItem - represents a space that stretches to fill available space in the toolbar
static int systemToolbarItems(__unused lua_State *L) {
    [[LuaSkin shared] pushNSObject:automaticallyIncluded] ;
    return 1 ;
}

/// hs._asm.toolbar.itemPriorities
/// Constant
/// A table containing some pre-defined toolbar item priority values for use when determining item order in the toolbar.
///
/// Defined keys are:
///  * standard - the default priority for an item which does not set or change its priority
///  * low      - a low priority value
///  * high     - a high priority value
///  * user     - the priority of an item which the user has added or moved with the customization panel
static int toolbarItemPriorities(lua_State *L) {
    lua_newtable(L) ;
    lua_pushinteger(L, NSToolbarItemVisibilityPriorityStandard) ; lua_setfield(L, -2, "standard") ;
    lua_pushinteger(L, NSToolbarItemVisibilityPriorityLow) ;      lua_setfield(L, -2, "low") ;
    lua_pushinteger(L, NSToolbarItemVisibilityPriorityHigh) ;     lua_setfield(L, -2, "high") ;
    lua_pushinteger(L, NSToolbarItemVisibilityPriorityUser) ;     lua_setfield(L, -2, "user") ;
    return 1 ;
}

#pragma mark - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

static int pushHSToolbar(lua_State *L, id obj) {
    LuaSkin *skin = [LuaSkin shared] ;
    HSToolbar *value = obj;
    if (value.selfRef == LUA_NOREF) {
        void** valuePtr = lua_newuserdata(L, sizeof(HSToolbar *));
        *valuePtr = (__bridge_retained void *)value;
        luaL_getmetatable(L, USERDATA_TAG);
        lua_setmetatable(L, -2);
        value.selfRef = [skin luaRef:refTable] ;
        [identifiersInUse addObject:value.identifier] ;
    }

    [skin pushLuaRef:refTable ref:value.selfRef] ;
    return 1;
}

static id toHSToolbarFromLua(lua_State *L, int idx) {
    LuaSkin *skin = [LuaSkin shared] ;
    HSToolbar *value ;
    if (luaL_testudata(L, idx, USERDATA_TAG)) {
        value = get_objectFromUserdata(__bridge HSToolbar, L, idx, USERDATA_TAG) ;
        // since this function is called every time a toolbar function/method is called, we
        // can keep the window reference valid by checking here...
        [value isAttachedToWindow] ;
    } else {
        [skin logError:[NSString stringWithFormat:@"expected %s object, found %s", USERDATA_TAG,
                                                   lua_typename(L, lua_type(L, idx))]] ;
    }
    return value ;
}

static int pushNSToolbarItem(lua_State *L, id obj) {
    LuaSkin *skin = [LuaSkin shared] ;
    NSToolbarItem *value = obj ;
    lua_newtable(L) ;
    [skin pushNSObject:value.itemIdentifier] ;     lua_setfield(L, -2, "id") ;
    [skin pushNSObject:value.label] ;              lua_setfield(L, -2, "label") ;
//     [skin pushNSObject:value.paletteLabel] ;       lua_setfield(L, -2, "paletteLabel") ;
    [skin pushNSObject:value.toolTip] ;            lua_setfield(L, -2, "tooltip") ;
    [skin pushNSObject:value.image] ;              lua_setfield(L, -2, "image") ;
    lua_pushinteger(L, value.visibilityPriority) ; lua_setfield(L, -2, "priority") ;
    lua_pushboolean(L, value.isEnabled) ;          lua_setfield(L, -2, "enable") ;
    lua_pushinteger(L, value.tag) ;                lua_setfield(L, -2, "tag") ;

    if ([value.toolbar isKindOfClass:[HSToolbar class]]) {
        [skin pushNSObject:value.toolbar] ;        lua_setfield(L, -2, "toolbar") ;
        HSToolbar *ourToolbar = (HSToolbar *)value.toolbar ;
        lua_pushboolean(L, [ourToolbar.selectableIdentifiers containsObject:[value itemIdentifier]]) ;
        lua_setfield(L, -2, "selectable") ;
    }
    if ([obj isKindOfClass:[NSToolbarItemGroup class]]) {
        [skin pushNSObject:[obj subitems]] ; lua_setfield(L, -2, "subitems") ;
    }

//     [skin pushNSObject:value.target] ; lua_setfield(L, -2, "target") ;
//     [skin pushNSObject:NSStringFromSelector(value.action)] ; lua_setfield(L, -2, "action") ;
//     [skin pushNSObject:value.view withOptions:LS_NSDescribeUnknownTypes] ; lua_setfield(L, -2, "view") ;
//     lua_pushboolean(L, value.autovalidates) ; lua_setfield(L, -2, "autovalidates") ;

    if ([value.view isKindOfClass:[ASMToolbarSearchField class]]) {
        lua_pushnumber(L, [value minSize].width) ; lua_setfield(L, -2, "searchMinWidth") ;
        lua_pushnumber(L, [value maxSize].width) ; lua_setfield(L, -2, "searchMaxWidth") ;
        [skin pushNSObject:[((ASMToolbarSearchField *)value.view) stringValue]] ;
        lua_setfield(L, -2, "searchText") ;
        lua_pushinteger(L, [[((ASMToolbarSearchField *)value.view) cell] maximumRecents]) ;
        lua_setfield(L, -2, "searchHistoryLimit") ;
        [skin pushNSObject:[[((ASMToolbarSearchField *)value.view) cell] recentSearches]] ;
        lua_setfield(L, -2, "searchHistory") ;
        [skin pushNSObject:[[((ASMToolbarSearchField *)value.view) cell] recentsAutosaveName]] ;
        lua_setfield(L, -2, "searchHistoryAutoSaveName") ;
    }
    return 1 ;
}

#pragma mark - Hammerspoon/Lua Infrastructure

static int userdata_tostring(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared] ;
    HSToolbar *obj = [skin luaObjectAtIndex:1 toClass:"HSToolbar"] ;
    NSString *title = obj.identifier ;
    [skin pushNSObject:[NSString stringWithFormat:@"%s: %@ (%p)", USERDATA_TAG, title, lua_topointer(L, 1)]] ;
    return 1 ;
}

static int userdata_eq(lua_State* L) {
// can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
// so use luaL_testudata before the macro causes a lua error
    if (luaL_testudata(L, 1, USERDATA_TAG) && luaL_testudata(L, 2, USERDATA_TAG)) {
        LuaSkin *skin = [LuaSkin shared] ;
        HSToolbar *obj1 = [skin luaObjectAtIndex:1 toClass:"HSToolbar"] ;
        HSToolbar *obj2 = [skin luaObjectAtIndex:2 toClass:"HSToolbar"] ;
        lua_pushboolean(L, [obj1 isEqualTo:obj2]) ;
    } else {
        lua_pushboolean(L, NO) ;
    }
    return 1 ;
}

/// hs._asm.toolbar:delete() -> none
/// Method
/// Deletes the toolbar, removing it from its window if it is currently attached.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
static int userdata_gc(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared] ;
    HSToolbar *obj = get_objectFromUserdata(__bridge_transfer HSToolbar, L, 1, USERDATA_TAG) ;
    if (obj) {
        for (NSNumber *fnRef in [obj.fnRefDictionary allValues]) [skin luaUnref:refTable ref:[fnRef intValue]] ;

        NSWindow *ourWindow = obj.windowUsingToolbar ;
        if (ourWindow && [[ourWindow toolbar] isEqualTo:obj])
            ourWindow.toolbar = nil ;

        obj.callbackRef = [skin luaUnref:refTable ref:obj.callbackRef];
        obj.selfRef = [skin luaUnref:refTable ref:obj.selfRef] ;
        obj.delegate = nil ;
        // they should be properly balanced, but lets check just in case...
        NSUInteger identifierIndex = [identifiersInUse indexOfObject:obj.identifier] ;
        if (identifierIndex != NSNotFound) [identifiersInUse removeObjectAtIndex:identifierIndex] ;
        obj = nil ;
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L) ;
    lua_setmetatable(L, 1) ;
    return 0 ;
}

static int meta_gc(__unused lua_State* L) {
    [identifiersInUse removeAllObjects] ;
    identifiersInUse = nil ;
    return 0 ;
}

// Metatable for userdata objects
static const luaL_Reg userdata_metaLib[] = {
    {"delete",          userdata_gc},
    {"copyToolbar",     copyToolbar},
    {"isAttached",      isAttachedToWindow},
    {"savedSettings",   configurationDictionary},

    {"identifier",      toolbarIdentifier},
    {"setCallback",     setCallback},
    {"displayMode",     displayMode},
    {"sizeMode",        sizeMode},
    {"visible",         visible},
    {"autosaves",       toolbarCanAutosave},
    {"separator",       showsBaselineSeparator},

    {"modifyItem",      modifyToolbarItem},
    {"insertItem",      insertItemAtIndex},
    {"removeItem",      removeItemAtIndex},

    {"items",           toolbarItems},
    {"visibleItems",    visibleToolbarItems},
    {"selectedItem",    selectedToolbarItem},
    {"allowedItems",    allowedToolbarItems},
    {"itemDetails",     detailsForItemIdentifier},

    {"notifyOnChange",  notifyWhenToolbarChanges},
    {"customizePanel",  customizeToolbar},
    {"isCustomizing",   toolbarIsCustomizing},
    {"canCustomize",    toolbarCanCustomize},

    {"infoDump",        infoDump},
    {"inject",          injectIntoDictionary},

    {"__tostring",      userdata_tostring},
    {"__eq",            userdata_eq},
    {"__gc",            userdata_gc},
    {NULL,              NULL}
};

// Functions for returned object when module loads
static luaL_Reg moduleLib[] = {
    {"new",           newHSToolbar},
    {"attachToolbar", attachToolbar},
    {NULL,            NULL}
};

// Metatable for module, if needed
static const luaL_Reg module_metaLib[] = {
    {"__gc", meta_gc},
    {NULL,   NULL}
};

int luaopen_hs__asm_toolbar_internal(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared] ;
    refTable = [skin registerLibraryWithObject:USERDATA_TAG
                                     functions:moduleLib
                                 metaFunctions:module_metaLib
                               objectFunctions:userdata_metaLib];

    builtinToolbarItems = @[
                              NSToolbarSpaceItemIdentifier,
                              NSToolbarFlexibleSpaceItemIdentifier,
                              NSToolbarShowColorsItemIdentifier,       // require additional support
                              NSToolbarShowFontsItemIdentifier,        // require additional support
                              NSToolbarPrintItemIdentifier,            // require additional support
                              NSToolbarSeparatorItemIdentifier,        // deprecated
                              NSToolbarCustomizeToolbarItemIdentifier, // deprecated
                          ] ;
    automaticallyIncluded = @[
                                NSToolbarSpaceItemIdentifier,
                                NSToolbarFlexibleSpaceItemIdentifier,
                            ] ;
    keysToKeepFromDefinitionDictionary = @[ @"id", @"default", @"selectable" ];
    keysToKeepFromGroupDefinition      = @[ @"searchfield", @"image", @"fn" ];

    identifiersInUse = [[NSMutableArray alloc] init] ;

    systemToolbarItems(L) ;    lua_setfield(L, -2, "systemToolbarItems") ;
    toolbarItemPriorities(L) ; lua_setfield(L, -2, "itemPriorities") ;

    [skin registerPushNSHelper:pushHSToolbar         forClass:"HSToolbar"];
    [skin registerLuaObjectHelper:toHSToolbarFromLua forClass:"HSToolbar" withUserdataMapping:USERDATA_TAG];
    [skin registerPushNSHelper:pushNSToolbarItem     forClass:"NSToolbarItem"];

    return 1;
}
