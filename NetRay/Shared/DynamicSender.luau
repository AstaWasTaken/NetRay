--!strict
--!optimize 2
--!native

--[[
    NetRaySender.lua

    Handles efficient serialization, optional compression, and batching
    for the NetRay networking module. Batches are sent as a single buffer.
    Uses an augmented compression marker byte to indicate batch status.
	Author: Asta (@TheYusufGamer)
]]

local Serializer = require(script.Parent.Serializer)
local Compressor = require(script.Parent.Compressor) -- Takes data, returns binary string
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService") -- Used for size estimation

local NetRaySender = {}

-- Constants for the combined status marker byte
local MARKER_BYTE_POS = 0
local MARKER_UNCOMPRESSED_SINGLE = 0
local MARKER_COMPRESSED_SINGLE = 1
local MARKER_UNCOMPRESSED_BATCH = 2
local MARKER_COMPRESSED_BATCH = 3

-- Configuration
NetRaySender.Config = {
	BatchingEnabled = true,
	BatchInterval = 0.03,
	MaxBatchSize = 20,
	MaxBatchWait = 0.05,
	CompressionThreshold = 256,     -- Data size (estimated) above which compression is attempted
	DebugMode = false,            -- Enable debug messages
	ForceCompressBatches = true,   -- Always try to compress batches regardless of threshold
	ForceCompressSingle = true,    -- Always try to compress single messages regardless of threshold
}

-- Internal State
local batchQueues = {} -- Key: RemoteEvent instance, Value: table of { data = any, target = Player? }
local batchTimers = {} -- Key: RemoteEvent instance, Value: thread
local batchCreationTimes = {} -- Key: RemoteEvent instance, Value: os.clock()

-- Forward Declarations
local processBatch

--[[
    Estimate the size of data before serialization/compression.
]]
local function estimateDataSize(data: any) 
	local dataType = typeof(data)
	if dataType == "string" then
		return #data
	elseif dataType == "buffer" then
		return buffer.len(data) -- Shouldn't happen since compressor takes original data
	elseif dataType == "table" then
		-- Use JSONEncode for a rough size estimate of tables
		local success, encoded = pcall(HttpService.JSONEncode, HttpService, data)
		if success and typeof(encoded) == "string" then
			return #encoded
		else
			return 1024 -- Fallback large size if JSON encoding fails
		end
	elseif dataType == "number" then
		return 8
	elseif dataType == "boolean" then
		return 1
	elseif dataType == "Vector3" then
		return 12
	else
		return 32 -- Default estimate for other types
	end
end

--[[
    Serializes the final payload (original or compressed) into a buffer.
    Returns nil on failure.
]]
local function serializePayload(payload) : buffer?
	local serializeSuccess, serializedBuffer = pcall(Serializer.Serialize, payload)
	if not serializeSuccess then
		warn("[NetRaySender] Failed to serialize payload:", serializedBuffer)
		return nil
	end
	if typeof(serializedBuffer) ~= "buffer" then
		warn(`[NetRaySender] Serializer did not return a buffer, got: {typeof(serializedBuffer)}. Attempting conversion from string.`)
		-- Attempt conversion if serializer accidentally returned string
		if typeof(serializedBuffer) == "string" then
			local ok, convertedBuffer = pcall(buffer.fromstring, serializedBuffer)
			if ok then
				return convertedBuffer
			else
				return nil
			end
		else
			warn("[NetRaySender] Cannot proceed with non-buffer/non-string serialized data.")
			return nil
		end
	end
	return serializedBuffer
end


--[[
    Prepares data for sending: Handles compression, serializes,
    and prepends the appropriate status marker byte (0-3).
    @param data: The raw data (single item OR array of items for batch).
    @param isBatch: Boolean indicating if 'data' represents a batch.
    @param forceCompressionCheck: Bool to force check compression.
    @return: buffer ready to send, or nil on failure.
]]
local function prepareDataForSend(data: any, isBatch: boolean, forceCompressionCheck: boolean) : buffer?
	local estimatedSize = estimateDataSize(data)
	local shouldAttemptCompress = forceCompressionCheck or (NetRaySender.Config.CompressionThreshold > 0 and estimatedSize >= NetRaySender.Config.CompressionThreshold)

	local finalPayloadToSerialize = data -- Start assuming original data
	local wasCompressed = false
	local compressedBinaryString = nil -- Keep track if compression occurred

	if shouldAttemptCompress then
		if NetRaySender.Config.DebugMode then print(`[NetRaySender DBG] Attempting compression. Estimated Size: {estimatedSize}. Batch: {isBatch}`) end

		local compSuccess, _compressedString = pcall(Compressor.Compress, Compressor, data)
		if compSuccess and typeof(_compressedString) == "string" and #_compressedString > 0 then
			compressedBinaryString = _compressedString :: string
			-- Optimization: Don't serialize yet. Just compare raw string lengths for a heuristic.
			-- This avoids potentially costly serialization of original data if compressed is clearly smaller.
			-- Note: Serialized size can differ from raw string size, but this is a reasonable estimate.
			if #compressedBinaryString < estimateDataSize(data) then -- Compare compressed string len vs original estimate
				if NetRaySender.Config.DebugMode then print(`[NetRaySender DBG] Compression likely beneficial based on raw sizes. Original Est: {estimatedSize}, Comp Len: {#compressedBinaryString}`) end
				finalPayloadToSerialize = compressedBinaryString -- Choose compressed payload
				wasCompressed = true
			else
				if NetRaySender.Config.DebugMode then print(`[NetRaySender DBG] Compression not beneficial based on raw sizes. Original Est: {estimatedSize}, Comp Len: {#compressedBinaryString}. Sending original.`) end
				-- finalPayloadToSerialize remains the original 'data'
				wasCompressed = false
			end
		else
			if NetRaySender.Config.DebugMode then warn("[NetRaySender WARN] Compression failed or returned non-string/empty:", _compressedString) end
			-- Proceed with original data if compression fails
			wasCompressed = false
			-- finalPayloadToSerialize remains the original 'data'
		end
	else
		-- Not attempting compression
		wasCompressed = false
	end

	-- Serialize the *chosen* payload ONCE
	local serializedBuffer = serializePayload(finalPayloadToSerialize) -- Only one serialization call
	if not serializedBuffer then
		warn("[NetRaySender ERR] Failed to serialize final payload.")
		return nil -- Cannot proceed
	end

	-- Determine the final marker byte based on compression AND batch status
	local markerByte: number
	if isBatch then
		markerByte = if wasCompressed then MARKER_COMPRESSED_BATCH else MARKER_UNCOMPRESSED_BATCH
	else
		markerByte = if wasCompressed then MARKER_COMPRESSED_SINGLE else MARKER_UNCOMPRESSED_SINGLE
	end

	-- Prepend the single marker byte
	local finalBuffer = buffer.create(1 + buffer.len(serializedBuffer))
	buffer.writeu8(finalBuffer, MARKER_BYTE_POS, markerByte)
	buffer.copy(finalBuffer, 1, serializedBuffer, 0, buffer.len(serializedBuffer))

	if NetRaySender.Config.DebugMode then
		print(`[NetRaySender DBG] Prepared data. Final buffer size: {buffer.len(finalBuffer)}, Marker: {markerByte} (Compressed: {wasCompressed}, Batch: {isBatch})`)
	end

	return finalBuffer
end

--[[
    Decodes received data, using the status marker to handle compression
    and identify batches.
    @param rawData: The raw buffer received from the network.
    @return: Decoded data (single item or table of items for batches), or nil on failure.
]]
function NetRaySender:DecodeReceivedData(rawData)
	if typeof(rawData) ~= "buffer" then
		warn("[NetRaySender] Decode expected a buffer, received:", typeof(rawData))
		return rawData
	end
	if buffer.len(rawData) < 1 then -- Need at least 1 byte for marker
		warn("[NetRaySender] Decode received an empty or too small buffer.")
		return nil
	end

	-- 1. Read the combined status marker
	local statusMarker = buffer.readu8(rawData, MARKER_BYTE_POS)

	-- Determine compression and batch status from the marker
	local isCompressed: boolean
	local isBatch: boolean

	if statusMarker == MARKER_UNCOMPRESSED_SINGLE then
		isCompressed = false
		isBatch = false
	elseif statusMarker == MARKER_COMPRESSED_SINGLE then
		isCompressed = true
		isBatch = false
	elseif statusMarker == MARKER_UNCOMPRESSED_BATCH then
		isCompressed = false
		isBatch = true
	elseif statusMarker == MARKER_COMPRESSED_BATCH then
		isCompressed = true
		isBatch = true
	else
		warn("[NetRaySender] Received unknown status marker:", statusMarker)
		return nil -- Invalid marker
	end

	if NetRaySender.Config.DebugMode then
		print(`[NetRaySender] Decoding. Size: {buffer.len(rawData)}, Marker: {statusMarker} (Compressed: {isCompressed}, Batch: {isBatch})`)
	end

	-- 2. Extract the serialized payload (data after the marker byte)
	local serializedPayloadBuffer = buffer.create(buffer.len(rawData) - 1)
	buffer.copy(serializedPayloadBuffer, 0, rawData, 1)

	-- 3. Deserialize the payload
	local deserializeSuccess, deserializedPayload = pcall(Serializer.Deserialize, serializedPayloadBuffer)
	if not deserializeSuccess then
		warn("[NetRaySender] Failed to deserialize payload:", deserializedPayload)
		return nil
	end

	local finalData
	-- 4. Handle decompression if needed
	if isCompressed then
		if typeof(deserializedPayload) == "string" then
			if NetRaySender.Config.DebugMode then
				print("[NetRaySender] Decompressing payload string...")
			end
			local decompressedData = Compressor:Decompress(deserializedPayload)
			local decompressSuccess = (decompressedData ~= nil)
			if decompressSuccess then
				finalData = decompressedData
				if NetRaySender.Config.DebugMode then
					print("[NetRaySender] Decompression successful.")
				end
			else
				warn("[NetRaySender] Failed to decompress data:", decompressedData)
				return nil -- Indicate failure
			end
		else
			warn(`[NetRaySender] Compressed marker received but deserialized payload is not a string: {typeof(deserializedPayload)}`)
			return nil -- Indicate failure
		end
	else
		-- Not compressed, the deserialized payload is the final data
		finalData = deserializedPayload
		if NetRaySender.Config.DebugMode then
			print("[NetRaySender] Payload was not compressed.")
		end
	end

	-- 5. Return based on batch status
	if isBatch then
		if NetRaySender.Config.DebugMode then
			print("[NetRaySender] Decoded a batch.")
		end
		-- The finalData *is* the array of events `{event1, event2,...}`.
		if typeof(finalData) == "table" then
			return finalData
		else
			warn("[NetRaySender] Batch marker indicated but final data is not a table:", typeof(finalData))
			return nil -- Error case
		end
	else
		-- Not a batch, return the single item
		if NetRaySender.Config.DebugMode then
			print("[NetRaySender] Decoded single item.")
		end
		return finalData
	end
end

--[[
    Processes a batch of events for a specific remote.
]]
processBatch = function(remote: RemoteEvent)
	local queue = batchQueues[remote]
	if not queue or #queue == 0 then
		batchTimers[remote] = nil
		batchCreationTimes[remote] = nil
		return
	end

	local eventsToProcess = queue -- Get a reference before clearing
	batchQueues[remote] = {} -- Clear queue immediately
	batchCreationTimes[remote] = os.clock()
	batchTimers[remote] = nil -- Clear timer

	if NetRaySender.Config.DebugMode then
		print(`[NetRaySender] Processing batch for {remote:GetFullName()}. Size: {#eventsToProcess}`)
	end

	-- Optimization: Handle single-item "batch" queue directly
	if #eventsToProcess == 1 then
		local event = eventsToProcess[1]
		-- Prepare single item, marked explicitly as NOT a batch
		local preparedData = prepareDataForSend(event.data, false, NetRaySender.Config.ForceCompressSingle) -- isBatch = false
		if preparedData then
			if event.target then
				pcall(remote.FireClient, remote, event.target, preparedData)
			elseif remote.FireAllClients then
				pcall(remote.FireAllClients, remote, preparedData)
			else
				warn("[NetRaySender] Cannot FireAllClients on", remote, "- Target was nil but method doesn't exist.")
			end
		else
			warn("[NetRaySender] Failed to prepare single event data from batch queue:", event.data)
		end
		return
	end

	-- Group events by target
	local eventsByTarget = {}
	for _, event in ipairs(eventsToProcess) do
		local targetKey = event.target or "all"
		if not eventsByTarget[targetKey] then
			eventsByTarget[targetKey] = {}
		end
		table.insert(eventsByTarget[targetKey], event.data)
	end

	-- Process each target group
	for targetKey, dataItems in pairs(eventsByTarget) do
		-- Create the batch payload directly as an array of the data items
		local batchPayload = dataItems -- The array itself IS the payload

		-- Prepare the *entire* batch payload, marked explicitly AS a batch
		local preparedBatchData = prepareDataForSend(batchPayload, true, NetRaySender.Config.ForceCompressBatches) -- isBatch = true

		if preparedBatchData then
			if targetKey == "all" then
				if remote.FireAllClients then
					pcall(remote.FireAllClients, remote, preparedBatchData)
					if NetRaySender.Config.DebugMode then
						print(`[NetRaySender] Fired batch to all clients. Final Size: {buffer.len(preparedBatchData)} bytes`)
					end
				else
					warn("[NetRaySender] Cannot FireAllClients on", remote, "- Target key was 'all' but method doesn't exist.")
				end
			else
				local targetPlayer = targetKey :: Player
				if targetPlayer and targetPlayer.Parent then
					pcall(remote.FireClient, remote, targetPlayer, preparedBatchData)
					if NetRaySender.Config.DebugMode then
						print(`[NetRaySender] Fired batch to {targetPlayer.Name}. Final Size: {buffer.len(preparedBatchData)} bytes`)
					end
				else
					if NetRaySender.Config.DebugMode then
						print(`[NetRaySender] Skipped firing batch to target {targetKey} - Player likely left.`)
					end
				end
			end
		else
			warn("[NetRaySender] Failed to prepare batch data for target:", targetKey)
		end
	end
end


--[[
    Send data using the most efficient method (serialization + optional compression).
    Handles batching automatically if enabled.
]]
function NetRaySender:Send(remote: RemoteEvent, data: any, target: Player?, options: { noBatch: boolean? }?)
	if not remote then
		warn("[NetRaySender] Cannot send: RemoteEvent is nil.")
		return
	end

	local forceImmediate = options and options.noBatch == true
	local canBatch = NetRaySender.Config.BatchingEnabled and not forceImmediate

	-- Send immediately if batching disabled, forced, or target is 'all' without FireAllClients support
	if not canBatch or (target == nil) then
		if NetRaySender.Config.DebugMode then
			print(`[NetRaySender] Sending immediately. Reason: { (not canBatch and 'No Batching') or 'Target All/No FireAllClients Support' }`)
		end
		-- Prepare single item, marked as NOT a batch
		local preparedData = prepareDataForSend(data, false, NetRaySender.Config.ForceCompressSingle) -- isBatch = false
		if preparedData then
			if RunService:IsClient() then
				remote:FireServer(preparedData)
			else
				if target then
					remote:FireClient(target, preparedData)
				else
					remote:FireAllClients(preparedData)
				end
			end
		else
			warn("[NetRaySender] Failed to prepare data for immediate send:", data)
		end
		return
	end

	-- --- Batching Logic ---
	local queue = batchQueues[remote]
	if not queue then
		queue = {}
		batchQueues[remote] = queue
		batchCreationTimes[remote] = os.clock()
		if NetRaySender.Config.DebugMode then
			print(`[NetRaySender] Created new batch queue for {remote:GetFullName()}`)
		end
	end

	table.insert(queue, { data = data, target = target })
	if NetRaySender.Config.DebugMode then
		print(`[NetRaySender] Added event to batch queue for {remote:GetFullName()}. Current size: {#queue}`)
	end


	-- Start/Check Timers
	if not batchTimers[remote] then
		if NetRaySender.Config.DebugMode then
			print(`[NetRaySender] Starting batch timer for {remote:GetFullName()}`)
		end
		batchTimers[remote] = task.delay(NetRaySender.Config.BatchInterval, function()
			if batchQueues[remote] then
				processBatch(remote)
			else
				batchTimers[remote] = nil -- Clear self if queue disappeared
			end
		end)
	end

	if #queue >= NetRaySender.Config.MaxBatchSize then
		if NetRaySender.Config.DebugMode then
			print(`[NetRaySender] Batch full for {remote:GetFullName()}. Processing immediately.`)
		end
		if batchTimers[remote] then
			task.cancel(batchTimers[remote])
			-- No need to nil here, processBatch will clear it
		end
		processBatch(remote) -- This clears the timer reference
	end
end

--[[
    Send the same data to multiple specific targets efficiently.
]]
function NetRaySender:SendToMany(remote: RemoteEvent, data: any, targets: { Player })
	print(remote,data,targets)
	if not remote then
		warn("[NetRaySender] Cannot SendToMany: RemoteEvent is nil.")
		return
	end
	if not targets or #targets == 0 then
		warn("[NetRaySender] Cannot SendToMany: Targets list is empty or nil.")
		return
	end

	-- Prepare single item data once, marked as NOT batch
	local preparedData = prepareDataForSend(data, false, NetRaySender.Config.ForceCompressSingle) -- isBatch = false
	if not preparedData then
		warn("[NetRaySender] Failed to prepare data for SendToMany:", data)
		return
	end

	if NetRaySender.Config.DebugMode then
		print(`[NetRaySender] Sending to { #targets } targets via SendToMany.`)
	end

	for _, target in ipairs(targets) do
		if target and target.Parent then
			remote:FireClient(target, preparedData)
		end
	end
end

--[[
    Flush all pending batches immediately for all remotes.
]]
function NetRaySender:FlushBatches()
	if NetRaySender.Config.DebugMode then
		print("[NetRaySender] Flushing all batches...")
	end

	local remotesToProcess = {}
	for remote, timer in pairs(batchTimers) do
		task.cancel(timer)
		if not table.find(remotesToProcess, remote) then
			table.insert(remotesToProcess, remote)
		end
	end
	batchTimers = {}

	for remote, queue in pairs(batchQueues) do
		if #queue > 0 and not table.find(remotesToProcess, remote) then
			table.insert(remotesToProcess, remote)
		end
	end

	for _, remote in ipairs(remotesToProcess) do
		if batchQueues[remote] and #batchQueues[remote] > 0 then
			if NetRaySender.Config.DebugMode then
				print(`[NetRaySender] Flushing batch for {remote:GetFullName()}`)
			end
			processBatch(remote) -- This clears the queue internally
		end
	end

	batchQueues = {}
	batchCreationTimes = {}

	if NetRaySender.Config.DebugMode then
		print("[NetRaySender] Batch flush complete.")
	end
end

-- Initialization

-- Background task to enforce MaxBatchWait
if NetRaySender.Config.BatchingEnabled then
	task.spawn(function()
		while true do
			local waitTime = NetRaySender.Config.MaxBatchWait
			task.wait(waitTime)

			local currentTime = os.clock()
			local remotesToProcess = {}

			-- Collect remotes that need processing first
			for remote, creationTime in pairs(batchCreationTimes) do
				-- Check queue exists, has items, NO active timer, and time expired
				if batchQueues[remote] and #batchQueues[remote] > 0 and not batchTimers[remote] then
					if (currentTime - creationTime) >= NetRaySender.Config.MaxBatchWait then
						table.insert(remotesToProcess, remote)
					end
				end
			end

			-- Process the collected remotes
			for _, remote in ipairs(remotesToProcess) do
				-- Double-check conditions before processing
				if batchQueues[remote] and #batchQueues[remote] > 0 and not batchTimers[remote] then
					if NetRaySender.Config.DebugMode then
						print(`[NetRaySender] Max wait time reached for {remote:GetFullName()}. Processing batch.`)
					end
					processBatch(remote)
				end
			end
		end
	end)
end

-- Server-side shutdown handler
if RunService:IsServer() then
	game:BindToClose(function()
		if NetRaySender then -- Check if module hasn't been destroyed
			warn("[NetRaySender] Game closing. Flushing remaining batches...")
			NetRaySender:FlushBatches()
			task.wait(0.1) -- Short wait to allow network flush attempt
		end
	end)
end

return NetRaySender
