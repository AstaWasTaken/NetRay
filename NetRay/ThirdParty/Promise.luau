-- Promise Implementation
-- Author: Asta (@TheYusufGamer)
-- NetRay

local Promise = {}
Promise.__index = Promise

function Promise.new(executor)
	local self = setmetatable({
		_state = "pending",
		_value = nil,
		_reason = nil,
		_thenCallbacks = {},
		_catchCallbacks = {}
	}, Promise)

	local function resolve(value)
		if self._state ~= "pending" then return end
		self._state = "fulfilled"
		self._value = value

		for _, callback in ipairs(self._thenCallbacks) do
			task.spawn(callback, value)
		end
	end

	local function reject(reason)
		if self._state ~= "pending" then return end
		self._state = "rejected"
		self._reason = reason

		for _, callback in ipairs(self._catchCallbacks) do
			task.spawn(callback, reason)
		end
	end

	task.spawn(function()
		local success, err = pcall(executor, resolve, reject)
		if not success then
			reject(err)
		end
	end)

	return self
end

function Promise:andThen(callback)
	if self._state == "fulfilled" then
		task.spawn(callback, self._value)
	elseif self._state == "pending" then
		table.insert(self._thenCallbacks, callback)
	end
	return self
end

function Promise:catch(callback)
	if self._state == "rejected" then
		task.spawn(callback, self._reason)
	elseif self._state == "pending" then
		table.insert(self._catchCallbacks, callback)
	end
	return self
end

function Promise:finally(callback)
	local function onFinally()
		callback()
	end

	self:andThen(onFinally)
	self:catch(onFinally)

	return self
end

function Promise.resolve(value)
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

function Promise.reject(reason)
	return Promise.new(function(_, reject)
		reject(reason)
	end)
end

function Promise.all(promises)
	return Promise.new(function(resolve, reject)
		local results = {}
		local remaining = #promises

		if remaining == 0 then
			resolve({})
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(function(value)
				results[i] = value
				remaining = remaining - 1

				if remaining == 0 then
					resolve(results)
				end
			end):catch(function(reason)
				reject(reason)
			end)
		end
	end)
end

return Promise