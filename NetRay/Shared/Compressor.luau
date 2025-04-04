--!strict
--!optimize 2
--!native

--[[
    Compressor.lua
    Handles data compression to reduce network traffic
    
    Uses the DataCompression module for compression/decompression
    Author: Asta (@TheYusufGamer)
]]

local ThirdParty = script.Parent.Parent.ThirdParty
local DataCompression = require(ThirdParty.DataCompression)

local Compressor = {}

--[[
    Compress data to reduce network traffic
    @param data: The data to compress
    @return: Compressed data
]]
function Compressor:Compress(data)
    return DataCompression:Compress(data)
end

--[[
    Decompress previously compressed data
    @param compressedData: The compressed data
    @return: Original uncompressed data
]]
function Compressor:Decompress(compressedData)
    return DataCompression:Decompress(compressedData)
end

--[[
    Determines if compression would be beneficial for the given data
    @param data: The data to evaluate
    @param threshold: Minimum size in bytes to compress (default: 1024)
    @return: true if compression is recommended
]]
function Compressor:ShouldCompress(data, threshold)
    threshold = threshold or 1024 -- Default 1KB threshold
    
    local dataSize = 0
    
    if typeof(data) == "string" then
        dataSize = #data
    elseif typeof(data) == "buffer" then
        dataSize = buffer.len(data) -- compressor doesnt support buffer's 
    else
        return false
    end
    
    return dataSize >= threshold
end

--[[
    Utility to check compression ratio for diagnostic purposes
    @param originalData: The original uncompressed data
    @param compressedData: The compressed version
    @return: Compression ratio (original/compressed)
]]
function Compressor:GetCompressionRatio(originalData, compressedData)
    local originalSize = 0
    local compressedSize = 0
    
    if typeof(originalData) == "string" then
        originalSize = #originalData
    elseif typeof(originalData) == "buffer" then
        originalSize = buffer.len(originalData)
    else
        return 1
    end
    
    if typeof(compressedData) == "string" then
        compressedSize = #compressedData
    elseif typeof(compressedData) == "buffer" then
        compressedSize = buffer.len(compressedData)
    else
        return 1
    end
    
    if compressedSize == 0 then
        return 1
    end
    
    return originalSize / compressedSize
end

return Compressor
