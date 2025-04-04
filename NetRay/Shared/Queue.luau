--!strict
--!optimize 2
--!native

--[[    
    Queue.lua
    Implementation of a priority queue system for network operations
    Optimized version with memory efficiency and performance improvements
    Author: Asta (@TheYusufGamer)
]]

-- Type definitions for Luau
export type QueueItem = { value: any }
export type QueueStats = {
	enqueues: number,
	dequeues: number,
	maxSize: number,
	resizes: number,
	peekCount: number,
	avgProcessingTime: number
}

-- Queue class definition
local Queue = {}
Queue.__index = Queue

-- Explicitly type the Queue object
export type Queue = typeof(setmetatable({
	_items = {} :: {[number]: any},
	_size = 0,
	_head = 0,
	_tail = 0,
	_capacity = 0,
	_stats = {
		enqueues = 0,
		dequeues = 0,
		maxSize = 0,
		resizes = 0,
		peekCount = 0,
		processingTimeTotal = 0,
		processingCount = 0
	},
	_isHomogeneous = false,
	_itemType = ""
}, Queue))

-- Constants
local DEFAULT_INITIAL_CAPACITY = 16
local GROWTH_FACTOR = 1.5
local SHRINK_THRESHOLD = 0.25

-- Local utility functions to reduce table lookups
local tableCreate = table.create
local mathCeil = math.ceil
local mathFloor = math.floor

function Queue.new(initialCapacity: number?): Queue
	local self = setmetatable({}, Queue)
	initialCapacity = initialCapacity or DEFAULT_INITIAL_CAPACITY
	self._items = tableCreate(initialCapacity)
	self._size = 0
	self._head = 1
	self._tail = 1
	self._capacity = initialCapacity
	self._isHomogeneous = true
	self._itemType = ""
	self._stats = { -- reset stats
		enqueues = 0, dequeues = 0, maxSize = 0, resizes = 0, peekCount = 0,
		processingTimeTotal = 0, processingCount = 0
	}
	return self
end

--[[    
    Add an item to the queue
    @param item: The item to add to the queue
   ]]
function Queue:Enqueue(item: any): () -- No priority param
	-- Track statistics
	self._stats.enqueues += 1

	-- Ensure we have enough capacity
	if self._size >= self._capacity then
		self:_Resize(mathCeil(self._capacity * GROWTH_FACTOR))
	end

	-- Track homogeneous status
	if self._size == 0 and item ~= nil then
		self._itemType = typeof(item)
	elseif self._isHomogeneous and item ~= nil and typeof(item) ~= self._itemType then
		self._isHomogeneous = false
	end

	-- Standard FIFO enqueue using circular buffer logic
	self._items[self._tail] = item
	self._tail = (self._tail % self._capacity) + 1 -- Modulo + 1 for Lua 1-based index
	self._size += 1

	-- Update max size statistic
	if self._size > self._stats.maxSize then
		self._stats.maxSize = self._size
	end
end

--[[    
    Convert a logical index (1 to size) to the physical array index
    @param logicalIndex: The logical index (1-based)
    @return: The physical index in the internal array
]]
function Queue:_PhysicalIndex(logicalIndex: number): number
	if logicalIndex < 1 or logicalIndex > self._size then
		error("Logical index out of bounds")
	end

	local physicalIndex = (self._head + logicalIndex - 2) % self._capacity + 1
	return physicalIndex
end

--[[    
    Resize the internal array to a new capacity
    @param newCapacity: New capacity for the array
]]
function Queue:_Resize(newCapacity: number): ()
	if newCapacity <= self._size then
		error("New capacity must be larger than current size")
	end

	-- Track statistics
	self._stats.resizes += 1

	local newItems = tableCreate(newCapacity)

	-- Copy items in order - use a fast path for contiguous items
	if self._head <= self._tail then
		-- Items are in one contiguous segment
		for i = self._head, self._tail - 1 do
			newItems[i - self._head + 1] = self._items[i]
		end
	else
		-- Items are in two segments (wrap around)
		local newIndex = 1

		-- Copy first segment (head to end)
		for i = self._head, self._capacity do
			newItems[newIndex] = self._items[i]
			newIndex += 1
		end

		-- Copy second segment (start to tail-1)
		for i = 1, self._tail - 1 do
			newItems[newIndex] = self._items[i]
			newIndex += 1
		end
	end

	-- Update internal state
	self._items = newItems
	self._head = 1
	self._tail = self._size + 1
	self._capacity = newCapacity
end

--[[    
    Remove and return the next item from the queue
    @return: The next item, or nil if queue is empty
]]
function Queue:Dequeue(): any?
	if self._size == 0 then
		return nil
	end

	-- Start time tracking for processing
	local startTime = tick()

	-- Track statistics
	self._stats.dequeues += 1

	local item = self._items[self._head]
	self._items[self._head] = nil  -- Clear reference to help with GC
	self._head = (self._head % self._capacity) + 1
	self._size -= 1

	-- Consider shrinking if the queue is using less than 25% of its capacity
	-- and capacity is larger than the default initial capacity
	if self._capacity > DEFAULT_INITIAL_CAPACITY and 
		self._size < self._capacity * SHRINK_THRESHOLD then
		local newCapacity = mathCeil(self._capacity / GROWTH_FACTOR)
		-- Ensure we don't go below default capacity
		newCapacity = math.max(newCapacity, DEFAULT_INITIAL_CAPACITY)

		if newCapacity >= self._size and newCapacity < self._capacity then
			self:_Resize(newCapacity)
		end
	end

	-- Priority handling removed, return item directly
	local result = item

	-- Update processing time statistics
	local processingTime = tick() - startTime
	self._stats.processingTimeTotal += processingTime
	self._stats.processingCount += 1

	return result
end

--[[    
    Peek at the next item without removing it
    @return: The next item, or nil if queue is empty
]]
function Queue:Peek(): any?
	if self._size == 0 then
		return nil
	end

	-- Track statistics
	self._stats.peekCount += 1

	local item = self._items[self._head]

	-- Priority handling removed, return item directly

	return item
end

--[[    
    Get the current size of the queue
    @return: Number of items in the queue
]]
function Queue:Size(): number
	return self._size
end

--[[    
    Check if the queue is empty
    @return: true if empty, false otherwise
]]
function Queue:IsEmpty(): boolean
	return self._size == 0
end

--[[    
    Clear all items from the queue
]]
function Queue:Clear(): ()
	-- Fast clear for large queues 
	if self._size > 1000 then
		-- Create a new storage array with the original capacity
		self._items = tableCreate(self._capacity)
	else
		-- For smaller queues, explicitly clear each item to help GC
		for i = 1, self._size do
			local physicalIndex = self:_PhysicalIndex(i)
			self._items[physicalIndex] = nil
		end
	end

	self._size = 0
	self._head = 1
	self._tail = 1

	-- Reset homogeneous tracking
	self._isHomogeneous = true
	self._itemType = ""
end

--[[    
    Get all items as an array
    @return: Array of all items in the queue (in queue order)
]]
function Queue:GetItems(): {any}
	-- Optimize array creation for better performance
	local result = tableCreate(self._size)

	-- Fast path for empty queue
	if self._size == 0 then
		return result
	end

	-- Fast path for homogeneous value types (avoids repeated type checks)
	if self._isHomogeneous then
		-- Simple copy without type checking for each item
		for i = 1, self._size do
			local physicalIndex = self:_PhysicalIndex(i)
			result[i] = self._items[physicalIndex]
		end

	else
		-- Mixed types, standard copy
		for i = 1, self._size do
			result[i] = self._items[self:_PhysicalIndex(i)]
		end
	end

	return result
end

--[[    
    Find an item in the queue
    @param predicate: Function that returns true for the item to find
    @return: The index of the item, or nil if not found
]]
function Queue:Find(predicate: (value: any) -> boolean): number?
	for i = 1, self._size do
		local value = self._items[self:_PhysicalIndex(i)] -- Directly get the value
		if predicate(value) then
			return i
		end
	end
	return nil
end

--[[    
    Remove a specific item from the queue
    @param predicate: Function that returns true for the item to remove
    @return: The removed item, or nil if not found
]]
function Queue:Remove(predicate: (value: any) -> boolean): any?
	local index = self:Find(predicate)
	if not index then
		return nil
	end

	-- Get the item value directly
	local physicalIndex = self:_PhysicalIndex(index)
	local value = self._items[physicalIndex] -- The actual item

	-- Optimized removal logic (remains the same logic as before, just accesses value directly)
	if index == 1 then
		self._items[physicalIndex] = nil
		self._head = (self._head % self._capacity) + 1
	elseif index == self._size then
		self._items[physicalIndex] = nil
		self._tail = physicalIndex
	else
		for i = index, self._size - 1 do
			local currentIdx = self:_PhysicalIndex(i)
			local nextIdx = self:_PhysicalIndex(i + 1)
			self._items[currentIdx] = self._items[nextIdx]
		end
		local lastIdx = self:_PhysicalIndex(self._size)
		self._items[lastIdx] = nil
		self._tail = (self._tail - 1)
		if self._tail == 0 then self._tail = self._capacity end
	end

	self._size -= 1

	return value -- Return the removed item's value
end

--[[    
    Batch enqueue multiple items at once
    @param items: Array of items to enqueue
   ]]
function Queue:BatchEnqueue(items: {any}): ()
	if #items == 0 then return end

	-- Ensure we have enough capacity for all items
	local requiredCapacity = self._size + #items
	if requiredCapacity > self._capacity then
		-- Calculate ideal new capacity that's at least big enough
		local newCapacity = self._capacity
		while newCapacity < requiredCapacity do
			newCapacity = mathCeil(newCapacity * GROWTH_FACTOR)
		end
		-- Resize if the calculated capacity is larger than the current one
		if newCapacity > self._capacity then
			self:_Resize(newCapacity)
		end
	end

	-- Add all items sequentially (standard enqueue)
	for i = 1, #items do
		self:Enqueue(items[i]) -- Use simplified Enqueue
	end
end

--[[    
    Get statistics about queue operations
    @return: Table with operation statistics
]]
function Queue:GetStats(): QueueStats
	local stats = table.clone(self._stats)

	-- Calculate average processing time
	if stats.processingCount > 0 then
		stats.avgProcessingTime = stats.processingTimeTotal / stats.processingCount
	else
		stats.avgProcessingTime = 0
	end

	-- Remove internal tracking fields
	stats.processingTimeTotal = nil
	stats.processingCount = nil

	return stats
end

return Queue