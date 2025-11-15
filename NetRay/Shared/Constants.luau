--!optimize 2

--[[
    Constants.lua
    Defines shared constants used throughout the NetRay library
    Author: Asta (@TheYusufGamer)
]]

-- Type definition for the Priority sub-table 
type PriorityConstants = {
	CRITICAL: number,
	HIGH: number,
	NORMAL: number,
	LOW: number,
	BACKGROUND: number,
	[string]: number? -- Allows other string keys, value is number or nil
}

-- Type definition for Rate Limit sub-table
type RateLimitConstants = {
	DEFAULT_MAX_REQUESTS: number,
	DEFAULT_TIME_WINDOW: number,
	DEFAULT_BURST_LIMIT: number,
	DEFAULT_BURST_WINDOW: number
}

-- Type definition for Compression sub-table
type CompressionConstants = {
	DEFAULT_THRESHOLD: number,
	COMPRESSION_LEVEL: number
}

-- Type definition for Timeout sub-table
type TimeoutConstants = {
	DEFAULT_REQUEST_TIMEOUT: number,
	CONNECT_TIMEOUT: number,
	QUEUE_PROCESS_INTERVAL: number
}

-- Type definition for Circuit Breaker sub-table
type CircuitBreakerConstants = {
	DEFAULT_FAILURE_THRESHOLD: number,
	DEFAULT_RESET_TIMEOUT: number
}

-- Type definition for Remote Naming sub-table
type RemoteNamingConstants = {
	FUNCTION_SUFFIX: string,
	EVENTS_FOLDER: string
}

-- Define the type for the returned module table
export type ConstantsModule = {
	PRIORITY: PriorityConstants, -- Use corrected type
	RATE_LIMIT: RateLimitConstants,
	COMPRESSION: CompressionConstants,
	TIMEOUT: TimeoutConstants,
	CIRCUIT_BREAKER: CircuitBreakerConstants,
	REMOTE_NAMING: RemoteNamingConstants,
	VERSION: string
}

-- Define the actual constant values, asserting the overall type
local Constants: ConstantsModule = {
	PRIORITY = {
		CRITICAL = 0, HIGH = 1, NORMAL = 2, LOW = 3, BACKGROUND = 4
	},
	PROCESS_LIMITS = {
		[0] = math.huge, 
		[1] = 5,
		[2] = 3, 
		[3] = 2, 
		[4] = 1
	},
	MIN_PROCESS_TIME = 0.005,
	CYCLE_WAIT = 0.1,
	RATE_LIMIT = {
		DEFAULT_MAX_REQUESTS = 120, DEFAULT_TIME_WINDOW = 1,
		DEFAULT_BURST_LIMIT = 20, DEFAULT_BURST_WINDOW = 0.1
	},
	COMPRESSION = {
		DEFAULT_THRESHOLD = 256, 
		COMPRESSION_LEVEL = 9,
	},
	TIMEOUT = {
		DEFAULT_REQUEST_TIMEOUT = 10, CONNECT_TIMEOUT = 5, QUEUE_PROCESS_INTERVAL = 0.01
	},
	CIRCUIT_BREAKER = {
		DEFAULT_FAILURE_THRESHOLD = 5, DEFAULT_RESET_TIMEOUT = 30
	},
	REMOTE_NAMING = {
		FUNCTION_SUFFIX = "_RF", EVENTS_FOLDER = "NetRayRemotes"
	},
	VERSION = "1.1.5"
}

return Constants