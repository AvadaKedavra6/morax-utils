--[[
    Morax-utils - Net
    Made with <3 by Morax :)
--]]

-- Dependencies

local Promise = MoraxUtils.Promise
local Cleaner = MoraxUtils.Cleaner

-- Variables

local ChannelPrefix = "__MoraxNet__"
local DefaultInvokeTimeout = 10
local IsServer = Server ~= nil

local DebugEnabled = false
local Log = (Console and Console.Log) or print

--

local PacketKind = {
	Fire = "F",
	Invoke = "I",
	Response = "R",
	Batch = "B",
}

local requestIdCounter = 0

---Generates a request id that is unique for the lifetime of this realm (Server or Client).
---Only needs to be locally unique: a Response packet is only ever matched against the pending
---table of the side that originated the matching Invoke, so a simple monotonic counter is
---already sufficient (no need for os.clock()/math.random()). Prefixed with "C:"/"S:" purely so
---request ids are recognizable at a glance in network debug logs (e.g. `Net.SetDebug(true)`).
---@return string
local RequestIdPrefix = IsServer and "S:" or "C:"
local function GenerateRequestId()
	requestIdCounter = requestIdCounter + 1
	return RequestIdPrefix .. requestIdCounter
end

---Returns the "n" (packed length) of a table.pack-style table, falling back to `#t` if a
---middleware returned a plain array without preserving the `n` field. Prevents
---`table.unpack(t, 1, nil)` from erroring when a user middleware forgets to keep it.
---@param t table
---@return integer
local function SafeN(t)
	return t.n or #t
end

-- Net

---@class Net
local Net = {}

Net._namespaces = {} ---@type table<string, NetNamespace> # not `private`: iterated by the module-level Tick flush loop and Player "Destroy" cleanup below

-- Connection

---A disconnect handle returned by `NetNamespace:Connect()` / `:Once()`. Exposes `:Disconnect()`
---(Sleitnick/Roblox-style ergonomics) but is also callable directly (`connection()`) to stay
---backward compatible with code written against the plain-function return value.
---@class NetConnection
---@field Connected boolean
---@field _onDisconnect fun()? # intentionally not `private`: NetNamespace:Connect() sets this from outside the Connection "class"
local Connection = {}
Connection.__index = Connection
Connection.__call = function(self)
	self:Disconnect()
end

function Connection:Disconnect()
	if self.Connected then
		self.Connected = false

		if self._onDisconnect then
			self._onDisconnect()
		end
	end
end

-- NetNamespace

---A single Namespace: one underlying nanos remote Event with framing for Fire/Invoke/Response,
---fire-and-forget dispatch, request/response Invoke support, middleware pipelines, optional
---batching and basic metrics.
---@class NetNamespace
---@field Name string
---@field private _channel string
---@field private _reliability integer
---@field private _cleaner table # A `Cleaner` instance.
---@field private _connections table<NetConnection, function>
---@field private _invokeHandler fun(...: any): any
---@field _pendingInvokes table<string, NetPendingInvoke> # not `private`: read by the module-level Player "Destroy" cleanup below
---@field private _inboundMiddleware NetMiddleware[]
---@field private _outboundMiddleware NetMiddleware[]
---@field private _invokeTimeout number
---@field private _destroyed boolean
---@field _batched boolean # not `private`: read by the module-level Tick flush loop below
---@field private _batchQueue table
---@field private _metrics table
local NetNamespace = {}
NetNamespace.__index = NetNamespace

---@class NetPendingInvoke
---@field resolve fun(...: any)
---@field reject fun(...: any)
---@field player Player? # who this Invoke was sent to/from (Server only), used for disconnect cleanup
---@field sentAt number # os.clock() timestamp, used for latency metrics

---A middleware function. Receives the sender and the packed arguments table
---(`{n = N, [1] = ..., [2] = ..., ...}`) and must return either a (possibly transformed) args
---table to let the message continue, or `nil`/`false` (optionally with a reason string as the
---second return value: `return false, "INVALID_PACKET"`) to drop it.
---
---The first parameter is `Player` for inbound packets (who sent it) on the Server and for
---outbound `:Fire()`/`:Invoke()` on the Server (who it's being sent to). It is `nil` on the
---Client (there's only one possible remote: the Server), and also `nil` for `:FireInRadius()`
---even on the Server, since there the middleware doesn't see individual recipients - nanos
---resolves the radius filtering itself.
---
---If you transform the args table, try to preserve the `n` field (packed length) - Net will fall
---back to `#t` if you don't, but that fallback breaks on trailing `nil` arguments.
---@alias NetMiddleware fun(player: Player?, args: table): (table|false|nil), string?

---Options accepted by `Net.Namespace()`.
---@class NetNamespaceOptions
---@field Reliability integer? # `Reliability.Reliable` (default) or `Reliability.Unreliable`.
---@field InvokeTimeout number? # Seconds before a pending `:Invoke()` rejects. Defaults to 10.
---@field Batched boolean? # If true, `:Fire()`/`:FireAll()` (single Player or "All" targets only)
---are queued and flushed once per Tick instead of sent immediately. Reduces overhead for many
---small/frequent messages. `:Invoke()` and array/radius targets are never batched (they stay
---immediate on purpose). Defaults to false.

-- Internal Helpers

---Runs a chain of middleware over a packed args table. Stops and returns `false` (plus whatever
---reason that middleware gave, if any) as soon as one middleware rejects the message.
---@param middlewareList NetMiddleware[]
---@param player Player?
---@param args table
---@return table|false, string? reason
local function RunMiddleware(middlewareList, player, args)
	local current = args

	for _, middleware in ipairs(middlewareList) do
		local result, reason = middleware(player, current)

		if result == false or result == nil then
			return false, reason
		end

		current = result
	end

	return current
end

-- Construction

---@private
---@param name string
---@param options NetNamespaceOptions?
---@return NetNamespace
function NetNamespace._new(name, options)
	options = options or {}

	local self = setmetatable({}, NetNamespace)

	self.Name = name
	self._channel = ChannelPrefix .. name
	self._reliability = options.Reliability or Reliability.Reliable
	self._invokeTimeout = options.InvokeTimeout or DefaultInvokeTimeout
	self._cleaner = Cleaner.new()
	self._connections = {}
	self._invokeHandler = nil
	self._pendingInvokes = {}
	self._inboundMiddleware = {}
	self._outboundMiddleware = {}
	self._destroyed = false
	self._batched = options.Batched or false
	self._batchQueue = {}

	self._metrics = {
		fireSent = 0,
		fireReceived = 0,
		batchesSent = 0,
		invokeSent = 0,
		invokeReceived = 0,
		invokeTimeouts = 0,
		invokeErrors = 0,
		invokeCompleted = 0,
		avgLatencyMs = 0,
	}

	self:_Listen()

	return self
end

-- Wire I/O (side)

---@private
function NetNamespace:_Listen()
	if IsServer then
		self._cleaner:ConnectRemoteEvent(self._channel, function(player, kind, requestId, ...)
			self:_OnPacket(player, kind, requestId, ...)
		end)
	else
		self._cleaner:ConnectRemoteEvent(self._channel, function(kind, requestId, ...)
			self:_OnPacket(nil, kind, requestId, ...)
		end)
	end
end

---Sends a raw packet to the remote side. On the Client this always targets the Server, on the
---Server, `target` selects the destination.
---@private
---@param target Player|table<integer, Player>|"All"|nil
---@param ... any packet fields: kind, requestId, ...args
function NetNamespace:_Send(target, ...)
	if not IsServer then
		Events.CallRemote(self._channel, self._reliability, ...)
		return
	end

	if target == "All" then
		Events.BroadcastRemote(self._channel, self._reliability, ...)
	elseif type(target) == "table" then
		Events.CallRemotePlayers(self._channel, target, self._reliability, ...)
	else
		assert(target ~= nil, "NetNamespace:_Send requires a target Player on the Server")

		---@cast target Player
		Events.CallRemote(self._channel, target, self._reliability, ...)
	end
end

-- Packet Dispatch

---@private
---@param player Player? # nil on the Client
---@param kind string
---@param requestId string
function NetNamespace:_OnPacket(player, kind, requestId, ...)
	if type(kind) ~= "string" then
		if DebugEnabled then
			Log(string.format("[Net:%s] Dropped packet with invalid kind: %s", self.Name, tostring(kind)))
		end

		return
	end

	if type(requestId) ~= "string" then
		if DebugEnabled then
			Log(string.format("[Net:%s] Dropped packet with invalid requestId: %s", self.Name, tostring(requestId)))
		end

		return
	end

	if kind ~= PacketKind.Fire
		and kind ~= PacketKind.Invoke
		and kind ~= PacketKind.Response
		and kind ~= PacketKind.Batch
	then
		if DebugEnabled then
			Log(string.format("[Net:%s] Dropped packet with unknown kind: %s", self.Name, tostring(kind)))
		end

		return
	end

	if kind == PacketKind.Fire then
		self:_DispatchFire(player, ...)
	elseif kind == PacketKind.Invoke then
		self:_DispatchInvoke(player, requestId, ...)
	elseif kind == PacketKind.Response then
		self:_DispatchResponse(requestId, ...)
	elseif kind == PacketKind.Batch then
		local items = ...
		self:_DispatchBatch(player, items)
	end
end

---@private
function NetNamespace:_DispatchFire(player, ...)
	local args = table.pack(...)

	if #self._inboundMiddleware > 0 then
		local filtered, reason = RunMiddleware(self._inboundMiddleware, player, args)

		if filtered == false then
			if DebugEnabled then
				Log(string.format(
					"[Net:%s] Fire < %s BLOCKED by inbound middleware (%s)",
					self.Name,
					tostring(player),
					reason or "no reason given"
				))
			end

			return
		end

		args = filtered
	end

	self._metrics.fireReceived = self._metrics.fireReceived + 1

	if DebugEnabled then
		Log(string.format("[Net:%s] Fire < %s", self.Name, tostring(player)))
	end

	for connection, callback in pairs(self._connections) do
		if connection.Connected then
			if IsServer then
				callback(player, table.unpack(args, 1, SafeN(args)))
			else
				callback(table.unpack(args, 1, SafeN(args)))
			end
		end
	end
end

---@private
---Unpacks a batched payload (array of packed-args tables) and dispatches each item as if it had
---arrived as its own individual Fire packet.
function NetNamespace:_DispatchBatch(player, items)
	if type(items) ~= "table" then
		return
	end

	for _, args in ipairs(items) do
		self:_DispatchFire(player, table.unpack(args, 1, SafeN(args)))
	end
end

---@private
function NetNamespace:_DispatchInvoke(player, requestId, ...)
	local args = table.pack(...)

	if #self._inboundMiddleware > 0 then
		local filtered, reason = RunMiddleware(self._inboundMiddleware, player, args)

		if filtered == false then
			self:_SendResponse(player, requestId, false, reason or "BLOCKED_BY_INBOUND_MIDDLEWARE")
			return
		end

		args = filtered
	end

	self._metrics.invokeReceived = self._metrics.invokeReceived + 1

	if DebugEnabled then
		Log(string.format(
			"[Net:%s] Invoke < %s (id=%s)",
			self.Name,
			tostring(player),
			requestId
		))
	end

	if not self._invokeHandler then
		self:_SendResponse(player, requestId, false, "NO_INVOKE_HANDLER")
		return
	end

	local handlerPromise

	if IsServer then
		handlerPromise = Promise.try(
			self._invokeHandler,
			player,
			table.unpack(args, 1, SafeN(args))
		)
	else
		handlerPromise = Promise.try(
			self._invokeHandler,
			table.unpack(args, 1, SafeN(args))
		)
	end

	handlerPromise
		:andThen(function(...)
			self:_SendResponse(player, requestId, true, ...)
		end)
		:catch(function(err)
			self:_SendResponse(player, requestId, false, tostring(err))
		end)
end

---@private
function NetNamespace:_SendResponse(player, requestId, success, ...)
	if IsServer then
		self:_Send(player, PacketKind.Response, requestId, success, ...)
	else
		self:_Send(nil, PacketKind.Response, requestId, success, ...)
	end
end

---@private
function NetNamespace:_DispatchResponse(requestId, success, ...)
	local pending = self._pendingInvokes[requestId]

	if not pending then
		return
	end

	self._pendingInvokes[requestId] = nil

	local latencyMs = (os.clock() - pending.sentAt) * 1000
	local completed = self._metrics.invokeCompleted

	self._metrics.avgLatencyMs =
		((self._metrics.avgLatencyMs * completed) + latencyMs) / (completed + 1)

	self._metrics.invokeCompleted = completed + 1

	if DebugEnabled then
		Log(string.format(
			"[Net:%s] Response (id=%s, success=%s, %.1fms)",
			self.Name,
			requestId,
			tostring(success),
			latencyMs
		))
	end

	if success then
		pending.resolve(...)
	else
		pending.reject(...)
	end
end

-- Batchingg

---@private
function NetNamespace:_QueueBatched(target, args)
	local key = target or "__nil__"
	local bucket = self._batchQueue[key]

	if not bucket then
		bucket = {
			target = target,
			items = {},
		}

		self._batchQueue[key] = bucket
	end

	table.insert(bucket.items, args)
end

function NetNamespace:_FlushBatch()
	if next(self._batchQueue) == nil then
		return
	end

	local queue = self._batchQueue
	self._batchQueue = {}

	for _, bucket in pairs(queue) do
		self._metrics.batchesSent = self._metrics.batchesSent + 1
		self:_Send(bucket.target, PacketKind.Batch, "", bucket.items)
	end
end

local TickSource = IsServer and Server or Client

TickSource.Subscribe("Tick", function()
	for _, namespace in pairs(Net._namespaces) do
		if namespace._batched then
			namespace:_FlushBatch()
		end
	end
end)

-- Public API :: Fire

---Sends a fire and forget message.
---
---On the **Client**, sends to the Server: `namespace:Fire(...)`
---On the **Server**, sends to a single Player: `namespace:Fire(player, ...)`
---@param ... any On Server: `player: Player, ...args: any`. On Client: `...args: any`.
function NetNamespace:Fire(...)
	assert(not self._destroyed, "Cannot Fire on a destroyed NetNamespace")

	if IsServer then
		local player = ...

		assert(
			player ~= nil,
			"NetNamespace:Fire(player, ...) requires a Player on the Server"
		)

		local args = table.pack(select(2, ...))
		self:_SendFiltered(player, args)
	else
		local args = table.pack(...)
		self:_SendFiltered(nil, args)
	end
end

---@private
function NetNamespace:_SendFiltered(target, args)
	if #self._outboundMiddleware > 0 then
		local filtered, reason = RunMiddleware(self._outboundMiddleware, target, args)

		if filtered == false then
			if DebugEnabled then
				Log(string.format(
					"[Net:%s] Fire > %s BLOCKED by outbound middleware (%s)",
					self.Name,
					tostring(target),
					reason or "no reason given"
				))
			end

			return
		end

		args = filtered
	end

	self._metrics.fireSent = self._metrics.fireSent + 1

	if DebugEnabled then
		Log(string.format("[Net:%s] Fire > %s", self.Name, tostring(target)))
	end

	if self._batched and type(target) ~= "table" then
		self:_QueueBatched(target, args)
		return
	end

	self:_Send(
		target,
		PacketKind.Fire,
		"",
		table.unpack(args, 1, SafeN(args))
	)
end

---**Server only.** Broadcasts a fire and forget message to every currently connected Player.
---@param ... any
function NetNamespace:FireAll(...)
	assert(not self._destroyed, "Cannot FireAll on a destroyed NetNamespace")
	assert(IsServer, "NetNamespace:FireAll() is Server-only")

	local args = table.pack(...)
	self:_SendFiltered("All", args)
end

---**Server only.** Broadcasts a fire and forget message to every Player except the given one(s).
---@param ignored Player|Player[] a single Player, or an array of Players to exclude
---@param ... any
function NetNamespace:FireAllExcept(ignored, ...)
	assert(not self._destroyed, "Cannot FireAllExcept on a destroyed NetNamespace")
	assert(IsServer, "NetNamespace:FireAllExcept() is Server-only")
	assert(ignored ~= nil, "NetNamespace:FireAllExcept() expects a Player or Player[]")

	local ignoredSet = {}
	if type(ignored) == "table" then
		for _, player in ipairs(ignored) do
			ignoredSet[player] = true
		end
	else
		ignoredSet[ignored] = true
	end

	local targets = {}
	for _, player in ipairs(Player.GetAll()) do
		if not ignoredSet[player] then
			table.insert(targets, player)
		end
	end

	if #targets == 0 then
		return
	end

	local args = table.pack(...)
	self:_SendFiltered(targets, args)
end

---**Server only.** Sends a fire and forget message to a specific list of Players.
---More network-efficient than looping `:Fire()`.
---@param players Player[]
---@param ... any
function NetNamespace:FirePlayers(players, ...)
	assert(not self._destroyed, "Cannot FirePlayers on a destroyed NetNamespace")
	assert(IsServer, "NetNamespace:FirePlayers() is Server-only")

    if type(players) ~= "table" or #players == 0 then
	    return
    end

	local args = table.pack(...)
	self:_SendFiltered(players, args)
end

---**Server only.** Broadcasts a fire and forget message to all Players within `radius` units of
---`location`. Always sent immediately (never batched).
---@param location Vector
---@param radius number
---@param ... any
function NetNamespace:FireInRadius(location, radius, ...)
	assert(not self._destroyed, "Cannot FireInRadius on a destroyed NetNamespace")
	assert(IsServer, "NetNamespace:FireInRadius() is Server-only")

	local args = table.pack(...)

	if #self._outboundMiddleware > 0 then
		-- player is always nil here: nanos resolves the radius targeting itself, so middleware
		-- never sees individual recipients for this call.
		local filtered, reason = RunMiddleware(self._outboundMiddleware, nil, args)

		if filtered == false then
			if DebugEnabled then
				Log(string.format(
					"[Net:%s] FireInRadius BLOCKED by outbound middleware (%s)",
					self.Name,
					reason or "no reason given"
				))
			end

			return
		end

		args = filtered
	end

	self._metrics.fireSent = self._metrics.fireSent + 1

	Events.BroadcastRemoteInRadius(
		self._channel,
		location,
		radius,
		self._reliability,
		PacketKind.Fire,
		"",
		table.unpack(args, 1, SafeN(args))
	)
end

-- Public API :: Connect

---Registers a listener for fire and forget messages sent through `:Fire()` / `:FireAll()` / etc.
---
---On the **Server**, `callback` is invoked as `callback(player, ...args)`.
---On the **Client**, `callback` is invoked as `callback(...args)`.
---@param callback function
---@param cleaner table? optional external Cleaner to auto-disconnect this listener with
---@return NetConnection connection call `:Disconnect()` on it, or call it directly, to stop listening
function NetNamespace:Connect(callback, cleaner)
	assert(not self._destroyed, "Cannot Connect on a destroyed NetNamespace")
	assert(type(callback) == "function", "NetNamespace:Connect expects a function")

	local connection = setmetatable({
		Connected = true,
	}, Connection)

	connection._onDisconnect = function()
		self._connections[connection] = nil
	end

	self._connections[connection] = callback
	self._cleaner:Add(connection)

	if cleaner then
		cleaner:Add(connection)
	end

	return connection
end

---Like `:Connect()`, but automatically disconnects itself after the first message received.
---@param callback function
---@param cleaner table?
---@return NetConnection connection
function NetNamespace:Once(callback, cleaner)
	local connection

	connection = self:Connect(function(...)
		connection:Disconnect()
		callback(...)
	end, cleaner)

	return connection
end

-- Public API :: Invoke

---@private
---@param timeoutOverride number? seconds, overrides this namespace's default InvokeTimeout for this call only
function NetNamespace:_DoInvoke(timeoutOverride, ...)
	assert(not self._destroyed, "Cannot Invoke on a destroyed NetNamespace")

	local player, args

	if IsServer then
		player = ...

		assert(
			player ~= nil,
			"NetNamespace:Invoke(player, ...) requires a Player on the Server"
		)

		args = table.pack(select(2, ...))
	else
		args = table.pack(...)
	end

	if #self._outboundMiddleware > 0 then
		local filtered, reason = RunMiddleware(
			self._outboundMiddleware,
			player,
			args
		)

		if filtered == false then
			return Promise.reject(
				reason or "BLOCKED_BY_OUTBOUND_MIDDLEWARE"
			)
		end

		args = filtered
	end

	local requestId = GenerateRequestId()
	local sentAt = os.clock()

	self._metrics.invokeSent = self._metrics.invokeSent + 1

	if DebugEnabled then
		Log(string.format(
			"[Net:%s] Invoke > %s (id=%s)",
			self.Name,
			tostring(player),
			requestId
		))
	end

	local promise = Promise.new(function(resolve, reject, onCancel)
		self._pendingInvokes[requestId] = {
			resolve = resolve,
			reject = reject,
			player = player,
			sentAt = sentAt,
		}

		onCancel(function()
			self._pendingInvokes[requestId] = nil
		end)

		local ok, err = pcall(function()
			self:_Send(
				player,
				PacketKind.Invoke,
				requestId,
				table.unpack(args, 1, SafeN(args))
			)
		end)

		if not ok then
			self._pendingInvokes[requestId] = nil
			reject(err)
		end
	end)

	promise = promise:timeout(
		timeoutOverride or self._invokeTimeout,
		"NET_INVOKE_TIMEOUT"
	)

	promise:catch(function(err)
		if err == "NET_INVOKE_TIMEOUT" then
			self._metrics.invokeTimeouts = self._metrics.invokeTimeouts + 1
		else
			self._metrics.invokeErrors = self._metrics.invokeErrors + 1
		end
	end)

	return promise
end

---Sends a request to the remote side and returns a Promise that resolves with whatever the
---remote's invoke handler (registered via `:SetInvokeHandler()`) returns or rejects on timeout
---or on error thrown by the handler.
---
---On the **Client**, invokes the Server: `namespace:Invoke(...)`
---On the **Server**, invokes a single Player: `namespace:Invoke(player, ...)`
---@param ... any On Server: `player: Player, ...args: any`. On Client: `...args: any`.
---@return PromiseObject<unknown>
function NetNamespace:Invoke(...)
	return self:_DoInvoke(nil, ...)
end

---Same as `:Invoke()`, but overrides this namespace's default `InvokeTimeout` for this single
---call. Useful when some calls must fail fast (e.g. an anti-cheat check) while others can be
---more tolerant (e.g. loading an inventory).
---
---On the **Client**: `namespace:InvokeWithTimeout(timeoutSeconds, ...args)`
---On the **Server**: `namespace:InvokeWithTimeout(timeoutSeconds, player, ...args)`
---@param timeout number seconds
---@param ... any
---@return PromiseObject<unknown>
function NetNamespace:InvokeWithTimeout(timeout, ...)
	assert(
		type(timeout) == "number" and timeout > 0,
		"InvokeWithTimeout expects a positive number as first arg"
	)

	return self:_DoInvoke(timeout, ...)
end

---Registers the handler invoked when the remote side calls `:Invoke()` on this namespace.
---
---The handler may return plain values (packed and sent back as the resolved values of the
---caller's Promise) or a `PromiseObject`, in which case the response is deferred until that
---Promise settles. Throwing an error inside the handler rejects the caller's Promise instead.
---
---On the **Server**, `handler` is called as `handler(player, ...args)`.
---On the **Client**, `handler` is called as `handler(...args)`.
---@param handler fun(...: any): any
function NetNamespace:SetInvokeHandler(handler)
	assert(
		type(handler) == "function",
		"NetNamespace:SetInvokeHandler expects a function"
	)

	if self._invokeHandler and DebugEnabled then
		Log(string.format(
			"[Net:%s] SetInvokeHandler called twice, overwriting the previous handler",
			self.Name
		))
	end

	self._invokeHandler = handler
end

-- Public API :: Middleware

---Sets the middleware pipeline applied to every packet received on this namespace (both `:Fire`
---messages and `:Invoke` requests) in order. Replaces any previously set inbound middleware.
---@param middlewareList NetMiddleware[]
function NetNamespace:SetInboundMiddleware(middlewareList)
	self._inboundMiddleware = middlewareList or {}
end

---Sets the middleware pipeline applied to every packet sent from this namespace (both `:Fire` and
---`:Invoke`) in order. Replaces any previously set outbound middleware.
---@param middlewareList NetMiddleware[]
function NetNamespace:SetOutboundMiddleware(middlewareList)
	self._outboundMiddleware = middlewareList or {}
end

-- Public API :: Metrics / Debug

---Returns a shallow copy of this namespace's counters: fireSent/fireReceived, batchesSent,
---invokeSent/invokeReceived/invokeCompleted/invokeTimeouts/invokeErrors and avgLatencyMs
---(rolling average over completed Invokes).
---@return table
function NetNamespace:GetMetrics()
	local copy = {}

	for k, v in pairs(self._metrics) do
		copy[k] = v
	end

	return copy
end

-- Public API :: Lifecycle

---Tears down this namespace: unsubscribes from the underlying Event, rejects every pending
---`:Invoke()` call, clears all listeners and removes it from the namespace cache so a future
---`Net.Namespace()` call with the same name creates a fresh instance.
function NetNamespace:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true

	local pending = self._pendingInvokes
	self._pendingInvokes = {}

	for _, request in pairs(pending) do
		request.reject("NET_NAMESPACE_DESTROYED")
	end

	self._batchQueue = {}
	self._cleaner:Destroy()
	self._connections = {}

	Net._namespaces[self.Name] = nil
end

-- Net :: Public API

---Gets or creates the `NetNamespace` for the given identifier. Namespaces are deduplicated by
---name: calling this twice from anywhere in your codebase (as long as they share the same
---MoraxUtils instance) returns the same instance and underlying Event.
---@param name string unique identifier for this communication channel
---@param options NetNamespaceOptions?
---@return NetNamespace
function Net.Namespace(name, options)
	assert(
		type(name) == "string" and #name > 0,
		"Net.Namespace expects a non-empty string name"
	)

	local existing = Net._namespaces[name]

	if existing then
		return existing
	end

	local namespace = NetNamespace._new(name, options)
	Net._namespaces[name] = namespace

	return namespace
end

---Destroys every namespace ever created through `Net.Namespace()`. Mainly useful for cleaning up
---in a package's `Unload` event.
function Net.DestroyAll()
	local namespaces = {}

	for _, namespace in pairs(Net._namespaces) do
		table.insert(namespaces, namespace)
	end

	for _, namespace in ipairs(namespaces) do
		namespace:Destroy()
	end
end

---Enables/disables verbose logging (Fire/Invoke/Response/Batch events, latency, handler
---overwrites) across every namespace. Meant for development, not for production servers.
---@param enabled boolean
function Net.SetDebug(enabled)
	DebugEnabled = enabled and true or false
end

---Returns `NetNamespace:GetMetrics()` for every namespace, keyed by namespace name. Handy to dump
---in a debug command/log to spot which namespace is spamming or timing out the most.
---@return table<string, table>
function Net.GetAllMetrics()
	local all = {}

	for name, namespace in pairs(Net._namespaces) do
		all[name] = namespace:GetMetrics()
	end

	return all
end

-- Player Disconnect Cleanup

if IsServer then
	Player.Subscribe("Destroy", function(player)
		for _, namespace in pairs(Net._namespaces) do
			local toReject = {}

			for requestId, pending in pairs(namespace._pendingInvokes) do
				if pending.player == player then
					table.insert(toReject, requestId)
				end
			end

			for _, requestId in ipairs(toReject) do
				local pending = namespace._pendingInvokes[requestId]

				if pending then
					namespace._pendingInvokes[requestId] = nil
					pending.reject("PLAYER_DISCONNECTED")
				end
			end
		end
	end)
end

-- My Registration

MoraxUtils = MoraxUtils or {}
MoraxUtils.Net = Net

return Net