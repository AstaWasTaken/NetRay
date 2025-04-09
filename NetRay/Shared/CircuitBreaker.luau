--!optimize 2

--[[
    CircuitBreaker.lua
    Implements the circuit breaker pattern to prevent cascading failures
    Optimized version with adaptive timeouts and improved state tracking
    Author: Asta (@TheYusufGamer)
]]

-- Assuming SignalPlus is typed
local SignalPlusModule = require(script.Parent.Parent.ThirdParty.SignalPlus)
local Constants = require(script.Parent.Constants)
type SignalPlus = SignalPlusModule.SignalPlus

-- Define the module table
local CircuitBreaker = {}
CircuitBreaker.__index = CircuitBreaker

-- Define State Enum Type
local CircuitStateType = {
	CLOSED = "CLOSED",
	OPEN = "OPEN",
	HALF_OPEN = "HALF_OPEN"
}
export type CircuitState = typeof(CircuitStateType.CLOSED) -- "CLOSED" | "OPEN" | "HALF_OPEN"
CircuitBreaker.State = CircuitStateType

-- Type for the options passed to CircuitBreaker.new
type CircuitBreakerOptions = {
	failureThreshold: number?,
	resetTimeout: number?,         -- Base timeout in seconds
	fallback: ((...any) -> any)?,  -- Optional fallback function signature
	halfOpenMaxRequests: number?,
	adaptiveTimeouts: boolean?,
	minimumTimeout: number?,
	maximumTimeout: number?,
	healthCheckInterval: number?   -- Interval in seconds
}

-- Type for the internal metrics structure
type CircuitBreakerMetrics = {
	totalFailures: number,
	totalSuccesses: number,
	lastOpenTime: number,
	openCount: number,
	successRateAfterRecovery: number, 
	failureRates: {number}, -- Ring buffer of last N failure rates
	averageRecoveryTime: number,
	-- Calculated fields added by GetMetrics
	currentState: CircuitState?,
	failureCount: number?,
	timeInCurrentState: number?,
	currentTimeout: number?,
	averageFailureRate: number?,
}

-- Type for the Signals table within CircuitBreaker instance
type CircuitBreakerSignals = {
	StateChanged: SignalPlus, -- (oldState: CircuitState, newState: CircuitState)
	FailureRecorded: SignalPlus, -- ()
	SuccessRecorded: SignalPlus, -- ()
	Recovered: SignalPlus -- (recoveryTime: number)
}

-- Type for the CircuitBreaker class itself
export type CircuitBreaker = {
	-- Properties
	Options: { -- Use non-optional types for internal storage after defaulting
		failureThreshold: number,
		resetTimeout: number,
		fallback: ((...any) -> any)?,
		halfOpenMaxRequests: number,
		adaptiveTimeouts: boolean,
		minimumTimeout: number,
		maximumTimeout: number,
		healthCheckInterval: number
	},
	State: CircuitState,
	FailureCount: number,
	LastFailureTime: number,
	LastStateChange: number,
	CurrentTimeout: number, -- Current adaptive timeout value
	ErrorHistory: {number}, -- Timestamps of last N errors
	ConsecutiveSuccesses: number,
	IsHealthCheckScheduled: boolean,
	HalfOpenRequestCount: number,
	Metrics: CircuitBreakerMetrics,
	Signals: CircuitBreakerSignals,

	-- Methods
	IsAllowed: (self: CircuitBreaker) -> boolean,
	Execute: <T>(self: CircuitBreaker, fn: (...any) -> T, ... any) -> T, 
	RecordSuccess: (self: CircuitBreaker) -> (),
	RecordFailure: (self: CircuitBreaker) -> (),
	TransitionTo: (self: CircuitBreaker, newState: CircuitState) -> (),
	PerformHealthCheck: (self: CircuitBreaker) -> (),
	ForceState: (self: CircuitBreaker, state: CircuitState) -> (),
	GetMetrics: (self: CircuitBreaker) -> CircuitBreakerMetrics,

	-- Constructor
	new: (options: CircuitBreakerOptions?) -> CircuitBreaker
}

-- Internal helper for adaptive timeout (types parameters and return)
local function calculateAdaptiveTimeout(errorHistory: {number}, baseTimeout: number): number
	if #errorHistory < 2 then
		return baseTimeout
	end

	local totalInterval = 0
	for i = 2, #errorHistory do
		totalInterval += errorHistory[i] - errorHistory[i-1]
	end
	local avgInterval = totalInterval / (#errorHistory - 1)

	if avgInterval < 1 then return baseTimeout * 2
	elseif avgInterval < 5 then return baseTimeout * 1.5
	else return baseTimeout
	end
end

-- Constructor
function CircuitBreaker.new(options: CircuitBreakerOptions?): CircuitBreaker
	options = options or {}
	local self: CircuitBreaker = setmetatable({}, CircuitBreaker)

	-- Initialize Options with defaults and assert types
	self.Options = {
		failureThreshold = options.failureThreshold or Constants.CIRCUIT_BREAKER.DEFAULT_FAILURE_THRESHOLD,
		resetTimeout = options.resetTimeout or Constants.CIRCUIT_BREAKER.DEFAULT_RESET_TIMEOUT,
		fallback = options.fallback, -- Keep as optional function
		halfOpenMaxRequests = options.halfOpenMaxRequests or 1,
		adaptiveTimeouts = options.adaptiveTimeouts ~= false,
		minimumTimeout = options.minimumTimeout or 5,
		maximumTimeout = options.maximumTimeout or 300,
		healthCheckInterval = options.healthCheckInterval or 5
	}

	self.State = CircuitStateType.CLOSED
	self.FailureCount = 0
	self.LastFailureTime = 0
	self.LastStateChange = tick()
	self.CurrentTimeout = self.Options.resetTimeout
	self.ErrorHistory = {} :: {number}
	self.ConsecutiveSuccesses = 0
	self.IsHealthCheckScheduled = false
	self.HalfOpenRequestCount = 0

	self.Metrics = {
		totalFailures = 0, totalSuccesses = 0, lastOpenTime = 0, openCount = 0,
		successRateAfterRecovery = 0, failureRates = {} :: {number}, averageRecoveryTime = 0
	} :: CircuitBreakerMetrics

	self.Signals = {
		StateChanged = SignalPlusModule.new(),
		FailureRecorded = SignalPlusModule.new(),
		SuccessRecorded = SignalPlusModule.new(),
		Recovered = SignalPlusModule.new()
	} :: CircuitBreakerSignals

	return self :: CircuitBreaker
end

-- Determines if a request should be allowed through
function CircuitBreaker:IsAllowed(): boolean
	local now = tick()

	if self.State == CircuitStateType.OPEN then
		if now - self.LastStateChange >= self.CurrentTimeout then
			self:TransitionTo(CircuitStateType.HALF_OPEN)
			-- Allow the first request in HALF_OPEN immediately after transition
			self.HalfOpenRequestCount = 1 -- Increment here as we are allowing it
			return true
		end
		return false -- Still Open
	elseif self.State == CircuitStateType.HALF_OPEN then
		-- Allow up to max requests, increment is done when returning true
		if self.HalfOpenRequestCount < self.Options.halfOpenMaxRequests then
			self.HalfOpenRequestCount += 1
			return true
		end
		return false -- Exceeded HALF_OPEN attempts
	end

	-- CLOSED state always allows
	return true
end

-- Execute a function with circuit breaker protection
-- Use generic <T> for the return type of the wrapped function
function CircuitBreaker:Execute<T>(fn: (...any) -> T, ...): T
	if not self:IsAllowed() then
		-- Circuit is open or HALF_OPEN limit reached
		if self.Options.fallback then
			-- Safely call fallback
			local fbSuccess, fbResult = pcall(self.Options.fallback, ...)
			if fbSuccess then
				return fbResult :: T -- Assume fallback returns compatible type T
			else
				error("Circuit breaker fallback function failed: " .. tostring(fbResult))
			end
		else
			error("Circuit breaker is open - request rejected")
		end
	end

	-- Try executing the protected function
	local args = {...}
	local success, resultOrError = pcall(fn, unpack(args))

	if success then
		self:RecordSuccess()
		return resultOrError :: T -- Assert return type T
	else
		self:RecordFailure()
		-- Failure occurred, use fallback if available
		if self.Options.fallback then
			local fbSuccess, fbResult = pcall(self.Options.fallback, unpack(args)) -- Pass original args to fallback
			if fbSuccess then
				return fbResult :: T -- Assume fallback returns compatible type T
			else
				error("Circuit breaker fallback function failed after primary failure: " .. tostring(fbResult))
			end
		else
			error(resultOrError) -- Re-throw the original error if no fallback
		end
	end
end

-- Record a successful operation
function CircuitBreaker:RecordSuccess()
	self.Metrics.totalSuccesses += 1

	if self.State == CircuitStateType.HALF_OPEN then
		self.ConsecutiveSuccesses += 1
		if self.ConsecutiveSuccesses >= self.Options.halfOpenMaxRequests then
			local recoveryTime = 0
			if self.Metrics.lastOpenTime > 0 then -- Ensure lastOpenTime was set
				recoveryTime = tick() - self.Metrics.lastOpenTime
				if self.Metrics.averageRecoveryTime > 0 then
					self.Metrics.averageRecoveryTime = (self.Metrics.averageRecoveryTime + recoveryTime) / 2
				else
					self.Metrics.averageRecoveryTime = recoveryTime
				end
			end
			self:TransitionTo(CircuitStateType.CLOSED)
			self.Signals.Recovered:Fire(recoveryTime)
		end
	elseif self.State == CircuitStateType.CLOSED then
		-- Reset failure count in CLOSED state only if it was > 0
		if self.FailureCount > 0 then
			self.FailureCount = 0
			self.ErrorHistory = {} :: {number} -- Clear history on recovery
		end
	end

	self.Signals.SuccessRecorded:Fire()
end

-- Record a failed operation
function CircuitBreaker:RecordFailure()
	local now = tick()
	self.LastFailureTime = now
	self.Metrics.totalFailures += 1

	table.insert(self.ErrorHistory, now)
	if #self.ErrorHistory > 10 then -- Limit history size
		table.remove(self.ErrorHistory, 1)
	end

	if self.State == CircuitStateType.HALF_OPEN then
		-- Failure in HALF_OPEN means transition back to OPEN
		if self.Options.adaptiveTimeouts then
			self.CurrentTimeout = math.min(self.CurrentTimeout * 1.5, self.Options.maximumTimeout)
		end
		self:TransitionTo(CircuitStateType.OPEN)
		-- Fire failure signal *after* transition
		self.Signals.FailureRecorded:Fire()
		return
	end

	-- Only increment failure count and check threshold if CLOSED
	if self.State == CircuitStateType.CLOSED then
		self.FailureCount += 1

		-- Calculate failure rate for metrics
		local totalRequests = self.Metrics.totalSuccesses + self.Metrics.totalFailures
		if totalRequests > 0 then
			local failureRate = self.Metrics.totalFailures / totalRequests
			table.insert(self.Metrics.failureRates, failureRate)
			if #self.Metrics.failureRates > 10 then
				table.remove(self.Metrics.failureRates, 1)
			end
		end

		-- Check threshold
		if self.FailureCount >= self.Options.failureThreshold then
			if self.Options.adaptiveTimeouts then
				self.CurrentTimeout = calculateAdaptiveTimeout(self.ErrorHistory, self.Options.resetTimeout)
				self.CurrentTimeout = math.clamp(self.CurrentTimeout, self.Options.minimumTimeout, self.Options.maximumTimeout)
			else
				self.CurrentTimeout = self.Options.resetTimeout
			end
			self:TransitionTo(CircuitStateType.OPEN)
		end
	end

	self.Signals.FailureRecorded:Fire()
end

-- Change the circuit state
function CircuitBreaker:TransitionTo(newState: CircuitState)
	if self.State == newState then return end -- No change

	local oldState = self.State
	self.State = newState
	self.LastStateChange = tick()
	local wasHealthCheckScheduled = self.IsHealthCheckScheduled -- Store before potentially resetting

	if newState == CircuitStateType.CLOSED then
		self.FailureCount = 0
		self.ConsecutiveSuccesses = 0
		self.HalfOpenRequestCount = 0
		self.ErrorHistory = {} :: {number}
		self.IsHealthCheckScheduled = false -- Cancel any pending health check logic
	elseif newState == CircuitStateType.OPEN then
		self.Metrics.openCount += 1
		self.Metrics.lastOpenTime = tick()
		self.HalfOpenRequestCount = 0 -- Reset this for when it transitions back to HALF_OPEN
		-- Schedule health check if enabled and not already running
		if not wasHealthCheckScheduled and self.Options.healthCheckInterval > 0 then
			self.IsHealthCheckScheduled = true
			task.delay(self.Options.healthCheckInterval, function()
				-- Check state again inside delay in case it changed
				if self.IsHealthCheckScheduled then
					self:PerformHealthCheck()
				end
			end)
		end
	elseif newState == CircuitStateType.HALF_OPEN then
		self.ConsecutiveSuccesses = 0
		self.HalfOpenRequestCount = 0 -- Reset before allowing first request
		self.IsHealthCheckScheduled = false -- Don't run health checks in HALF_OPEN
	end

	self.Signals.StateChanged:Fire(oldState, newState)
end

-- Perform a periodic health check (internal use)
function CircuitBreaker:PerformHealthCheck()
	-- Clear scheduled flag regardless of outcome
	self.IsHealthCheckScheduled = false

	if self.State ~= CircuitStateType.OPEN then return end -- Only run if still OPEN

	local now = tick()
	if now - self.LastStateChange >= self.CurrentTimeout / 2 then
		if self.State == CircuitStateType.OPEN then -- Double check state before transition
			self:TransitionTo(CircuitStateType.HALF_OPEN)
		end
	else
		-- Reschedule next check if still within timeout window
		if self.Options.healthCheckInterval > 0 then
			self.IsHealthCheckScheduled = true
			task.delay(self.Options.healthCheckInterval, function()
				if self.IsHealthCheckScheduled then
					self:PerformHealthCheck()
				end
			end)
		end
	end
end

-- Manually force the circuit to a specific state
function CircuitBreaker:ForceState(state: CircuitState)
	-- Check if the provided state string is a valid key in the enum table
	if CircuitStateType[state] then -- Assumes state is "CLOSED", "OPEN", etc.
		self:TransitionTo(state)
	else
		error("[NetRay CircuitBreaker] Invalid circuit state provided to ForceState: " .. tostring(state), 2)
	end
end

-- Get current metrics and status
function CircuitBreaker:GetMetrics(): CircuitBreakerMetrics
	local now = tick()
	local metrics: CircuitBreakerMetrics = table.clone(self.Metrics)

	metrics.currentState = self.State
	metrics.failureCount = self.FailureCount
	metrics.timeInCurrentState = now - self.LastStateChange
	metrics.currentTimeout = self.CurrentTimeout

	local numRates = #self.Metrics.failureRates
	if numRates > 0 then
		local sum = 0
		for _, rate in ipairs(self.Metrics.failureRates) do sum += rate end
		metrics.averageFailureRate = sum / numRates
	else
		metrics.averageFailureRate = 0
	end

	return metrics
end


return CircuitBreaker :: { State: typeof(CircuitStateType), new: (options: CircuitBreakerOptions?) -> CircuitBreaker }