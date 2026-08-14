--[[
    Morax-utils - Component
    Made with <3 by Morax :)
]]

-- Dependencies

local Promise = MoraxUtils.Promise
local Cleaner = MoraxUtils.Cleaner

-- Table utils

local function TableFind(t, value)
	for i = 1, #t do
		if t[i] == value then
			return i
		end
	end

	return nil
end

local function TableClear(t)
	for key in pairs(t) do
		t[key] = nil
	end
end

-- Signal

---@class _Signal
---@field private _connections table
---@field private _firingDepth integer
---@field private _pendingCleanup boolean
local _Signal = {}
_Signal.__index = _Signal

function _Signal.new()
	return setmetatable({
		_connections = {},
		_firingDepth = 0,
		_pendingCleanup = false,
	}, _Signal)
end

function _Signal:_compact()
	local compacted = {}

	for _, connection in ipairs(self._connections) do
		if connection.connected then
			table.insert(compacted, connection)
		end
	end

	self._connections = compacted
	self._pendingCleanup = false
end

---Subscribes fn to this signal. Returns a disconnect function.
---@param fn fun(...)
---@return fun() disconnect
function _Signal:Connect(fn)
	assert(type(fn) == "function", "Signal:Connect() expects a function")

	local connections = self._connections
	local connection = { fn = fn, connected = true }
	table.insert(connections, connection)

	return function()
		if not connection.connected then
			return
		end
		connection.connected = false

		if self._firingDepth > 0 then
			self._pendingCleanup = true
			return
		end

		local index = TableFind(connections, connection)
		if index then
			local n = #connections
			connections[index] = connections[n]
			connections[n] = nil
		end
	end
end

---Subscribes fn for a single firing. Auto-disconnects before fn runs.
---@param fn fun(...)
---@return fun() disconnect
function _Signal:Once(fn)
	local disconnect
	disconnect = self:Connect(function(...)
		disconnect()
		fn(...)
	end)
	return disconnect
end

---Returns a Promise that resolves with the arguments of the next firing.
---@return table Promise
function _Signal:Wait()
	local disconnect
	return Promise.fromEvent(
		function(callback)
			disconnect = self:Once(callback)
		end,

		function()
			if disconnect then
				disconnect()
			end
		end
	)
end

function _Signal:Fire(...)
	self._firingDepth = self._firingDepth + 1
	local connections = self._connections
	local count = #connections

	for i = 1, count do
		local connection = connections[i]
		if connection and connection.connected then
			connection.fn(...)
		end
	end

	self._firingDepth = self._firingDepth - 1
	if self._firingDepth == 0 and self._pendingCleanup then
		self:_compact()
	end
end

function _Signal:Destroy()
	TableClear(self._connections)
	self._pendingCleanup = false
end

-- Types

---@alias ExtensionFn fun(component: any)
---@alias ExtensionShouldFn fun(component: any): boolean

---@class Extension
---@field ShouldExtend ExtensionShouldFn?
---@field ShouldConstruct ExtensionShouldFn?
---@field Constructing ExtensionFn?
---@field Constructed ExtensionFn?
---@field Starting ExtensionFn?
---@field Started ExtensionFn?
---@field Stopping ExtensionFn?
---@field Stopped ExtensionFn?

---@alias Realm "Server" | "Client" | "Shared"

---@class ComponentConfig
---@field Classes table
---@field Tag string?
---@field Extensions Extension[]?
---@field Realm Realm?
---@field TickInterval integer?
---@field NetworkProperties string[]?
---@field Debug boolean?
---@field Timeout number?

---@class ComponentClass
---@field FromInstance fun(self: ComponentClass, instance: any): Component?
---@field WaitForInstance fun(self: ComponentClass, instance: any, timeout: number?): table
---@field GetAll fun(self: ComponentClass): Component[]
---@field Count fun(self: ComponentClass): integer
---@field GetTag fun(self: ComponentClass): string?
---@field GetClasses fun(self: ComponentClass): table
---@field Destroy fun(self: ComponentClass)
---@field Started _Signal
---@field Stopped _Signal
---@field Tag string?

-- Realm

local IsServer = Server ~= nil
local CurrentRealm = IsServer and "Server" or "Client"
local DefaultTimeout = 60

-- Symbols

local function Symbol(name)
	return setmetatable({}, {
		__tostring = function()
			return "Symbol(" .. name .. ")"
		end,
	})
end

local KeyClasses = Symbol("Classes")
local KeyTag = Symbol("Tag")
local KeyRealm = Symbol("Realm")
local KeyTickInterval = Symbol("TickInterval")
local KeyNetworkProps = Symbol("NetworkProperties")
local KeyDebug = Symbol("Debug")
local KeyTimeout = Symbol("Timeout")
local KeyStub = Symbol("Stub")
local KeyInstToComponents = Symbol("InstancesToComponents")
local KeyLockConstruct = Symbol("LockConstruct")
local KeyConstructCleaners = Symbol("ConstructCleaners")
local KeyComponents = Symbol("Components")
local KeyCleaner = Symbol("Cleaner")
local KeyExtensions = Symbol("Extensions")
local KeyActiveExtensions = Symbol("ActiveExtensions")
local KeyStarting = Symbol("Starting")
local KeyStarted = Symbol("Started")
local KeyTickId = Symbol("TickId")
local KeyUnsubscribers = Symbol("Unsubscribers")
local KeyComponentId = Symbol("ComponentId")
local KeyTryDeconstruct = Symbol("TryDeconstruct")
local KeyDestroyed = Symbol("Destroyed")

local AllComponentClasses = {}
local ComponentIdCounter = 0

-- Logging

local function Log(customComponent, ...)
	if not customComponent[KeyDebug] then
		return
	end

	local args = { ... }
	local parts = {}

	for i = 1, select("#", ...) do
		parts[i] = tostring(args[i])
	end

	Console.Log("[MoraxUtils.Component][" .. tostring(customComponent.Tag or "?") .. "] " .. table.concat(parts, " "))
end

-- Extensions

local function InvokeExtensionFn(component, fnName)
	for _, extension in ipairs(component[KeyActiveExtensions]) do
		local fn = extension[fnName]

		if type(fn) == "function" then
			local ok, err = pcall(fn, component)

			if not ok then
				Console.Error("[MoraxUtils.Component] Extension." .. fnName .. "() failed: " .. tostring(err))
			end
		end
	end
end

local function InvokeExtensionFnReverse(component, fnName)
	local extensions = component[KeyActiveExtensions]

	for i = #extensions, 1, -1 do
		local fn = extensions[i][fnName]

		if type(fn) == "function" then
			local ok, err = pcall(fn, component)

			if not ok then
				Console.Error("[MoraxUtils.Component] Extension." .. fnName .. "() failed: " .. tostring(err))
			end
		end
	end
end

local function ShouldConstruct(component)
	for _, extension in ipairs(component[KeyActiveExtensions]) do
		local fn = extension.ShouldConstruct

		if type(fn) == "function" then
			local ok, result = pcall(fn, component)

			if not ok then
				Console.Error("[MoraxUtils.Component] Extension.ShouldConstruct() failed: " .. tostring(result))
				return false
			end

			if not result then
				return false
			end
		end
	end

	return true
end

local function GetActiveExtensions(component, extensionList)
	local activeExtensions = {}
	local allActive = true

	for _, extension in ipairs(extensionList) do
		local fn = extension.ShouldExtend
		local shouldExtend = true

		if type(fn) == "function" then
			local ok, result = pcall(fn, component)

			if not ok then
				Console.Error("[MoraxUtils.Component] Extension.ShouldExtend() failed: " .. tostring(result))
				shouldExtend = false
			else
				shouldExtend = not not result
			end
		end

		if shouldExtend then
			table.insert(activeExtensions, extension)
		else
			allActive = false
		end
	end

	if allActive then
		return extensionList
	end

	return activeExtensions
end

-- Component

---@class Component
---@field Tag string?
---@field Instance any
---@field Destroying _Signal
---@field Started _Signal
---@field Stopped _Signal
---@field OnReplicated fun(self: Component, key: string, value: any)?
---@field ConstructCleaner table?

local Component = {}
Component.__index = Component

---Creates a new custom Component class.
---@param config ComponentConfig
---@return ComponentClass
function Component.new(config)
	assert(type(config) == "table", "ComponentConfig must be a table")
	assert(type(config.Classes) == "table" and #config.Classes > 0, "ComponentConfig.Classes is required and must contain at least one Entity class")
	assert(config.Extensions == nil or type(config.Extensions) == "table", "ComponentConfig.Extensions must be an array of Extension tables")

	local customComponent = {}
	customComponent.__index = customComponent
	customComponent.__tostring = function()
		return "Component<" .. tostring(config.Tag or config.Classes[1].name or "?") .. ">"
	end

	customComponent.Tag = config.Tag
	ComponentIdCounter = ComponentIdCounter + 1

	customComponent[KeyComponentId] = ComponentIdCounter
	customComponent[KeyClasses] = config.Classes
	customComponent[KeyTag] = config.Tag
	customComponent[KeyRealm] = config.Realm
	customComponent[KeyTickInterval] = config.TickInterval
	customComponent[KeyNetworkProps] = config.NetworkProperties or {}
	customComponent[KeyDebug] = config.Debug or false
	customComponent[KeyTimeout] = config.Timeout or DefaultTimeout
	customComponent[KeyInstToComponents] = {}
	customComponent[KeyComponents] = {}
	customComponent[KeyLockConstruct] = {}
	customComponent[KeyConstructCleaners] = {}
	customComponent[KeyCleaner] = Cleaner.new()
	customComponent[KeyExtensions] = config.Extensions or {}
	customComponent[KeyStarted] = false
	customComponent[KeyDestroyed] = false
	customComponent[KeyStub] = config.Realm ~= nil and config.Realm ~= "Shared" and config.Realm ~= CurrentRealm

	customComponent.Started = customComponent[KeyCleaner]:Construct(_Signal)
	customComponent.Stopped = customComponent[KeyCleaner]:Construct(_Signal)

	setmetatable(customComponent, Component)
	table.insert(AllComponentClasses, customComponent)

	if not customComponent[KeyStub] then
		customComponent:_setup()
	end

	return customComponent
end

---@param instance any
---@param constructCleaner table
function Component:_instantiate(instance, constructCleaner)
	local component = setmetatable({}, self)
	component.Instance = instance
	component[KeyActiveExtensions] = GetActiveExtensions(component, self[KeyExtensions])

	if not ShouldConstruct(component) then
		return nil
	end

	component.Destroying = _Signal.new()
	component.ConstructCleaner = constructCleaner

	InvokeExtensionFn(component, "Constructing")

	local result
	if type(component.Construct) == "function" then
		local ok, constructResultOrErr = pcall(component.Construct, component)

		if not ok then
			Console.Error("[MoraxUtils.Component] Construct() failed: " .. tostring(constructResultOrErr))
			return nil
		end

		result = constructResultOrErr
	end

	if type(result) == "table" and type(result.andThen) == "function" then
		return result:andThen(function()
			return component
		end)
	end

	return component
end

function Component:_setup()
	local networkProps = self[KeyNetworkProps]
	local hasNetworkProps = #networkProps > 0
	local networkPrefix = "__MoraxComponent:" .. self[KeyComponentId] .. ":"

	if IsServer and hasNetworkProps then
		self.Set = function(component, key, value)
			component[key] = value
			if TableFind(networkProps, key) then
				component.Instance:SetValue(networkPrefix .. key, value, true)
			end
		end
	else
		self.Set = function(_, key)
			error("Component:Set('" .. tostring(key) .. "') can only be called server-side on a component with NetworkProperties declared", 2)
		end
	end

	local function IsTaggedProperly(instance)
		if not self[KeyTag] then
			return true
		end

		return instance:GetValue(self[KeyTag], false) == true
	end

	local function ApplyNetworkProperties(component)
		if not hasNetworkProps or IsServer then
			return
		end

		for _, key in ipairs(networkProps) do
			local value = component.Instance:GetValue(networkPrefix .. key, nil)

			if value ~= nil then
				component[key] = value
			end
		end

		local function onValueChange(_, key, value)
			if key:sub(1, #networkPrefix) ~= networkPrefix then
				return
			end

			local propName = key:sub(#networkPrefix + 1)
			component[propName] = value

			if type(component.OnReplicated) == "function" then
				component:OnReplicated(propName, value)
			end
		end

		component.Instance:Subscribe("ValueChange", onValueChange)
		component[KeyUnsubscribers] = component[KeyUnsubscribers] or {}
		table.insert(component[KeyUnsubscribers], function()
			if component.Instance and component.Instance:IsValid() then
				component.Instance:Unsubscribe("ValueChange", onValueChange)
			end
		end)
	end

	local function StartComponent(component)
		component[KeyStarting] = true
		InvokeExtensionFn(component, "Starting")
		Log(self, "Starting", tostring(component.Instance:GetID()))

		local ok, err = pcall(component.Start, component)
		if not ok then
			Console.Error("[MoraxUtils.Component] Start() failed: " .. tostring(err))
			component[KeyStarting] = nil
			component[KeyStarted] = false

			if component.Destroying then
				component.Destroying:Fire()
				component.Destroying:Destroy()
			end

			InvokeExtensionFnReverse(component, "Stopping")
			local stopOk, stopErr = pcall(component.Stop, component)

			if not stopOk then
				Console.Error("[MoraxUtils.Component] Stop() after Start() failure failed: " .. tostring(stopErr))
			end

			InvokeExtensionFnReverse(component, "Stopped")
			self.Stopped:Fire(component)

			return false
		end

		if not component[KeyStarting] then
			return false
		end

		InvokeExtensionFn(component, "Started")

		if type(component.Update) == "function" then
			local interval = self[KeyTickInterval]

			if interval then
				local lastTime = os.clock()

				component[KeyTickId] = Timer.SetInterval(function()
					local now = os.clock()
					local dt = now - lastTime
					lastTime = now

					if component.Instance:IsValid() and component[KeyStarted] then
						component:Update(dt)
					end
				end, interval)

				Timer.Bind(component[KeyTickId], component.Instance)
			end
		end

		component[KeyStarted] = true
		component[KeyStarting] = nil

		self.Started:Fire(component)
		return true
	end

	local function StopComponent(component)
		component[KeyStarting] = nil
		component[KeyStarted] = false

		if component[KeyTickId] then
			Timer.ClearInterval(component[KeyTickId])
			component[KeyTickId] = nil
		end

		if component[KeyUnsubscribers] then
			for _, unsubscribe in ipairs(component[KeyUnsubscribers]) do
				unsubscribe()
			end

			component[KeyUnsubscribers] = nil
		end

		if component.Destroying then
			component.Destroying:Fire()
			component.Destroying:Destroy()
		end

		InvokeExtensionFnReverse(component, "Stopping")
		local ok, err = pcall(component.Stop, component)

		if not ok then
			Console.Error("[MoraxUtils.Component] Stop() failed: " .. tostring(err))
		end

		InvokeExtensionFnReverse(component, "Stopped")
		Log(self, "Stopped", tostring(component.Instance:GetID()))

		self.Stopped:Fire(component)
	end

	local function SettleConstructCleaner(instance, id)
		local entry = self[KeyConstructCleaners][instance]

		if entry and entry.id == id then
			self[KeyConstructCleaners][instance] = nil
			entry.cleaner:Destroy()
		end
	end

	local function FinishConstruct(instance, id, component)
		SettleConstructCleaner(instance, id)

		if not component or self[KeyDestroyed] then
			return
		end
		if self[KeyLockConstruct][instance] ~= id then
			return
		end
		if not instance:IsValid() then
			return
		end

		self[KeyInstToComponents][instance] = component
		table.insert(self[KeyComponents], component)

		InvokeExtensionFn(component, "Constructed")
		ApplyNetworkProperties(component)

		if self[KeyInstToComponents][instance] == component then
			local started = StartComponent(component)

			if not started then
				self[KeyInstToComponents][instance] = nil

				local components = self[KeyComponents]
				local index = TableFind(components, component)

				if index then
					local n = #components
					components[index] = components[n]
					components[n] = nil
				end
			end
		end
	end

	local function TryConstructComponent(instance)
		if self[KeyInstToComponents][instance] then
			return
		end

		local id = (self[KeyLockConstruct][instance] or 0) + 1
		self[KeyLockConstruct][instance] = id

		Timer.SetTimeout(function()
			if self[KeyDestroyed] then
				return
			end

			if self[KeyLockConstruct][instance] ~= id then
				return
			end

			if not instance:IsValid() then
				return
			end

			local constructCleaner = Cleaner.new()
			self[KeyConstructCleaners][instance] = { id = id, cleaner = constructCleaner }

			local result = self:_instantiate(instance, constructCleaner)
			if type(result) == "table" and type(result.andThen) == "function" then
				result:andThen(function(component)
					FinishConstruct(instance, id, component)
				end):catch(function(err)
					SettleConstructCleaner(instance, id)
					Console.Error("[MoraxUtils.Component] async Construct failed: " .. tostring(err))
				end)
			else
				FinishConstruct(instance, id, result)
			end
		end, 0)
	end

	local function TryDeconstructComponent(instance)
		local pendingConstruct = self[KeyConstructCleaners][instance]

		if pendingConstruct then
			self[KeyConstructCleaners][instance] = nil
			pendingConstruct.cleaner:Destroy()
		end

		local component = self[KeyInstToComponents][instance]

		if not component then
			self[KeyLockConstruct][instance] = nil
			return
		end

		self[KeyInstToComponents][instance] = nil
		self[KeyLockConstruct][instance] = nil

		local components = self[KeyComponents]
		local index = TableFind(components, component)

		if index then
			local n = #components
			components[index] = components[n]
			components[n] = nil
		end

		if component[KeyStarted] or component[KeyStarting] then
			StopComponent(component)
		end
	end

	self[KeyTryDeconstruct] = TryDeconstructComponent

	for _, class in ipairs(self[KeyClasses]) do
		self[KeyCleaner]:ConnectStatic(class, "Spawn", function(instance)
			if IsTaggedProperly(instance) then
				TryConstructComponent(instance)
			end
		end)

		self[KeyCleaner]:ConnectStatic(class, "Destroy", function(instance)
			TryDeconstructComponent(instance)
		end)

		if self[KeyTag] then
			self[KeyCleaner]:ConnectStatic(class, "ValueChange", function(instance, key, value)
				if key ~= self[KeyTag] then
					return
				end

				if value == true then
					TryConstructComponent(instance)
				else
					TryDeconstructComponent(instance)
				end
			end)
		end

		for _, instance in ipairs(class.GetAll()) do
			if IsTaggedProperly(instance) then
				TryConstructComponent(instance)
			end
		end
	end
end

---Gets all active instances of this component class.
---@return table
function Component:GetAll()
	local source = self[KeyComponents] or {}
	local copy = {}

	for i, component in ipairs(source) do
		copy[i] = component
	end

	return copy
end

---Returns the number of active instances.
---@return integer
function Component:Count()
	return #(self[KeyComponents] or {})
end

---Gets the component instance bound to a given Entity.
---@param instance any
---@return Component?
function Component:FromInstance(instance)
	if self[KeyStub] then
		return nil
	end

	return self[KeyInstToComponents][instance]
end

---Resolves once the component finishes starting.
---@param instance any
---@param timeout number?
---@return table Promise<Component>
function Component:WaitForInstance(instance, timeout)
	if self[KeyStub] then
		return Promise.reject("Component is a stub on this realm")
	end

	local componentInstance = self:FromInstance(instance)
	if componentInstance and componentInstance[KeyStarted] then
		return Promise.resolve(componentInstance)
	end

	local disconnect
	return Promise.fromEvent(
		function(callback)
			disconnect = self.Started:Connect(callback)
		end,

		function()
			if disconnect then
				disconnect()
			end
		end,

		function(c)
			return c.Instance == instance
		end
	):timeout(timeout or self[KeyTimeout])
end

---Called before the component starts.
---@return any?
function Component:Construct()
end

---Called once the component is ready.
function Component:Start()
end

---Called when the component is being torn down.
function Component:Stop()
end

---Retrieves another component bound to the same Entity.
---@param componentClass ComponentClass
---@return Component?
function Component:GetComponent(componentClass)
	return componentClass:FromInstance(self.Instance)
end

---Resolves once another component has started.
---@param componentClass ComponentClass
---@param timeout number?
---@return table
function Component:WaitForComponent(componentClass, timeout)
	return componentClass:WaitForInstance(self.Instance, timeout)
end

---Whether this instance has fully finished starting.
---@return boolean
function Component:IsStarted()
	return self[KeyStarted] == true
end

---Returns the Tag.
---@return string?
function Component:GetTag()
	return self[KeyTag]
end

---Returns the Entity classes this Component binds to.
---@return table
function Component:GetClasses()
	return self[KeyClasses]
end

---Destroys this Component class.
function Component:Destroy()
	if self[KeyDestroyed] then
		return
	end

	self[KeyDestroyed] = true

	for instance, pendingConstruct in pairs(self[KeyConstructCleaners]) do
		self[KeyConstructCleaners][instance] = nil
		pendingConstruct.cleaner:Destroy()
	end

	local deconstruct = self[KeyTryDeconstruct]
	if deconstruct then
		local components = {}

		for _, component in ipairs(self:GetAll()) do
			table.insert(components, component)
		end

		for _, component in ipairs(components) do
			deconstruct(component.Instance)
		end
	end

	self[KeyCleaner]:Destroy()

	local index = TableFind(AllComponentClasses, self)

	if index then
		table.remove(AllComponentClasses, index)
	end
end

---Destroys every Component class.
function Component.DestroyAll()
	for i = #AllComponentClasses, 1, -1 do
		local class = AllComponentClasses[i]

		if class.Destroy then
			class:Destroy()
		end
	end
end

---Returns debug information.
---@return table
function Component.GetRegistry()
	local info = {}

	for _, class in ipairs(AllComponentClasses) do
		table.insert(info, {
			Tag = class.Tag,
			InstanceCount = class:Count(),
			Realm = class[KeyRealm] or "Shared",
			IsStub = class[KeyStub] or false,
		})
	end

	return info
end

-- My Registration

MoraxUtils = MoraxUtils or {}
MoraxUtils.Component = Component

return Component