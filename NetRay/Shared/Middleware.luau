--!optimize 2

--[[
    Middleware.lua
    Implements a lightweight middleware system for preprocessing network events
    Author: Asta (@TheYusufGamer)
]]

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
	-- Metrics per handler (optional)
	executionCount: number,
	errors: number,
	blocked: number
}

-- Type definition for Middleware configuration
type MiddlewareConfig = {
	logErrors: boolean,
	enableMetrics: boolean
}

-- Type definition for Middleware performance metrics
type MiddlewareMetrics = {
	totalExecutions: number,
	errors: number,
	blocked: number,
	-- Calculated fields added by GetMetrics
	errorRate: number?,
	blockRate: number?,
	handlerStats: {MiddlewareHandlerMetrics}?
}

-- Type definition for individual handler metrics within MiddlewareMetrics
type MiddlewareHandlerMetrics = {
	name: string,
	priority: number,
	executionCount: number,
	errors: number,
	blocked: number,
	errorRate: number,
	blockRate: number,
}

-- Type definition for the Middleware class itself
export type Middleware = {
	-- Properties
	Handlers: {MiddlewareInfo},
	Metrics: MiddlewareMetrics,
	Config: MiddlewareConfig,

	-- Methods
	Register: (self: Middleware, name: string, handler: MiddlewareHandler, priority: number?) -> (),
	Remove: (self: Middleware, name: string) -> boolean,
	Execute: (self: Middleware, eventName: string, player: Player?, data: any) -> any? | boolean, -- Mirrors handler return
	SortHandlers: (self: Middleware) -> (),
	GetMetrics: (self: Middleware) -> MiddlewareMetrics,
	ResetMetrics: (self: Middleware) -> (),
	Configure: (self: Middleware, config: table) -> (), -- Accepts partial config table
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

	self.Metrics = { -- Initialize with correct types
		totalExecutions = 0,
		errors = 0,
		blocked = 0
	} :: MiddlewareMetrics -- Add type assertion

	self.Config = {
		logErrors = true,
		enableMetrics = false
	} :: MiddlewareConfig -- Add type assertion

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
			return -- Exit after update
		end
	end

	-- Add new middleware
	local newMiddleware: MiddlewareInfo = {
		name = name,
		handler = handler,
		priority = priority,
		executionCount = 0,
		errors = 0,
		blocked = 0
	}
	tableInsert(self.Handlers, newMiddleware)
	self:SortHandlers() -- Sort after adding
end

-- Remove a middleware handler by name
function MiddlewareImpl:Remove(name: string): boolean
	for i, middleware in ipairs(self.Handlers) do
		if middleware.name == name then
			tableRemove(self.Handlers, i)
			return true -- Indicate success
		end
	end
	return false -- Not found
end

-- Execute the middleware chain
function MiddlewareImpl:Execute(eventName: string, player: Player?, data: any): any? | boolean
	if #self.Handlers == 0 then
		return data -- Return original data if no middleware
	end

	if self.Config.enableMetrics then
		self.Metrics.totalExecutions += 1
	end

	-- Execute handlers
	local currentData = data

	for i, middleware in ipairs(self.Handlers) do
		-- Use pcall to safely execute user-provided middleware handler
		local success, resultOrError = pcall(middleware.handler, eventName, player, currentData)

		-- Update metrics for this handler
		if self.Config.enableMetrics then
			middleware.executionCount += 1
		end

		if not success then
			-- Handler errored
			if self.Config.enableMetrics then
				self.Metrics.errors += 1
				middleware.errors += 1
			end
			if self.Config.logErrors then
				warn(("[NetRay Middleware] Error in '%s': %s"):format(middleware.name, tostring(resultOrError)))
			end

		elseif resultOrError == false then
			-- Handler returned false, block the event
			if self.Config.enableMetrics then
				self.Metrics.blocked += 1
				middleware.blocked += 1
			end
			return false -- Stop chain and return false

		elseif resultOrError ~= nil then
			-- Handler returned modified data
			currentData = resultOrError
		end -- If resultOrError is nil, currentData remains unchanged
	end

	return currentData -- Return the final (potentially modified) data
end

-- Sort handlers by priority
function MiddlewareImpl:SortHandlers()
	tableSort(self.Handlers, function(a: MiddlewareInfo, b: MiddlewareInfo)
		return a.priority < b.priority
	end)
end

-- Get performance metrics
function MiddlewareImpl:GetMetrics(): MiddlewareMetrics
	local metrics: MiddlewareMetrics = {
		totalExecutions = self.Metrics.totalExecutions,
		errors = self.Metrics.errors,
		blocked = self.Metrics.blocked
	}

	-- Calculate derived metrics
	local totalExecutions = metrics.totalExecutions
	if totalExecutions > 0 then
		metrics.blockRate = metrics.blocked / totalExecutions
		metrics.errorRate = metrics.errors / totalExecutions
	else
		metrics.blockRate = 0
		metrics.errorRate = 0
	end

	-- Add individual handler stats
	metrics.handlerStats = {} :: {MiddlewareHandlerMetrics} -- Initialize with type
	for _, middleware in ipairs(self.Handlers) do
		local handlerExecCount = middleware.executionCount
		local handlerStat: MiddlewareHandlerMetrics = {
			name = middleware.name,
			priority = middleware.priority,
			executionCount = handlerExecCount,
			errors = middleware.errors,
			blocked = middleware.blocked,
			errorRate = handlerExecCount > 0 and middleware.errors / handlerExecCount or 0,
			blockRate = handlerExecCount > 0 and middleware.blocked / handlerExecCount or 0
		}
		tableInsert(metrics.handlerStats, handlerStat)
	end

	return metrics
end

-- Reset performance metrics
function MiddlewareImpl:ResetMetrics()
	-- Reset overall metrics
	self.Metrics = {
		totalExecutions = 0,
		errors = 0,
		blocked = 0
	} :: MiddlewareMetrics

	-- Reset metrics within each handler info object
	for _, middleware in ipairs(self.Handlers) do
		middleware.executionCount = 0
		middleware.errors = 0
		middleware.blocked = 0
	end
end

-- Configure middleware settings
function MiddlewareImpl:Configure(config: table) -- Accept partial config
	for key, value in pairs(config) do
		-- Only update keys that exist in the default Config table
		if self.Config[key] ~= nil and typeof(self.Config[key]) == typeof(value) then
			self.Config[key] = value
		elseif self.Config[key] ~= nil then
			warn(("[NetRay Middleware] Configure: Type mismatch for key '%s'. Expected %s, got %s."):format(key, typeof(self.Config[key]), typeof(value)))
		end
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
