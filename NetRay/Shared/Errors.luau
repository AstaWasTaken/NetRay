--!strict
--!optimize 2
--!native

--[[
    Errors.lua
    Defines error types and handling utilities for the NetRay library
    Author: Asta (@TheYusufGamer)
]]

local Errors = {}

-- Error types
Errors.Type = {
	NETWORK = "NETWORK_ERROR",
	TIMEOUT = "TIMEOUT_ERROR",
	VALIDATION = "VALIDATION_ERROR",
	SERIALIZATION = "SERIALIZATION_ERROR",
	RATE_LIMIT = "RATE_LIMIT_ERROR", 
	CIRCUIT_OPEN = "CIRCUIT_OPEN_ERROR",
	MIDDLEWARE = "MIDDLEWARE_ERROR",
	INTERNAL = "INTERNAL_ERROR",
	NOT_FOUND = "NOT_FOUND_ERROR",
	TYPE_ERROR = "TYPE_ERROR"
}

-- Error class
Errors.Error = {}
Errors.Error.__index = Errors.Error

function Errors.Error.new(errorType, message, details)
	local self = setmetatable({}, Errors.Error)

	self.type = errorType or Errors.Type.INTERNAL
	self.message = message or "An unknown error occurred"
	self.details = details
	self.timestamp = tick()

	return self 
end

function Errors.Error:__tostring()
	return "[NetRay." .. self.type .. "] " .. self.message
end

-- Create specific error constructors
for name, errorType in pairs(Errors.Type) do
	Errors[name] = function(message, details)
		return Errors.Error.new(errorType, message, details)
	end
end

-- Determine if an object is a NetRay error
function Errors.isNetRayError(err)
	return type(err) == "table" and getmetatable(err) == Errors.Error
end

-- Helper to wrap pcall with error handling
function Errors.try(fn, ...)
	local success, result = pcall(fn, ...)

	if success then
		return {
			success = true,
			value = result
		}
	else
		-- Convert string errors to NetRay errors
		if type(result) == "string" then
			result = Errors.INTERNAL(result)
		end

		return {
			success = false,
			error = result
		}
	end
end

-- Format an error for transport over the network
function Errors.serialize(err)
	if Errors.isNetRayError(err) then
		return {
			type = err.type,
			message = err.message,
			details = err.details,
			timestamp = err.timestamp
		}
	else
		-- Generic error
		return {
			type = Errors.Type.INTERNAL,
			message = tostring(err),
			timestamp = tick()
		}
	end
end

-- Recreate an error from serialized data
function Errors.deserialize(data)
	if type(data) ~= "table" then
		return Errors.SERIALIZATION("Invalid error data format")
	end

	return Errors.Error.new(
		data.type or Errors.Type.INTERNAL,
		data.message or "Unknown error",
		data.details
	)
end

return Errors