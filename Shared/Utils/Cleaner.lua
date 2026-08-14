--[[
        Morax Lib's - Cleaner
        More informations about it on the description! (Github coming soon)
        Made with <3 by me :)
--]]

local FunctionMarker = setmetatable({}, {
    __tostring = function()
        return "Cleaner.FunctionMarker"
    end,
})

local ThreadMarker = setmetatable({}, {
    __tostring = function()
        return "Cleaner.ThreadMarker"
    end,
})

local GenericCleanupMethods = {
    "Destroy",
    "destroy",
    "Stop",
    "stop",
    "Cancel",
    "cancel",
    "Disconnect",
    "disconnect",
}

---@class CleanerHandle
---@field package _cleaner Cleaner
---@field package _object any
---@field package _cleanup_method string|table|function
---@field package _cleaned boolean
local CleanerHandle = {}
CleanerHandle.__index = CleanerHandle

---Creates a new cleanup handle.
---@param cleaner Cleaner
---@param object any
---@param cleanup_method string|table|function
---@return CleanerHandle
function CleanerHandle.new(cleaner, object, cleanup_method)
    local self = setmetatable({}, CleanerHandle)

    self._cleaner = cleaner
    self._object = object
    self._cleanup_method = cleanup_method
    self._cleaned = false

    return self
end

---Cleans the resource associated with this handle.
function CleanerHandle:Destroy()
    if self._cleaned then
        return
    end

    local cleaner = self._cleaner

    if cleaner then
        cleaner:_RemoveHandle(self)
    end
end

---Returns whether this handle has already been cleaned.
---@return boolean
function CleanerHandle:IsCleaned()
    return self._cleaned
end

---Returns the resource associated with this handle.
---@return any
function CleanerHandle:GetObject()
    return self._object
end

---Returns the cleanup method associated with this handle.
---@return string|table|function
function CleanerHandle:GetCleanupMethod()
    return self._cleanup_method
end

---Infers how to clean up an arbitrary tracked object.
---@param object any
---@param cleanup_method string|function|nil
---@return string|table|function cleanup identifier
local function ResolveCleanupMethod(object, cleanup_method)
    local object_type = type(object)

    if object_type == "function" then
        return FunctionMarker
    elseif object_type == "thread" then
        return ThreadMarker
    end

    if type(cleanup_method) == "function" then
        return cleanup_method
    end

    if cleanup_method ~= nil then
        if type(object) ~= "table" and type(object) ~= "userdata" then
            error(string.format("[Cleaner] Cannot use cleanup method '%s' on object of type '%s'", tostring(cleanup_method), object_type), 3)
        end

        if type(object[cleanup_method]) ~= "function" then
            error(string.format("[Cleaner] Object has no cleanup method '%s'", tostring(cleanup_method)), 3)
        end

        return cleanup_method
    end

    if object_type == "table" or object_type == "userdata" then
        if type(object.Destroy) == "function" then
            return "Destroy"
        end

        for _, method_name in ipairs(GenericCleanupMethods) do
            if type(object[method_name]) == "function" then
                return method_name
            end
        end
    end

    error(string.format("[Cleaner] Failed to resolve a cleanup method for object of type '%s': %s", object_type, tostring(object)), 3)
end

---@class Cleaner
---@field private _handles CleanerHandle[]
---@field private _count number
---@field private _cleaning boolean
---@field private _destroyed boolean
local Cleaner = {}
Cleaner.__index = Cleaner

---Creates a new Cleaner instance.
---@return Cleaner
function Cleaner.new()
    local self = setmetatable({}, Cleaner)
    self._handles = {}
    self._count = 0
    self._cleaning = false
    self._destroyed = false
    return self
end

---Checks whether the Cleaner is currently cleaning its resources.
---@return boolean
function Cleaner:IsCleaning()
    return self._cleaning
end

---Checks whether the Cleaner has been destroyed.
---@return boolean
function Cleaner:IsDestroyed()
    return self._destroyed
end

---Returns the number of resources currently tracked by the Cleaner.
---@return number
function Cleaner:Count()
    return self._count
end

---Creates and tracks a sub-Cleaner. Cleaning the parent also cleans the child.
---@return Cleaner
function Cleaner:Extend()
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Extend() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:Extend() after destruction", 2)
    end

    local child = Cleaner.new()

    self:Add(child, "Destroy")

    return child
end

---Constructs an object via a class (`class.new(...)`) or a function
---(`fn(...)`) and tracks the result.
---@param class table|function
---@param ... any
---@return any
function Cleaner:Construct(class, ...)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Construct() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:Construct() after destruction", 2)
    end

    local object
    local object_type = type(class)

    if object_type == "table" then
        if type(class.new) ~= "function" then
            error("[Cleaner] Cleaner:Construct() expects the class to expose a :new() method", 2)
        end

        object = class.new(...)
    elseif object_type == "function" then
        object = class(...)
    else
        error("[Cleaner] Cleaner:Construct() expects a table or a function", 2)
    end

    self:Add(object)

    return object
end

---Tracks an object so it gets cleaned up when the Cleaner is cleaned.
---@param object any
---@param cleanup_method string|function|nil optional explicit method name, or a
---custom `function(object)` cleanup override
---@return any object the same object that was passed in
function Cleaner:Add(object, cleanup_method)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Add() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:Add() after destruction", 2)
    end

    if object == nil then
        error("[Cleaner] Cannot add nil to a Cleaner", 2)
    end

    local resolved_method = ResolveCleanupMethod(object, cleanup_method)
    local handle = CleanerHandle.new(self, object, resolved_method)

    table.insert(self._handles, handle)
    self._count = self._count + 1

    return object
end

---Tracks an object and returns a cleanup handle for direct resource control.
---@param object any
---@param cleanup_method string|function|nil optional explicit method name, or a
---custom `function(object)` cleanup override
---@return CleanerHandle
function Cleaner:Track(object, cleanup_method)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Track() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:Track() after destruction", 2)
    end

    if object == nil then
        error("[Cleaner] Cannot track nil in a Cleaner", 2)
    end

    local resolved_method = ResolveCleanupMethod(object, cleanup_method)
    local handle = CleanerHandle.new(self, object, resolved_method)

    table.insert(self._handles, handle)
    self._count = self._count + 1

    return handle
end

---Alias of `Cleaner:Add()`.
---@param object any
---@param cleanup_method string|function|nil
---@return any
function Cleaner:GiveTask(object, cleanup_method)
    return self:Add(object, cleanup_method)
end

---Removes the first matching object from the Cleaner and cleans it up.
---@param object any
---@return boolean removed true if the object was found and cleaned
function Cleaner:Remove(object)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Remove() while cleaning", 2)
    end

    if self._destroyed then
        return false
    end

    for index, handle in ipairs(self._handles) do
        if handle._object == object then
            self:_RemoveHandleAt(index, handle)
            return true
        end
    end

    return false
end

---Removes and cleans a specific handle.
---@param handle CleanerHandle
---@return boolean removed true if the handle was tracked and cleaned
function Cleaner:RemoveHandle(handle)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:RemoveHandle() while cleaning", 2)
    end

    if self._destroyed then
        return false
    end

    if type(handle) ~= "table" or handle._cleaner ~= self then
        return false
    end

    for index, tracked_handle in ipairs(self._handles) do
        if tracked_handle == handle then
            self:_RemoveHandleAt(index, handle)
            return true
        end
    end

    return false
end

---@package
---@param handle CleanerHandle
function Cleaner:_RemoveHandle(handle)
    if self._cleaning or self._destroyed then
        return
    end

    for index, tracked_handle in ipairs(self._handles) do
        if tracked_handle == handle then
            self:_RemoveHandleAt(index, handle)
            return
        end
    end
end

---@private
---@param index number
---@param handle CleanerHandle
function Cleaner:_RemoveHandleAt(index, handle)
    table.remove(self._handles, index)

    self._count = self._count - 1

    handle._cleaned = true
    handle._cleaner = nil

    self:_CleanupObject(handle._object, handle._cleanup_method)

    handle._object = nil
    handle._cleanup_method = nil
end

---Cleans up an arbitrary tracked object using its resolved cleanup method.
---@param object any
---@param cleanup_method string|table|function
---@private
function Cleaner:_CleanupObject(object, cleanup_method)
    if object == nil then
        return
    end

    if cleanup_method == FunctionMarker then
        local ok, err = pcall(object)

        if not ok then
            Console.Error("[Cleaner] Function cleanup failed: " .. tostring(err))
        end

        return
    end

    if cleanup_method == ThreadMarker then
        if coroutine.close then
            local ok, err = pcall(coroutine.close, object)

            if not ok then
                Console.Error("[Cleaner] Thread cleanup failed: " .. tostring(err))
            end
        end

        return
    end

    if type(cleanup_method) == "function" then
        local ok, err = pcall(cleanup_method, object)

        if not ok then
            Console.Error("[Cleaner] Internal cleanup failed: " .. tostring(err))
        end

        return
    end

    if type(object) == "table" or type(object) == "userdata" then
        if type(object.IsValid) == "function" then
            local valid_ok, is_valid = pcall(object.IsValid, object)

            if valid_ok and not is_valid then
                return
            end
        end
    end

    local cleanup_function = object[cleanup_method]

    if type(cleanup_function) ~= "function" then
        Console.Error(string.format("[Cleaner] Cleanup method '%s' is no longer available on object '%s'", tostring(cleanup_method), tostring(object)))
        return
    end

    local ok, err = pcall(cleanup_function, object)

    if not ok then
        local error_message = tostring(err)

        if not string.find(error_message, "destroyed") then
            Console.Error(string.format("[Cleaner] Cleanup of '%s' failed: %s", tostring(cleanup_method), error_message))
        end
    end
end

---Cleans up every tracked object.
---Cleanup order follows the registration order.
---Safe to call re-entrantly.
function Cleaner:Clean()
    if self._cleaning then
        return
    end

    if self._destroyed then
        return
    end

    self._cleaning = true

    local handles = self._handles

    self._handles = {}
    self._count = 0

    for _, handle in ipairs(handles) do
        if not handle._cleaned then
            handle._cleaned = true
            handle._cleaner = nil

            self:_CleanupObject(
                handle._object,
                handle._cleanup_method
            )

            handle._object = nil
            handle._cleanup_method = nil
        end
    end

    self._cleaning = false
end

---Destroys the Cleaner and all tracked resources.
---Safe to call multiple times.
function Cleaner:Destroy()
    if self._destroyed then
        return
    end

    self:Clean()

    self._destroyed = true
end

---Subscribes to an event on a specific Entity instance and tracks it.
---
---```lua
---cleaner:Connect(my_character, "EnterVehicle", function(self, vehicle)
---    ...
---end)
---```
---
---@param entity any nanos world Entity instance
---@param event_name string
---@param callback function
---@return function callback the same callback for API convenience
function Cleaner:Connect(entity, event_name, callback)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:Connect() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:Connect() after destruction", 2)
    end

    if entity == nil then
        error("[Cleaner] Cleaner:Connect() expects a valid Entity", 2)
    end

    if type(event_name) ~= "string" then
        error("[Cleaner] Cleaner:Connect() expects event_name to be a string", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:Connect() expects callback to be a function", 2)
    end

    entity:Subscribe(event_name, callback)

    local handle = {
        entity = entity,
        event_name = event_name,
        callback = callback,
    }

    self:Track(handle, function(h)
        if h.entity
            and type(h.entity.IsValid) == "function"
            and h.entity:IsValid()
        then
            h.entity:Unsubscribe(h.event_name, h.callback)
        end
    end)

    return callback
end

---Subscribes to an event on a Class itself and tracks it.
---The callback will receive events for all entities of that class.
---
---```lua
---cleaner:ConnectStatic(Player, "Spawn", function(player)
---    ...
---end)
---```
---
---@param class table nanos world Class
---@param event_name string
---@param callback function
---@return function callback the same callback for API convenience
function Cleaner:ConnectStatic(class, event_name, callback)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:ConnectStatic() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:ConnectStatic() after destruction", 2)
    end

    if type(class) ~= "table" then
        error("[Cleaner] Cleaner:ConnectStatic() expects a nanos world Class", 2)
    end

    if type(event_name) ~= "string" then
        error("[Cleaner] Cleaner:ConnectStatic() expects event_name to be a string", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:ConnectStatic() expects callback to be a function", 2)
    end

    class.Subscribe(event_name, callback)

    local handle = {
        class = class,
        event_name = event_name,
        callback = callback,
    }

    self:Track(handle, function(h)
        h.class.Unsubscribe(h.event_name, h.callback)
    end)

    return callback
end

---Subscribes to a custom remote event sent to a specific Entity and tracks it.
---@param entity any nanos world Entity instance
---@param event_name string
---@param callback function
---@return function callback the same callback for API convenience
function Cleaner:ConnectRemote(entity, event_name, callback)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:ConnectRemote() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:ConnectRemote() after destruction", 2)
    end

    if entity == nil then
        error("[Cleaner] Cleaner:ConnectRemote() expects a valid Entity", 2)
    end

    if type(event_name) ~= "string" then
        error("[Cleaner] Cleaner:ConnectRemote() expects event_name to be a string", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:ConnectRemote() expects callback to be a function", 2)
    end

    entity:SubscribeRemote(event_name, callback)

    local handle = {
        entity = entity,
        event_name = event_name,
        callback = callback,
    }

    self:Track(handle, function(h)
        if h.entity
            and type(h.entity.IsValid) == "function"
            and h.entity:IsValid()
        then
            h.entity:Unsubscribe(h.event_name, h.callback)
        end
    end)

    return callback
end

---Subscribes to a local custom Event and tracks it.
---@param event_name string
---@param callback function
---@return function callback the same callback for API convenience
function Cleaner:ConnectEvent(event_name, callback)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:ConnectEvent() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:ConnectEvent() after destruction", 2)
    end

    if type(event_name) ~= "string" then
        error("[Cleaner] Cleaner:ConnectEvent() expects event_name to be a string", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:ConnectEvent() expects callback to be a function", 2)
    end

    Events.Subscribe(event_name, callback)

    local handle = {
        event_name = event_name,
        callback = callback,
    }

    self:Track(handle, function(h)
        Events.Unsubscribe(h.event_name, h.callback)
    end)

    return callback
end

---Subscribes to a remote custom Event and tracks it.
---@param event_name string
---@param callback function
---@return function callback the same callback for API convenience
function Cleaner:ConnectRemoteEvent(event_name, callback)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:ConnectRemoteEvent() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:ConnectRemoteEvent() after destruction", 2)
    end

    if type(event_name) ~= "string" then
        error("[Cleaner] Cleaner:ConnectRemoteEvent() expects event_name to be a string", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:ConnectRemoteEvent() expects callback to be a function", 2)
    end

    Events.SubscribeRemote(event_name, callback)

    local handle = {
        event_name = event_name,
        callback = callback,
    }

    self:Track(handle, function(h)
        Events.UnsubscribeRemote(h.event_name, h.callback)
    end)

    return callback
end

---Schedules `Timer.SetTimeout` and tracks it.
---The timer is automatically removed from the Cleaner after execution.
---@param callback function
---@param delay_ms number
---@param ... any extra arguments forwarded to the callback
---@return number timer_id
function Cleaner:SetTimeout(callback, delay_ms, ...)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:SetTimeout() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:SetTimeout() after destruction", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:SetTimeout() expects callback to be a function", 2)
    end

    if type(delay_ms) ~= "number" then
        error("[Cleaner] Cleaner:SetTimeout() expects delay_ms to be a number", 2)
    end

    local timer_id

    timer_id = Timer.SetTimeout(function(...)
        self:_RemoveTimer(timer_id)
        callback(...)
    end, delay_ms, ...)

    local handle = {
        timer_id = timer_id,
    }

    self:Track(handle, function(h)
        Timer.ClearTimeout(h.timer_id)
    end)

    return timer_id
end

---@private
---@param timer_id number
function Cleaner:_RemoveTimer(timer_id)
    for index, handle in ipairs(self._handles) do
        if type(handle._object) == "table"
            and handle._object.timer_id == timer_id
        then
            table.remove(self._handles, index)
            self._count = self._count - 1

            handle._cleaned = true
            handle._cleaner = nil
            handle._object = nil
            handle._cleanup_method = nil

            return
        end
    end
end

---Schedules `Timer.SetInterval` and tracks it.
---@param callback function
---@param delay_ms number
---@param ... any extra arguments forwarded to the callback
---@return number timer_id
function Cleaner:SetInterval(callback, delay_ms, ...)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:SetInterval() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:SetInterval() after destruction", 2)
    end

    if type(callback) ~= "function" then
        error("[Cleaner] Cleaner:SetInterval() expects callback to be a function", 2)
    end

    if type(delay_ms) ~= "number" then
        error("[Cleaner] Cleaner:SetInterval() expects delay_ms to be a number", 2)
    end

    local timer_id = Timer.SetInterval(callback, delay_ms, ...)

    local handle = {
        timer_id = timer_id,
    }

    self:Track(handle, function(h)
        Timer.ClearInterval(h.timer_id)
    end)

    return timer_id
end

---Attaches the Cleaner's lifetime to a nanos world Entity.
---Once the Entity is destroyed, the Cleaner automatically cleans itself.
---
---```lua
---local cleaner = Cleaner.new()
---cleaner:AttachToEntity(my_character)
---```
---
---@param entity any nanos world Entity instance
---@return function callback the subscribed Destroy callback
function Cleaner:AttachToEntity(entity)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:AttachToEntity() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:AttachToEntity() after destruction", 2)
    end

    if type(entity) ~= "table" and type(entity) ~= "userdata" then
        error("[Cleaner] Cleaner:AttachToEntity() expects a nanos world Entity", 2)
    end

    if type(entity.IsValid) ~= "function" or not entity:IsValid() then
        error("[Cleaner] Cleaner:AttachToEntity() expects a valid nanos world Entity", 2)
    end

    return self:Connect(entity, "Destroy", function()
        self:Destroy()
    end)
end

---Checks whether an object behaves like a Promise.
---@param object any
---@return boolean
local function IsPromiseLike(object)
    return type(object) == "table" and type(object.cancel) == "function" and (type(object.finally) == "function" or type(object.andThen) == "function")
end

---Tracks a Promise-like object and cancels it when the Cleaner is cleaned.
---The Promise is returned unchanged so calls can still be chained.
---@param promise table
---@return table promise
function Cleaner:AddPromise(promise)
    if self._cleaning then
        error("[Cleaner] Cannot call Cleaner:AddPromise() while cleaning", 2)
    end

    if self._destroyed then
        error("[Cleaner] Cannot call Cleaner:AddPromise() after destruction", 2)
    end

    if not IsPromiseLike(promise) then
        error("[Cleaner] Cleaner:AddPromise() expects an object exposing :cancel() and :finally()/:andThen()", 2)
    end

    self:Add(promise, "cancel")
    return promise
end

MoraxUtils = MoraxUtils or {}
MoraxUtils.Cleaner = Cleaner

return Cleaner