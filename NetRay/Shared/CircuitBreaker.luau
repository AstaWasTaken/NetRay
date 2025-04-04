--!strict
--!optimize 2
--!native
--[[    
    CircuitBreaker.lua
    Implements the circuit breaker pattern to prevent cascading failures
    Optimized version with adaptive timeouts and improved state tracking
    Author: Asta (@TheYusufGamer)
]]

local SignalPlus = require(script.Parent.Parent.ThirdParty.SignalPlus)

local CircuitBreaker = {}
CircuitBreaker.__index = CircuitBreaker

-- Circuit states
CircuitBreaker.State = {
    CLOSED = "CLOSED",     -- Normal operation, requests flow through
    OPEN = "OPEN",         -- Circuit is open, requests are blocked
    HALF_OPEN = "HALF_OPEN" -- Testing if system has recovered
}

-- Track error patterns for adaptive timeout calculation
local function calculateAdaptiveTimeout(errorHistory, baseTimeout)
    if #errorHistory < 2 then
        return baseTimeout
    end
    
    -- Calculate the average time between errors
    local totalInterval = 0
    for i = 2, #errorHistory do
        totalInterval += errorHistory[i] - errorHistory[i-1]
    end
    
    local avgInterval = totalInterval / (#errorHistory - 1)
    
    -- If errors are very frequent, increase timeout exponentially
    if avgInterval < 1 then -- Less than 1 second between errors
        return baseTimeout * 2 -- Double the timeout
    elseif avgInterval < 5 then -- Less than 5 seconds between errors
        return baseTimeout * 1.5 -- Increase timeout by 50%
    else
        return baseTimeout -- Use the base timeout
    end
end

function CircuitBreaker.new(options)
    local self = setmetatable({}, CircuitBreaker)
    
    self.Options = {
        failureThreshold = options.failureThreshold or 5,  -- Number of failures before opening
        resetTimeout = options.resetTimeout or 30,         -- Seconds before trying half-open
        fallback = options.fallback or nil,                -- Optional fallback function
        halfOpenMaxRequests = options.halfOpenMaxRequests or 1, -- Max requests in half-open state
        adaptiveTimeouts = options.adaptiveTimeouts ~= false, -- Whether to use adaptive timeouts
        minimumTimeout = options.minimumTimeout or 5,     -- Minimum timeout duration
        maximumTimeout = options.maximumTimeout or 300,   -- Maximum timeout duration (5 minutes)
        healthCheckInterval = options.healthCheckInterval or 5 -- How often to check health during OPEN state
    }
    
    self.State = CircuitBreaker.State.CLOSED
    self.FailureCount = 0
    self.LastFailureTime = 0
    self.LastStateChange = tick()
    self.CurrentTimeout = self.Options.resetTimeout
    self.ErrorHistory = {}
    self.ConsecutiveSuccesses = 0
    self.IsHealthCheckScheduled = false
    self.HalfOpenRequestCount = 0
    
    -- Track metrics for monitoring
    self.Metrics = {
        totalFailures = 0,
        totalSuccesses = 0,
        lastOpenTime = 0,
        openCount = 0,
        successRateAfterRecovery = 0,
        failureRates = {}, -- Store last 10 failure rates
        averageRecoveryTime = 0
    }
    
    -- Signals for monitoring and debugging
    self.Signals = {
        StateChanged = SignalPlus(), -- Fires when circuit state changes
        FailureRecorded = SignalPlus(), -- Fires when a failure is recorded
        SuccessRecorded = SignalPlus(), -- Fires when a success is recorded
        Recovered = SignalPlus() -- Fires when circuit fully recovers from open state
    }
    
    return self
end

--[[    
    Determines if a request should be allowed through
    @return: true if allowed, false if blocked
]]
function CircuitBreaker:IsAllowed()
    local now = tick()
    
    if self.State == CircuitBreaker.State.OPEN then
        -- Check if it's time to try recovery
        if now - self.LastStateChange >= self.CurrentTimeout then
            self:TransitionTo(CircuitBreaker.State.HALF_OPEN)
            return true
        end
        return false
    elseif self.State == CircuitBreaker.State.HALF_OPEN then
        -- In half-open state, only allow a limited number of test requests through
        if self.HalfOpenRequestCount < self.Options.halfOpenMaxRequests then
            self.HalfOpenRequestCount += 1
            return true
        end
        return false
    end
    
    -- In closed state, all requests are allowed
    return true
end

--[[    
    Execute a function with circuit breaker protection
    @param fn: The function to execute
    @param ...: Arguments to pass to the function
    @return: Results from the function or fallback
]]
function CircuitBreaker:Execute(fn, ...)
    if not self:IsAllowed() then
        -- Circuit is open, use fallback if available
        if self.Options.fallback then
            return self.Options.fallback(...)
        else
            error("Circuit breaker is open - request rejected")
        end
    end
    
    -- Try executing the protected function
    local success, result = pcall(fn, ...)
    
    if success then
        self:RecordSuccess()
        return result
    else
        self:RecordFailure()
        
        -- Use fallback if available
        if self.Options.fallback then
            return self.Options.fallback(...)
        else
            error(result) -- Re-throw the original error
        end
    end
end

--[[    
    Record a successful operation
    Called after successful operations to potentially reset the circuit
]]
function CircuitBreaker:RecordSuccess()
    self.Metrics.totalSuccesses += 1
    
    if self.State == CircuitBreaker.State.HALF_OPEN then
        -- In half-open state, track consecutive successes
        self.ConsecutiveSuccesses += 1
        
        -- If we've had enough consecutive successes, close the circuit
        if self.ConsecutiveSuccesses >= self.Options.halfOpenMaxRequests then
            local recoveryTime = tick() - self.Metrics.lastOpenTime
            
            -- Update recovery time metric
            if self.Metrics.averageRecoveryTime > 0 then
                self.Metrics.averageRecoveryTime = (self.Metrics.averageRecoveryTime + recoveryTime) / 2
            else
                self.Metrics.averageRecoveryTime = recoveryTime
            end
            
            self:TransitionTo(CircuitBreaker.State.CLOSED)
            self.Signals.Recovered:Fire(recoveryTime)
        end
    end
    
    -- In closed state, reset failure count on success
    if self.State == CircuitBreaker.State.CLOSED and self.FailureCount > 0 then
        self.FailureCount = 0
        self.ErrorHistory = {}
    end
    
    -- Fire success recorded signal
    self.Signals.SuccessRecorded:Fire()
end

--[[    
    Record a failed operation
    Called after failed operations to potentially open the circuit
]]
function CircuitBreaker:RecordFailure()
    local now = tick()
    self.LastFailureTime = now
    self.Metrics.totalFailures += 1
    
    -- Add to error history for adaptive timeout calculation
    table.insert(self.ErrorHistory, now)
    if #self.ErrorHistory > 10 then
        table.remove(self.ErrorHistory, 1) -- Keep only last 10 errors
    end
    
    if self.State == CircuitBreaker.State.HALF_OPEN then
        -- If testing in half-open mode fails, go back to open with increased timeout
        if self.Options.adaptiveTimeouts then
            -- Increase timeout for next attempt but don't exceed maximum
            self.CurrentTimeout = math.min(
                self.CurrentTimeout * 1.5, 
                self.Options.maximumTimeout
            )
        end
        
        self:TransitionTo(CircuitBreaker.State.OPEN)
        return
    end
    
    -- Increment failure counter
    self.FailureCount += 1
    
    -- Calculate current failure rate for metrics
    local totalRequests = self.Metrics.totalSuccesses + self.Metrics.totalFailures
    if totalRequests > 0 then
        local failureRate = self.Metrics.totalFailures / totalRequests
        
        -- Store in failure rates history
        table.insert(self.Metrics.failureRates, failureRate)
        if #self.Metrics.failureRates > 10 then
            table.remove(self.Metrics.failureRates, 1)
        end
    end
    
    -- Check if we've exceeded threshold
    if self.State == CircuitBreaker.State.CLOSED and self.FailureCount >= self.Options.failureThreshold then
        -- Calculate adaptive timeout if enabled
        if self.Options.adaptiveTimeouts then
            self.CurrentTimeout = calculateAdaptiveTimeout(
                self.ErrorHistory,
                self.Options.resetTimeout
            )
            
            -- Ensure timeout is within limits
            self.CurrentTimeout = math.max(
                self.CurrentTimeout,
                self.Options.minimumTimeout
            )
            self.CurrentTimeout = math.min(
                self.CurrentTimeout,
                self.Options.maximumTimeout
            )
        else
            self.CurrentTimeout = self.Options.resetTimeout
        end
        
        self:TransitionTo(CircuitBreaker.State.OPEN)
    end
    
    -- Fire failure recorded signal
    self.Signals.FailureRecorded:Fire()
end

--[[    
    Change the circuit state
    @param newState: The new state to transition to
]]
function CircuitBreaker:TransitionTo(newState)
    local oldState = self.State
    self.State = newState
    self.LastStateChange = tick()
    
    if newState == CircuitBreaker.State.CLOSED then
        -- Reset tracking metrics when closing the circuit
        self.FailureCount = 0
        self.ConsecutiveSuccesses = 0
        self.HalfOpenRequestCount = 0
        self.ErrorHistory = {}
    elseif newState == CircuitBreaker.State.OPEN then
        -- Track metrics for open circuits
        self.Metrics.openCount += 1
        self.Metrics.lastOpenTime = tick()
        self.HalfOpenRequestCount = 0
        
        -- Schedule periodic health checks if configured
        if not self.IsHealthCheckScheduled and self.Options.healthCheckInterval > 0 then
            self.IsHealthCheckScheduled = true
            
            task.delay(self.Options.healthCheckInterval, function()
                self:PerformHealthCheck()
            end)
        end
    elseif newState == CircuitBreaker.State.HALF_OPEN then
        -- Reset counters for half-open testing
        self.ConsecutiveSuccesses = 0
        self.HalfOpenRequestCount = 0
    end
    
    -- Fire state changed signal
    self.Signals.StateChanged:Fire(oldState, newState)
end

--[[    
    Perform a health check to potentially recover faster
]]
function CircuitBreaker:PerformHealthCheck()
    self.IsHealthCheckScheduled = false
    
    -- Only run health checks while circuit is open
    if self.State ~= CircuitBreaker.State.OPEN then
        return
    end
    
    -- Try transitioning to half-open if enough time has passed
    local now = tick()
    if now - self.LastStateChange >= self.CurrentTimeout / 2 then
        self:TransitionTo(CircuitBreaker.State.HALF_OPEN)
    else
        -- Schedule next health check
        task.delay(self.Options.healthCheckInterval, function()
            self:PerformHealthCheck()
        end)
    end
end

--[[    
    Manually force the circuit to a specific state
    @param state: Target state to set
]]
function CircuitBreaker:ForceState(state)
    if CircuitBreaker.State[state] then
        self:TransitionTo(state)
    else
        error("[NetRay] Invalid circuit state: " .. tostring(state))
    end
end

--[[    
    Get current metrics and status
    @return: Table with circuit metrics and status
]]
function CircuitBreaker:GetMetrics()
    local now = tick()
    local metrics = table.clone(self.Metrics)
    
    metrics.currentState = self.State
    metrics.failureCount = self.FailureCount
    metrics.timeInCurrentState = now - self.LastStateChange
    metrics.currentTimeout = self.CurrentTimeout
    
    if #self.Metrics.failureRates > 0 then
        local sum = 0
        for _, rate in ipairs(self.Metrics.failureRates) do
            sum += rate
        end
        metrics.averageFailureRate = sum / #self.Metrics.failureRates
    else
        metrics.averageFailureRate = 0
    end
    
    return metrics
end

return CircuitBreaker
