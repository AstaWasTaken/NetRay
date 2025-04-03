--!strict
--!optimize 2
--!native

--[[    
    Utilities.lua
    Common utility functions used throughout the NetRay library
    Optimized version with caching and improved performance
    Author: Asta (@TheYusufGamer)
]]

local Utilities = {}

-- Cache for expensive operations with LRU implementation
local memoizeCache = {}
local memoizeCacheHits = 0
local memoizeCacheMisses = 0
local memoizeCacheSize = 0
local MAX_MEMOIZE_CACHE_SIZE = 100

-- LRU tracking
local lruList = { first = nil, last = nil } -- Doubly-linked list for LRU tracking
local lruMap = {} -- Maps cache keys to nodes in LRU list

-- Counter for ID generation
local idCounter = (function()
    local counter = 0
    return function()
        counter += 1
        return counter
    end
end)()

-- Local optimizations
local mathFloor = math.floor
local mathRandom = math.random
local stringFormat = string.format
local stringByte = string.byte
local tableCreate = table.create
local tableFastRemove = table.remove
local osTime = os.time
local tick = tick

--[[    
    Generate a unique ID for requests and events
    @return: A unique string ID
]]
function Utilities.generateId()
    -- Combine time, random number, and sequence counter for uniqueness
    local counter = idCounter()
    local time = osTime()
    local rand = mathRandom(0, 1048575)
    
    -- Format with bit operations for better performance
    return stringFormat("%x%x%x", time, rand, counter % 16777215)
end

--[[    
    Utility functions for LRU cache management
]]
local function lruAddNode(key)
    local node = { key = key, prev = nil, next = nil }
    
    if not lruList.first then
        -- Empty list
        lruList.first = node
        lruList.last = node
    else
        -- Add to front (most recently used)
        node.next = lruList.first
        lruList.first.prev = node
        lruList.first = node
    end
    
    lruMap[key] = node
    return node
end

local function lruMoveToFront(node)
    if node == lruList.first then return end -- Already at front
    
    -- Remove from current position
    if node == lruList.last then
        -- Last node
        lruList.last = node.prev
        lruList.last.next = nil
    else
        -- Middle node
        node.prev.next = node.next
        node.next.prev = node.prev
    end
    
    -- Add to front
    node.next = lruList.first
    node.prev = nil
    lruList.first.prev = node
    lruList.first = node
end

local function lruRemoveLast()
    if not lruList.last then return nil end
    
    local lastNode = lruList.last
    local key = lastNode.key
    
    if lruList.first == lruList.last then
        -- Only one node
        lruList.first = nil
        lruList.last = nil
    else
        -- More than one node
        lruList.last = lastNode.prev
        lruList.last.next = nil
    end
    
    lruMap[key] = nil
    return key
end

--[[    
    Deep copy a table with circular reference handling and optimization for arrays
    @param original: The table to copy
    @param seen: Internal parameter for tracking circular references
    @return: A deep copy of the original table
]]
function Utilities.deepCopy(original, seen)
    -- Handle non-table values and nil
    if type(original) ~= "table" then
        return original
    end
    
    -- Handle circular references
    seen = seen or {}
    if seen[original] then
        return seen[original]
    end
    
    -- Create new table with same metatable
    local copy = setmetatable({}, getmetatable(original))
    seen[original] = copy
    
    -- Fast path for array-like tables (numeric indices)
    local isArray = true
    local count = 0
    local maxIndex = 0
    
    -- First pass to determine if it's an array
    for k, _ in pairs(original) do
        count += 1
        if type(k) == "number" and k == mathFloor(k) and k > 0 then
            maxIndex = math.max(maxIndex, k)
        else
            isArray = false
            break
        end
    end
    
    if isArray and count > 0 and count == maxIndex then
        -- It's a proper array with no holes
        local arrayCopy = tableCreate(count)
        
        -- Fast path for arrays of primitives or same type
        local allPrimitives = true
        local firstItemType = nil
        
        -- Check if all items are primitives or same complex type
        for i = 1, count do
            local itemType = type(original[i])
            if i == 1 then
                firstItemType = itemType
            end
            
            if itemType == "table" or (firstItemType ~= itemType) then
                allPrimitives = false
                break
            end
        end
        
        if allPrimitives then
            -- Fast copy for arrays of primitives
            for i = 1, count do
                arrayCopy[i] = original[i]
            end
        else
            -- Regular copy for mixed arrays
            for i = 1, count do
                if type(original[i]) == "table" then
                    arrayCopy[i] = Utilities.deepCopy(original[i], seen)
                else
                    arrayCopy[i] = original[i]
                end
            end
        end
        
        -- Copy array to result
        for k, v in pairs(arrayCopy) do
            copy[k] = v
        end
    else
        -- Regular table copy with key typechecking
        for k, v in pairs(original) do
            if type(v) == "table" then
                copy[k] = Utilities.deepCopy(v, seen)
            else
                copy[k] = v
            end
        end
    end
    
    return copy
end

--[[    
    Memory-efficient shallow copy for tables
    @param original: The table to copy
    @return: A shallow copy of the original table
]]
function Utilities.shallowCopy(original)
    if type(original) ~= "table" then
        return original
    end
    
    local copy = {}
    
    -- Preserve metatable if present
    local mt = getmetatable(original)
    if mt then
        setmetatable(copy, mt)
    end
    
    -- Fast copy of key-value pairs
    for k, v in pairs(original) do
        copy[k] = v
    end
    
    return copy
end

--[[    
    Measure elapsed time for performance monitoring
    @return: A function that returns the elapsed time in seconds
]]
function Utilities.timer()
    local startTime = tick()
    return function()
        return tick() - startTime
    end
end

--[[    
    Throttle a function call with improved memory management
    @param fn: The function to throttle
    @param limit: The minimum time between calls (in seconds)
    @return: A throttled function
]]
function Utilities.throttle(fn, limit)
    local lastCall = 0
    local queuedThread = nil
    local lastArgs = nil
    
    return function(...)
        local now = tick()
        local args = {...}
        
        -- Store only the most recent args
        lastArgs = args
        
        if now - lastCall >= limit then
            -- Enough time has passed, execute immediately
            lastCall = now
            
            -- Cancel any queued execution
            if queuedThread then
                task.cancel(queuedThread)
                queuedThread = nil
            end
            
            return fn(unpack(args))
        elseif not queuedThread then
            -- Queue one call to happen after the throttle period
            local timeToWait = limit - (now - lastCall)
            
            queuedThread = task.delay(timeToWait, function()
                queuedThread = nil
                lastCall = tick()
                
                -- Use the most recent args when executing
                fn(unpack(lastArgs))
                
                -- Clean up reference
                lastArgs = nil
            end)
        end
        
        -- Return nil if throttled
        return nil
    end
end

--[[    
    Debounce a function call with better cleanup
    @param fn: The function to debounce
    @param wait: The time to wait after the last call (in seconds)
    @return: A debounced function
]]
function Utilities.debounce(fn, wait)
    local scheduled = nil
    local argsRef = nil
    
    return function(...)
        -- Store only the most recent args
        argsRef = {...}
        
        -- Cancel previous execution
        if scheduled then
            task.cancel(scheduled)
        end
        
        -- Schedule new execution
        scheduled = task.delay(wait, function()
            scheduled = nil
            
            -- Call with the most recent args
            fn(unpack(argsRef))
            
            -- Clean up reference
            argsRef = nil
        end)
    end
end

--[[    
    Safely call a function and catch any errors
    @param fn: The function to call
    @param ...: Arguments to pass to the function
    @return: success, result or error message
]]
function Utilities.safeCall(fn, ...)
    return pcall(fn, ...)
end

--[[    
    Memoize a function to cache expensive results with LRU eviction
    @param fn: The function to memoize
    @param keyFn: Optional function to generate cache keys (defaults to serializing all args)
    @param ttl: Optional time-to-live for cache entries in seconds (defaults to no expiration)
    @return: Memoized function with same signature as original
]]
function Utilities.memoize(fn, keyFn, ttl)
    local cache = {}
    local fnId = tostring(fn):sub(1, 8) -- Use partial function identity for grouping
    
    -- Create or retrieve cache for this function
    if not memoizeCache[fnId] then
        memoizeCache[fnId] = cache
        memoizeCacheSize += 1
    else
        cache = memoizeCache[fnId]
    end
    
    return function(...)
        local args = {...}
        local key
        
        -- Generate cache key
        if keyFn then
            key = keyFn(unpack(args))
        else
            -- Default key generation - faster implementation
            key = ""
            for i, arg in ipairs(args) do
                if type(arg) == "table" then
                    -- Simple hash for tables using length and first few elements
                    local hash = 0
                    local count = 0
                    
                    -- Include table length in hash
                    local tbl = arg
                    local length = #tbl
                    hash = hash + length * 31
                    
                    -- Hash a subset of the table elements
                    for k, v in pairs(tbl) do
                        hash = hash + (stringByte(tostring(k):sub(1, 1)) + stringByte(tostring(v):sub(1, 1))) * 17
                        count += 1
                        if count > 5 then break end -- Only hash a few elements
                    end
                    
                    key = key .. "t" .. hash .. "_"
                else
                    -- Direct string representation for primitives
                    key = key .. type(arg):sub(1, 1) .. tostring(arg) .. "_"
                end
            end
        end
        
        -- Check cache hit
        if cache[key] then
            -- Check TTL if specified
            if ttl and cache[key].time and (tick() - cache[key].time > ttl) then
                -- TTL expired, remove from cache
                cache[key] = nil
                
                -- Remove from LRU tracking
                if lruMap[key] then
                    lruMoveToFront(lruMap[key])
                    lruRemoveLast()
                end
            else
                -- Valid cache hit
                memoizeCacheHits += 1
                
                -- Update LRU status
                if lruMap[key] then
                    lruMoveToFront(lruMap[key])
                end
                
                return unpack(cache[key].result)
            end
        end
        
        -- Cache miss
        memoizeCacheMisses += 1
        
        -- Call the original function
        local result = {fn(unpack(args))}
        
        -- Manage cache size using LRU
        local totalCacheEntries = 0
        for _, funcCache in pairs(memoizeCache) do
            for _ in pairs(funcCache) do
                totalCacheEntries += 1
            end
        end
        
        -- Evict entries if cache is full
        if totalCacheEntries >= MAX_MEMOIZE_CACHE_SIZE then
            local lruKey = lruRemoveLast()
            if lruKey then
                -- Find and remove the entry from its function cache
                for _, funcCache in pairs(memoizeCache) do
                    if funcCache[lruKey] then
                        funcCache[lruKey] = nil
                        break
                    end
                end
            end
        end
        
        -- Add to LRU tracking
        lruAddNode(key)
        
        -- Store in cache
        cache[key] = {
            result = result,
            time = tick() -- Add timestamp for TTL and LRU
        }
        
        return unpack(result)
    end
end

--[[    
    Check if an object is an instance of a specified class
    @param object: The object to check
    @param className: The name of the class
    @return: true if object is an instance of className
]]
function Utilities.isInstanceOf(object, className)
    return typeof(object) == "table" and object.__type == className
end

--[[    
    Format network size for display (bytes to human-readable)
    @param bytes: The number of bytes
    @return: A formatted string (e.g., "1.5 KB")
]]
function Utilities.formatNetworkSize(bytes)
    if bytes < 1024 then
        return stringFormat("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return stringFormat("%.2f KB", bytes / 1024)
    else
        return stringFormat("%.2f MB", bytes / (1024 * 1024))
    end
end

--[[    
    Create a simple logger function with specified prefix and enhanced formatting
    @param prefix: Prefix for log messages
    @return: Logger function
]]
function Utilities.createLogger(prefix)
    -- Pre-compile string format for better performance
    local formats = {
        INFO = "[NetRay:%s] INFO: %s",
        WARN = "[NetRay:%s] WARN: %s",
        ERROR = "[NetRay:%s] ERROR: %s",
        DEBUG = "[NetRay:%s] DEBUG: %s",
    }
    
    return function(message, level, context)
        level = level or "INFO"
        
        -- Format the message
        local messageStr = ""
        if typeof(message) == "table" then
            messageStr = table.concat(message, " ")
        else
            messageStr = tostring(message)
        end
        
        -- Add context if provided
        if context then
            local contextStr = ""
            if typeof(context) == "table" then
                -- Format table context as key-value pairs
                local pairs = {}
                for k, v in pairs(context) do
                    table.insert(pairs, tostring(k) .. "=" .. tostring(v))
                end
                contextStr = "[" .. table.concat(pairs, ", ") .. "]"
            else
                contextStr = "[" .. tostring(context) .. "]"
            end
            messageStr = messageStr .. " " .. contextStr
        end
        
        local formatted = stringFormat(
            formats[level] or formats.INFO,
            prefix,
            messageStr
        )
        
        if level == "ERROR" then
            error(formatted)
        elseif level == "WARN" then
            warn(formatted)
        elseif level == "DEBUG" then
            -- Only print debug messages in non-production environments
            -- You can add a debug flag check here if needed
            print(formatted)
        else
            print(formatted)
        end
    end
end

--[[    
    Wait for a condition to be met with timeout and progress monitoring
    @param condition: Function that returns true when condition is met
    @param timeout: Maximum time to wait in seconds
    @param checkInterval: Time between condition checks
    @param onProgress: Optional callback for progress updates (receives elapsed/total time)
    @return: success, result or timeout message
]]
function Utilities.waitFor(condition, timeout, checkInterval, onProgress)
    timeout = timeout or 10
    checkInterval = checkInterval or 0.1
    
    local startTime = tick()
    local endTime = startTime + timeout
    
    while tick() < endTime do
        local currentTime = tick()
        local result = condition()
        
        if result then
            return true, result
        end
        
        -- Call progress callback if provided
        if onProgress and type(onProgress) == "function" then
            local elapsed = currentTime - startTime
            onProgress(elapsed, timeout)
        end
        
        task.wait(checkInterval)
    end
    
    return false, "Timeout waiting for condition"
end

--[[    
    Get statistics about the memoize cache
    @return: Table with cache statistics
]]
function Utilities.getMemoizeStats()
    local cacheEntries = 0
    local cacheGroups = 0
    
    for groupId, group in pairs(memoizeCache) do
        cacheGroups += 1
        for key, _ in pairs(group) do
            cacheEntries += 1
        end
    end
    
    return {
        cacheGroups = cacheGroups,
        cacheEntries = cacheEntries,
        cacheHits = memoizeCacheHits,
        cacheMisses = memoizeCacheMisses,
        hitRatio = memoizeCacheHits / (memoizeCacheHits + memoizeCacheMisses + 0.0001),
        lruSize = #lruMap
    }
end

--[[    
    Clear the memoize cache
    @param fnId: Optional function ID to clear only a specific function's cache
]]
function Utilities.clearMemoizeCache(fnId)
    if fnId then
        memoizeCache[fnId] = nil
    else
        memoizeCache = {}
        memoizeCacheSize = 0
    end
    
    -- Reset LRU tracking
    lruList = { first = nil, last = nil }
    lruMap = {}
    
    -- Reset statistics
    memoizeCacheHits = 0
    memoizeCacheMisses = 0
end

--[[    
    Table utilities optimized for Luau
]]
Utilities.Table = {
    -- Safely get a nested table value with a default
    getPath = function(tbl, path, default)
        if type(tbl) ~= "table" then return default end
        
        local current = tbl
        for _, key in ipairs(path) do
            if type(current) ~= "table" then return default end
            current = current[key]
            if current == nil then return default end
        end
        
        return current
    end,
    
    -- Set a nested table value, creating intermediate tables as needed
    setPath = function(tbl, path, value)
        if type(tbl) ~= "table" or #path == 0 then return end
        
        local current = tbl
        for i = 1, #path - 1 do
            local key = path[i]
            if current[key] == nil or type(current[key]) ~= "table" then
                current[key] = {}
            end
            current = current[key]
        end
        
        current[path[#path]] = value
    end,
    
    -- Check if a table is empty
    isEmpty = function(tbl)
        if type(tbl) ~= "table" then return true end
        return next(tbl) == nil
    end
}

return Utilities
