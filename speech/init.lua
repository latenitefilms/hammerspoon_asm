--- === hs._asm.speech ===
---
--- This module provides access to the Speech Synthesizer component of OS X.
---
--- The speech synthesizer functions and methods provide access to OS X's Text-To-Speech capabilities and facilitates generating speech output both to the currently active audio device and to an AIFF file.
---
--- A discussion concerning the embedding of commands into the text to be spoken can be found at https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/SpeechSynthesisProgrammingGuide/FineTuning/FineTuning.html#//apple_ref/doc/uid/TP40004365-CH5-SW6.  It is somewhat dated and specific to the older MacinTalk style voices, but still contains some information relevant to the more modern higer quality voices as well in its discussion about embedded commands.

--- === hs._asm.speech.listener ===
---
--- This module provides access to the Speech Recognizer component of OS X.
---
--- The speech recognizer functions and methods provide a way to add commands which may be issued to Hammerspoon through spoken words and phrases to trigger a callback.

local module = require("hs._asm.speech.internal")
local log    = require("hs.logger").new("hs._asm.speech","warning")
module.log = log
module._registerLogForC(log)
module._registerLogForC = nil

module.listener = require("hs._asm.speech.listener")
module.listener._registerLogForC(log)
module.listener._registerLogForC = nil

-- private variables and methods -----------------------------------------

local _kMetaTable = {}
_kMetaTable._k = {}
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
_kMetaTable.__tostring = function(obj)
        local result = ""
        if _kMetaTable._k[obj] then
            local width = 0
            for k,v in pairs(_kMetaTable._k[obj]) do width = width < #k and #k or width end
            for k,v in require("hs.fnutils").sortByKeys(_kMetaTable._k[obj]) do
                result = result..string.format("%-"..tostring(width).."s %s\n", k, tostring(v))
            end
        else
            result = "constants table missing"
        end
        return result
    end
_kMetaTable.__metatable = _kMetaTable -- go ahead and look, but don't unset this

local _makeConstantsTable = function(theTable)
    local results = setmetatable({}, _kMetaTable)
    _kMetaTable._k[results] = theTable
    return results
end

-- Public interface ------------------------------------------------------

if module.properties        then module.properties        = _makeConstantsTable(module.properties)         end
if module.speakingModes     then module.speakingModes     = _makeConstantsTable(module.speakingModes)      end
if module.characterModes    then module.characterModes    = _makeConstantsTable(module.characterModes)     end
if module.commandDelimiters then module.commandDelimiters =  _makeConstantsTable(module.commandDelimiters) end

-- Return speech Object --------------------------------------------------

return module
