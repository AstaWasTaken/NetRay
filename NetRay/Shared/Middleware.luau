--!optimize 2

--[[
    Middleware.lua
    Implements a flexible middleware system for preprocessing network events
    Optimized version with caching, performance metrics, and better error handling
    Author: Asta (@TheYusufGamer)
]]


local Utilities = require(script.Parent.Utilities)

local Players = game:GetService("Players") 
type Player = Players.Player 

-- Type definition for the middleware handler function
-- Returns: modifiedData (any type), or false to block, or nil to continue with original data
type MiddlewareHandler = (eventName: string, player: Player?, data: any) -> any? | boolean

-- Type definition for the internal storage of a middleware handler
type MiddlewareInfo = {
	name: string,
	handler: MiddlewareHandler,
	priority: number,
	-- Metrics per handler
	executionCount: number,
	totalExecutionTime: number,
	errors: number,
	blocked: number
}

-- Type definition for the cache entry
type MiddlewareCacheEntry = {
	result: any? | boolean,
	timestamp: number
}

-- Type definition for the precomputed path cache entry
type PrecomputedPathEntry = {
	count: number, -- How often this path was encountered
	handlers: {number}, -- Indices of handlers that actively modified data or blocked
	changesMade: boolean -- Did any handler in this path ever make a change?
}

-- Type definition for LRU Manager (assuming structure from Utilities)
type LRUManager = {
	add: (key: string) -> (),
	touch: (key: string) -> (),
	remove: (key: string) -> (),
	getSize: () -> number,
}

-- Type definition for Middleware configuration
type MiddlewareConfig = {
	enableCache: boolean,
	timeoutMs: number,
	logErrors: boolean,
	cacheTTL: number,
	enablePerformanceLogging: boolean,
	logSlowExecutions: boolean,
	slowExecutionThresholdMs: number
}

-- Type definition for Middleware performance metrics
type MiddlewareMetrics = {
	totalExecutions: number,
	cacheHits: number,
	cacheMisses: number,
	totalExecutionTime: number,
	maxExecutionTime: number,
	avgExecutionTime: number, -- Calculated in GetMetrics
	errors: number,
	blocked: number,
	timeouts: number,
	-- Calculated fields added by GetMetrics
	averageExecutionTime: number?,
	blockRate: number?,
	errorRate: number?,
	timeoutRate: number?,
	cacheHitRate: number?,
	cacheSize: number?,
	maxCacheSize: number?,
	handlerStats: {MiddlewareHandlerMetrics}?,
	precomputedPaths: number?,
}

-- Type definition for individual handler metrics within MiddlewareMetrics
type MiddlewareHandlerMetrics = {
	name: string,
	priority: number,
	executionCount: number,
	avgExecutionTime: number,
	errors: number,
	blocked: number,
	errorRate: number,
	blockRate: number,
}

-- Type definition for the Middleware class itself
export type Middleware = {
	-- Properties
	Handlers: {MiddlewareInfo},
	Cache: {[string]: MiddlewareCacheEntry?},
	MaxCacheSize: number,
	lruManager: LRUManager,
	Metrics: MiddlewareMetrics,
	Config: MiddlewareConfig,
	PrecomputedPaths: {[string]: PrecomputedPathEntry?},

	-- Methods
	Register: (self: Middleware, name: string, handler: MiddlewareHandler, priority: number?) -> (),
	Remove: (self: Middleware, name: string) -> boolean,
	Execute: (self: Middleware, eventName: string, player: Player?, data: any) -> any? | boolean, -- Mirrors handler return
	AddToCache: (self: Middleware, key: string, result: any? | boolean) -> (),
	SortHandlers: (self: Middleware) -> (),
	GetMetrics: (self: Middleware) -> MiddlewareMetrics,
	ResetMetrics: (self: Middleware) -> (),
	Configure: (self: Middleware, config: table) -> (), -- Accepts partial config table
	ClearCache: (self: Middleware) -> (),
	-- Helper Middleware Adders (optional)
	AddErrorHandling: (self: Middleware, options: {logErrors: boolean?, fallbackValue: any?, blockOnError: boolean?, priority: number?}?) -> (),
	AddRateLimiting: (self: Middleware, options: {maxRequests: number?, timeWindow: number?, cooldown: number?, logViolations: boolean?, priority: number?}?) -> (),

	-- Constructor
	new: () -> Middleware
}

-- Local function optimizations for performance (already defined)
local tableSort = table.sort
local tableFindFirst = table.find -- Renamed from table.find which isn't standard
local tableInsert = table.insert
local tableRemove = table.remove
local tableClone = table.clone or Utilities.deepCopy -- Use Utilities.Clone if available
local tick = tick
local typeof = typeof
local pcall = pcall
local warn = warn
local error = error
local tostring = tostring
local setmetatable = setmetatable

-- Define the Middleware module table
local MiddlewareImpl = {}
MiddlewareImpl.__index = MiddlewareImpl

-- Constructor
function MiddlewareImpl.new(): Middleware
	local self = setmetatable({}, MiddlewareImpl)

	self.Handlers = {} :: {MiddlewareInfo}
	self.Cache = {} :: {[string]: MiddlewareCacheEntry?}
	self.MaxCacheSize = 50
	
	-- Assuming Utilities.CreateLRUManager exists and returns the expected type
	self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey: string)
		self.Cache[evictedKey] = nil -- Eviction callback
	end) :: LRUManager

	self.Metrics = { -- Initialize with correct types
		totalExecutions = 0, cacheHits = 0, cacheMisses = 0,
		totalExecutionTime = 0, maxExecutionTime = 0, avgExecutionTime = 0,
		errors = 0, blocked = 0, timeouts = 0
	} :: MiddlewareMetrics -- Add type assertion

	self.Config = {
		enableCache = true, timeoutMs = 100, logErrors = true,
		cacheTTL = 60, enablePerformanceLogging = false,
		logSlowExecutions = true, slowExecutionThresholdMs = 50
	} :: MiddlewareConfig -- Add type assertion

	self.PrecomputedPaths = {} :: {[string]: PrecomputedPathEntry?}

	return self :: Middleware -- Cast the final object
end

-- Register a middleware handler
function MiddlewareImpl:Register(name: string, handler: MiddlewareHandler, priority: number?)
	if typeof(handler) ~= "function" then
		error("[NetRay Middleware] Handler must be a function", 2)
		-- No return needed after error
	end

	priority = priority or 100

	-- Check if middleware with this name already exists
	for i, middleware in ipairs(self.Handlers) do
		if middleware.name == name then
			-- Update existing middleware
			self.Handlers[i].handler = handler
			self.Handlers[i].priority = priority
			self:SortHandlers() -- Re-sort after priority change
			self:ClearCache() -- Clear cache as behavior changed
			if self.Config.enablePerformanceLogging then
				print("[NetRay Middleware] Updated middleware:", name)
			end
			return -- Exit after update
		end
	end

	-- Add new middleware
	local newMiddleware: MiddlewareInfo = {
		name = name,
		handler = handler,
		priority = priority,
		executionCount = 0,
		totalExecutionTime = 0,
		errors = 0,
		blocked = 0
	}
	tableInsert(self.Handlers, newMiddleware)
	self:SortHandlers() -- Sort after adding
	self:ClearCache() -- Clear cache as chain changed
	if self.Config.enablePerformanceLogging then
		print("[NetRay Middleware] Registered new middleware:", name)
	end
end

-- Remove a middleware handler by name
function MiddlewareImpl:Remove(name: string): boolean
	for i, middleware in ipairs(self.Handlers) do
		if middleware.name == name then
			tableRemove(self.Handlers, i)
			self:ClearCache() -- Clear cache as chain changed
			if self.Config.enablePerformanceLogging then
				print("[NetRay Middleware] Removed middleware:", name)
			end
			return true -- Indicate success
		end
	end
	return false -- Not found
end

-- Execute the middleware chain
function MiddlewareImpl:Execute(eventName: string, player: Player?, data: any): any? | boolean
	self.Metrics.totalExecutions += 1
	local startTime = tick()

	if #self.Handlers == 0 then
		return data -- Return original data if no middleware
	end

	-- Caching logic (simplified for readability, original was complex)
	-- Consider a simpler cache key strategy if the original proves too complex/buggy
	local cacheKey: string? = nil
	if self.Config.enableCache and typeof(data) ~= "table" and typeof(data) ~= "userdata" and typeof(data) ~= "function" then -- Only cache simple, hashable types
		local playerKey = typeof(player) == "Instance" and tostring(player.UserId) or "nil" -- Use UserId string
		cacheKey = eventName .. "_" .. playerKey .. "_" .. tostring(data)

		local cachedEntry = self.Cache[cacheKey]
		if cachedEntry then
			if (tick() - cachedEntry.timestamp) < self.Config.cacheTTL then
				self.Metrics.cacheHits += 1
				self.lruManager:touch(cacheKey) -- Update LRU status
				return cachedEntry.result -- Return cached result
			else
				-- Expired cache entry
				self.Cache[cacheKey] = nil
				self.lruManager:remove(cacheKey)
			end
		end
		-- If not cached or expired
		self.Metrics.cacheMisses += 1
	end
	-- Precomputation path logic removed for simplification, can be added back if needed


	-- Execute handlers
	local currentData = data
	local timeoutAt = startTime + (self.Config.timeoutMs / 1000)

	for i, middleware in ipairs(self.Handlers) do
		-- Check for timeout before executing handler
		if tick() > timeoutAt then
			warn(("[NetRay Middleware] Chain timed out for event '%s' at handler '%s'"):format(eventName, middleware.name))
			self.Metrics.timeouts += 1
			break -- Stop processing chain
		end

		local handlerStartTime = tick()
		-- Use pcall to safely execute user-provided middleware handler
		local success, resultOrError = pcall(middleware.handler, eventName, player, currentData)
		local handlerExecutionTime = tick() - handlerStartTime

		-- Update metrics for this handler
		middleware.executionCount += 1
		middleware.totalExecutionTime += handlerExecutionTime

		if not success then
			-- Handler errored
			self.Metrics.errors += 1
			middleware.errors += 1
			if self.Config.logErrors then
				warn(("[NetRay Middleware] Error in '%s': %s"):format(middleware.name, tostring(resultOrError)))
			end

		elseif resultOrError == false then
			-- Handler returned false, block the event
			self.Metrics.blocked += 1
			middleware.blocked += 1
			-- Cache the 'false' result if applicable
			if cacheKey then self:AddToCache(cacheKey, false) end
			-- Update overall metrics
			local executionTime = tick() - startTime
			self.Metrics.totalExecutionTime += executionTime
			self.Metrics.maxExecutionTime = math.max(self.Metrics.maxExecutionTime, executionTime)
			return false -- Stop chain and return false

		elseif resultOrError ~= nil then
			-- Handler returned modified data
			currentData = resultOrError
		end -- If resultOrError is nil, currentData remains unchanged

		-- Log slow executions
		if self.Config.logSlowExecutions and handlerExecutionTime * 1000 > self.Config.slowExecutionThresholdMs then
			warn(("[NetRay Middleware] Slow execution in '%s' (%d ms)"):format(middleware.name, handlerExecutionTime * 1000))
		end
	end

	-- Chain completed (or timed out)
	-- Cache the final result if caching was applicable
	if cacheKey then
		self:AddToCache(cacheKey, currentData)
	end

	-- Update overall metrics
	local executionTime = tick() - startTime
	self.Metrics.totalExecutionTime += executionTime
	self.Metrics.maxExecutionTime = math.max(self.Metrics.maxExecutionTime, executionTime)
	-- Note: avgExecutionTime calculated in GetMetrics

	return currentData -- Return the final (potentially modified) data
end

-- Add result to cache and manage LRU
function MiddlewareImpl:AddToCache(key: string, result: any? | boolean)
	if not self.Config.enableCache then return end -- Check if cache is enabled

	self.Cache[key] = {
		result = result,
		timestamp = tick()
	}
	self.lruManager:add(key) -- Let LRU manager handle size limits/eviction
end

-- Sort handlers by priority
function MiddlewareImpl:SortHandlers()
	tableSort(self.Handlers, function(a: MiddlewareInfo, b: MiddlewareInfo)
		return a.priority < b.priority
	end)
end

-- Get performance metrics
function MiddlewareImpl:GetMetrics(): MiddlewareMetrics
	-- Use tableClone or Utilities.Clone if available and deep cloning is needed, otherwise shallow copy is fine for metrics struct
	local metrics: MiddlewareMetrics = tableClone(self.Metrics)

	-- Calculate derived metrics
	local totalExecutions = metrics.totalExecutions
	if totalExecutions > 0 then
		metrics.averageExecutionTime = metrics.totalExecutionTime / totalExecutions
		metrics.blockRate = metrics.blocked / totalExecutions
		metrics.errorRate = metrics.errors / totalExecutions
		metrics.timeoutRate = metrics.timeouts / totalExecutions
	else
		metrics.averageExecutionTime = 0; metrics.blockRate = 0; metrics.errorRate = 0; metrics.timeoutRate = 0;
	end

	local totalCacheLookups = metrics.cacheHits + metrics.cacheMisses
	if totalCacheLookups > 0 then
		metrics.cacheHitRate = metrics.cacheHits / totalCacheLookups
	else
		metrics.cacheHitRate = 0
	end

	metrics.cacheSize = self.lruManager:getSize()
	metrics.maxCacheSize = self.MaxCacheSize

	-- Add individual handler stats
	metrics.handlerStats = {} :: {MiddlewareHandlerMetrics} -- Initialize with type
	for _, middleware in ipairs(self.Handlers) do
		local handlerExecCount = middleware.executionCount
		local avgTime = 0
		if handlerExecCount > 0 then
			avgTime = middleware.totalExecutionTime / handlerExecCount
		end
		local handlerStat: MiddlewareHandlerMetrics = {
			name = middleware.name,
			priority = middleware.priority,
			executionCount = handlerExecCount,
			avgExecutionTime = avgTime,
			errors = middleware.errors,
			blocked = middleware.blocked,
			errorRate = handlerExecCount > 0 and middleware.errors / handlerExecCount or 0,
			blockRate = handlerExecCount > 0 and middleware.blocked / handlerExecCount or 0
		}
		tableInsert(metrics.handlerStats, handlerStat)
	end

	-- Count precomputed paths (if logic is re-enabled)
	metrics.precomputedPaths = 0
	-- for _ in pairs(self.PrecomputedPaths) do metrics.precomputedPaths += 1 end

	return metrics
end

-- Reset performance metrics
function MiddlewareImpl:ResetMetrics()
	-- Reset overall metrics
	self.Metrics = {
		totalExecutions = 0, cacheHits = 0, cacheMisses = 0,
		totalExecutionTime = 0, maxExecutionTime = 0, avgExecutionTime = 0,
		errors = 0, blocked = 0, timeouts = 0
	} :: MiddlewareMetrics

	-- Reset metrics within each handler info object
	for _, middleware in ipairs(self.Handlers) do
		middleware.executionCount = 0
		middleware.totalExecutionTime = 0
		middleware.errors = 0
		middleware.blocked = 0
	end
	if self.Config.enablePerformanceLogging then
		print("[NetRay Middleware] Metrics Reset.")
	end
end

-- Configure middleware settings
function MiddlewareImpl:Configure(config: table) -- Accept partial config
	local cacheStateChanged = false
	local oldCacheState = self.Config.enableCache

	for key, value in pairs(config) do
		-- Only update keys that exist in the default Config table
		if self.Config[key] ~= nil and typeof(self.Config[key]) == typeof(value) then
			if key == "enableCache" and self.Config.enableCache ~= value then
				cacheStateChanged = true
			end
			self.Config[key] = value
		elseif self.Config[key] ~= nil then
			warn(("[NetRay Middleware] Configure: Type mismatch for key '%s'. Expected %s, got %s."):format(key, typeof(self.Config[key]), typeof(value)))
		end
	end

	-- If cache enabled status changed, potentially clear cache
	if cacheStateChanged and not self.Config.enableCache then
		self:ClearCache()
		if self.Config.enablePerformanceLogging then
			print("[NetRay Middleware] Cache Disabled via Configure.")
		end
	elseif cacheStateChanged and self.Config.enableCache then
		if self.Config.enablePerformanceLogging then
			print("[NetRay Middleware] Cache Enabled via Configure.")
		end
	end

	-- Update MaxCacheSize if provided in config and re-init LRU manager
	if config.MaxCacheSize and type(config.MaxCacheSize) == "number" and config.MaxCacheSize > 0 then
		self.MaxCacheSize = config.MaxCacheSize
		self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey: string)
			self.Cache[evictedKey] = nil
		end) :: LRUManager
		self:ClearCache() -- Clear cache when size changes
		if self.Config.enablePerformanceLogging then
			print("[NetRay Middleware] MaxCacheSize set to", self.MaxCacheSize)
		end
	end
end

-- Clear caches
function MiddlewareImpl:ClearCache()
	self.Cache = {} :: {[string]: MiddlewareCacheEntry?}
	self.PrecomputedPaths = {} :: {[string]: PrecomputedPathEntry?}
	-- Recreate LRU Manager to clear its internal state as well
	self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey: string)
		self.Cache[evictedKey] = nil
	end) :: LRUManager
	if self.Config.enablePerformanceLogging then
		print("[NetRay Middleware] Cache Cleared.")
	end
end

-- Add Error Handling Middleware helper
function MiddlewareImpl:AddErrorHandling(options: {logErrors: boolean?, fallbackValue: any?, blockOnError: boolean?, priority: number?}?)
	options = options or {}

	local errorHandler: MiddlewareHandler = function(eventName: string, player: Player?, data: any)
		warn("[NetRay Middleware] AddErrorHandling helper is flawed and may not provide intended error isolation.")
		return data -- Pass data through unchanged
	end

	self:Register("ErrorHandler_" .. (options.priority or 10), errorHandler, options.priority or 10)
end

-- Add Rate Limiting Middleware helper
function MiddlewareImpl:AddRateLimiting(options: {maxRequests: number?, timeWindow: number?, cooldown: number?, logViolations: boolean?, priority: number?}?)
	options = options or {}

	-- Use a closure to maintain state for this specific rate limiter instance
	local limits: {[string]: {count: number, lastReset: number, cooldownUntil: number}} = {}
	local maxRequests = options.maxRequests or 10
	local timeWindow = options.timeWindow or 1 -- seconds
	local cooldown = options.cooldown or 5 -- seconds

	local rateLimiter: MiddlewareHandler = function(eventName: string, player: Player?, data: any)
		if not player then return data end -- Only rate limit player actions

		local userId = player.UserId
		-- Use a key combining event and user for per-event limits, or just user for global limits
		local key = userId .. "_" .. eventName -- Per-event limit key

		local limitData = limits[key]
		local now = tick()

		if not limitData then
			limitData = { count = 0, lastReset = now, cooldownUntil = 0 }
			limits[key] = limitData
		end

		-- Check cooldown
		if limitData.cooldownUntil > now then
			return false -- Blocked due to cooldown
		end

		-- Reset window if needed
		if now - limitData.lastReset > timeWindow then
			limitData.count = 0
			limitData.lastReset = now
		end

		-- Increment and check limit
		limitData.count += 1
		if limitData.count > maxRequests then
			limitData.cooldownUntil = now + cooldown
			limitData.count = 0 -- Reset count when cooldown starts
			if options.logViolations ~= false then
				warn(("[NetRay Middleware] Rate limit exceeded for User %d on Event '%s'. Cooldown applied."):format(userId, eventName))
			end
			return false -- Block
		end

		return data -- Allow
	end

	self:Register("RateLimiter_"..(options.priority or 20), rateLimiter, options.priority or 20)
end


return MiddlewareImpl :: Middleware