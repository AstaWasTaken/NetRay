--!optimize 2

--[[
    Errors.lua
    Defines error types and handling utilities for the NetRay library
    Author: Asta (@TheYusufGamer)
]]

-- Define the module table first
local Errors = {}

-- Error types Enum (using a table as an enum)
-- Use PascalCase for enum-like table names by convention
local ErrorTypes = {
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
-- Export the ErrorTypes table if needed elsewhere
export type ErrorTypesEnum = typeof(ErrorTypes)
Errors.Type = ErrorTypes -- Assign to the export table

-- Define the type for the error object itself
export type NetRayError = {
	type: string, -- Should ideally match one of the values in ErrorTypes
	message: string,
	details: any?, -- Can hold additional context
	timestamp: number,
	__tostring: (self: NetRayError) -> string, -- Metamethod signature
}

-- Define the type for the Error 'class' table (containing .new)
type NetRayErrorClass = {
	__index: NetRayErrorClass, -- Points to itself for method lookup
	new: (errorType: string?, message: string?, details: any?) -> NetRayError, -- Constructor
}

-- Define the type for the main Errors module table
export type ErrorsModule = {
	Type: ErrorTypesEnum,
	Error: NetRayErrorClass, -- The 'class' table

	-- Specific error constructor functions
	NETWORK: (message: string?, details: any?) -> NetRayError,
	TIMEOUT: (message: string?, details: any?) -> NetRayError,
	VALIDATION: (message: string?, details: any?) -> NetRayError,
	SERIALIZATION: (message: string?, details: any?) -> NetRayError,
	RATE_LIMIT: (message: string?, details: any?) -> NetRayError,
	CIRCUIT_OPEN: (message: string?, details: any?) -> NetRayError,
	MIDDLEWARE: (message: string?, details: any?) -> NetRayError,
	INTERNAL: (message: string?, details: any?) -> NetRayError,
	NOT_FOUND: (message: string?, details: any?) -> NetRayError,
	TYPE_ERROR: (message: string?, details: any?) -> NetRayError,

	-- Utility functions
	isNetRayError: (err: any) -> boolean,
	try: <T>(fn: (...any) -> T, ...any) -> {success: true, value: T} | {success: false, error: NetRayError | any}, -- Generic return type
	serialize: (err: any) -> {type: string, message: string, details: any?, timestamp: number},
	deserialize: (data: any) -> NetRayError
}

-- Implementation
local ErrorImpl = {} -- Internal table for the Error 'class' methods
ErrorImpl.__index = ErrorImpl

-- Error class constructor
function ErrorImpl.new(errorType: string?, message: string?, details: any?): NetRayError
	local self = setmetatable({}, ErrorImpl)

	self.type = errorType or ErrorTypes.INTERNAL
	self.message = message or "An unknown error occurred"
	self.details = details
	self.timestamp = tick()

	-- Ensure the returned object matches the NetRayError type structure
	return self :: NetRayError
end

-- Error class __tostring metamethod
function ErrorImpl:__tostring(): string
	return "[NetRay." .. self.type .. "] " .. self.message
end

-- Assign the implementation to the exported Error 'class' table
Errors.Error = ErrorImpl :: NetRayErrorClass

-- Create specific error constructors dynamically
for name, errorType in pairs(ErrorTypes) do
	-- Create a correctly typed function for each error type
	Errors[name] = (function(errType: string)
		return function(message: string?, details: any?): NetRayError
			return Errors.Error.new(errType, message, details)
		end
	end)(errorType) -- Pass errorType into the closure
end

-- Determine if an object is a NetRay error
function Errors.isNetRayError(err: any): boolean
	-- Check if it's a table and has the correct metatable assigned by Errors.Error.new
	return typeof(err) == "table" and getmetatable(err) == ErrorImpl
end

-- Helper to wrap pcall with error handling
-- Use generic <T> for the success return type
function Errors.try<T>(fn: (...any) -> T, ...): {success: true, value: T} | {success: false, error: NetRayError | any} -- Just use ... for varargs
	local success, result = pcall(fn, ...)

	if success then
		return {
			success = true,
			value = result :: T -- Assert the type of the successful result
		}
	else
		local errorResult: NetRayError | any
		-- Convert plain string errors to NetRay INTERNAL errors
		if typeof(result) == "string" then
			errorResult = Errors.INTERNAL(result)
		else
			-- Keep non-string errors as they are (could be NetRayError or other error objects)
			errorResult = result
		end

		return {
			success = false,
			error = errorResult
		}
	end
end

-- Format an error for transport over the network
-- Returns a plain table suitable for serialization
function Errors.serialize(err: any): {type: string, message: string, details: any?, timestamp: number}
	if Errors.isNetRayError(err) then
		-- Cast err to NetRayError to access properties safely
		local netRayErr = err :: NetRayError
		return {
			type = netRayErr.type,
			message = netRayErr.message,
			-- Note: Serializing 'details' might fail if it contains non-serializable types (Instances, functions etc.)
			details = netRayErr.details,
			timestamp = netRayErr.timestamp
		}
	else
		-- Generic error conversion
		return {
			type = ErrorTypes.INTERNAL,
			message = tostring(err),
			details = nil, -- Cannot reliably serialize details of unknown errors
			timestamp = tick()
		}
	end
end

-- Recreate a NetRayError object from serialized data
function Errors.deserialize(data: any): NetRayError
	if typeof(data) ~= "table" then
		-- Return a specific serialization error if data format is wrong
		return Errors.SERIALIZATION("Invalid error data format received for deserialization")
	end

	-- Create a new NetRayError using the data from the table
	return Errors.Error.new(
		data.type, -- Let .new handle default if type is missing/invalid
		data.message, -- Let .new handle default if message is missing
		data.details -- Pass details through
	)
end

-- Return the fully typed module table
return Errors :: ErrorsModule