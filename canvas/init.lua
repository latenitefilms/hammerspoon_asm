--- === hs._asm.canvas ===
---
--- A different approach to drawing in Hammerspoon
---
--- `hs.drawing` approaches graphical images and independant primitives, each "shape" being an independant drawing object based on the core primitives: ellipse, rectangle, point, line, text, etc.  This model works well with graphical elements that are expected to be managed individually and don't have complex clipping interactions, but does not scale well when more complex combinations or groups of drawing elements need to be moved or manipulated as a group, and only allows for simple inclusionary clipping regions.
---
--- This module works by designating a canvas and then assigning a series of graphical primitives to the canvas.  Included in this assignment list are rules about how the individual elements interact with each other within the canvas (compositing and clipping rules), and direct modification of the canvas itself (move, resize, etc.) causes all of the assigned elements to be adjusted as a group.
---
--- This is an experimental work in progress, so we'll see how it goes...

local USERDATA_TAG = "hs._asm.canvas"
local module       = require(USERDATA_TAG..".internal")
local canvasMT     = hs.getObjectMetatable(USERDATA_TAG)

-- private variables and methods -----------------------------------------

local _kMetaTable = {}
_kMetaTable._k = setmetatable({}, {__mode = "k"})
_kMetaTable._t = setmetatable({}, {__mode = "k"})
_kMetaTable.__index = function(obj, key)
        if _kMetaTable._k[obj] then
            if _kMetaTable._k[obj][key] then
                return _kMetaTable._k[obj][key]
            else
                for k,v in pairs(_kMetaTable._k[obj]) do
                    if v == key then return k end
                end
            end
        end
        return nil
    end
_kMetaTable.__newindex = function(obj, key, value)
        error("attempt to modify a table of constants",2)
        return nil
    end
_kMetaTable.__pairs = function(obj) return pairs(_kMetaTable._k[obj]) end
_kMetaTable.__len = function(obj) return #_kMetaTable._k[obj] end
_kMetaTable.__tostring = function(obj)
        local result = ""
        if _kMetaTable._k[obj] then
            local width = 0
            for k,v in pairs(_kMetaTable._k[obj]) do width = width < #tostring(k) and #tostring(k) or width end
            for k,v in require("hs.fnutils").sortByKeys(_kMetaTable._k[obj]) do
                if _kMetaTable._t[obj] == "table" then
                    result = result..string.format("%-"..tostring(width).."s %s\n", tostring(k),
                        ((type(v) == "table") and "{ table }" or tostring(v)))
                else
                    result = result..((type(v) == "table") and "{ table }" or tostring(v)).."\n"
                end
            end
        else
            result = "constants table missing"
        end
        return result
    end
_kMetaTable.__metatable = _kMetaTable -- go ahead and look, but don't unset this

local _makeConstantsTable
_makeConstantsTable = function(theTable)
    if type(theTable) ~= "table" then
        local dbg = debug.getinfo(2)
        local msg = dbg.short_src..":"..dbg.currentline..": attempting to make a '"..type(theTable).."' into a constant table"
        if module.log then module.log.ef(msg) else print(msg) end
        return theTable
    end
    for k,v in pairs(theTable) do
        if type(v) == "table" then
            local count = 0
            for a,b in pairs(v) do count = count + 1 end
            local results = _makeConstantsTable(v)
            if #v > 0 and #v == count then
                _kMetaTable._t[results] = "array"
            else
                _kMetaTable._t[results] = "table"
            end
            theTable[k] = results
        end
    end
    local results = setmetatable({}, _kMetaTable)
    _kMetaTable._k[results] = theTable
    local count = 0
    for a,b in pairs(theTable) do count = count + 1 end
    if #theTable > 0 and #theTable == count then
        _kMetaTable._t[results] = "array"
    else
        _kMetaTable._t[results] = "table"
    end
    return results
end

-- Public interface ------------------------------------------------------

module.compositeTypes = _makeConstantsTable(module.compositeTypes)

--- hs._asm.canvas:behaviorByLabels(behaviorTable) -> canvasObject | currentValue
--- Method
--- Get or set the window behavior settings for the canvas object using labels defined in `hs.drawing.windowBehaviors`.
---
--- Parameters:
---  * behaviorTable - an optional table of strings and/or numbers specifying the desired window behavior for the canvas object.
---
--- Returns:
---  * If an argument is provided, the canvas object; otherwise the current value.
---
--- Notes:
---  * Window behaviors determine how the canvas object is handled by Spaces and Exposé. See `hs.drawing.windowBehaviors` for more information.
canvasMT.behaviorByLabels = function(obj, ...)
    local drawing = require"hs.drawing"
    local args = table.pack(...)

    if args.n == 0 then
        local results = {}
        local behaviorNumber = obj:behavior()

        if behaviorNumber ~= 0 then
            for i, v in pairs(drawing.windowBehaviors) do
                if type(i) == "string" then
                    if (behaviorNumber & v) > 0 then table.insert(results, i) end
                end
            end
        else
            table.insert(results, drawing.windowBehaviors[0])
        end
        return setmetatable(results, { __tostring = function(_)
            table.sort(_)
            return "{ "..table.concat(_, ", ").." }"
        end})
    elseif args.n == 1 and type(args[1]) == "table" then
        local newBehavior = 0
        for i,v in ipairs(args[1]) do
            local flag = tonumber(v) or drawing.windowBehaviors[v]
            if flag then newBehavior = newBehavior | flag end
        end
        return obj:behavior(newBehavior)
    elseif args.n > 1 then
        error("behaviorByLabels method expects 0 or 1 arguments", 2)
    else
        error("behaviorByLabels method argument must be a table", 2)
    end
end

--- hs._asm.canvas:frame([rect]) -> canvasObject | currentValue
--- Method
--- Get or set the frame of the canvasObject.
---
--- Parameters:
---  * rect - An optional rect-table containing the co-ordinates and size the canvas object should be moved and set to
---
--- Returns:
---  * If an argument is provided, the canvas object; otherwise the current value.
---
--- Notes:
---  * a rect-table is a table with key-value pairs specifying the new top-left coordinate on the screen of the canvas (keys `x  and `y`) and the new size (keys `h` and `w`).  The table may be crafted by any method which includes these keys, including the use of an `hs.geometry` object.
---
---  * elements in the canvas that do not have the `absolutePosition` attribute set will be moved so that their relative position within the canvas remains the same with respect to the new size.
---  * elements in the canvas that do not have the `absoluteSize` attribute set will be resized so that their size relative to the canvas remains the same with respect to the new size.
canvasMT.frame = function(obj, ...)
    local args = table.pack(...)

    if args.n == 0 then
        local topLeft = obj:topLeft()
        local size    = obj:size()
        return {
            __luaSkinType = "NSRect",
            x = topLeft.x,
            y = topLeft.y,
            h = size.h,
            w = size.w,
        }
    elseif args.n == 1 and type(args[1]) == "table" then
        obj:size(args[1])
        obj:topLeft(args[1])
        return obj
    elseif args.n > 1 then
        error("frame method expects 0 or 1 arguments", 2)
    else
        error("frame method argument must be a table", 2)
    end
end

--- hs._asm.canvas:bringToFront([aboveEverything]) -> canvasObject
--- Method
--- Places the canvas object on top of normal windows
---
--- Parameters:
---  * aboveEverything - An optional boolean value that controls how far to the front the canvas should be placed. Defaults to false.
---    * if true, place the canvas on top of all windows (including the dock and menubar and fullscreen windows).
---    * if false, place the canvas above normal windows, but below the dock, menubar and fullscreen windows.
---
--- Returns:
---  * The canvas object
canvasMT.bringToFront = function(obj, ...)
    local drawing = require"hs.drawing"
    local args = table.pack(...)

    if args.n == 0 then
        return obj:level(drawing.windowLevels.floating)
    elseif args.n == 1 and type(args[1]) == "boolean" then
        return obj:level(drawing.windowLevels[(args[1] and "screenSaver" or "floating")])
    elseif args.n > 1 then
        error("bringToFront method expects 0 or 1 arguments", 2)
    else
        error("bringToFront method argument must be boolean", 2)
    end
end

--- hs._asm.canvas:sendToBack() -> canvasObject
--- Method
--- Places the canvas object behind normal windows, between the desktop wallpaper and desktop icons
---
--- Parameters:
---  * None
---
--- Returns:
---  * The canvas object
canvasMT.sendToBack = function(obj, ...)
    local drawing = require"hs.drawing"
    local args = table.pack(...)

    if args.n == 0 then
        return obj:level(drawing.windowLevels.desktopIcon - 1)
    else
        error("sendToBack method expects 0", 2)
    end
end

--- hs._asm.canvas:isVisible() -> boolean
--- Method
--- Returns whether or not the canvas is currently showing and is (at least partially) visible on screen.
---
--- Parameters:
---  * None
---
--- Returns:
---  * a boolean indicating whether or not the canvas is currently visible.
---
--- Notes:
---  * This is syntactic sugar for `not hs._asm.canvas:isOccluded()`.
---  * See (hs._asm.canvas:isOccluded)[#isOccluded] for more details.
canvasMT.isVisible = function(obj, ...) return not obj:isOccluded(...) end

-- Return Module Object --------------------------------------------------

return module