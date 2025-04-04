--!strict
--!optimize 2
--!native

--[[    
    Middleware.lua
    Implements a flexible middleware system for preprocessing network events
    Optimized version with caching, performance metrics, and better error handling
    Author: Asta (@TheYusufGamer)
]]

local Utilities = require(script.Parent.Utilities) -- Make sure Utilities is required

local Middleware = {}
Middleware.__index = Middleware

-- Local function optimizations for performance
local tableSort = table.sort
local tableFindFirst = table.find
local tableInsert = table.insert
local tableRemove = table.remove
local tableClone = table.clone
local tick = tick
local typeof = typeof
local pcall = pcall
local unpack = unpack
local warn = warn
local error = error
local tostring = tostring
local setmetatable = setmetatable

function Middleware.new()
	local self = setmetatable({}, Middleware)

	-- Middleware handlers in priority order
	self.Handlers = {}

	-- Cache for frequently executed middleware chains
	self.Cache = {}
	self.MaxCacheSize = 50 -- Limit cache size to prevent memory bloat
	-- LRU Manager for cache eviction
	self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey)
		-- Eviction callback: Remove the item from the actual cache table
		self.Cache[evictedKey] = nil
	end)
	-- Enhanced performance metrics
	self.Metrics = {
		totalExecutions = 0,
		cacheHits = 0,
		cacheMisses = 0,
		totalExecutionTime = 0,
		maxExecutionTime = 0,
		avgExecutionTime = 0,
		errors = 0,
		blocked = 0,
		timeouts = 0
	}

	-- Configuration
	self.Config = {
		enableCache = true,
		timeoutMs = 100, -- Maximum milliseconds a middleware chain can run
		logErrors = true,
		cacheTTL = 60, -- Cache entries expire after 60 seconds
		enablePerformanceLogging = false,
		logSlowExecutions = true,
		slowExecutionThresholdMs = 50 -- Log executions taking longer than this
	}

	-- Pre-compute common paths for performance
	self.PrecomputedPaths = {}

	return self
end

--[[    
    Register a new middleware handler
    @param name: Unique identifier for the middleware
    @param handler: Function to execute (receives eventName, player, data)
    @param priority: Lower numbers run earlier (default: 100)
]]
function Middleware:Register(name, handler, priority)
	if typeof(handler) ~= "function" then
		error("[NetRay] Middleware handler must be a function")
		return
	end

	priority = priority or 100

	-- Check if middleware with this name already exists
	for i, middleware in ipairs(self.Handlers) do
		if middleware.name == name then
			-- Update existing middleware
			self.Handlers[i].handler = handler
			self.Handlers[i].priority = priority

			-- Re-sort by priority
			self:SortHandlers()

			-- Clear cache since middleware has changed
			if self.Config.enableCache then
				self.Cache = {} -- Clear data cache
				self.PrecomputedPaths = {}
				-- Recreate LRU Manager as cache structure/size logic might reset
				self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey)
					self.Cache[evictedKey] = nil
				end)
			end

			return
		end
	end

	-- Add new middleware
	tableInsert(self.Handlers, {
		name = name,
		handler = handler,
		priority = priority,
		executionCount = 0,
		totalExecutionTime = 0,
		errors = 0,
		blocked = 0
	})

	-- Sort by priority
	self:SortHandlers()

	-- Clear cache since middleware chain has changed
	if self.Config.enableCache then
		self.Cache = {} -- Clear data cache
		self.PrecomputedPaths = {}
		-- Recreate LRU Manager
		self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey)
			self.Cache[evictedKey] = nil
		end)
	end
end

--[[    
    Remove a middleware handler by name
    @param name: Name of the middleware to remove
    @return: True if middleware was removed, false otherwise
]]
function Middleware:Remove(name)
	for i, middleware in ipairs(self.Handlers) do
		if middleware.name == name then
			tableRemove(self.Handlers, i)

			-- Clear cache since middleware chain has changed
			if self.Config.enableCache then
				self.Cache = {} -- Clear data cache
				self.PrecomputedPaths = {}
				-- Recreate LRU Manager
				self.lruManager = Utilities.CreateLRUManager(self.MaxCacheSize, function(evictedKey)
					self.Cache[evictedKey] = nil
				end)
			end

			return true
		end
	end

	return false
end

--[[    
    Execute all middleware handlers in priority order
    @param eventName: Name of the event
    @param player: Player instance (nil on client)
    @param data: Data to process
    @return: Modified data, or false if the event should be blocked
]]
function Middleware:Execute(eventName, player, data)
	-- Performance tracking
	self.Metrics.totalExecutions += 1
	local startTime = tick()

	-- Fast path: no middleware
	if #self.Handlers == 0 then
		return data
	end

	-- Check cache for common execution paths
	local cacheKey = nil
	if self.Config.enableCache then
		-- Improved cache key generation
		if type(data) ~= "table" then
			-- Only cache simple data types (strings, numbers, booleans)
			local playerKey = typeof(player) == "Instance" and player.UserId or "nil"
			cacheKey = eventName .. "_" .. playerKey .. "_" .. tostring(data)

			-- Check pre-computed paths for this event+player combination
			local precomputePath = self.PrecomputedPaths[eventName .. "_" .. playerKey]
			if precomputePath and precomputePath.count > 5 then -- Only use precomputed paths after enough samples
				-- Use the optimized path if available
				if self.Config.enablePerformanceLogging then
					warn("[NetRay] Using precomputed path for " .. eventName)
				end

				-- Execute only the middleware handlers that matter for this event+player
				local currentData = data
				for _, handlerIndex in ipairs(precomputePath.handlers) do
					local middleware = self.Handlers[handlerIndex]

					local success, result = pcall(function()
						return middleware.handler(eventName, player, currentData)
					end)

					-- Track individual middleware performance
					middleware.executionCount += 1

					if not success then
						middleware.errors += 1
						self.Metrics.errors += 1
						if self.Config.logErrors then
							warn("[NetRay] Middleware error in '" .. middleware.name .. "': " .. tostring(result))
						end
						-- Continue with unmodified data
					elseif result == false then
						-- Block the event
						middleware.blocked += 1
						self.Metrics.blocked += 1
						return false
					elseif result ~= nil then
						-- Update data with middleware result
						currentData = result
					end
				end

				-- Update execution time metrics
				local executionTime = tick() - startTime
				self.Metrics.totalExecutionTime += executionTime
				self.Metrics.maxExecutionTime = math.max(self.Metrics.maxExecutionTime, executionTime)

				return currentData
			end

			if self.Cache[cacheKey] then
				-- Check if cache entry is still valid
				if (tick() - self.Cache[cacheKey].timestamp) < self.Config.cacheTTL then
					self.Metrics.cacheHits += 1

					-- Update execution time metrics
					local executionTime = tick() - startTime
					self.Metrics.totalExecutionTime += executionTime

					-- Valid cache hit - Touch the LRU entry
					self.lruManager:touch(cacheKey)
					return self.Cache[cacheKey].result
				else
					-- Expired cache entry - Remove from Cache and LRU manager
					self.Cache[cacheKey] = nil
					self.lruManager:remove(cacheKey)
				end
			end

			self.Metrics.cacheMisses += 1
		else
			-- Initialize or update precomputed path data
			local pathKey = eventName
			if typeof(player) == "Instance" then
				pathKey = pathKey .. "_" .. player.UserId
			else
				pathKey = pathKey .. "_nil"
			end

			if not self.PrecomputedPaths[pathKey] then
				self.PrecomputedPaths[pathKey] = {
					count = 0,
					handlers = {}, -- Indexes of handlers that matter for this path
					changesMade = false
				}
			end
		end
	end

	local currentData = data
	local timeoutAt = tick() + (self.Config.timeoutMs / 1000)
	local activeHandlers = {}

	for i, middleware in ipairs(self.Handlers) do
		-- Check for timeout
		if tick() > timeoutAt then
			warn("[NetRay] Middleware chain timed out for event '" .. eventName .. "'")
			self.Metrics.timeouts += 1
			break
		end

		local handlerStartTime = tick()
		local success, result = pcall(function()
			return middleware.handler(eventName, player, currentData)
		end)
		local handlerExecutionTime = tick() - handlerStartTime

		-- Track individual middleware performance
		middleware.executionCount += 1
		middleware.totalExecutionTime += handlerExecutionTime

		-- Track if this handler actually did something to the data
		local madeChange = false

		if not success then
			self.Metrics.errors += 1
			middleware.errors += 1
			if self.Config.logErrors then
				warn("[NetRay] Middleware error in '" .. middleware.name .. "': " .. tostring(result))
			end
			-- Continue with unmodified data
		elseif result == false then
			-- Block the event if middleware returns false
			self.Metrics.blocked += 1
			middleware.blocked += 1
			madeChange = true

			-- Record that this handler is important for this event path
			if self.Config.enableCache and cacheKey then
				local pathKey = eventName
				if typeof(player) == "Instance" then
					pathKey = pathKey .. "_" .. player.UserId
				else
					pathKey = pathKey .. "_nil"
				end

				local path = self.PrecomputedPaths[pathKey]
				if path then
					path.count += 1
					if tableFindFirst(path.handlers, i) == nil then
						tableInsert(path.handlers, i)
					end
					path.changesMade = true
				end
			end

			-- Add to cache if caching is enabled
			if cacheKey then
				self:AddToCache(cacheKey, false)
			end

			-- Log slow executions if configured
			if self.Config.logSlowExecutions and handlerExecutionTime > (self.Config.slowExecutionThresholdMs / 1000) then
				warn("[NetRay] Slow middleware execution in '" .. middleware.name .. 
					"' for event '" .. eventName .. "': " .. (handlerExecutionTime * 1000) .. "ms")
			end

			-- Update execution time metrics
			local executionTime = tick() - startTime
			self.Metrics.totalExecutionTime += executionTime
			self.Metrics.maxExecutionTime = math.max(self.Metrics.maxExecutionTime, executionTime)

			return false
		elseif result ~= nil then
			-- Update data with middleware result
			if result ~= currentData then -- Only count as a change if data actually changed
				madeChange = true
				currentData = result

				-- Record that this handler is important for this event path
				if self.Config.enableCache then
					local pathKey = eventName
					if typeof(player) == "Instance" then
						pathKey = pathKey .. "_" .. player.UserId
					else
						pathKey = pathKey .. "_nil"
					end

					local path = self.PrecomputedPaths[pathKey]
					if path then
						path.count += 1
						if tableFindFirst(path.handlers, i) == nil then
							tableInsert(path.handlers, i)
						end
						path.changesMade = true
					end
				end
			end
		end

		-- If this middleware handler made a change, remember it
		if madeChange then
			tableInsert(activeHandlers, i)
		end

		-- Log slow executions if configured
		if self.Config.logSlowExecutions and handlerExecutionTime > (self.Config.slowExecutionThresholdMs / 1000) then
			warn("[NetRay] Slow middleware execution in '" .. middleware.name .. 
				"' for event '" .. eventName .. "': " .. (handlerExecutionTime * 1000) .. "ms")
		end
	end

	-- Update precomputed paths with the active handlers for this event
	if self.Config.enableCache and #activeHandlers > 0 then
		local pathKey = eventName
		if typeof(player) == "Instance" then
			pathKey = pathKey .. "_" .. player.UserId
		else
			pathKey = pathKey .. "_nil"
		end

		local path = self.PrecomputedPaths[pathKey]
		if path then
			path.count += 1
			path.handlers = activeHandlers
		end
	end

	-- Add result to cache if caching is enabled
	if cacheKey then
		self:AddToCache(cacheKey, currentData)
	end

	-- Update execution time metrics
	local executionTime = tick() - startTime
	self.Metrics.totalExecutionTime += executionTime
	self.Metrics.maxExecutionTime = math.max(self.Metrics.maxExecutionTime, executionTime)

	-- Calculate average execution time
	if self.Metrics.totalExecutions > 0 then
		self.Metrics.avgExecutionTime = self.Metrics.totalExecutionTime / self.Metrics.totalExecutions
	end

	return currentData
end

--[[    
    Add a result to the middleware cache
    @param key: Cache key
    @param result: Result to cache
]]
function Middleware:AddToCache(key, result)
	-- Add/Update the entry in the main cache
	self.Cache[key] = {
		result = result,
		timestamp = tick()
	}
	-- Notify the LRU manager. It will handle eviction via callback if size exceeds limit.
	self.lruManager:add(key)
end

--[[    
    Sort middleware handlers by priority (low to high)
]]
function Middleware:SortHandlers()
	tableSort(self.Handlers, function(a, b)
		return a.priority < b.priority
	end)
end

--[[    
    Get performance metrics for the middleware system
    @return: Table of performance metrics
]]
function Middleware:GetMetrics()
	local metrics = tableClone(self.Metrics)

	-- Calculate derived metrics
	if metrics.totalExecutions > 0 then
		metrics.averageExecutionTime = metrics.totalExecutionTime / metrics.totalExecutions
		metrics.blockRate = metrics.blocked / metrics.totalExecutions
		metrics.errorRate = metrics.errors / metrics.totalExecutions
		metrics.timeoutRate = metrics.timeouts / metrics.totalExecutions
	else
		metrics.averageExecutionTime = 0
		metrics.blockRate = 0
		metrics.errorRate = 0
		metrics.timeoutRate = 0
	end

	if metrics.cacheHits + metrics.cacheMisses > 0 then
		metrics.cacheHitRate = metrics.cacheHits / (metrics.cacheHits + metrics.cacheMisses)
	else
		metrics.cacheHitRate = 0
	end

	-- Add cache statistics
	local cacheSize = 0
	-- Get size directly from LRU manager
	metrics.cacheSize = self.lruManager:getSize()
	metrics.maxCacheSize = self.MaxCacheSize

	-- Add middleware handler statistics
	metrics.handlerStats = {}
	for _, middleware in ipairs(self.Handlers) do
		local avgTime = 0
		if middleware.executionCount > 0 then
			avgTime = middleware.totalExecutionTime / middleware.executionCount
		end

		tableInsert(metrics.handlerStats, {
			name = middleware.name,
			priority = middleware.priority,
			executionCount = middleware.executionCount,
			avgExecutionTime = avgTime,
			errors = middleware.errors,
			blocked = middleware.blocked,
			errorRate = middleware.executionCount > 0 and middleware.errors / middleware.executionCount or 0,
			blockRate = middleware.executionCount > 0 and middleware.blocked / middleware.executionCount or 0
		})
	end

	-- Add precomputed path statistics
	metrics.precomputedPaths = 0
	for _ in pairs(self.PrecomputedPaths) do
		metrics.precomputedPaths += 1
	end

	return metrics
end

--[[    
    Reset performance metrics
]]
function Middleware:ResetMetrics()
	self.Metrics = {
		totalExecutions = 0,
		cacheHits = 0,
		cacheMisses = 0,
		totalExecutionTime = 0,
		maxExecutionTime = 0,
		avgExecutionTime = 0,
		errors = 0,
		blocked = 0,
		timeouts = 0
	}

	-- Reset individual middleware handler metrics
	for _, middleware in ipairs(self.Handlers) do
		middleware.executionCount = 0
		middleware.totalExecutionTime = 0
		middleware.errors = 0
		middleware.blocked = 0
	end
end

--[[    
    Configure middleware settings
    @param config: Table with configuration options
]]
function Middleware:Configure(config)
	for key, value in pairs(config) do
		if self.Config[key] ~= nil then
			self.Config[key] = value
		end
	end

	-- If cache was disabled, clear existing cache
	if config.enableCache == false then
		self.Cache = {}
		self.PrecomputedPaths = {}
	end
end

--[[    
    Clear the middleware cache
]]
function Middleware:ClearCache()
	self.Cache = {}
	self.PrecomputedPaths = {}
end

--[[    
    Add error handling middleware with configurable behavior
    @param options: Configuration options for error handling
]]
function Middleware:AddErrorHandling(options)
	options = options or {}

	local errorHandler = function(eventName, player, data)
		if type(data) ~= "table" then
			return data -- No error handling needed for primitive types
		end

		-- Try to execute the operation safely
		local success, result = pcall(function()
			return data
		end)

		if not success then
			-- Handle the error based on configuration
			if options.logErrors ~= false then
				warn("[NetRay] Error in event '" .. eventName .. "': " .. tostring(result))
			end

			if options.fallbackValue ~= nil then
				return options.fallbackValue
			elseif options.blockOnError then
				return false -- Block the event
			else
				return data -- Pass through unchanged
			end
		end

		return data
	end

	-- Register as a high-priority middleware (runs early)
	self:Register("ErrorHandler", errorHandler, options.priority or 10)
end

--[[    
    Add rate limiting middleware to protect against spam
    @param options: Configuration options for rate limiting
]]
function Middleware:AddRateLimiting(options)
	options = options or {}

	local limits = {}
	local maxRequests = options.maxRequests or 10
	local timeWindow = options.timeWindow or 1 -- seconds
	local cooldown = options.cooldown or 5 -- seconds

	local rateLimiter = function(eventName, player, data)
		if not player then
			return data -- Only rate limit players
		end

		local userId = player.UserId
		local key = userId .. "_" .. eventName

		if not limits[key] then
			limits[key] = {
				count = 0,
				lastReset = tick(),
				cooldownUntil = 0
			}
		end

		local limit = limits[key]
		local now = tick()

		-- Check if in cooldown
		if limit.cooldownUntil > now then
			return false -- Block during cooldown
		end

		-- Reset counter if time window elapsed
		if now - limit.lastReset > timeWindow then
			limit.count = 0
			limit.lastReset = now
		end

		-- Increment counter
		limit.count += 1

		-- Check if limit exceeded
		if limit.count > maxRequests then
			limit.cooldownUntil = now + cooldown
			limit.count = 0

			if options.logViolations ~= false then
				warn("[NetRay] Rate limit exceeded for user " .. userId .. " on event '" .. eventName .. "'. Cooldown applied.")
			end

			return false -- Block the event
		end

		return data
	end

	-- Register as a high-priority middleware (runs early)
	self:Register("RateLimiter", rateLimiter, options.priority or 20)
end

return Middleware
