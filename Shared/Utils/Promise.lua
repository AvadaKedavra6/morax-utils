--[[
    Morax-utils - Promise
    Made with <3 by Morax :)
--]]

-- Variables

local unpack = table.unpack

local ErrorNonPromiseInList = "Non-promise value passed into %s at index %s"
local ErrorNonList = "Please pass a list of promises to %s"
local ErrorNonFunction = "Please pass a handler function to %s"

local WeakKeyMetatable = {
    __mode = "k",
}

-- Types

---@alias PromiseStatusKind
---| "Started"
---| "Resolved"
---| "Rejected"
---| "Cancelled"

---@alias PromiseErrorKind
---| "ExecutionError"
---| "AlreadyCancelled"
---| "NotResolvedInTime"
---| "TimedOut"

---@alias PromiseExecutor<T> fun(
---    resolve: fun(value: T),
---    reject: fun(...: any),
---    onCancel: fun(cancellationHook: fun()?): boolean)
---): ()

---@alias PromiseHandler<T, U> fun(...: any): U | PromiseObject<U> | nil

---@class Promise.ErrorKindEnum
---@field ExecutionError "ExecutionError"
---@field AlreadyCancelled "AlreadyCancelled"
---@field NotResolvedInTime "NotResolvedInTime"
---@field TimedOut "TimedOut"

---@class Promise.Error
---@field error string
---@field trace string?
---@field context string?
---@field kind PromiseErrorKind?
---@field parent Promise.Error?
---@field createdTick number
---@field createdTrace string
---@field Kind Promise.ErrorKindEnum

---@class Promise.ErrorOptions
---@field error any
---@field trace string?
---@field context string?
---@field kind PromiseErrorKind?

---@class Promise.ErrorClass
---@field Kind Promise.ErrorKindEnum
---@field new fun(options: Promise.ErrorOptions?, parent: Promise.Error?): Promise.Error
---@field is fun(value: any): boolean
---@field isKind fun(value: any, kind: PromiseErrorKind): boolean

---@class Promise.StatusEnum
---@field Started "Started"
---@field Resolved "Resolved"
---@field Rejected "Rejected"
---@field Cancelled "Cancelled"

---@class PromiseObject<T>
---@field package _thread thread?
---@field package _source string
---@field package _status PromiseStatusKind
---@field package _values any[]
---@field package _valuesLength number
---@field package _unhandledRejection boolean
---@field package _queuedResolve function[]
---@field package _queuedReject function[]
---@field package _queuedFinally function[]
---@field package _cancellationHook fun()?
---@field package _parent PromiseObject<any>?
---@field package _consumers table<PromiseObject<any>, boolean>
---@field package _finalized boolean

---@class Promise
---@field prototype PromiseObject<any>
---@field Error Promise.ErrorClass
---@field Status Promise.StatusEnum
---@field TEST boolean?
local Promise = {}

---@class PromiseObject<T>
local PromiseObject = {}

-- Utility functions

---Checks whether a value can be called like a function.
---@param value any
---@return boolean
local function isCallable(value)
    if type(value) == "function" then
        return true
    end

    if type(value) == "table" then
        local metatable = getmetatable(value)

        if metatable and type(rawget(metatable, "__call")) == "function" then
            return true
        end
    end

    return false
end

---Finds the first occurrence of a value inside an array.
---
---Nanos World does not provide `table.find`, so this helper keeps the
---Promise implementation independent from additional utility libraries.
---@param list any[]
---@param value any
---@return number?
local function tableFind(list, value)
    for index, currentValue in ipairs(list) do
        if currentValue == value then
            return index
        end
    end

    return nil
end

---Creates an enum dictionary with protected members.
---@param enumName string
---@param members string[]
---@return table<string, string>
local function makeEnum(enumName, members)
    local enum = {}

    for _, memberName in ipairs(members) do
        enum[memberName] = memberName
    end

    return setmetatable(enum, {
        __index = function(_, key)
            error(string.format("%s is not a member of %s", tostring(key), enumName), 2)
        end,

        __newindex = function()
            error(string.format("Creating new members in %s is not allowed", enumName), 2)
        end,
    })
end

---Packs variadic values into an array without losing trailing nil values.
---@param ... any
---@return number length
---@return any[] values
local function pack(...)
    return select("#", ...), { ... }
end

---Runs a callback and returns its success state and packed result.
---@param callback function
---@param ... any
---@return boolean success
---@return number length
---@return any[] values
local function packResult(callback, ...)
    local values = table.pack(xpcall(callback, ...))

    local success = values[1]
    table.remove(values, 1)

    return success, #values, values
end

---Creates an error handler used by Promise executors and callbacks.
---@param traceback string
---@return fun(errorValue: any): Promise.Error
local function makeErrorHandler(traceback)
    return function(errorValue)
        if Promise.Error.is(errorValue) then
            return errorValue
        end

        return Promise.Error.new({
            error = errorValue,
            kind = Promise.Error.Kind.ExecutionError,
            trace = debug.traceback(tostring(errorValue), 2),
            context = "Promise created at:\n\n" .. traceback,
        })
    end
end

---Runs a callback through xpcall and converts runtime errors into Promise errors.
---@param traceback string
---@param callback function
---@param ... any
---@return boolean success
---@return number length
---@return any[] values
local function runExecutor(traceback, callback, ...)
    local results = table.pack(
        xpcall(
            callback,
            makeErrorHandler(traceback),
            ...
        )
    )

    local success = results[1]
    table.remove(results, 1)
    return success, #results, results
end

---Creates a callback wrapper that automatically resolves or rejects a Promise.
---@param traceback string
---@param callback function
---@param resolve function
---@param reject function
---@return function
local function createAdvancer(traceback, callback, resolve, reject)
    return function(...)
        local success, resultLength, result = runExecutor(
            traceback,
            callback,
            ...
        )

        if success then
            resolve(unpack(result, 1, resultLength))
        else
            reject(result[1])
        end
    end
end

---Closes a coroutine safely.
---
---If the coroutine is currently running, closing it immediately is invalid.
---In that case the close operation is deferred to the next engine tick.
---@param thread thread?
local function closeThread(thread)
    if not thread then
        return
    end

    local status = coroutine.status(thread)

    if status == "dead" then
        return
    end

    if status == "running" then
        Timer.SetTimeout(function()
            if coroutine.status(thread) ~= "dead" then
                pcall(coroutine.close, thread)
            end
        end, 0)

        return
    end

    pcall(coroutine.close, thread)
end

-- Promise.Error

local Error = {
    Kind = makeEnum("Promise.Error.Kind", {
        "ExecutionError",
        "AlreadyCancelled",
        "NotResolvedInTime",
        "TimedOut",
    }),
}

Error.__index = Error

---Creates a new Promise.Error.
---@param options { error: any, trace: string?, context: string?, kind: PromiseErrorKind? }?
---@param parent Promise.Error?
---@return Promise.Error
function Error.new(options, parent)
    options = options or {}

    return setmetatable({
        error = options.error ~= nil and tostring(options.error) or "[This error has no error text.]",
        trace = options.trace,
        context = options.context,
        kind = options.kind,
        parent = parent,
        createdTick = os.clock(),
        createdTrace = debug.traceback(),
    }, Error)
end

---Checks whether a value is a Promise.Error.
---@param value any
---@return boolean
function Error.is(value)
    if type(value) ~= "table" then
        return false
    end

    local metatable = getmetatable(value)
    return metatable == Error and type(value.error) == "string"
end

---Checks whether a value is a Promise.Error of a specific kind.
---@param value any
---@param kind PromiseErrorKind
---@return boolean
function Error.isKind(value, kind)
    if kind == nil then
        error("Argument #2 to Promise.Error.isKind must not be nil", 2)
    end

    return Error.is(value) and value.kind == kind
end

---Creates a child error while preserving the current error as its parent.
---@param options { error: any, trace: string?, context: string?, kind: PromiseErrorKind? }?
---@return Promise.Error
function Error:extend(options)
    options = options or {}
    options.kind = options.kind or self.kind
    return Error.new(options, self)
end

---Returns the complete parent chain of this error.
---@return Promise.Error[]
function Error:getErrorChain()
    local chain = { self }
    local current = self

    while current.parent do
        current = current.parent
        table.insert(chain, current)
    end

    return chain
end

function Error:__tostring()
    local errorStrings = {
        string.format("-- Promise.Error(%s) --", self.kind or "Unknown"),
    }

    for _, runtimeError in ipairs(self:getErrorChain()) do
        local message = runtimeError.trace or runtimeError.error

        if runtimeError.context then
            message = message .. "\n" .. runtimeError.context
        end

        table.insert(errorStrings, message)
    end

    return table.concat(errorStrings, "\n")
end

Promise.Error = Error

-- PromiseObject internals

PromiseObject.__index = PromiseObject

---@generic T
---@param traceback string
---@param executor PromiseExecutor<T>
---@param parent PromiseObject<any>?
---@return PromiseObject<T>
function Promise._new(traceback, executor, parent)
    if parent ~= nil and not Promise.is(parent) then
        error("Argument #3 to Promise._new must be a Promise or nil", 2)
    end

    local self = {
        _thread = nil,
        _source = traceback,
        _status = Promise.Status.Started,
        _values = {},
        _valuesLength = 0,
        _unhandledRejection = true,
        _queuedResolve = {},
        _queuedReject = {},
        _queuedFinally = {},
        _cancellationHook = nil,
        _parent = parent,
        _consumers = setmetatable({}, WeakKeyMetatable),
        _finalized = false,
    }

    setmetatable(self, PromiseObject)

    if parent and parent._status == Promise.Status.Started then
        parent._consumers[self] = true
    end

    local function resolve(...)
        self:_resolve(...)
    end

    local function reject(...)
        self:_reject(...)
    end

    local function onCancel(cancellationHook)
        if cancellationHook ~= nil then
            if not isCallable(cancellationHook) then
                error("Promise cancellation hook must be callable", 2)
            end

            if self._status == Promise.Status.Cancelled then
                cancellationHook()
            else
                self._cancellationHook = cancellationHook
            end
        end

        return self._status == Promise.Status.Cancelled
    end

    self._thread = coroutine.create(function()
        local success, _, results = runExecutor(
            traceback,
            executor,
            resolve,
            reject,
            onCancel
        )

        if not success then
            reject(results[1])
        end
    end)

    local success, resumeError = coroutine.resume(self._thread)

    if not success then
        reject(
            Error.new({
                error = resumeError,
                kind = Error.Kind.ExecutionError,
                trace = debug.traceback(tostring(resumeError), 2),
                context = "Promise created at:\n\n" .. traceback,
            })
        )
    end

    return self
end

-- Promise

Promise.Status = makeEnum("Promise.Status", {
    "Started",
    "Resolved",
    "Rejected",
    "Cancelled",
})

Promise.prototype = PromiseObject

---Creates a new Promise.
---
---Errors thrown by the executor are automatically converted into rejections.
---@generic T
---@param executor PromiseExecutor<T>
---@return PromiseObject<T>
function Promise.new(executor)
    if not isCallable(executor) then
        error(string.format(ErrorNonFunction, "Promise.new"), 2)
    end

    return Promise._new(
        debug.traceback(nil, 2),
        executor
    )
end

function PromiseObject:__tostring()
    return string.format(
        "Promise(%s)",
        self._status
    )
end

---Creates a Promise whose executor starts on the next engine tick.
---
---Nanos World uses `Timer.SetTimeout(..., 0)` instead of Roblox's `task.defer`.
---@generic T
---@param executor PromiseExecutor<T>
---@return PromiseObject<T>
function Promise.defer(executor)
    if not isCallable(executor) then
        error(string.format(ErrorNonFunction, "Promise.defer"), 2)
    end

    local traceback = debug.traceback(nil, 2)

    return Promise._new(
        traceback,
        function(resolve, reject, onCancel)
            local timerId

            timerId = Timer.SetTimeout(function()
                if timerId == nil then
                    return
                end

                local success, _, results = runExecutor(
                    traceback,
                    executor,
                    resolve,
                    reject,
                    onCancel
                )

                if not success then
                    reject(results[1])
                end
            end, 0)

            onCancel(function()
                if timerId then
                    Timer.ClearTimeout(timerId)
                    timerId = nil
                end
            end)
        end
    )
end

---Alias of `Promise.defer`.
Promise.async = Promise.defer

---Creates an immediately resolved Promise.
---@generic T
---@param value T
---@return PromiseObject<T>
function Promise.resolve(value)
    return Promise._new(
        debug.traceback(nil, 2),
        function(resolve)
            resolve(value)
        end
    )
end

---Creates an immediately rejected Promise.
---@param ... any
---@return PromiseObject<any>
function Promise.reject(...)
    local length, values = pack(...)

    return Promise._new(
        debug.traceback(nil, 2),
        function(_, reject)
            reject(unpack(values, 1, length))
        end
    )
end

---Runs a normal function inside a Promise.
---
---Errors thrown by the callback become Promise rejections.
---@generic T
---@param callback fun(...: any): T
---@param ... any
---@return PromiseObject<T>
function Promise.try(callback, ...)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise.try"), 2)
    end

    local traceback = debug.traceback(nil, 2)
    local length, values = pack(...)

    return Promise._new(
        traceback,
        function(resolve)
            resolve(callback(unpack(values, 1, length)))
        end
    )
end

-- Promise combinators

---Returns a Promise that resolves when all input Promises resolve.
---
---The resulting values preserve the original input order.
---@generic T
---@param promises PromiseObject<T>[]
---@return PromiseObject<T[]>
function Promise.all(promises)
    if type(promises) ~= "table" then
        error(string.format(ErrorNonList, "Promise.all"), 2)
    end

    for index, promise in pairs(promises) do
        if not Promise.is(promise) then
            error(string.format(ErrorNonPromiseInList, "Promise.all", tostring(index)), 2)
        end
    end

    if #promises == 0 then
        return Promise.resolve({})
    end

    return Promise._all(
        debug.traceback(nil, 2),
        promises
    )
end

---@private
---@generic T
---@param traceback string
---@param promises PromiseObject<T>[]
---@param amount number?
---@return PromiseObject<any>
function Promise._all(traceback, promises, amount)
    if #promises == 0 then
        if amount == nil then
            return Promise.resolve({})
        end

        if amount <= 0 then
            return Promise.resolve({})
        end

        return Promise.reject(
            Error.new({
                error = "No promises were provided.",
                kind = Error.Kind.NotResolvedInTime,
            })
        )
    end

    if amount ~= nil then
        if amount <= 0 then
            return Promise.resolve({})
        end

        if amount > #promises then
            return Promise.reject(
                Error.new({
                    error = string.format("Promise.some expected at least %d successful promises, but only %d were provided.", amount, #promises),
                })
            )
        end
    end

    return Promise._new(
        traceback,
        function(resolve, reject, onCancel)
            local resolvedValues = {}
            local childPromises = {}

            local resolvedCount = 0
            local rejectedCount = 0
            local finished = false

            local requiredCount = amount or #promises

            local function cancelChildren()
                for _, childPromise in ipairs(childPromises) do
                    childPromise:cancel()
                end
            end

            local function resolveOne(index, ...)
                if finished then
                    return
                end

                resolvedCount = resolvedCount + 1

                if amount then
                    resolvedValues[resolvedCount] = ...
                else
                    resolvedValues[index] = ...
                end

                if resolvedCount >= requiredCount then
                    finished = true
                    resolve(resolvedValues)
                    cancelChildren()
                end

                return nil
            end

            local function rejectOne(...)
                if finished then
                    return
                end

                rejectedCount = rejectedCount + 1

                if amount == nil or (#promises - rejectedCount) < amount then
                    finished = true
                    reject(...)
                    cancelChildren()
                end

                return nil
            end

            onCancel(function()
                finished = true
                cancelChildren()
            end)

            for index, promise in ipairs(promises) do
                childPromises[index] = promise:andThen(
                    function(...)
                        resolveOne(index, ...)
                        return nil
                    end,

                    function(...)
                        rejectOne(...)
                        return nil
                    end
                )
            end
        end
    )
end

---Folds an array sequentially using an asynchronous reducer.
---@generic T, U
---@param list T[]
---@param reducer fun(accumulator: U, value: T, index: number): U | PromiseObject<U>
---@param initialValue U
---@return PromiseObject<U>
function Promise.fold(list, reducer, initialValue)
    if type(list) ~= "table" then
        error(string.format(ErrorNonList, "Promise.fold"), 2)
    end

    if not isCallable(reducer) then
        error(string.format(ErrorNonFunction, "Promise.fold"), 2)
    end

    local accumulator = Promise.resolve(initialValue)

    return Promise.each(
        list,
        function(value, index)
            accumulator = accumulator:andThen(function(previousValue)
                return reducer(
                    previousValue,
                    value,
                    index
                )
            end)

            return nil
        end
    ):andThen(function()
        return accumulator
    end)
end

---Resolves when `count` input Promises resolve.
---@generic T
---@param promises PromiseObject<T>[]
---@param count number
---@return PromiseObject<T[]>
function Promise.some(promises, count)
    if type(count) ~= "number" then
        error("Bad argument #2 to Promise.some: must be a number", 2)
    end

    if count % 1 ~= 0 then
        error("Bad argument #2 to Promise.some: must be an integer", 2)
    end

    if count < 0 then
        error("Bad argument #2 to Promise.some: must be greater than or equal to zero", 2)
    end

    if type(promises) ~= "table" then
        error(string.format(ErrorNonList, "Promise.some"), 2)
    end

    for index, promise in pairs(promises) do
        if not Promise.is(promise) then
            error(string.format(ErrorNonPromiseInList, "Promise.some", tostring(index)), 2)
        end
    end

    return Promise._all(
        debug.traceback(nil, 2),
        promises,
        count
    )
end

---Resolves as soon as any input Promise resolves.
---@generic T
---@param promises PromiseObject<T>[]
---@return PromiseObject<T>
function Promise.any(promises)
    return Promise.some(
        promises,
        1
    ):andThen(function(values)
        return values[1]
    end)
end

---Resolves when every input Promise has settled.
---@param promises PromiseObject<any>[]
---@return PromiseObject<PromiseStatusKind[]>
function Promise.allSettled(promises)
    if type(promises) ~= "table" then
        error(string.format(ErrorNonList, "Promise.allSettled"), 2)
    end

    for index, promise in pairs(promises) do
        if not Promise.is(promise) then
            error(string.format(ErrorNonPromiseInList, "Promise.allSettled", tostring(index)), 2)
        end
    end

    if #promises == 0 then
        return Promise.resolve({})
    end

    return Promise._new(
        debug.traceback(nil, 2),
        function(resolve, _, onCancel)
            local statuses = {}
            local childPromises = {}
            local finishedCount = 0
            local finished = false

            local function cancelChildren()
                for _, childPromise in ipairs(childPromises) do
                    childPromise:cancel()
                end
            end

            onCancel(function()
                finished = true
                cancelChildren()
            end)

            for index, promise in ipairs(promises) do
                -- finally() re-settles like the original promise. When the
                -- original is rejected, the promise returned by finally()
                -- also rejects. Nobody observes that rejection by default,
                -- which would trigger an unhandled-rejection warning.
                -- We attach a no-op catch so the rejection is considered handled
                -- while still keeping the finally-promise for cancellation.
                local settled = promise:finally(function(status)
                    if finished then
                        return
                    end

                    statuses[index] = status
                    finishedCount = finishedCount + 1

                    if finishedCount >= #promises then
                        finished = true
                        resolve(statuses)
                    end
                end)

                settled:catch(function() end)
                childPromises[index] = settled
            end
        end
    )
end

---Resolves or rejects as soon as any input Promise settles.
---@param promises PromiseObject<any>[]
---@return PromiseObject<any>
function Promise.race(promises)
    if type(promises) ~= "table" then
        error(string.format(ErrorNonList, "Promise.race"), 2)
    end

    for index, promise in pairs(promises) do
        if not Promise.is(promise) then
            error(string.format(ErrorNonPromiseInList, "Promise.race", tostring(index)), 2)
        end
    end

    return Promise._new(
        debug.traceback(nil, 2),
        function(resolve, reject, onCancel)
            local childPromises = {}
            local finished = false

            local function cancelChildren()
                for _, childPromise in ipairs(childPromises) do
                    childPromise:cancel()
                end
            end

            local function finish(callback, ...)
                if finished then
                    return
                end

                finished = true
                callback(...)
                cancelChildren()
            end

            onCancel(function()
                finished = true
                cancelChildren()
            end)

            for index, promise in ipairs(promises) do
                childPromises[index] = promise:andThen(
                    function(...)
                        finish(resolve, ...)
                        return nil
                    end,

                    function(...)
                        finish(reject, ...)
                        return nil
                    end
                )
            end
        end
    )
end

---Iterates over an array sequentially.
---
---If the predicate returns a Promise, iteration waits for it before continuing.
---@generic T, U
---@param list T[]
---@param predicate fun(value: T, index: number): U | PromiseObject<U> | nil
---@return PromiseObject<U[]>
function Promise.each(list, predicate)
    if type(list) ~= "table" then
        error(string.format(ErrorNonList, "Promise.each"), 2)
    end

    if not isCallable(predicate) then
        error(string.format(ErrorNonFunction, "Promise.each"), 2)
    end

    return Promise._new(
        debug.traceback(nil, 2),
        function(resolve, reject, onCancel)
            local results = {}
            local childPromises = {}
            local cancelled = false

            local function cancelChildren()
                for _, childPromise in ipairs(childPromises) do
                    childPromise:cancel()
                end
            end

            onCancel(function()
                cancelled = true
                cancelChildren()
            end)

            for index, value in ipairs(list) do
                if cancelled then
                    return
                end

                local valuePromise = Promise.resolve(value)

                table.insert(
                    childPromises,
                    valuePromise
                )

                local success, resolvedValue = valuePromise:await()

                if not success then
                    cancelChildren()
                    reject(resolvedValue)
                    return
                end

                if cancelled then
                    return
                end

                local predicatePromise = Promise.try(
                    predicate,
                    resolvedValue,
                    index
                )

                table.insert(
                    childPromises,
                    predicatePromise
                )

                local predicateSuccess, result =
                    predicatePromise:await()

                if not predicateSuccess then
                    cancelChildren()
                    reject(result)
                    return
                end

                results[index] = result
            end

            if not cancelled then
                resolve(results)
            end
        end
    )
end

-- Promise inspection and conversion

---Checks whether a value behaves like a Promise.
---
---This intentionally uses duck typing so compatible Promise implementations
---can be consumed by this library.
---@param object any
---@return boolean
function Promise.is(object)
    if type(object) ~= "table" then
        return false
    end

    if getmetatable(object) == PromiseObject then
        return true
    end

    local metatable = getmetatable(object)

    if metatable == nil then
        return isCallable(object.andThen)
    end

    if type(metatable) == "table" then
        local index = rawget(metatable, "__index")

        if type(index) == "table" then
            return isCallable(rawget(index, "andThen"))
        end
    end

    return false
end

---Wraps a yielding function in a Promise-returning function.
---@generic T
---@param callback fun(...: any): T
---@return fun(...: any): PromiseObject<T>
function Promise.promisify(callback)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise.promisify"), 2)
    end

    return function(...)
        return Promise.try(
            callback,
            ...
        )
    end
end

-- Timers

---Creates a Promise that resolves after a number of seconds.
---
---The returned value is the actual elapsed time.
---@param seconds number
---@return PromiseObject<number>
function Promise.delay(seconds)
    if type(seconds) ~= "number" then
        error("Bad argument #1 to Promise.delay: must be a number", 2)
    end

    if seconds ~= seconds or seconds == math.huge or seconds < 1 / 60 then
        seconds = 1 / 60
    end

    return Promise._new(
        debug.traceback(nil, 2),

        function(resolve, _, onCancel)
            local startTime = Promise._getTime()

            local timerId = Timer.SetTimeout(function()
                resolve(
                    Promise._getTime() - startTime
                )
            end, seconds * 1000)

            onCancel(function()
                Timer.ClearTimeout(timerId)
            end)
        end
    )
end

Promise._getTime = os.clock

---Creates a Promise that rejects if this Promise does not resolve in time.
---
---The original Promise is cancelled when the timeout wins.
---@generic T
---@param seconds number
---@param rejectionValue? any
---@return PromiseObject<T>
function PromiseObject:timeout(seconds, rejectionValue)
    if type(seconds) ~= "number" then
        error("Bad argument #1 to Promise:timeout: must be a number", 2)
    end

    local traceback = debug.traceback(nil, 2)

    return Promise.race({
        Promise.delay(seconds):andThen(function()
            return Promise.reject(
                rejectionValue ~= nil and rejectionValue or Error.new({
                    kind = Error.Kind.TimedOut,
                    error = "Promise timed out.",
                    context = string.format("Timeout of %s seconds exceeded.\n\n:timeout() was called at:\n\n%s", tostring(seconds), traceback),
                })
            )
        end),

        self,
    })
end

-- Promise instance API

---Returns the current Promise status.
---@return PromiseStatusKind
function PromiseObject:getStatus()
    return self._status
end

---Chains handlers onto this Promise.
---@generic U
---@param successHandler? fun(...: any): U | PromiseObject<U> | nil
---@param failureHandler? fun(...: any): U | PromiseObject<U> | nil
---@return PromiseObject<U>
function PromiseObject:andThen(successHandler, failureHandler)
    if successHandler ~= nil and not isCallable(successHandler) then
        error(string.format(ErrorNonFunction, "Promise:andThen"), 2)
    end

    if failureHandler ~= nil and not isCallable(failureHandler) then
        error(string.format(ErrorNonFunction, "Promise:andThen"), 2)
    end

    return self:_andThen(
        debug.traceback(nil, 2),
        successHandler,
        failureHandler
    )
end

---Internal implementation of `Promise:andThen`.
---@private
function PromiseObject:_andThen(traceback, successHandler, failureHandler)
    self._unhandledRejection = false

    if self._status == Promise.Status.Cancelled then
        local cancelledPromise = Promise.new(function() end)
        cancelledPromise:cancel()
        return cancelledPromise
    end

    return Promise._new(
        traceback,
        function(resolve, reject, onCancel)
            local successCallback = resolve

            if successHandler then
                successCallback = createAdvancer(traceback, successHandler, resolve, reject)
            end

            local failureCallback = reject

            if failureHandler then
                failureCallback = createAdvancer(traceback, failureHandler, resolve, reject)
            end

            if self._status == Promise.Status.Started then
                table.insert(self._queuedResolve, successCallback)
                table.insert(self._queuedReject, failureCallback)

                onCancel(function()
                    local resolveIndex = tableFind(self._queuedResolve, successCallback)

                    if resolveIndex then
                        table.remove(self._queuedResolve, resolveIndex)
                    end

                    local rejectIndex = tableFind(self._queuedReject, failureCallback)

                    if rejectIndex then
                        table.remove(self._queuedReject, rejectIndex)
                    end
                end)
            elseif self._status == Promise.Status.Resolved then
                successCallback(unpack(self._values, 1, self._valuesLength))
            elseif self._status == Promise.Status.Rejected then
                failureCallback(unpack(self._values, 1, self._valuesLength))
            end
        end,

        self
    )
end

---Shorthand for `Promise:andThen(nil, failureHandler)`.
---@generic U
---@param failureHandler? fun(...: any): U | PromiseObject<U> | nil
---@return PromiseObject<U>
function PromiseObject:catch(failureHandler)
    if failureHandler ~= nil and not isCallable(failureHandler) then
        error(string.format(ErrorNonFunction, "Promise:catch"), 2)
    end

    return self:_andThen(debug.traceback(nil, 2), nil, failureHandler)
end

---Runs a side-effect handler while preserving the original resolved value.
---@generic T
---@param tapHandler fun(...: any): ...any
---@return PromiseObject<T>
function PromiseObject:tap(tapHandler)
    if not isCallable(tapHandler) then
        error(string.format(ErrorNonFunction, "Promise:tap"), 2)
    end

    return self:_andThen(
        debug.traceback(nil, 2),
        function(...)
            local length, values = pack(...)
            local callbackReturn = tapHandler(unpack(values, 1, length))

            if Promise.is(callbackReturn) then
                return callbackReturn:andThen(function()
                    return unpack(values, 1, length)
                end)
            end

            return unpack(values, 1, length)
        end
    )
end

---Calls a callback with predefined arguments after resolution.
---@param callback fun(...: any): any
---@param ... any
---@return PromiseObject<any>
function PromiseObject:andThenCall(callback, ...)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise:andThenCall"), 2)
    end

    local length, values = pack(...)

    return self:_andThen(
        debug.traceback(nil, 2),

        function()
            return callback(unpack(values, 1, length))
        end
    )
end

---Discards the resolved value and resolves with the provided values.
---@param ... any
---@return PromiseObject<any>
function PromiseObject:andThenReturn(...)
    local length, values = pack(...)

    return self:_andThen(
        debug.traceback(nil, 2),

        function()
            return unpack(values, 1, length)
        end
    )
end

-- Cancellation

---Cancels this Promise.
---
---Cancellation does nothing once the Promise has already settled.
function PromiseObject:cancel()
    if self._status ~= Promise.Status.Started then
        return
    end

    self._status = Promise.Status.Cancelled

    local cancellationHook = self._cancellationHook
    self._cancellationHook = nil

    if cancellationHook then
        local success, err = pcall(cancellationHook)

        if not success then
            Console.Error("[Morax-utils] Promise cancellation hook failed: " .. tostring(err))
        end
    end

    if self._parent then
        self._parent:_consumerCancelled(self)
        self._parent = nil
    end

    if self._consumers then
        local consumers = self._consumers
        self._consumers = {}

        for child in pairs(consumers) do
            child:cancel()
        end
    end

    closeThread(self._thread)

    self:_finalize()
end

---Called when a child Promise no longer consumes this Promise.
---@private
---@param consumer PromiseObject<any>
function PromiseObject:_consumerCancelled(consumer)
    if self._status ~= Promise.Status.Started then
        return
    end

    if self._consumers then
        self._consumers[consumer] = nil

        if next(self._consumers) == nil then
            self:cancel()
        end
    end
end

-- Finally

---Internal implementation of `Promise:finally`.
---@private
---@param traceback string
---@param finallyHandler? function
---@return PromiseObject<any>
function PromiseObject:_finally(traceback, finallyHandler)
    self._unhandledRejection = false

    return Promise._new(
        traceback,
        function(resolve, reject, onCancel)
            local handlerPromise

            onCancel(function()
                self:_consumerCancelled(self)

                if handlerPromise then
                    handlerPromise:cancel()
                end
            end)

            local finallyCallback = resolve

            if finallyHandler then
                finallyCallback = function(status)
                    local callbackReturn = finallyHandler(status)

                    if Promise.is(callbackReturn) then
                        handlerPromise = callbackReturn

                        callbackReturn
                            :andThen(function()
                                resolve(self)
                            end)
                            :catch(function(...)
                                reject(...)
                            end)
                    else
                        resolve(self)
                    end
                end
            end

            if self._status == Promise.Status.Started then
                table.insert(self._queuedFinally, finallyCallback)
            else
                finallyCallback(self._status)
            end
        end,

        self
    )
end

---Runs a handler regardless of whether the Promise resolves, rejects or cancels.
---@param finallyHandler? fun(status: PromiseStatusKind): any | nil
---@return PromiseObject<any>
function PromiseObject:finally(finallyHandler)
    if finallyHandler ~= nil and not isCallable(finallyHandler) then
        error(string.format(ErrorNonFunction, "Promise:finally"), 2)
    end

    return self:_finally(debug.traceback(nil, 2), finallyHandler)
end

---Runs a callback with predefined arguments during finalization.
---@param callback fun(...: any): any
---@param ... any
---@return PromiseObject<any>
function PromiseObject:finallyCall(callback, ...)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise:finallyCall"), 2)
    end

    local length, values = pack(...)

    return self:_finally(
        debug.traceback(nil, 2),
        function()
            return callback(unpack(values, 1, length))
        end
    )
end

---Runs finalization and resolves with the provided values.
---@param ... any
---@return PromiseObject<any>
function PromiseObject:finallyReturn(...)
    local length, values = pack(...)

    return self:_finally(
        debug.traceback(nil, 2),
        function()
            return unpack(values, 1, length)
        end
    )
end

-- Awaiting

---Yields until the Promise settles.
---
---Returns the final status followed by the Promise values.
---@generic T
---@return PromiseStatusKind status
---@return any ...
function PromiseObject:awaitStatus()
    self._unhandledRejection = false

    if self._status == Promise.Status.Started then
        local thread = coroutine.running()

        if not thread then
            error("Promise:awaitStatus() cannot be called outside of a coroutine", 2)
        end

        local resumePromise = self:finally(function()
            if coroutine.status(thread) == "suspended" then
                coroutine.resume(thread)
            end
        end)

        resumePromise:catch(function()
            -- The original Promise result is handled below.
        end)

        coroutine.yield()
    end

    if self._status == Promise.Status.Resolved then
        return self._status, unpack(self._values, 1, self._valuesLength)
    end

    if self._status == Promise.Status.Rejected then
        return self._status, unpack(self._values, 1, self._valuesLength)
    end

    return self._status
end

---Yields until the Promise settles.
---
---Returns `true` followed by the resolved values, or `false` followed by
---the rejected values.
---
---Cancellation also returns `false`. Use `awaitStatus()` when cancellation
---must be distinguished from rejection.
---@generic T
---@return boolean success
---@return any ...
function PromiseObject:await()
    local results = table.pack(self:awaitStatus())
    local status = results[1]

    return status == Promise.Status.Resolved, unpack(results, 2, results.n)
end

---Yields until the Promise resolves.
---
---Throws if the Promise rejects or is cancelled.
---@generic T
---@return any ...
function PromiseObject:expect()
    local results = table.pack(self:awaitStatus())
    local status = results[1]

    if status ~= Promise.Status.Resolved then
        error(results[2] ~= nil and results[2] or "Expected Promise to resolve.", 3)
    end

    return unpack(results, 2, results.n)
end

PromiseObject.awaitValue = PromiseObject.expect

---Returns the settled values without yielding.
---
---Primarily intended for tests.
---@return boolean success
---@return any ...
function PromiseObject:_unwrap()
    if self._status == Promise.Status.Started then
        error("Promise has not resolved or rejected.", 2)
    end

    return self._status == Promise.Status.Resolved, unpack(self._values, 1, self._valuesLength)
end

-- Resolution / rejection

---Resolves this Promise.
---@private
function PromiseObject:_resolve(...)
    if self._status ~= Promise.Status.Started then
        local value = ...

        if Promise.is(value) then
            value:_consumerCancelled(self)
        end

        return
    end

    local value = ...

    if Promise.is(value) then
        if select("#", ...) > 1 then
            Console.Warn(string.format("Returning a Promise from a Promise handler discards extra values.\n\nPromise created at:\n\n%s", self._source))
        end

        local chainedPromise = value

        local adoptionPromise = chainedPromise:andThen(
            function(...)
                self:_resolve(...)
            end,

            function(...)
                self:_reject(...)
            end
        )

        if adoptionPromise._status == Promise.Status.Cancelled then
            self:cancel()
        elseif adoptionPromise._status == Promise.Status.Started then
            self._parent = adoptionPromise
            adoptionPromise._consumers[self] = true
        end

        return
    end

    self._status = Promise.Status.Resolved
    self._valuesLength, self._values = pack(...)

    local callbacks = self._queuedResolve

    for _, callback in ipairs(callbacks) do
        coroutine.wrap(callback)(...)
    end

    self:_finalize()
end

---Rejects this Promise.
---@private
function PromiseObject:_reject(...)
    if self._status ~= Promise.Status.Started then
        return
    end

    self._status = Promise.Status.Rejected
    self._valuesLength, self._values = pack(...)

    if #self._queuedReject == 0 then
        local values = self._values
        local valuesLength = self._valuesLength
        local source = self._source

        Timer.SetTimeout(function()
            if not self._unhandledRejection then
                return
            end

            local message = string.format("Unhandled Promise rejection:\n\n%s\n\n%s", tostring(values[1]), source)

            for _, callback in ipairs(Promise._unhandledRejectionCallbacks) do
                local success, callbackError = pcall(callback, self, unpack(values, 1, valuesLength))

                if not success then
                    Console.Error("[Morax-utils] Error in Promise.onUnhandledRejection callback: " .. tostring(callbackError))
                end
            end

            if Promise.TEST then
                return
            end

            Console.Warn(message)
        end, 0)
    else
        local callbacks = self._queuedReject

        for _, callback in ipairs(callbacks) do
            coroutine.wrap(callback)(...)
        end
    end

    self:_finalize()
end

---Finalizes a settled Promise and runs all finally handlers.
---@private
function PromiseObject:_finalize()
    if self._finalized then
        return
    end

    self._finalized = true

    local finallyCallbacks = self._queuedFinally

    for _, callback in ipairs(finallyCallbacks) do
        coroutine.wrap(callback)(self._status)
    end

    self._queuedFinally = {}
    self._queuedReject = {}
    self._queuedResolve = {}
    self._cancellationHook = nil

    self._parent = nil
    self._consumers = {}

    closeThread(self._thread)
end

-- Utility instance methods

---Returns a new Promise that resolves immediately if this Promise is already resolved.
---
---Otherwise the returned Promise rejects with `rejectionValue`.
---@param rejectionValue? any
---@return PromiseObject<any>
function PromiseObject:now(rejectionValue)
    local traceback = debug.traceback(nil, 2)

    if self._status == Promise.Status.Resolved then
        return self:_andThen(
            traceback,

            function(...)
                return ...
            end
        )
    end

    return Promise.reject(
        rejectionValue ~= nil and rejectionValue or Error.new({
            kind = Error.Kind.NotResolvedInTime,
            error = "This Promise was not resolved in time for :now().",
            context = ":now() was called at:\n\n" .. traceback,
        })
    )
end

-- Retry

---Retries a Promise-returning callback.
---@generic T
---@param callback fun(...: any): T | PromiseObject<T>
---@param times number
---@param ... any
---@return PromiseObject<T>
function Promise.retry(callback, times, ...)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise.retry"), 2)
    end

    if type(times) ~= "number" then
        error("Parameter #2 to Promise.retry must be a number", 2)
    end

    times = math.max(0, math.floor(times))

    local length, values = pack(...)

    local function attempt(remaining)
        return Promise.try(
            callback,
            unpack(values, 1, length)
        ):catch(function(...)
            if remaining > 0 then
                return attempt(remaining - 1)
            end

            return Promise.reject(...)
        end)
    end

    return attempt(times)
end

---Retries a callback with a delay between attempts.
---@generic T
---@param callback fun(...: any): T | PromiseObject<T>
---@param times number
---@param seconds number
---@param ... any
---@return PromiseObject<T>
function Promise.retryWithDelay(callback, times, seconds, ...)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise.retryWithDelay"), 2)
    end

    if type(times) ~= "number" then
        error("Parameter #2 to Promise.retryWithDelay must be a number", 2)
    end

    if type(seconds) ~= "number" then
        error("Parameter #3 to Promise.retryWithDelay must be a number", 2)
    end

    times = math.max(0, math.floor(times))

    local length, values = pack(...)

    local function attempt(remaining)
        return Promise.try(
            callback,
            unpack(values, 1, length)
        ):catch(function(...)
            if remaining <= 0 then
                return Promise.reject(...)
            end

            return Promise.delay(seconds):andThen(function()
                return attempt(remaining - 1)
            end)
        end)
    end

    return attempt(times)
end

-- Nanos World event helpers

---Creates a Promise that resolves the next time an event fires.
---
---This generic helper allows any Nanos World event API to be used.
---@generic T
---@param subscribe fun(callback: fun(...: any))
---@param unsubscribe fun(callback: fun(...: any))
---@param predicate? fun(...: any): boolean
---@return PromiseObject<T>
function Promise.fromEvent(
    subscribe,
    unsubscribe,
    predicate
)
    if not isCallable(subscribe) then
        error("Bad argument #1 to Promise.fromEvent: must be a function", 2)
    end

    if not isCallable(unsubscribe) then
        error("Bad argument #2 to Promise.fromEvent: must be a function", 2)
    end

    if predicate ~= nil and not isCallable(predicate) then
        error("Bad argument #3 to Promise.fromEvent: must be a function or nil", 2)
    end

    predicate = predicate or function()
        return true
    end

    return Promise._new(
        debug.traceback(nil, 2),
        function(resolve, reject, onCancel)
            local callback
            local disconnected = false

            local function disconnect()
                if disconnected or callback == nil then
                    return
                end

                disconnected = true

                local success, err = pcall(
                    unsubscribe,
                    callback
                )

                if not success then
                    Console.Error("[Morax-utils] Failed to unsubscribe Promise.fromEvent: " .. tostring(err))
                end

                callback = nil
            end

            callback = function(...)
                if disconnected then
                    return
                end

                local success, predicateResult = pcall(
                    predicate,
                    ...
                )

                if not success then
                    disconnect()
                    reject(
                        Error.new({
                            error = predicateResult,
                            kind = Error.Kind.ExecutionError,
                            trace = debug.traceback(tostring(predicateResult), 2),
                            context = "Promise.fromEvent predicate failed.",
                        })
                    )

                    return
                end

                if type(predicateResult) ~= "boolean" then
                    disconnect()
                    reject(
                        Error.new({
                            error = "Promise.fromEvent predicate must return a boolean.",
                            kind = Error.Kind.ExecutionError,
                        })
                    )

                    return
                end

                if predicateResult then
                    resolve(...)
                    disconnect()
                end
            end

            local success, subscribeError = pcall(
                subscribe,
                callback
            )

            if not success then
                callback = nil

                reject(
                    Error.new({
                        error = subscribeError,
                        kind = Error.Kind.ExecutionError,
                        trace = debug.traceback(tostring(subscribeError), 2),
                        context = "Promise.fromEvent subscription failed.",
                    })
                )

                return
            end

            onCancel(disconnect)
        end
    )
end

---Creates a Promise from a static Nanos World event.
---
---Uses `Events.Subscribe` and `Events.Unsubscribe`.
---@generic T
---@param eventName string
---@param predicate? fun(...: any): boolean
---@return PromiseObject<T>
function Promise.fromNanosEvent(
    eventName,
    predicate
)
    if type(eventName) ~= "string" then
        error("Bad argument #1 to Promise.fromNanosEvent: must be a string", 2)
    end

    return Promise.fromEvent(
        function(callback)
            Events.Subscribe(eventName, callback)
        end,

        function(callback)
            Events.Unsubscribe(eventName, callback)
        end,

        predicate
    )
end

---Creates a Promise from a static Nanos World remote event.
---
---Uses `Events.SubscribeRemote` and `Events.UnsubscribeRemote`.
---@generic T
---@param eventName string
---@param predicate? fun(...: any): boolean
---@return PromiseObject<T>
function Promise.fromRemoteNanosEvent(
    eventName,
    predicate
)
    if type(eventName) ~= "string" then
        error("Bad argument #1 to Promise.fromRemoteNanosEvent: must be a string", 2)
    end

    return Promise.fromEvent(
        function(callback)
            Events.SubscribeRemote(eventName, callback)
        end,

        function(callback)
            Events.UnsubscribeRemote(eventName, callback)
        end,

        predicate
    )
end

---Creates a Promise from an Entity event.
---
---Uses `Entity:Subscribe` and `Entity:Unsubscribe`.
---@generic T
---@param entity any
---@param eventName string
---@param predicate? fun(...: any): boolean
---@return PromiseObject<T>
function Promise.fromEntityEvent(
    entity,
    eventName,
    predicate
)
    if entity == nil then
        error("Bad argument #1 to Promise.fromEntityEvent: entity cannot be nil", 2)
    end

    if type(eventName) ~= "string" then
        error("Bad argument #2 to Promise.fromEntityEvent: must be a string", 2)
    end

    if type(entity.Subscribe) ~= "function"
        or type(entity.Unsubscribe) ~= "function"
    then
        error("Bad argument #1 to Promise.fromEntityEvent: entity does not support Subscribe/Unsubscribe", 2)
    end

    return Promise.fromEvent(
        function(callback)
            entity:Subscribe(eventName, callback)
        end,

        function(callback)
            entity:Unsubscribe(eventName, callback)
        end,

        predicate
    )
end

---Creates a Promise from an Entity remote event.
---
---Uses `Entity:SubscribeRemote` and `Entity:Unsubscribe`.
---@generic T
---@param entity any
---@param eventName string
---@param predicate? fun(...: any): boolean
---@return PromiseObject<T>
function Promise.fromRemoteEvent(
    entity,
    eventName,
    predicate
)
    if entity == nil then
        error("Bad argument #1 to Promise.fromRemoteEvent: entity cannot be nil", 2)
    end

    if type(eventName) ~= "string" then
        error("Bad argument #2 to Promise.fromRemoteEvent: must be a string", 2)
    end

    if type(entity.SubscribeRemote) ~= "function" or type(entity.Unsubscribe) ~= "function" then
        error("Bad argument #1 to Promise.fromRemoteEvent: entity does not support remote event subscriptions", 2)
    end

    return Promise.fromEvent(
        function(callback)
            entity:SubscribeRemote(eventName, callback)
        end,

        function(callback)
            entity:Unsubscribe(eventName, callback)
        end,

        predicate
    )
end

-- Unhandled rejections

---Registers a callback for unhandled Promise rejections.
---
---The returned function removes the callback.
---@param callback fun(promise: PromiseObject<any>, ...: any)
---@return fun()
function Promise.onUnhandledRejection(callback)
    if not isCallable(callback) then
        error(string.format(ErrorNonFunction, "Promise.onUnhandledRejection"), 2)
    end

    table.insert(
        Promise._unhandledRejectionCallbacks,
        callback
    )

    local removed = false

    return function()
        if removed then
            return
        end

        removed = true

        local index = tableFind(
            Promise._unhandledRejectionCallbacks,
            callback
        )

        if index then
            table.remove(
                Promise._unhandledRejectionCallbacks,
                index
            )
        end
    end
end

-- Internal state

Promise._unhandledRejectionCallbacks = {}
Promise._getTime = os.clock

-- My registration

MoraxUtils = MoraxUtils or {}
MoraxUtils.Promise = Promise

return Promise
