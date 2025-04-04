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

-- Note: Global LRU list/map for memoize is being replaced by instance-based LRU Managers

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
	local fnId = tostring(fn):sub(1, 8) -- Use partial function identity for grouping

	-- Memoize now uses its own instance of the LRU manager
	local cache = {} -- The actual data cache
	local lruManager = Utilities.CreateLRUManager(MAX_MEMOIZE_CACHE_SIZE, function(evictedKey)
		-- Eviction callback: remove the item from the actual cache
		if cache[evictedKey] then
			cache[evictedKey] = nil
		end
	end)
	-- The fnId grouping is less relevant now cache/lru is per-memoized function instance
	-- Remove the global memoizeCache logic

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

				lruManager:remove(key) -- Use manager to handle removal
			else
				-- Valid cache hit
				memoizeCacheHits += 1

				lruManager:touch(key) -- Mark as recently used

				return unpack(cache[key].result)
			end
		end

		-- Cache miss
		memoizeCacheMisses += 1

		-- Call the original function
		local result = {fn(unpack(args))}

		-- Add to cache and handle potential eviction via LRU manager
		cache[key] = {
			result = result,
			time = tick() -- Add timestamp for TTL
		}
		lruManager:add(key) -- Adds to LRU list and triggers eviction callback if needed

		-- Store in cache
		-- Result is already in cache[key] from line 428's block

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
	} -- Add LRU manager creation below

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
    Get *global* statistics about the memoize cache calls.
    Note: Cannot report total combined size of individual instance LRU lists.
    @return: Table with cache statistics
]]
function Utilities.getMemoizeStats()
	local cacheEntries = 0
	local cacheGroups = 0

	-- Iterate over the main cache structure holding results
	for groupId, group in pairs(memoizeCache) do
		if type(group) == "table" then -- Ensure group is a table (might be nil if cleared selectively)
			cacheGroups += 1
			for key, entry in pairs(group) do
				-- Check if entry structure is as expected before counting
				if type(entry) == "table" and entry.result ~= nil then
					cacheEntries += 1
				end
			end
		end
	end

	-- Calculate hit ratio, avoiding division by zero
	local totalAttempts = memoizeCacheHits + memoizeCacheMisses
	local hitRatio = if totalAttempts > 0 then memoizeCacheHits / totalAttempts else 0

	return {
		cacheGroups = cacheGroups,       -- Number of distinct memoized function calls (approx)
		cacheEntries = cacheEntries,     -- Total number of cached results across all groups
		cacheHits = memoizeCacheHits,    -- Total hits across all memoized functions
		cacheMisses = memoizeCacheMisses,-- Total misses across all memoized functions
		hitRatio = hitRatio,
	}
end

--[[
    Clear the memoize cache data and global statistics.
    Note: This clears the stored results but cannot reset the internal LRU state
    of individual memoized function instances without a more complex registry system.
    @param fnId: Optional function ID (partial hash) to clear only a specific function's cache.
                 Currently, fnId handling is not fully implemented as memoize creates
                 isolated cache/LRU instances per call. This parameter is kept for
                 potential future enhancements or compatibility but currently has limited effect.
                 If fnId is nil, it clears the entire top-level cache data structure.
]]
function Utilities.clearMemoizeCache(fnId)
	if fnId then
		if memoizeCache[fnId] then
			memoizeCache[fnId] = nil -- Remove the group's data cache
		end
	else
		-- Clear the entire cache data structure
		memoizeCache = {}
	end

	-- Reset global statistics (These track overall hits/misses across all memoized functions)
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

--[[
	Create an LRU Manager instance.
	Manages the order of keys based on access, evicting the least recently used
	when the size limit is exceeded.
	@param maxSize: Maximum number of items to track
	@param onEvict: Function(key) called when a key is evicted due to size limit
	@return: An LRU Manager object with :add(key), :touch(key), :remove(key) methods
]]
function Utilities.CreateLRUManager(maxSize, onEvict)
	local lruList = { first = nil, last = nil, size = 0 } -- Doubly-linked list: {key, prev, next}
	local lruMap = {} -- Maps key -> node in lruList
	local manager = {} -- The object to return

	-- Internal Helper Functions (defined locally)
	local removeNodeHelper, removeLastHelper, moveToFrontHelper, addNodeHelper -- Forward declare

	removeNodeHelper = function(node)
		if not node then return nil end
		local key = node.key
		if not lruMap[key] then return nil end

		lruMap[key] = nil
		lruList.size -= 1

		if node == lruList.first then lruList.first = node.next end
		if node == lruList.last then lruList.last = node.prev end

		if node.prev then node.prev.next = node.next end
		if node.next then node.next.prev = node.prev end

		return key
	end

	removeLastHelper = function()
		if not lruList.last then return nil end
		return removeNodeHelper(lruList.last)
	end

	moveToFrontHelper = function(node)
		if not node or node == lruList.first then return end

		-- Detach node
		if node == lruList.last then
			lruList.last = node.prev
			if lruList.last then lruList.last.next = nil end
		else
			if node.prev then node.prev.next = node.next end -- Ensure prev exists
			if node.next then node.next.prev = node.prev end -- Ensure next exists
		end
		-- Nullify node's pointers after detaching (might not be necessary but safer)
		node.prev, node.next = nil, nil

		-- Attach to front
		node.next = lruList.first
		-- node.prev is already nil
		if lruList.first then lruList.first.prev = node end
		lruList.first = node

		-- Update last pointer if list was empty or became empty after detaching the single node
		if not lruList.last then lruList.last = node end
	end

	addNodeHelper = function(key)
		if lruMap[key] then return end -- Key already exists

		local node = { key = key, prev = nil, next = nil }
		lruMap[key] = node
		lruList.size += 1

		if not lruList.first then
			lruList.first = node
			lruList.last = node
		else
			node.next = lruList.first
			lruList.first.prev = node
			lruList.first = node
		end

		-- Check eviction
		if lruList.size > maxSize then
			local evictedKey = removeLastHelper()
			if evictedKey and onEvict then
				onEvict(evictedKey) -- Call callback to remove from actual cache
			end
		end
	end

	-- Public Methods assigned to manager table
	function manager:add(key)
		addNodeHelper(key) -- Calls local helper
	end

	function manager:touch(key)
		local node = lruMap[key]
		if node then
			moveToFrontHelper(node) -- Calls local helper
		end
	end

	function manager:remove(key)
		local node = lruMap[key]
		if node then
			removeNodeHelper(node) -- Calls local helper
		end
	end

	function manager:getSize()
		return lruList.size
	end

	return manager
end

return Utilities
