--!strict
--[[
    Constants.lua
    Defines shared constants used throughout the NetRay library
    Author: Asta (@TheYusufGamer)
]]

local Constants = {
    -- Event priorities
    PRIORITY = {
        CRITICAL = 0,
        HIGH = 1,
        NORMAL = 2,
        LOW = 3,
        BACKGROUND = 4
    },
    
    -- Default rate limiting settings
    RATE_LIMIT = {
        DEFAULT_MAX_REQUESTS = 120,    -- Per second
        DEFAULT_TIME_WINDOW = 1,       -- In seconds
        DEFAULT_BURST_LIMIT = 20,      -- Per burst window
        DEFAULT_BURST_WINDOW = 0.1     -- In seconds (100ms)
    },
    
    -- Compression settings
    COMPRESSION = {
        DEFAULT_THRESHOLD = 1000 or 256,      -- Minimum size in bytes to compress (1KB)
        COMPRESSION_LEVEL = 9,         -- Highest compression 
    },
    
    -- Timeout settings
    TIMEOUT = {
        DEFAULT_REQUEST_TIMEOUT = 10,  -- In seconds
        CONNECT_TIMEOUT = 5,          -- In seconds
        QUEUE_PROCESS_INTERVAL = 0.01  -- In seconds
    },
    
    -- Circuit breaker settings
    CIRCUIT_BREAKER = {
        DEFAULT_FAILURE_THRESHOLD = 5,  -- Failures before opening
        DEFAULT_RESET_TIMEOUT = 30,     -- Seconds before trying half-open
    },
    
    -- Remote object naming
    REMOTE_NAMING = {
        FUNCTION_SUFFIX = "_RF",       -- Suffix for RemoteFunction objects
        EVENTS_FOLDER = "NetRayRemotes" -- Folder name for RemoteEvents
    },
    
    -- Version info
    VERSION = "1.0.1"
}

return Constants
