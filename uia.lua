local launchArgs = { ... }
local launchOptions = type(launchArgs[1]) == "table" and launchArgs[1] or nil

local DEFAULT_CONFIG = {
    lockKey = "__MINHHIEUHUB_BOOTSTRAP_LOCK_V1",
    chunkName = "@MinhHieuHub_Core",
    maxRetries = 3,
    baseRetryDelay = 1.5,
    maxRetryDelay = 8.0,
    gameLoadTimeout = 15.0,
    minPayloadLength = 8,
    shiftKey = 7,
    preventDuplicateRun = true,
    silentSuccess = true,
    segA = {
        111, 123, 123, 119, 122, 65, 54, 54, 121, 104, 126, 53,
        110, 112, 123, 111, 124, 105, 124, 122, 108, 121, 106, 118,
        117, 123, 108, 117, 123, 53, 106, 118, 116, 54
    },
    segB = {
        123, 121, 104, 117, 111, 124, 128, 114, 111, 104, 117, 110,
        58, 56, 55, 58, 57, 55, 56, 58, 52, 114, 118, 118,
        106, 105, 112, 108, 123, 54, 106, 111, 124, 118, 112, 102,
        116, 104, 111, 118, 104, 53, 115, 124, 104, 54
    },
    segC = {
        121, 108, 109, 122, 54, 111, 108, 104, 107, 122, 54, 116,
        104, 112, 117, 54, 115, 118, 104, 107, 108, 121, 102, 116,
        112, 117, 111, 111, 112, 108, 124, 111, 124, 105, 53, 115,
        124, 104
    }
}

local function mergeTables(base, override)
    local result = {}
    if type(base) == "table" then
        for k, v in pairs(base) do
            result[k] = v
        end
    end
    if type(override) == "table" then
        for k, v in pairs(override) do
            result[k] = v
        end
    end
    return result
end

local function createBootstrap(customConfig, customEnv)
    local config = mergeTables(DEFAULT_CONFIG, customConfig)
    local env = customEnv or _G

    local function getApi(name)
        if customEnv ~= nil then
            return customEnv[name]
        end
        if name == "game" then return game end
        if name == "task" then return task end
        if name == "wait" then return wait end
        if name == "loadstring" then return loadstring end
        if name == "getgenv" then return getgenv end
        if name == "_G" then return _G end
        if name == "pcall" then return pcall end
        if name == "xpcall" then return xpcall end
        if name == "warn" then return warn end
        if name == "type" then return type end
        if name == "tostring" then return tostring end
        if name == "string" then return string end
        if name == "table" then return table end
        if name == "math" then return math end
        if name == "os" then return os end
        if name == "tick" then return tick end
        return nil
    end

    local pcallFn = getApi("pcall") or pcall
    local xpcallFn = getApi("xpcall") or xpcall
    local typeFn = getApi("type") or type
    local tostringFn = getApi("tostring") or tostring
    local stringLib = getApi("string") or string
    local tableLib = getApi("table") or table
    local mathLib = getApi("math") or math
    local warnFn = getApi("warn")

    local function sanitizeMessage(rawMsg)
        if typeFn(rawMsg) ~= "string" then
            return "Unknown runtime error"
        end
        local redacted = stringLib.gsub(rawMsg, "https?://[^%s\"'<>]+", "[REDACTED_URL]")
        redacted = stringLib.gsub(redacted, "githubusercontent%.com[^%s\"'<>]*", "[REDACTED_HOST]")
        if #redacted > 200 then
            redacted = stringLib.sub(redacted, 1, 200) .. "..."
        end
        return redacted
    end

    local function logDiagnostic(code, detail)
        if typeFn(warnFn) == "function" then
            local safeDetail = sanitizeMessage(tostringFn(detail or ""))
            pcallFn(warnFn, "[Bootstrap:" .. tostringFn(code) .. "] " .. safeDetail)
        end
    end

    local function resolveClock()
        local osLib = getApi("os")
        if typeFn(osLib) == "table" and typeFn(osLib.clock) == "function" then
            return osLib.clock
        end
        local tickFn = getApi("tick")
        if typeFn(tickFn) == "function" then
            return tickFn
        end
        if typeFn(osLib) == "table" and typeFn(osLib.time) == "function" then
            return osLib.time
        end
        return nil
    end

    local function resolveWait()
        local taskLib = getApi("task")
        if typeFn(taskLib) == "table" and typeFn(taskLib.wait) == "function" then
            return taskLib.wait
        end
        local legacyWait = getApi("wait")
        if typeFn(legacyWait) == "function" then
            return legacyWait
        end
        return nil
    end

    local function resolveGlobalStore()
        local getgenvFn = getApi("getgenv")
        if typeFn(getgenvFn) == "function" then
            local ok, genv = pcallFn(getgenvFn)
            if ok and typeFn(genv) == "table" then
                return genv
            end
        end
        local sharedG = getApi("_G")
        if typeFn(sharedG) == "table" then
            return sharedG
        end
        if typeFn(env) == "table" then
            return env
        end
        return nil
    end

    local resources = {
        connections = {},
        tasks = {},
        instances = {},
        cleanups = {},
        isCleaned = false,
        isCleaning = false
    }

    local state = {
        status = "IDLE",
        aborted = false,
        lastErrorCode = nil,
        lastErrorMessage = nil,
        lockAcquired = false
    }

    local function trackConnection(conn)
        if conn == nil or resources.isCleaned then
            return conn
        end
        resources.connections[#resources.connections + 1] = conn
        return conn
    end

    local function trackTask(threadObj)
        if threadObj == nil or resources.isCleaned then
            return threadObj
        end
        resources.tasks[#resources.tasks + 1] = threadObj
        return threadObj
    end

    local function trackInstance(inst)
        if inst == nil or resources.isCleaned then
            return inst
        end
        resources.instances[#resources.instances + 1] = inst
        return inst
    end

    local function trackCleanup(fn)
        if typeFn(fn) ~= "function" or resources.isCleaned then
            return
        end
        resources.cleanups[#resources.cleanups + 1] = fn
    end

    local function releaseLock(finalStatus)
        if not state.lockAcquired then
            return
        end
        local store = resolveGlobalStore()
        if typeFn(store) == "table" then
            local currentLock = store[config.lockKey]
            if typeFn(currentLock) == "table" then
                currentLock.active = false
                currentLock.status = finalStatus or state.status
            end
        end
        state.lockAcquired = false
    end

    local function cleanupResources()
        if resources.isCleaning or resources.isCleaned then
            return true
        end
        resources.isCleaning = true

        for i = #resources.cleanups, 1, -1 do
            local fn = resources.cleanups[i]
            resources.cleanups[i] = nil
            if typeFn(fn) == "function" then
                pcallFn(fn)
            end
        end

        for i = #resources.connections, 1, -1 do
            local conn = resources.connections[i]
            resources.connections[i] = nil
            if conn ~= nil then
                pcallFn(function()
                    if typeFn(conn) == "table" or typeFn(conn) == "userdata" then
                        if conn.Disconnect then
                            conn:Disconnect()
                        elseif conn.disconnect then
                            conn:disconnect()
                        end
                    end
                end)
            end
        end

        local taskLib = getApi("task")
        local cancelFn = typeFn(taskLib) == "table" and taskLib.cancel or nil
        for i = #resources.tasks, 1, -1 do
            local threadObj = resources.tasks[i]
            resources.tasks[i] = nil
            if threadObj ~= nil and typeFn(cancelFn) == "function" then
                pcallFn(cancelFn, threadObj)
            end
        end

        for i = #resources.instances, 1, -1 do
            local inst = resources.instances[i]
            resources.instances[i] = nil
            if inst ~= nil then
                pcallFn(function()
                    if typeFn(inst) == "table" or typeFn(inst) == "userdata" then
                        if inst.Destroy then
                            inst:Destroy()
                        elseif inst.destroy then
                            inst:destroy()
                        end
                    end
                end)
            end
        end

        resources.isCleaned = true
        resources.isCleaning = false
        return true
    end

    local function shutdown()
        state.aborted = true
        state.status = "STOPPED"
        cleanupResources()
        releaseLock("STOPPED")
        return true
    end

    local function failBootstrap(code, message)
        state.status = "FAILED"
        state.lastErrorCode = code
        state.lastErrorMessage = sanitizeMessage(message)
        cleanupResources()
        releaseLock("FAILED")
        logDiagnostic(code, state.lastErrorMessage)
        return {
            success = false,
            code = code,
            message = state.lastErrorMessage,
            status = state.status
        }
    end

    local function acquireLock()
        local store = resolveGlobalStore()
        if typeFn(store) ~= "table" then
            return false, "ERR_ENV_STORE", "Global state container is unavailable"
        end

        local existing = store[config.lockKey]
        if config.preventDuplicateRun and typeFn(existing) == "table" and existing.active == true then
            return false, "ERR_ALREADY_ACTIVE", "Bootstrap or runtime instance is already active"
        end

        store[config.lockKey] = {
            active = true,
            status = "STARTING",
            shutdown = shutdown
        }
        state.lockAcquired = true
        state.status = "STARTING"
        return true
    end

    local function validateCapabilities()
        if typeFn(pcallFn) ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Missing required primitive: pcall"
        end

        if typeFn(stringLib) ~= "table" or typeFn(stringLib.char) ~= "function" or typeFn(stringLib.sub) ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Missing required library: string"
        end

        if typeFn(tableLib) ~= "table" or typeFn(tableLib.concat) ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Missing required library: table.concat"
        end

        local loadstringFn = getApi("loadstring")
        if typeFn(loadstringFn) ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Environment does not support loadstring"
        end

        local waitFn = resolveWait()
        if typeFn(waitFn) ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Environment does not provide task.wait or wait"
        end

        local gameObj = getApi("game")
        local gameType = typeFn(gameObj)
        if gameObj == nil or (gameType ~= "userdata" and gameType ~= "table") then
            return false, "ERR_CAPABILITY_MISSING", "Missing DataModel reference: game"
        end

        local hasHttpGetOk, httpGetType = pcallFn(function()
            return typeFn(gameObj.HttpGet)
        end)
        if not hasHttpGetOk or httpGetType ~= "function" then
            return false, "ERR_CAPABILITY_MISSING", "Environment does not support game:HttpGet"
        end

        return true, {
            game = gameObj,
            loadstring = loadstringFn,
            wait = waitFn,
            clock = resolveClock()
        }
    end

    local function prepareRuntime(caps)
        if state.aborted then
            return false, "ERR_ABORTED", "Bootstrap aborted during runtime preparation"
        end

        resources.isCleaned = false
        resources.isCleaning = false

        local gameObj = caps.game
        local hasIsLoaded, isLoadedVal = pcallFn(function()
            if typeFn(gameObj.IsLoaded) == "function" then
                return gameObj:IsLoaded()
            end
            return true
        end)

        if hasIsLoaded and isLoadedVal == false then
            local loadedResolved = false
            local tempConn = nil

            pcallFn(function()
                local loadedSignal = gameObj.Loaded
                if loadedSignal ~= nil and (typeFn(loadedSignal) == "userdata" or typeFn(loadedSignal) == "table") then
                    if typeFn(loadedSignal.Connect) == "function" then
                        tempConn = trackConnection(loadedSignal:Connect(function()
                            loadedResolved = true
                        end))
                    end
                end
            end)

            local elapsed = 0
            local step = 0.1
            local timeout = tonumber(config.gameLoadTimeout) or 15.0
            local clockFn = caps.clock
            local startTime = typeFn(clockFn) == "function" and clockFn() or nil

            while not loadedResolved and not state.aborted do
                local okNow, nowLoaded = pcallFn(function()
                    return gameObj:IsLoaded()
                end)
                if okNow and nowLoaded == true then
                    loadedResolved = true
                    break
                end

                if startTime ~= nil then
                    if (clockFn() - startTime) >= timeout then
                        break
                    end
                else
                    if elapsed >= timeout then
                        break
                    end
                end

                caps.wait(step)
                elapsed = elapsed + step
            end

            if tempConn ~= nil then
                pcallFn(function()
                    if tempConn.Disconnect then
                        tempConn:Disconnect()
                    elseif tempConn.disconnect then
                        tempConn:disconnect()
                    end
                end)
            end

            if state.aborted then
                return false, "ERR_ABORTED", "Bootstrap aborted while waiting for DataModel"
            end

            if not loadedResolved then
                return false, "ERR_PRECONDITION_TIMEOUT", "Timed out waiting for game:IsLoaded()"
            end
        end

        return true
    end

    local function decodeSegment(segment, shift)
        if typeFn(segment) ~= "table" or #segment == 0 then
            return nil
        end
        local chars = {}
        local charFn = stringLib.char
        for i = 1, #segment do
            local raw = segment[i]
            if typeFn(raw) ~= "number" then
                return nil
            end
            local code = raw - shift
            if code < 32 or code > 126 then
                return nil
            end
            chars[i] = charFn(code)
        end
        local str = tableLib.concat(chars)
        for i = 1, #chars do
            chars[i] = nil
        end
        return str
    end

    local function buildEndpoint()
        if typeFn(config.overrideEndpoint) == "string" and #config.overrideEndpoint > 0 then
            return config.overrideEndpoint
        end
        local shift = tonumber(config.shiftKey) or 7
        local part1 = decodeSegment(config.segA, shift)
        local part2 = decodeSegment(config.segB, shift)
        local part3 = decodeSegment(config.segC, shift)
        if not part1 or not part2 or not part3 then
            return nil
        end
        return part1 .. part2 .. part3
    end

    local function fetchPayload(caps)
        local endpoint = buildEndpoint()
        if typeFn(endpoint) ~= "string" or #endpoint < 12 then
            return false, "ERR_ENDPOINT_DECODE", "Failed to reconstruct remote endpoint"
        end

        local maxRetries = tonumber(config.maxRetries) or 3
        if maxRetries < 0 then maxRetries = 0 end
        if maxRetries > 5 then maxRetries = 5 end

        local baseDelay = tonumber(config.baseRetryDelay) or 1.5
        if baseDelay < 0.05 then baseDelay = 0.05 end
        local maxDelay = tonumber(config.maxRetryDelay) or 8.0

        local totalAttempts = maxRetries + 1
        local lastErr = "Unknown transport failure"

        for attempt = 1, totalAttempts do
            if state.aborted or resources.isCleaned then
                endpoint = nil
                return false, "ERR_ABORTED", "Bootstrap aborted during network fetch"
            end

            local ok, response = pcallFn(function()
                return caps.game:HttpGet(endpoint)
            end)

            if ok and typeFn(response) == "string" and #response > 0 then
                endpoint = nil
                return true, response
            end

            lastErr = sanitizeMessage(tostringFn(response))

            if attempt < totalAttempts then
                local multiplier = 2 ^ (attempt - 1)
                local waitTime = baseDelay * multiplier
                if waitTime > maxDelay then
                    waitTime = maxDelay
                end
                caps.wait(waitTime)
            end
        end

        endpoint = nil
        return false, "ERR_RETRY_EXHAUSTED", "Network fetch failed after " .. tostringFn(totalAttempts) .. " attempts: " .. lastErr
    end

    local function validateAndCompilePayload(caps, rawPayload)
        if typeFn(rawPayload) ~= "string" then
            return false, "ERR_PAYLOAD_TYPE", "Fetched payload is not a string"
        end

        local trimmed = stringLib.match(rawPayload, "^%s*(.-)%s*$") or ""
        local minLen = tonumber(config.minPayloadLength) or 8
        if #trimmed < minLen then
            return false, "ERR_PAYLOAD_EMPTY", "Fetched payload is empty or below minimum length"
        end

        local headerSample = stringLib.lower(stringLib.sub(trimmed, 1, 64))
        if stringLib.find(headerSample, "<!doctype", 1, true)
            or stringLib.find(headerSample, "<html", 1, true)
            or stringLib.find(headerSample, "404: not found", 1, true)
            or stringLib.find(headerSample, "400: invalid request", 1, true)
            or stringLib.find(headerSample, "500: internal server error", 1, true)
            or stringLib.find(headerSample, "rate limit", 1, true) then
            return false, "ERR_PAYLOAD_FORMAT", "Remote server returned an HTTP error page instead of Lua source"
        end

        local compileOk, compiledChunk, compileErr = pcallFn(caps.loadstring, rawPayload, config.chunkName)
        if not compileOk then
            return false, "ERR_PAYLOAD_SYNTAX", "loadstring invocation failed: " .. sanitizeMessage(tostringFn(compiledChunk))
        end

        if typeFn(compiledChunk) ~= "function" then
            return false, "ERR_PAYLOAD_SYNTAX", "Syntax error in payload: " .. sanitizeMessage(tostringFn(compileErr))
        end

        return true, compiledChunk
    end

    local function executeMainChunk(compiledChunk)
        if state.aborted or resources.isCleaned then
            return false, "ERR_ABORTED", "Bootstrap aborted prior to main execution"
        end

        state.status = "RUNNING"
        local store = resolveGlobalStore()
        if typeFn(store) == "table" and typeFn(store[config.lockKey]) == "table" then
            store[config.lockKey].status = "RUNNING"
        end

        local execOk, execResult
        if typeFn(xpcallFn) == "function" then
            execOk, execResult = xpcallFn(compiledChunk, function(err)
                return sanitizeMessage(tostringFn(err))
            end)
        else
            execOk, execResult = pcallFn(compiledChunk)
            if not execOk then
                execResult = sanitizeMessage(tostringFn(execResult))
            end
        end

        if not execOk then
            return false, "ERR_RUNTIME_EXECUTION", tostringFn(execResult)
        end

        return true, execResult
    end

    local function run()
        state.aborted = false
        state.lastErrorCode = nil
        state.lastErrorMessage = nil

        local lockOk, lockCode, lockMsg = acquireLock()
        if not lockOk then
            logDiagnostic(lockCode, lockMsg)
            return {
                success = false,
                code = lockCode,
                message = lockMsg,
                status = state.status
            }
        end

        local capOk, capsOrCode, capMsg = validateCapabilities()
        if not capOk then
            return failBootstrap(capsOrCode, capMsg)
        end
        local caps = capsOrCode

        local prepOk, prepCode, prepMsg = prepareRuntime(caps)
        if not prepOk then
            return failBootstrap(prepCode, prepMsg)
        end

        local fetchOk, payloadOrCode, fetchMsg = fetchPayload(caps)
        if not fetchOk then
            return failBootstrap(payloadOrCode, fetchMsg)
        end

        local validOk, chunkOrCode, validMsg = validateAndCompilePayload(caps, payloadOrCode)
        payloadOrCode = nil
        if not validOk then
            return failBootstrap(chunkOrCode, validMsg)
        end

        local execOk, resultOrCode, execMsg = executeMainChunk(chunkOrCode)
        chunkOrCode = nil
        if not execOk then
            return failBootstrap(resultOrCode, execMsg)
        end

        cleanupResources()

        return {
            success = true,
            code = "OK",
            result = resultOrCode,
            status = state.status,
            shutdown = shutdown
        }
    end

    return {
        run = run,
        shutdown = shutdown,
        cleanup = cleanupResources,
        trackConnection = trackConnection,
        trackTask = trackTask,
        trackInstance = trackInstance,
        trackCleanup = trackCleanup,
        getState = function()
            return {
                status = state.status,
                aborted = state.aborted,
                lastErrorCode = state.lastErrorCode,
                lastErrorMessage = state.lastErrorMessage,
                isCleaned = resources.isCleaned,
                activeConnections = #resources.connections,
                activeTasks = #resources.tasks,
                activeInstances = #resources.instances
            }
        end
    }
end

if launchOptions ~= nil then
    local instance = createBootstrap(launchOptions.config, launchOptions.env)
    if launchOptions.autoRun ~= false then
        return instance.run(), instance
    end
    return instance
end

local defaultBootstrap = createBootstrap()
return defaultBootstrap.run()
