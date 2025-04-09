-- Promise Implementation (Basic Promise/A+ style)
-- Author: Asta (@TheYusufGamer)
-- NetRay

local Promise = {}
Promise.__index = Promise

-- Define internal Promise states
type PromiseState = "pending" | "fulfilled" | "rejected"

-- Define callback types
type ResolveCallback<T> = (value: T) -> ()
type RejectCallback = (reason: any) -> ()
type ThenCallback<T, U> = (value: T) -> U | Promise<U> -- Can return a value or a new promise
type CatchCallback<V> = (reason: any) -> V | Promise<V> -- Can return a value or a new promise
type FinallyCallback = () -> ()
type Executor<T> = (resolve: ResolveCallback<T>, reject: RejectCallback) -> ()

-- Define the Promise class type using generics
export type Promise<T> = {
	-- Internal properties (conventionally prefixed with _)
	_state: PromiseState,
	_value: T?, -- Value when fulfilled
	_reason: any?, -- Reason when rejected
	_thenCallbacks: {ThenCallback<T, any>}, -- Stores callbacks for 'then'
	_catchCallbacks: {CatchCallback<any>}, -- Stores callbacks for 'catch'
	_finallyCallbacks: {FinallyCallback}?, -- Optional: Store finally callbacks separately

	-- Public Methods
	andThen: <U>(self: Promise<T>, onFulfilled: ThenCallback<T, U>) -> Promise<U>, -- Returns a new promise
	-- Note: The original 'andThen' didn't return a new promise, adjusted for standard behavior
	catch: <V>(self: Promise<T>, onRejected: CatchCallback<V>) -> Promise<T | V>, -- Returns a new promise that resolves with T or V
	finally: (self: Promise<T>, onFinally: FinallyCallback) -> Promise<T>, -- Returns a new promise

	-- Static Methods (Attached to the main Promise table)
	-- new: <T>(executor: Executor<T>) -> Promise<T>, -- Constructor defined separately
	-- resolve: <T>(value: T) -> Promise<T>,
	-- reject: (reason: any) -> Promise<any>, -- Rejects with any type
	-- all: <T>(promises: {Promise<T>}) -> Promise<{T}>, -- Takes array of promises, returns promise of array results
}

-- Define the main Promise module type
export type PromiseModule = {
	__index: any, -- Metatable __index
	-- Static Methods / Constructor
	new: <T>(executor: Executor<T>) -> Promise<T>,
	resolve: <T>(value: T) -> Promise<T>,
	reject: (reason: any) -> Promise<any>,
	all: <T>(promises: {Promise<any>}) -> Promise<{any}>, -- Input can be promises of any type
}

-- Internal function to transition promise state safely
local function transition<T>(promise: Promise<T>, state: PromiseState, result: any)
	if promise._state ~= "pending" then return end -- Only transition pending promises

	promise._state = state
	if state == "fulfilled" then
		promise._value = result :: T -- Assign value
		-- Schedule fulfillment callbacks
		for _, callback in ipairs(promise._thenCallbacks) do
			task.spawn(callback, promise._value)
		end
	elseif state == "rejected" then
		promise._reason = result -- Assign reason
		-- Schedule rejection callbacks
		for _, callback in ipairs(promise._catchCallbacks) do
			task.spawn(callback, promise._reason)
		end
	end

	-- Trigger finally callbacks regardless of state change outcome (if they exist)
	if promise._finallyCallbacks then
		for _, callback in ipairs(promise._finallyCallbacks) do
			task.spawn(callback)
		end
	end

	-- Clear callbacks after scheduling to prevent memory leaks
	promise._thenCallbacks = {}
	promise._catchCallbacks = {}
	promise._finallyCallbacks = nil -- Clear finally callbacks too
end

-- Constructor
function Promise.new<T>(executor: Executor<T>): Promise<T>
	local self: Promise<T> = setmetatable({
		_state = "pending",
		_value = nil,
		_reason = nil,
		_thenCallbacks = {},
		_catchCallbacks = {},
		_finallyCallbacks = {} -- Initialize finally callbacks
	}, Promise)

	local function resolve(value: T)
		-- Use task.defer to ensure resolution happens after the current event loop tick
		task.defer(transition, self, "fulfilled", value)
	end

	local function reject(reason: any)
		task.defer(transition, self, "rejected", reason)
	end

	-- Execute the executor function asynchronously
	task.spawn(function()
		local success, err = pcall(executor, resolve, reject)
		if not success then
			-- If executor itself errors, reject the promise
			reject(err)
		end
	end)

	return self
end

-- then method (implements Promise/A+ behavior more closely)
-- Returns a *new* promise that resolves based on the callback's result
function Promise:andThen<U>(onFulfilled: ThenCallback<T, U>): Promise<U>
	-- Create the new promise to return
	local newPromise = Promise.new(function(resolve, reject)
		-- Define the callback wrapper to handle resolution/rejection of the new promise
		local function fulfilledCallbackWrapper(value: T)
			local success, resultOrPromise = pcall(onFulfilled, value)
			if not success then
				-- If the onFulfilled callback throws an error, reject the new promise
				reject(resultOrPromise)
			elseif typeof(resultOrPromise) == "table" and resultOrPromise._state then -- Check if it's a promise (basic check)
				-- If onFulfilled returns a promise, chain it
				(resultOrPromise :: Promise<U>):andThen(resolve):catch(reject)
			else
				-- If onFulfilled returns a value, resolve the new promise with it
				resolve(resultOrPromise :: U)
			end
		end

		-- Define how to handle rejection of the *original* promise
		local function rejectedCallbackWrapper(reason: any)
			-- If the original promise is rejected, the new promise is also rejected with the same reason
			reject(reason)
		end

		-- Attach the wrappers based on the current state
		if self._state == "fulfilled" then
			task.spawn(fulfilledCallbackWrapper, self._value) -- Execute immediately if already fulfilled
		elseif self._state == "rejected" then
			task.spawn(rejectedCallbackWrapper, self._reason) -- Execute immediately if already rejected
		elseif self._state == "pending" then
			-- Queue the wrappers if pending
			table.insert(self._thenCallbacks, fulfilledCallbackWrapper)
			table.insert(self._catchCallbacks, rejectedCallbackWrapper)
		end
	end)
	return newPromise :: Promise<U>
end


-- catch method (returns a new promise)
function Promise:catch<V>(onRejected: CatchCallback<V>): Promise<T | V>
	-- Create the new promise
	local newPromise = Promise.new(function(resolve, reject)
		-- Define how to handle fulfillment of the *original* promise
		local function fulfilledCallbackWrapper(value: T)
			-- If the original promise fulfills, the new promise fulfills with the same value
			resolve(value)
		end

		-- Define the callback wrapper for rejection
		local function rejectedCallbackWrapper(reason: any)
			local success, resultOrPromise = pcall(onRejected, reason)
			if not success then
				-- If the onRejected callback errors, reject the new promise
				reject(resultOrPromise)
			elseif typeof(resultOrPromise) == "table" and resultOrPromise._state then -- Check if it's a promise
				-- If onRejected returns a promise, chain it
				(resultOrPromise :: Promise<V>):andThen(resolve):catch(reject)
			else
				-- If onRejected returns a value (handling the error), resolve the new promise with that value
				resolve(resultOrPromise :: V)
			end
		end

		-- Attach wrappers based on current state
		if self._state == "fulfilled" then
			task.spawn(fulfilledCallbackWrapper, self._value)
		elseif self._state == "rejected" then
			task.spawn(rejectedCallbackWrapper, self._reason)
		elseif self._state == "pending" then
			table.insert(self._thenCallbacks, fulfilledCallbackWrapper)
			table.insert(self._catchCallbacks, rejectedCallbackWrapper)
		end
	end)
	-- The new promise can resolve with type T (from original fulfillment) or type V (from catch handler)
	return newPromise :: Promise<T | V>
end

-- finally method
function Promise:finally(onFinally: FinallyCallback): Promise<T>
	-- Ensure _finallyCallbacks table exists
	self._finallyCallbacks = self._finallyCallbacks or {}

	if self._state ~= "pending" then
		-- If already settled, schedule immediately
		task.spawn(onFinally)
	else
		-- If pending, add to the list
		table.insert(self._finallyCallbacks, onFinally)
	end

	-- Finally should return the original promise (or a promise that mirrors its settlement)
	-- For simplicity here, returning self, though a strict implementation returns a new mirroring promise.
	return self
end


-- Static resolve method
function Promise.resolve<T>(value: T): Promise<T>
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

-- Static reject method
function Promise.reject(reason: any): Promise<any> -- Returns Promise<any> as rejection type is not generic here
	return Promise.new(function(_, reject)
		reject(reason)
	end)
end

-- Static all method
function Promise.all<T>(promises: {Promise<any>}): Promise<{T}> -- Input can be any promise, output is array of results assumed to be T
	return Promise.new(function(resolve, reject)
		local results: {T} = {} -- Expecting an array of type T
		local remaining = #promises

		if remaining == 0 then
			resolve({} :: {T}) -- Resolve with empty array of type T
			return
		end

		local rejected = false -- Flag to prevent multiple rejections

		for i, promise in ipairs(promises) do
			-- Ensure input is treated as a promise
			local p = promise :: Promise<any>
			p:andThen(function(value)
				if rejected then return end -- Don't process if already rejected
				results[i] = value :: T -- Assume value matches expected type T
				remaining = remaining - 1
				if remaining == 0 then
					resolve(results)
				end
			end):catch(function(reason)
				if rejected then return end -- Only reject once
				rejected = true
				reject(reason) -- Reject the Promise.all if any input promise rejects
			end)
		end
	end)
end

return Promise :: PromiseModule