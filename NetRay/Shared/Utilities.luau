--!optimize 2

--[[
    Utilities.lua
    Common utility functions used throughout the NetRay library
    Optimized version with caching and improved performance
    Author: Asta (@TheYusufGamer)
]]

local Utilities = {}

-- Type definition for LRU Manager (simplified placeholder)
-- Actual type depends on the implementation in CreateLRUManager
type LRUManager = {
	add: (key: string) -> (),
	touch: (key: string) -> (),
	remove: (key: string) -> (),
	getSize: () -> number,
}

-- Type definition for the Utilities module
export type UtilitiesModule = {
	generateId: () -> string,
	deepCopy: <T>(original: T, seen: {any}?) -> T,
	shallowCopy: <T>(original: T) -> T,
	timer: () -> (() -> number),
	throttle: <F>(fn: F, limit: number) -> F,
	debounce: <F>(fn: F, wait: number) -> F,
	safeCall: <T>(fn: (...any) -> T, ... any) -> (boolean, T | any), 
	memoize: <F>(fn: F, keyFn: ((...any) -> string)?, ttl: number?) -> F,
	isInstanceOf: (object: any, className: string) -> boolean,
	formatNetworkSize: (bytes: number) -> string,
	createLogger: (prefix: string) -> ((message: any, level: string?, context: any?) -> ()),
	waitFor: <T>(condition: () -> T?, timeout: number?, checkInterval: number?, onProgress: ((elapsed: number, total: number) -> ())?) -> (boolean, T | string),
	getMemoizeStats: () -> { cacheGroups: number, cacheEntries: number, cacheHits: number, cacheMisses: number, hitRatio: number },
	clearMemoizeCache: (fnId: string?) -> (),
	CreateLRUManager: (maxSize: number, onEvict: (key: string) -> ()) -> LRUManager,
	Table: {
		getPath: <T>(tbl: any, path: {string | number}, defaultValue: T?) -> T?,
		setPath: (tbl: any, path: {string | number}, value: any) -> (),
		isEmpty: (tbl: any) -> boolean,
		serialize: (tbl: table) -> string, -- Added type for serialize helper
	}
}


-- Cache stats (global for memoize, though individual instances have own cache now)
local memoizeCacheHits = 0
local memoizeCacheMisses = 0
local MAX_MEMOIZE_CACHE_SIZE = 100

-- Counter for ID generation (closure)
local idCounter = (function()
	local counter = 0
	return function(): number
		counter += 1
		return counter
	end
end)()

-- Local optimizations
local mathFloor = math.floor
local mathRandom = math.random
local mathMax = math.max -- Cache math.max
local stringFormat = string.format
local stringByte = string.byte
local stringSub = string.sub -- Cache string.sub
local tableCreate = table.create
local tableInsert = table.insert -- Cache table.insert
local tableRemove = table.remove
local tableConcat = table.concat -- Cache table.concat
local osTime = os.time
local tick = tick
local type = type -- Cache global type
local pairs = pairs -- Cache global pairs
local ipairs = ipairs -- Cache global ipairs
local pcall = pcall
local task = task -- Cache task library
local setmetatable = setmetatable
local getmetatable = getmetatable
local unpack = unpack -- Not used, can remove
local tostring = tostring -- Cache global tostring

-- Generate unique ID
function Utilities.generateId(): string
	local counter = idCounter()
	local time = osTime()
	local rand = mathRandom(0, 1048575)
	return stringFormat("%x%x%x", time, rand, counter % 16777215)
end

-- Deep copy with circular reference handling (generic)
function Utilities.deepCopy<T>(original: T, seen: {any}?): T
	if type(original) ~= "table" then return original end
	seen = seen or {}
	if seen[original] then return seen[original] end

	local copy = setmetatable({}, getmetatable(original))
	seen[original] = copy

	-- Simpler loop for deep copy, handles arrays implicitly
	for k, v in pairs(original) do
		copy[k] = Utilities.deepCopy(v, seen) -- Recursive call
	end

	return copy :: T -- Assert return type
end

-- Shallow copy (generic)
function Utilities.shallowCopy<T>(original: T): T
	if type(original) ~= "table" then return original end
	local copy = {}
	local mt = getmetatable(original)
	if mt then setmetatable(copy, mt) end
	for k, v in pairs(original) do copy[k] = v end
	return copy :: T -- Assert return type
end

-- Timer function
function Utilities.timer(): () -> number
	local startTime = tick()
	return function(): number
		return tick() - startTime
	end
end

-- Throttle function (generic)
function Utilities.throttle<F>(fn: F, limit: number): F
	if typeof(fn) ~= "function" then error("throttle expects a function", 2) end
	local lastCall = 0
	local queuedThread: thread | nil = nil
	local lastArgs: {any} | nil = nil

	return (function(...)
		local now = tick()
		local args = {...}
		lastArgs = args -- Store latest args

		if now - lastCall >= limit then
			lastCall = now
			if queuedThread then task.cancel(queuedThread); queuedThread = nil end
			-- Call fn directly (type F implies it's callable)
			local success, result = pcall(fn, unpack(args))
			if not success then warn("Error in throttled function:", result) end
			return result -- Return result of immediate call
		elseif not queuedThread then
			local timeToWait = limit - (now - lastCall)
			queuedThread = task.delay(timeToWait, function()
				queuedThread = nil
				lastCall = tick()
				if lastArgs then -- Check if args exist before unpacking
					local success, reason = pcall(fn, unpack(lastArgs))
					if not success then warn("Error in throttled delayed function:", reason) end
					lastArgs = nil -- Clear args after use
				end
			end)
		end
		return nil -- Throttled
	end) :: F -- Assert return type
end

-- Debounce function (generic)
function Utilities.debounce<F>(fn: F, wait: number): F
	if typeof(fn) ~= "function" then error("debounce expects a function", 2) end
	local scheduled: thread | nil = nil
	local argsRef: {any} | nil = nil

	return (function(...)
		argsRef = {...} -- Store latest args
		if scheduled then task.cancel(scheduled) end
		scheduled = task.delay(wait, function()
			scheduled = nil
			if argsRef then -- Check if args exist
				local success, reason = pcall(fn, unpack(argsRef))
				if not success then warn("Error in debounced function:", reason) end
				argsRef = nil -- Clear args after use
			end
		end)
	end) :: F -- Assert return type
end

-- Safe call (generic return)
function Utilities.safeCall<T>(fn: (...any) -> T, ...: any): (boolean, T | any)
	return pcall(fn, ...) -- Pass varargs using '...'
end

-- Memoize function (generic)
function Utilities.memoize<F>(fn: F, keyFn: ((...any) -> string)?, ttl: number?): F
	if typeof(fn) ~= "function" then error("memoize expects a function", 2) end

	local cache: {[string]: { result: {any}, time: number }?} = {}
	local lruManager = Utilities.CreateLRUManager(MAX_MEMOIZE_CACHE_SIZE, function(evictedKey: string)
		cache[evictedKey] = nil
	end)

	return (function(...)
		local args = {...}
		local key: string

		if keyFn then
			local keySuccess, keyResult = pcall(keyFn, unpack(args))
			if not keySuccess or type(keyResult) ~= "string" then
				warn("Memoize keyFn failed or returned non-string:", keyResult)
				key = "__MEMOIZE_KEY_ERROR__" -- Fallback key
			else
				key = keyResult
			end
		else
			-- Default key generation (simplified)
			key = ""
			for i=1, #args do
				key = key .. tostring(args[i]) .. "_"
			end
		end

		local cachedEntry = cache[key]
		if cachedEntry then
			if not ttl or (tick() - cachedEntry.time <= ttl) then
				memoizeCacheHits += 1
				lruManager:touch(key)
				return unpack(cachedEntry.result) -- Return cached result tuple
			else
				-- TTL expired
				cache[key] = nil
				lruManager:remove(key)
			end
		end

		-- Cache miss or expired
		memoizeCacheMisses += 1
		local result = {pcall(fn, unpack(args))} -- Call original function safely and store results in a table

		-- Let's cache regardless of pcall success for now. The result table contains [success, valueOrError]
		cache[key] = {
			result = result,
			time = tick()
		}
		lruManager:add(key)

		-- Check if the pcall succeeded before returning the actual value
		if result[1] then
			return unpack(result, 2) -- Return values from index 2 onwards
		else
			error(result[2]) -- Re-throw error if pcall failed
		end
	end) :: F -- Assert return type
end

-- Check custom __type field (not standard Lua OOP, specific to this library's potential pattern)
function Utilities.isInstanceOf(object: any, className: string): boolean
	return typeof(object) == "table" and rawget(object, "__type") == className
end

-- Format network size
function Utilities.formatNetworkSize(bytes: number): string
	if bytes < 1024 then return stringFormat("%d B", bytes)
	elseif bytes < 1048576 then return stringFormat("%.2f KB", bytes / 1024)
	else return stringFormat("%.2f MB", bytes / 1048576) -- Corrected MB calculation
	end
end

-- Create logger function
function Utilities.createLogger(prefix: string): (message: any, level: string?, context: any?) -> ()
	local formats = {
		INFO = "[NetRay:%s] INFO: %s", WARN = "[NetRay:%s] WARN: %s",
		ERROR = "[NetRay:%s] ERROR: %s", DEBUG = "[NetRay:%s] DEBUG: %s",
	}
	return function(message: any, level: string?, context: any?)
		level = level and string.upper(level) or "INFO" -- Ensure uppercase level
		local msgStr = typeof(message) == "table" and tableConcat(message, " ") or tostring(message)
		if context then
			local ctxStr = typeof(context) == "table" and Utilities.Table.serialize(context) or tostring(context) -- Example: Serialize table context
			msgStr = msgStr .. " " .. ctxStr
		end
		local fmt = formats[level] or formats.INFO
		local formatted = stringFormat(fmt, prefix, msgStr)
		if level == "ERROR" then error(formatted, 0) -- Level 0 to hide logger call itself
		elseif level == "WARN" then warn(formatted)
		else print(formatted) -- Print INFO and DEBUG
		end
	end
end

-- Wait for condition (generic success result)
function Utilities.waitFor<T>(condition: () -> T?, timeout: number?, checkInterval: number?, onProgress: ((elapsed: number, total: number) -> ())?): (boolean, T | string)
	timeout = timeout or 10
	checkInterval = checkInterval or 0.1
	local startTime = tick()
	local endTime = startTime + timeout

	while tick() < endTime do
		local success, result = pcall(condition) -- Call condition safely
		if success and result ~= nil then -- Check for non-nil success result
			return true, result :: T -- Return success and the value
		elseif not success then
			warn("Error in waitFor condition function:", result) -- Log error from condition
		end

		if onProgress then pcall(onProgress, tick() - startTime, timeout) end -- Call progress safely
		task.wait(checkInterval)
	end
	return false, "Timeout waiting for condition" -- Timeout
end

-- Get global memoize stats
function Utilities.getMemoizeStats(): { cacheGroups: number, cacheEntries: number, cacheHits: number, cacheMisses: number, hitRatio: number }
	local totalAttempts = memoizeCacheHits + memoizeCacheMisses
	local hitRatio = if totalAttempts > 0 then memoizeCacheHits / totalAttempts else 0
	return {
		cacheGroups = -1, -- Indicate not tracked globally
		cacheEntries = -1, -- Indicate not tracked globally
		cacheHits = memoizeCacheHits,
		cacheMisses = memoizeCacheMisses,
		hitRatio = hitRatio,
	}
end

-- Clear global memoize stats
function Utilities.clearMemoizeCache(fnId: string?) -- fnId has no effect now
	-- Only resets global counters, doesn't clear individual memoize caches
	memoizeCacheHits = 0
	memoizeCacheMisses = 0
end

-- Table utilities
Utilities.Table = {
	getPath = function<T>(tbl: any, path: {string | number}, default: T?): T?
		if type(tbl) ~= "table" then return default end
		local current = tbl
		for i=1, #path do
			local key = path[i]
			if typeof(current) ~= "table" then return default end -- Check intermediate step
			current = current[key]
			if current == nil then return default end
		end
		return current :: T? -- Assert return type
	end,
	setPath = function(tbl: any, path: {string | number}, value: any)
		if type(tbl) ~= "table" or #path == 0 then return end
		local current = tbl
		for i = 1, #path - 1 do
			local key = path[i]
			if typeof(current[key]) ~= "table" then current[key] = {} end -- Create table if needed
			current = current[key]
		end
		current[path[#path]] = value
	end,
	isEmpty = function(tbl: any): boolean
		return type(tbl) == "table" and next(tbl) == nil
	end,
	-- Add serialize function if needed by logger context
	serialize = function(tbl: table): string
		local parts = {}
		for k, v in pairs(tbl) do
			tableInsert(parts, tostring(k)..":"..tostring(v))
		end
		return "{" .. tableConcat(parts, ",") .. "}"
	end
}

-- Create LRU Manager instance
function Utilities.CreateLRUManager(maxSize: number, onEvict: (key: string) -> ()): LRUManager
	maxSize = mathMax(1, maxSize) -- Ensure maxSize is at least 1
	local lruList = { first = nil, last = nil, size = 0 } -- Doubly-linked list: {key, prev, next}
	local lruMap: {[string]: {key: string, prev: any?, next: any?}?} = {} -- Maps key -> node
	local manager = {} -- The object to return

	-- Define node type internally for clarity
	type LRUNode = {key: string, prev: LRUNode?, next: LRUNode?}

	-- Internal Helper Functions (defined locally, using explicit types)
	local removeNodeHelper: (node: LRUNode?) -> string?
	local removeLastHelper: () -> string?
	local moveToFrontHelper: (node: LRUNode?) -> ()
	local addNodeHelper: (key: string) -> ()

	removeNodeHelper = function(node: LRUNode?): string?
		if not node then return nil end
		local key = node.key
		if not lruMap[key] then return nil end -- Already removed?

		lruMap[key] = nil -- Remove from map first
		lruList.size -= 1

		local prevNode = node.prev
		local nextNode = node.next

		if node == lruList.first then lruList.first = nextNode end
		if node == lruList.last then lruList.last = prevNode end

		if prevNode then prevNode.next = nextNode end
		if nextNode then nextNode.prev = prevNode end

		return key
	end

	removeLastHelper = function(): string?
		return removeNodeHelper(lruList.last)
	end

	moveToFrontHelper = function(node: LRUNode?)
		if not node or node == lruList.first then return end -- No node or already at front

		local prevNode = node.prev
		local nextNode = node.next

		-- Detach node
		if node == lruList.last then
			lruList.last = prevNode
			if prevNode then prevNode.next = nil end
		else
			if prevNode then prevNode.next = nextNode end
			if nextNode then nextNode.prev = prevNode end
		end

		-- Attach to front
		node.prev = nil -- It becomes the new first node
		node.next = lruList.first
		if lruList.first then lruList.first.prev = node end
		lruList.first = node
		-- If list was empty/became empty, last should also be this node
		if not lruList.last then lruList.last = node end
	end

	addNodeHelper = function(key: string)
		if lruMap[key] then return end -- Key already exists, do nothing (or maybe move to front?)

		local node: LRUNode = { key = key, prev = nil, next = nil }
		lruMap[key] = node
		lruList.size += 1

		-- Insert at front
		node.next = lruList.first
		if lruList.first then
			lruList.first.prev = node
		end
		lruList.first = node
		-- If list was empty, it's also the last node
		if not lruList.last then
			lruList.last = node
		end

		-- Check eviction
		if lruList.size > maxSize then
			local evictedKey = removeLastHelper()
			if evictedKey and onEvict then
				-- Use pcall for safety as onEvict is user code
				local success, err = pcall(onEvict, evictedKey)
				if not success then warn("Error during LRU onEvict callback:", err) end
			end
		end
	end

	-- Public Methods (typed) assigned to manager table
	function manager:add(key: string) addNodeHelper(key) end
	function manager:touch(key: string) moveToFrontHelper(lruMap[key]) end -- Pass node to helper
	function manager:remove(key: string) removeNodeHelper(lruMap[key]) end -- Pass node to helper
	function manager:getSize(): number return lruList.size end

	return manager :: LRUManager -- Assert return type
end


return Utilities :: UtilitiesModule