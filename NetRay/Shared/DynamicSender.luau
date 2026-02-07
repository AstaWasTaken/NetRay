--!strict
--!optimize 2
--!native

--[[
    DynamicSender Module (v2.0.0)

    Buffer-based dynamic serialization with arena batching.
    Uses NetRaySerializer for type-aware encoding and trims buffers to the exact cursor length.

    Author: Asta (@TheYusufGamer)
]]

local RunService = game:GetService("RunService")

local CursorModule = require(script.Parent.Parent.Types.Cursor)
local Serializer = require(script.Parent.Serializer)

local bufferCreate = buffer.create
local bufferLen = buffer.len
local bufferWriteU32 = buffer.writeu32
local osClock = os.clock
local pairs = pairs
local tableInsert = table.insert
local typeof = typeof
local warn = warn

local isClient = RunService:IsClient()
local isServer = RunService:IsServer()

export type DynamicSenderConfig = {
	MaxBatchSizeTrigger: number,
	DebugMode: boolean,
	InitialBufferSize: number,
	MaxMessageSize: number,
}

export type DynamicSenderMetrics = {
	serializeCount: number,
	deserializeCount: number,
	totalSerializeTime: number,
	totalDeserializeTime: number,
	errors: number,
	decodeErrors: number,
	sendErrors: number,
	avgSerializeTime: number,
	avgDeserializeTime: number,
}

export type SendOptions = {
	batchable: boolean?,
	[string]: any,
}

export type DynamicSenderModule = {
	VERSION: string,
	Config: DynamicSenderConfig,
	Send: (self: DynamicSenderModule, remote: RemoteEvent, data: any, target: Player?, options: SendOptions?) -> (),
	SendToMany: (self: DynamicSenderModule, remote: RemoteEvent, data: any, targets: { Player }, options: SendOptions?) -> (),
	DecodeReceivedData: (self: DynamicSenderModule, rawDataBuffer: buffer, rawInstances: {Instance}?) -> {any},
	GetMetrics: (self: DynamicSenderModule) -> DynamicSenderMetrics,
	ResetMetrics: (self: DynamicSenderModule) -> (),
	FlushBatches: (self: DynamicSenderModule) -> (),
}

type Cursor = CursorModule.Cursor

type BatchState = {
	PerPlayerCursors: { [Player]: Cursor },
	AllCursor: Cursor?,
}

local DynamicSender = {} :: DynamicSenderModule
DynamicSender.VERSION = "2.0.0"

DynamicSender.Config = {
	MaxBatchSizeTrigger = 8 * 1024,
	DebugMode = false,
	InitialBufferSize = 1024,
	MaxMessageSize = 1024 * 64,
}

local metrics = {
	serializeCount = 0,
	deserializeCount = 0,
	totalSerializeTime = 0,
	totalDeserializeTime = 0,
	errors = 0,
	decodeErrors = 0,
	sendErrors = 0,
}

local batchState: { [RemoteEvent]: BatchState } = {}
local activeRemotes: { [RemoteEvent]: boolean } = {}
local runServiceConnection: RBXScriptConnection? = nil

local function createCursor(initialSize: number): Cursor
	return CursorModule(bufferCreate(initialSize), {})
end

local function getOrCreateBatchCursor(remote: RemoteEvent, target: Player?): Cursor
	local remoteState = batchState[remote]
	if not remoteState then
		remoteState = { PerPlayerCursors = {} }
		batchState[remote] = remoteState
	end

	if target == nil then
		if not remoteState.AllCursor then
			remoteState.AllCursor = createCursor(DynamicSender.Config.InitialBufferSize)
		end
		return remoteState.AllCursor
	end

	if not remoteState.PerPlayerCursors[target] then
		remoteState.PerPlayerCursors[target] = createCursor(DynamicSender.Config.InitialBufferSize)
	end

	return remoteState.PerPlayerCursors[target]
end

local function writeMessage(cursor: Cursor, data: any)
	local lengthPos = cursor.Index
	cursor:WriteU4(0)
	local startIndex = cursor.Index
	Serializer.WriteValue(cursor, data)
	local messageLength = cursor.Index - startIndex
	if messageLength > DynamicSender.Config.MaxMessageSize then
		error("Message exceeds MaxMessageSize", 2)
	end
	bufferWriteU32(cursor.Buffer, lengthPos, messageLength)
end

local function sendImmediate(remote: RemoteEvent, data: any, target: Player?)
	metrics.serializeCount += 1
	local startTime = osClock()
	local estimated = Serializer.EstimateSize(data) + 4
	local cursor = createCursor(math.max(estimated, 16))
	writeMessage(cursor, data)
	local finalBuffer = cursor:Truncate()
	local finalInstances = cursor.Instances
	metrics.totalSerializeTime += (osClock() - startTime)
	if isServer then
		if target then
			remote:FireClient(target, finalBuffer, finalInstances)
		else
			remote:FireAllClients(finalBuffer, finalInstances)
		end
	else
		remote:FireServer(finalBuffer, finalInstances)
	end
end

local function processFrameBatches(triggeredRemote: RemoteEvent?)
	local remotesToProcess: { [RemoteEvent]: boolean } = {}
	if triggeredRemote and batchState[triggeredRemote] then
		remotesToProcess[triggeredRemote] = true
		activeRemotes[triggeredRemote] = nil
	end

	if next(activeRemotes) then
		for remote, _ in pairs(activeRemotes) do
			if batchState[remote] then
				remotesToProcess[remote] = true
			end
		end
		activeRemotes = {}
	end

	if not next(remotesToProcess) then
		return
	end

	local playersToRemove: { [RemoteEvent]: { Player } } = {}

	for remote, _ in pairs(remotesToProcess) do
		local remoteState = batchState[remote]
		if not remoteState then
			continue
		end

		if isServer then
			for player, cursor in pairs(remoteState.PerPlayerCursors) do
				if cursor.Index > 0 then
					if player and player.Parent then
						local finalBuffer = cursor:Truncate()
						local finalInstances = cursor.Instances
						remote:FireClient(player, finalBuffer, finalInstances)
						cursor:Clear()
					else
						cursor:Clear()
						if player then
							playersToRemove[remote] = playersToRemove[remote] or {}
							tableInsert(playersToRemove[remote], player)
						end
					end
				elseif player and not player.Parent then
					playersToRemove[remote] = playersToRemove[remote] or {}
					tableInsert(playersToRemove[remote], player)
				end
			end

			local allCursor = remoteState.AllCursor
			if allCursor and allCursor.Index > 0 then
				local finalBuffer = allCursor:Truncate()
				local finalInstances = allCursor.Instances
				remote:FireAllClients(finalBuffer, finalInstances)
				allCursor:Clear()
			end
		else
			local allCursor = remoteState.AllCursor
			if allCursor and allCursor.Index > 0 then
				local finalBuffer = allCursor:Truncate()
				local finalInstances = allCursor.Instances
				remote:FireServer(finalBuffer, finalInstances)
				allCursor:Clear()
			end
		end
	end

	if isServer then
		for remote, players in pairs(playersToRemove) do
			local remoteState = batchState[remote]
			if remoteState then
				for _, player in ipairs(players) do
					remoteState.PerPlayerCursors[player] = nil
				end
			end
		end
	end
end

function DynamicSender:Send(remote: RemoteEvent, data: any, target: Player?, options: SendOptions?)
	if not remote then warn("[DynamicSender ERR] RemoteEvent is nil.") return end
	if isClient and target then target = nil end
	if isServer and target and not target:IsA("Player") then warn("[DynamicSender ERR] Target must be Player instance or nil.") return end
	options = options or {}
	local batchable = options.batchable ~= false

	if not batchable then
		local ok, err = pcall(sendImmediate, remote, data, target)
		if not ok then
			metrics.errors += 1
			metrics.sendErrors += 1
			warn("[DynamicSender ERR] Immediate send failed: " .. tostring(err))
		end
		return
	end

	local cursor = getOrCreateBatchCursor(remote, target)
	local startTime = osClock()
	local ok, err = pcall(writeMessage, cursor, data)
	metrics.serializeCount += 1
	metrics.totalSerializeTime += (osClock() - startTime)
	if not ok then
		metrics.errors += 1
		warn("[DynamicSender ERR] Batch write failed: " .. tostring(err))
		return
	end

	if cursor.Index > 0 then
		activeRemotes[remote] = true
	end

	if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
		processFrameBatches(remote)
	end
end

function DynamicSender:SendToMany(remote: RemoteEvent, data: any, targets: { Player }, options: SendOptions?)
	if not isServer then warn("[DynamicSender ERR] SendToMany is server-only.") return end
	if not remote then warn("[DynamicSender ERR] RemoteEvent is nil.") return end
	if not targets or #targets == 0 then return end
	options = options or {}
	local batchable = options.batchable ~= false

	if not batchable then
		local startTime = osClock()
		local estimated = Serializer.EstimateSize(data) + 4
		local cursor = createCursor(math.max(estimated, 16))
		local ok, err = pcall(writeMessage, cursor, data)
		metrics.serializeCount += 1
		metrics.totalSerializeTime += (osClock() - startTime)
		if not ok then
			metrics.errors += 1
			metrics.sendErrors += 1
			warn("[DynamicSender ERR] Immediate SendToMany failed: " .. tostring(err))
			return
		end
		local finalBuffer = cursor:Truncate()
		local finalInstances = cursor.Instances
		for _, player in ipairs(targets) do
			if player and player.Parent then
				remote:FireClient(player, finalBuffer, finalInstances)
			end
		end
		return
	end

	for _, player in ipairs(targets) do
		if player and player.Parent then
			local cursor = getOrCreateBatchCursor(remote, player)
			local startTime = osClock()
			local ok, err = pcall(writeMessage, cursor, data)
			metrics.serializeCount += 1
			metrics.totalSerializeTime += (osClock() - startTime)
			if not ok then
				metrics.errors += 1
				warn("[DynamicSender ERR] Batch SendToMany write failed: " .. tostring(err))
			else
				activeRemotes[remote] = true
				if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
					processFrameBatches(remote)
				end
			end
		end
	end
end

function DynamicSender:DecodeReceivedData(rawDataBuffer: buffer, rawInstances: {Instance}?): {any}
	if typeof(rawDataBuffer) ~= "buffer" then
		if rawDataBuffer == nil then
			return {}
		end
		metrics.decodeErrors += 1
		warn("[DynamicSender ERR] Buffer expected for DecodeReceivedData")
		return {}
	end
	if bufferLen(rawDataBuffer) == 0 then
		return {}
	end

	local decodedMessages = {}
	local startTime = osClock()
	local cursor = CursorModule(rawDataBuffer, rawInstances or {})
	local totalLength = bufferLen(rawDataBuffer)

	while cursor.Index < totalLength do
		local length = cursor:ReadU4()
		if length <= 0 then
			metrics.errors += 1
			metrics.decodeErrors += 1
			break
		end
		local messageEnd = cursor.Index + length
		if messageEnd > totalLength then
			metrics.errors += 1
			metrics.decodeErrors += 1
			break
		end
		local success, valueOrError = pcall(Serializer.ReadValue, cursor)
		if not success then
			metrics.errors += 1
			metrics.decodeErrors += 1
			break
		end
		if cursor.Index ~= messageEnd then
			cursor.Index = messageEnd
		end
		metrics.deserializeCount += 1
		tableInsert(decodedMessages, valueOrError)
	end

	metrics.totalDeserializeTime += (osClock() - startTime)
	return decodedMessages
end

function DynamicSender.GetMetrics(): DynamicSenderMetrics
	local copy: any = {}
	for k, v in pairs(metrics) do copy[k] = v end
	copy.avgSerializeTime = if metrics.serializeCount > 0 then metrics.totalSerializeTime / metrics.serializeCount else 0
	copy.avgDeserializeTime = if metrics.deserializeCount > 0 then metrics.totalDeserializeTime / metrics.deserializeCount else 0
	return copy :: DynamicSenderMetrics
end

function DynamicSender.ResetMetrics()
	metrics.serializeCount = 0
	metrics.deserializeCount = 0
	metrics.totalSerializeTime = 0
	metrics.totalDeserializeTime = 0
	metrics.errors = 0
	metrics.decodeErrors = 0
	metrics.sendErrors = 0
end

function DynamicSender.FlushBatches()
	processFrameBatches()
end

if runServiceConnection then
	runServiceConnection:Disconnect()
	runServiceConnection = nil
end

runServiceConnection = RunService.Heartbeat:Connect(function()
	processFrameBatches()
end)

return DynamicSender
