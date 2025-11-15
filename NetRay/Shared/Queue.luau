--!optimize 2

--[[
    Queue.lua
    Implementation of a FIFO queue system for network operations (Not priority queue)
    Optimized version with memory efficiency and performance improvements
    Author: Asta (@TheYusufGamer)
]]

-- Type definitions for Luau

-- Stats structure (internal, used to build QueueStats)
type InternalQueueStats = {
	enqueues: number,
	dequeues: number,
	maxSize: number,
	resizes: number,
	peekCount: number,
	processingTimeTotal: number, -- Internal sum for avg calculation
	processingCount: number -- Internal count for avg calculation
}

-- Exported Stats structure (omits internal calculation fields)
export type QueueStats = {
	enqueues: number,
	dequeues: number,
	maxSize: number,
	resizes: number,
	peekCount: number,
	avgProcessingTime: number -- Calculated average
}

-- Queue class definition (Generic T for stored item type)
local Queue = {}
Queue.__index = Queue

-- Explicitly type the Queue object instance structure using generic T
-- Note: Direct typeof() on setmetatable doesn't work well with generics.
-- Define the instance type separately.
export type Queue<T> = {
	-- Internal properties (conventionally private)
	_items: {[number]: T?}, -- Array used as circular buffer, values can be nil after dequeue
	_size: number, -- Current number of items in queue
	_head: number, -- Physical index of the first item
	_tail: number, -- Physical index *after* the last item
	_capacity: number, -- Current physical size of the _items array
	_stats: InternalQueueStats, -- Internal stats tracking
	-- Homogeneous tracking (less useful without priority, but keep if used elsewhere)
	_isHomogeneous: boolean,
	_itemType: string,

	-- Methods
	Enqueue: (self: Queue<T>, item: T) -> (),
	Dequeue: (self: Queue<T>) -> T?,
	Peek: (self: Queue<T>) -> T?,
	Size: (self: Queue<T>) -> number,
	IsEmpty: (self: Queue<T>) -> boolean,
	Clear: (self: Queue<T>) -> (),
	GetItems: (self: Queue<T>) -> {T}, -- Returns array of type T
	Find: (self: Queue<T>, predicate: (value: T) -> boolean) -> number?,
	Remove: (self: Queue<T>, predicate: (value: T) -> boolean) -> T?,
	BatchEnqueue: (self: Queue<T>, items: {T}) -> (),
	GetStats: (self: Queue<T>) -> QueueStats,
	-- Internal methods
	_PhysicalIndex: (self: Queue<T>, logicalIndex: number) -> number,
	_Resize: (self: Queue<T>, newCapacity: number) -> (),
}

-- Constants
local DEFAULT_INITIAL_CAPACITY = 16
local GROWTH_FACTOR = 1.5
local SHRINK_THRESHOLD = 0.25
local Utilities = require(script.Parent.Utilities)

-- Local utility functions
local tableCreate = table.create
local tableClone = table.clone or Utilities.deepCopy
local mathCeil = math.ceil
local mathFloor = math.floor
local mathMax = math.max -- Cache math.max

-- Constructor function 
function Queue.new<T>(initialCapacity: number?): Queue<T>
	local capacity = mathMax(initialCapacity or DEFAULT_INITIAL_CAPACITY, 1) -- Ensure positive capacity
	local self = setmetatable({}, Queue)
	self._items = tableCreate(capacity) :: {[number]: T?} -- Assert type of items table
	self._size = 0
	self._head = 1
	self._tail = 1
	self._capacity = capacity
	self._isHomogeneous = true
	self._itemType = ""
	self._stats = { -- Initialize internal stats
		enqueues = 0, dequeues = 0, maxSize = 0, resizes = 0, peekCount = 0,
		processingTimeTotal = 0, processingCount = 0
	} :: InternalQueueStats -- Assert type of stats table

	return self :: Queue<T> -- Assert return type
end

-- Add an item to the queue
function Queue:Enqueue(item: T) -- Type T for item
	self._stats.enqueues += 1
--	print(os.time(), string.format("[Queue] Enqueued. Size: %d, Head: %d, Tail: %d, Cap: %d", self._size, self._head, self._tail, self._capacity))
	if self._size >= self._capacity then
		self:_Resize(mathCeil(self._capacity * GROWTH_FACTOR))
	end

	-- Update homogeneous tracking (removed priority check)
	if self._size == 0 and item ~= nil then self._itemType = typeof(item)
	elseif self._isHomogeneous and item ~= nil and typeof(item) ~= self._itemType then self._isHomogeneous = false
	end

	self._items[self._tail] = item
	self._tail = (self._tail % self._capacity) + 1
	self._size += 1
	self._stats.maxSize = mathMax(self._size, self._stats.maxSize)
end

-- Convert logical index to physical index
function Queue:_PhysicalIndex(logicalIndex: number): number
	if logicalIndex < 1 or logicalIndex > self._size then error("Logical index out of bounds", 2) end
	return (self._head + logicalIndex - 2) % self._capacity + 1
end

-- Resize internal array
-- In Queue.lua
function Queue:_Resize(newCapacity: number)
	if newCapacity <= self._size then error("New capacity must be larger than current size", 2) end
	self._stats.resizes += 1
	local newItems = tableCreate(newCapacity) :: {[number]: T?}

--	print(os.time(), string.format("[Queue Resize Start] OldCap: %d, NewCap: %d, Size: %d, Head: %d, Tail: %d", self._capacity, newCapacity, self._size, self._head, self._tail)) -- Add log

	-- Copy items into newItems starting at index 1
	local currentTargetIndex = 1
	if self._head < self._tail then -- Contiguous block (Normal Case)
		-- Copy from old physical index self._head up to self._tail - 1
		for i = self._head, self._tail - 1 do
			newItems[currentTargetIndex] = self._items[i]
			currentTargetIndex = currentTargetIndex + 1
		end
	else -- Wrapped around block
		-- Copy from old physical index self._head up to self._capacity
		for i = self._head, self._capacity do
			newItems[currentTargetIndex] = self._items[i]
			currentTargetIndex = currentTargetIndex + 1
		end
		-- Copy from old physical index 1 up to self._tail - 1
		for i = 1, self._tail - 1 do
			newItems[currentTargetIndex] = self._items[i]
			currentTargetIndex = currentTargetIndex + 1
		end
	end

	-- Check if the number of copied items matches the size
	local itemsCopied = currentTargetIndex - 1
	if itemsCopied ~= self._size then
		warn(string.format("[Queue Resize WARN] Size mismatch after copy! Expected %d, Copied %d. State(H:%d,T:%d,C:%d)", self._size, itemsCopied, self._head, self._tail, self._capacity))
		-- This indicates a potential logic error in the copy loops above
	end

	-- Update internal state
	self._items = newItems
	self._head = 1                     -- New head is always 1
	self._tail = self._size + 1       -- New tail is size + 1 (index after last item)
	self._capacity = newCapacity

	-- Log state AFTER resize (Using corrected print from last time)
	--print(os.time(), string.format("[Queue Resize Complete] New Cap: %d, Size: %d, Head: %d, Tail: %d", self._capacity, self._size, self._head, self._tail))
	local snippet = {}; local log = {"    New Items (Start): {"}; local first=true
	for i = 1, math.min(5, self._size) do if not first then table.insert(log,", ") end; table.insert(log,string.format("[%d]=",i)); table.insert(log,tostring(self._items[i])); first=false; end
	table.insert(log," }");-- print(table.concat(log))
	-- Check if the item at the new head is nil IMMEDIATELY after resize
	if self._size > 0 and self._items[self._head] == nil then
		warn("[Queue Resize CRITICAL] Item at new head (index 1) is nil immediately after resize!")
	end
end

-- Remove and return item from front
function Queue:Dequeue(): T? -- Returns optional T
	if self._size == 0 then return nil end
	local startTime = tick()
	self._stats.dequeues += 1

	local physicalHead = self._head -- Store physical index before incrementing
--	print("----> Queue State Before Dequeue <----")
--	print("      Size:", self._size, "Head:", self._head, "Tail:", self._tail, "Cap:", self._capacity)
	-- Log only a relevant snippet around head if table is huge
	local snippet = {}
	for i = math.max(1, self._head - 2), math.min(self._capacity, self._head + 2) do
		snippet[i] = self._items[i]
	end
--	print("      Items near head:", snippet)
	-- Or print the whole table if small enough for debugging:
	-- print("      Full _items:", self._items)
--	print("------------------------------------")
	local item = self._items[physicalHead]
	self._items[physicalHead] = nil -- Clear reference
	self._head = (self._head % self._capacity) + 1
	self._size -= 1

	-- Shrink logic
	if self._capacity > DEFAULT_INITIAL_CAPACITY and self._size < self._capacity * SHRINK_THRESHOLD then
		local newCapacity = mathMax(mathCeil(self._capacity / GROWTH_FACTOR), DEFAULT_INITIAL_CAPACITY)
		if newCapacity < self._capacity then self:_Resize(newCapacity) end -- Only resize if smaller
	end

	local processingTime = tick() - startTime
	self._stats.processingTimeTotal += processingTime
	self._stats.processingCount += 1
--	print(os.time(), string.format("[Queue] Dequeued. New Size: %d, New Head: %d, Tail: %d", self._size, self._head, self._tail))
--	print("    Dequeued Item:", item)
	return item -- Return the dequeued item
end

-- Peek at front item
function Queue:Peek(): T? -- Returns optional T
	if self._size == 0 then return nil end
	self._stats.peekCount += 1
	return self._items[self._head]
end

-- Get current size
function Queue:Size(): number return self._size end

-- Check if empty
function Queue:IsEmpty(): boolean return self._size == 0 end

-- Clear the queue
function Queue:Clear()
	if self._size > 1000 then self._items = tableCreate(self._capacity) :: {[number]: T?} -- Faster clear for large queues
	else for i = 1, self._size do self._items[self:_PhysicalIndex(i)] = nil end end -- Explicit clear for smaller
	self._size = 0; self._head = 1; self._tail = 1; self._isHomogeneous = true; self._itemType = ""
end

-- Get all items as an array
function Queue:GetItems(): {T} -- Returns array of T
	local result = tableCreate(self._size) :: {T} -- Assert type
	if self._size == 0 then return result end
	-- No need to check self._isHomogeneous here, just copy
	for i = 1, self._size do result[i] = self._items[self:_PhysicalIndex(i)] :: T end -- Assert item type
	return result
end

-- Find item by predicate
function Queue:Find(predicate: (value: T) -> boolean): number? -- Predicate takes T
	for i = 1, self._size do
		local value = self._items[self:_PhysicalIndex(i)] :: T -- Assert T
		if predicate(value) then return i end
	end
	return nil
end

-- Remove item by predicate
function Queue:Remove(predicate: (value: T) -> boolean): T? -- Predicate takes T, returns optional T
	local index = self:Find(predicate)
	if not index then return nil end
	local physicalIndex = self:_PhysicalIndex(index)
	local value = self._items[physicalIndex] -- Get value before potential modification
	if index == 1 then -- Remove from head
		self._items[physicalIndex] = nil; self._head = (self._head % self._capacity) + 1
	elseif index == self._size then -- Remove from tail
		local physicalTailBefore = (self._tail - 2 + self._capacity) % self._capacity + 1 -- Calculate correct tail index *before* modification
		self._items[physicalTailBefore] = nil
		self._tail = physicalTailBefore -- Update tail index
	else -- Remove from middle (shift elements)
		for i = index, self._size - 1 do
			local currentIdx = self:_PhysicalIndex(i)
			local nextIdx = self:_PhysicalIndex(i + 1)
			self._items[currentIdx] = self._items[nextIdx]
		end
		local physicalTailBefore = (self._tail - 2 + self._capacity) % self._capacity + 1
		self._items[physicalTailBefore] = nil -- Clear the last shifted element
		self._tail = physicalTailBefore
	end
	self._size -= 1
	return value
end

-- Batch enqueue items
function Queue:BatchEnqueue(items: {T}) -- Takes array of T
	local numItems = #items; if numItems == 0 then return end
	local requiredCapacity = self._size + numItems
	if requiredCapacity > self._capacity then
		local newCapacity = self._capacity; while newCapacity < requiredCapacity do newCapacity = mathCeil(newCapacity * GROWTH_FACTOR) end
		if newCapacity > self._capacity then self:_Resize(newCapacity) end
	end
	-- Use individual Enqueue to maintain stats and homogeneous checks correctly
	for i = 1, numItems do self:Enqueue(items[i]) end
end

-- Get statistics
function Queue:GetStats(): QueueStats
	local stats = tableClone(self._stats) :: InternalQueueStats -- Clone internal stats
	local avgTime = 0
	if stats.processingCount > 0 then avgTime = stats.processingTimeTotal / stats.processingCount end
	-- Create the public QueueStats object
	local publicStats: QueueStats = {
		enqueues = stats.enqueues, dequeues = stats.dequeues, maxSize = stats.maxSize,
		resizes = stats.resizes, peekCount = stats.peekCount, avgProcessingTime = avgTime
	}
	return publicStats
end

-- Define the type for the module table being returned
export type QueueModule = {
	new: <T>(initialCapacity: number?) -> Queue<T>, -- Export the generic constructor
	-- Export the Queue *type* itself if needed for external annotations
	-- This is tricky with generics. Exporting a base type is safer.
	Queue: Queue<any> | nil -- Placeholder for base type if needed externally
}

-- Return the module table, asserting its type
return Queue :: QueueModule