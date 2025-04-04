--!optimize 2
--!native

--[[

           +++                                                                                      
       ++++++++   ===                                                                               
    ++++++++++   ====                                                  ====                         
     ++++++                                                            ====                         
       +++++     ====     ====== =====  ==== =======      ========     ====        ====             
        +++++    ====    =============  =============    ===========   ====        ====             
         ++++    ====   ====     =====  =====    ====           ====   ====        ====             
         ++++    ====   ====     =====  =====    ====     ==========   ====    =============        
         ++++    ====   ====     =====  =====    ====   ======  ====   ====    =============        
       ++++++    ====   =====   ======  =====    ====  ====     ====   ====        ====    +++++++++
   ++++++++++    ====    =============  =====    ====   ============   ====   ++++ ==== ++++++++++++
  +++++++        ====            =====  ====     ====   + ====  ====   ==== ++++++++  ++++++++      
 +++++                  ==== +++ ==== +++++++++++++++++++++++++++++++++++++++++++++++++++++         
 ++++        +++++++++++ =========== +++++++++++++++++++++++++++++++++++++++      ++++++            
+++++++++++++++++++++++++++                                                         +               
 +++++++++++++++++++++++++                                                                          
      +++++                                                                                         

v2.6.1

An insanely fast, memory efficient, fully typed, featureful,
lightweight, open-source script signal module for Roblox.


GitHub:
https://github.com/AlexanderLindholt/SignalPlus

Devforum:
https://devforum.roblox.com/t/3552231


--------------------------------------------------------------------------------
MIT License

Copyright (c) 2025 AlexanderLindholt

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--------------------------------------------------------------------------------

]]--

-- Types.
export type Connection = {
	Disconnect: typeof(
		-- Disconnects the connection.
		-- To reconnect, make a new connection.
		function(connection: Connection) end
	),
	Connected: boolean
}
export type Signal<Parameters...> = {
	Connect: typeof(
		-- Connects the given function.
		function(signal: Signal<Parameters...>, callback: (Parameters...) -> ()): Connection end
	),
	Once: typeof(
		-- Connects the given function, but disconnects after first fire.
		function(signal: Signal<Parameters...>, callback: (Parameters...) -> ()): Connection end
	),
	Wait: typeof(
		-- Yields the current thread until the next fire.
		function(signal: Signal<Parameters...>): Parameters... end
	),

	Fire: typeof(
		-- Fires all callbacks and resumes all waiting threads.
		function(signal: Signal<Parameters...>, ...: Parameters...) end
	),

	DisconnectAll: typeof(
		-- Disconnects all connections.
		function(signal: Signal<Parameters...>) end
	),
	Destroy: typeof(
		-- Disconnects all connections, and makes the signal unusable.
		function(signal: Signal<Parameters...>) end
	),
}
type CreateSignal = typeof(
	-- Creates a new signal.
	function(): Signal end
)

-- No operation function.
local function noOperation()

end

-- Setup thread recycling.
local threads = {}
local function reusableThreadCall(callback, ...)
	callback(...)
	table.insert(threads, coroutine.running())
end
local function reusableThread(callback, ...)
	callback(...)
	table.insert(threads, coroutine.running())
	while true do
		reusableThreadCall(coroutine.yield())
	end
end

-- Connection class.
local connectionClass = table.freeze({__index = table.freeze({
	Disconnect = function(connection)
		-- Ensure it is already connected.
		if not connection.Connected then return end

		-- Remove from linked list.
		local previous = connection[2]
		local next = connection[3]
		if previous then
			previous[3] = next
		else
			connection[1][1] = next
		end
		if next then
			next[2] = previous
		end
		-- Set connected property.
		connection.Connected = false
		-- Clear values.
		connection[1] = nil
		connection[2] = nil
		connection[3] = nil
		connection[4] = nil
	end
})})

-- Signal class.
local signalClass = table.freeze({__index = table.freeze({
	Connect = function(signal, callback)
		-- Create connection.
		local connection = setmetatable({
			[1] = signal,
			[2] = nil, -- Previous.
			[3] = signal[1], -- Next.
			[4] = callback,

			Connected = true
		}, connectionClass)

		-- Add connection.
		signal[1] = connection

		-- Return connection.
		return connection
	end,
	Once = function(signal, callback)
		-- Create connection.
		local connection = nil
		connection = setmetatable({
			[1] = signal,
			[2] = nil, -- Previous.
			[3] = signal[1], -- Next.
			[4] = function(...) -- Callback.
				-- Remove from linked list.
				local previous = connection[2]
				local next = connection[3]
				if previous then
					previous[3] = next
				else
					signal[1] = next
				end
				if next then
					next[2] = previous
				end
				-- Set connected property.
				connection.Connected = false
				-- Clear values.
				connection[1] = nil
				connection[2] = nil
				connection[3] = nil
				connection[4] = nil

				-- Fire callback.
				callback(...)
			end,

			Connected = true
		}, connectionClass)

		-- Add connection.
		signal[1] = connection

		-- Return connection.
		return connection
	end,
	Wait = function(signal)
		-- Save this thread to resume later.
		local thread = coroutine.running()

		-- Create connection.
		local connection = nil
		connection = {
			[1] = signal,
			[2] = nil, -- Previous.
			[3] = signal[1], -- Next.
			[4] = function(...) -- Callback.
				-- Remove from linked list.
				local previous = connection[2]
				local next = connection[3]
				if previous then
					previous[3] = next
				else
					signal[1] = next
				end
				if next then
					next[2] = previous
				end
				-- Clear values.
				connection[1] = nil
				connection[2] = nil
				connection[3] = nil
				connection[4] = nil

				-- Resume the thread.
				task.spawn(thread, ...)
			end,
		}

		-- Add connection.
		signal[1] = connection

		-- Yield until the next fire, and return the arguments on resume.
		return coroutine.yield()
	end,

	Fire = function(signal, ...)
		-- Fire all callbacks.
		local node = signal[1]
		while node do
			-- Find or create a thread, and run the callback in it.
			local length = #threads
			if length == 0 then
				task.spawn(reusableThread, node[4], ...)
			else
				local thread = threads[length]
				threads[length] = nil -- Remove from free threads list.
				task.spawn(thread, node[4], ...)
			end

			-- Go to the next connection.
			node = node[3]
		end
	end,

	DisconnectAll = function(signal)
		local node = signal[1]
		while node do
			-- Cache next node before removing value.
			local next = node[3]

			-- Set connected property.
			if node.Connected then -- Since 'Wait' connections don't have the 'Connected' property.
				node.Connected = false
			end
			-- Remove values.
			node[1] = nil
			node[2] = nil
			node[3] = nil
			node[4] = nil

			-- Go to the next connection.
			node = next
		end
		signal[1] = nil -- Reset head value.
	end,
	Destroy = function(signal)
		-- Disconnect all.
		local node = signal[1]
		while node do
			-- Cache next node before removing value.
			local next = node[3]

			-- Set connected property.
			if node.Connected then -- Since 'Wait' connections don't have the 'Connected' property.
				node.Connected = false
			end
			-- Remove values.
			node[1] = nil
			node[2] = nil
			node[3] = nil
			node[4] = nil

			-- Go to the next connection.
			node = next
		end
		signal[1] = nil -- Reset head value.

		-- Link all methods to no-operation function.
		signal.Connect = noOperation
		signal.Once = noOperation
		signal.Wait = noOperation
		signal.Fire = noOperation
		signal.DisconnectAll = noOperation
		signal.Destroyed = noOperation
	end
})})

-- Return signal create function.
return function()
	return setmetatable({}, signalClass)
end :: CreateSignal