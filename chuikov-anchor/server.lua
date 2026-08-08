local STATE_KEY = 'chuikov-anchor:anchored'
local REQUEST_EVENT = 'chuikov-anchor:server:setAnchored'
local CANCEL_EVENT = 'chuikov-anchor:server:cancelOperation'
local START_EVENT = 'chuikov-anchor:client:operationStarted'
local RESULT_EVENT = 'chuikov-anchor:client:result'
local PROXIMITY_SOUND_START_EVENT = 'chuikov-anchor:client:startProximitySound'
local PROXIMITY_SOUND_STOP_EVENT = 'chuikov-anchor:client:stopProximitySound'

local OPERATION_DURATION_MS = 5000
local OPERATION_CHECK_INTERVAL_MS = 250
local MAX_ANCHOR_SPEED_KMH = 13.0
local MAX_ANCHOR_HORIZONTAL_SPEED = MAX_ANCHOR_SPEED_KMH / 3.6
local REQUEST_COOLDOWN_MS = 250

local anchoredBoats = {}
local lastRequests = {}
local operationsByPlayer = {}
local operationsByVehicle = {}
local resourceStopping = false
local nextSoundToken = 0

local function sendResult(playerId, requestId, networkId, success, anchored, message)
    TriggerClientEvent(RESULT_EVENT, playerId, requestId, networkId, success, anchored, message)
end

local function isValidInteger(value, minimum, maximum)
    return type(value) == 'number'
        and value == value
        and value >= minimum
        and value <= maximum
        and value % 1 == 0
end

local function isBoat(vehicle)
    return vehicle ~= 0
        and DoesEntityExist(vehicle)
        and GetEntityType(vehicle) == 2
        and GetVehicleType(vehicle) == 'boat'
end

local function getHorizontalSpeed(vehicle)
    local velocity = GetEntityVelocity(vehicle)
    return math.sqrt(
        velocity.x * velocity.x
        + velocity.y * velocity.y
    )
end

local function isOperationCurrent(operation)
    return operationsByPlayer[operation.playerId] == operation
        and operationsByVehicle[operation.vehicle] == operation
end

local function clearOperation(operation)
    if operationsByPlayer[operation.playerId] == operation then
        operationsByPlayer[operation.playerId] = nil
    end

    if operationsByVehicle[operation.vehicle] == operation then
        operationsByVehicle[operation.vehicle] = nil
    end
end

local function syncOperationSoundRecipients(operation)
    if operation.soundStopped then
        return
    end

    local vehicleCoords = GetEntityCoords(operation.vehicle)
    local routingBucket = GetEntityRoutingBucket(operation.vehicle)
    local currentRecipients = {}

    operation.soundRecipients = operation.soundRecipients or {}

    for _, targetPlayer in ipairs(GetPlayers()) do
        local targetPlayerId = tonumber(targetPlayer)

        if targetPlayerId
            and GetPlayerRoutingBucket(targetPlayerId) == routingBucket
        then
            currentRecipients[targetPlayerId] = true

            if not operation.soundRecipients[targetPlayerId] then
                TriggerClientEvent(
                    PROXIMITY_SOUND_START_EVENT,
                    targetPlayerId,
                    operation.soundToken,
                    operation.networkId,
                    operation.shouldAnchor,
                    vehicleCoords.x,
                    vehicleCoords.y,
                    vehicleCoords.z,
                    OPERATION_DURATION_MS
                )
            end
        end
    end

    for targetPlayerId in pairs(operation.soundRecipients) do
        if not currentRecipients[targetPlayerId] then
            TriggerClientEvent(
                PROXIMITY_SOUND_STOP_EVENT,
                targetPlayerId,
                operation.soundToken
            )
        end
    end

    operation.soundRecipients = currentRecipients
end

local function startOperationSoundForNearbyPlayers(operation)
    operation.soundRecipients = {}
    syncOperationSoundRecipients(operation)
end

local function stopOperationSoundForNearbyPlayers(operation)
    if operation.soundStopped then
        return
    end

    operation.soundStopped = true

    for targetPlayerId in pairs(operation.soundRecipients or {}) do
        TriggerClientEvent(
            PROXIMITY_SOUND_STOP_EVENT,
            targetPlayerId,
            operation.soundToken
        )
    end
end

local function getOperationProblem(operation)
    local vehicle = operation.vehicle

    if NetworkGetEntityFromNetworkId(operation.networkId) ~= vehicle
        or not isBoat(vehicle)
    then
        return 'Tekne artık mevcut değil.'
    end

    local playerPed = GetPlayerPed(operation.playerId)

    if playerPed == 0
        or GetPedInVehicleSeat(vehicle, -1) ~= playerPed
    then
        return 'Demirleme işlemi iptal edildi: artık teknenin sürücüsü değilsin.'
    end

    local isAnchored = anchoredBoats[vehicle] == true

    if isAnchored ~= operation.wasAnchored then
        return 'Teknenin demir durumu işlem sırasında değişti.'
    end

    if operation.shouldAnchor
        and getHorizontalSpeed(vehicle) >= MAX_ANCHOR_HORIZONTAL_SPEED
    then
        return string.format(
            'Demir atma iptal edildi: hız %.0f km/sa sınırına ulaştı.',
            MAX_ANCHOR_SPEED_KMH
        )
    end
end

local function failOperation(operation, message)
    if not isOperationCurrent(operation) then
        return
    end

    stopOperationSoundForNearbyPlayers(operation)
    clearOperation(operation)
    sendResult(
        operation.playerId,
        operation.requestId,
        operation.networkId,
        false,
        operation.wasAnchored,
        message
    )
end

local function runOperation(operation)
    local startedAt = GetGameTimer()

    while true do
        local elapsedMs = GetGameTimer() - startedAt

        if elapsedMs >= OPERATION_DURATION_MS then
            break
        end

        local waitMs = math.min(OPERATION_CHECK_INTERVAL_MS, OPERATION_DURATION_MS - elapsedMs)

        Wait(waitMs)

        if not isOperationCurrent(operation) then
            return
        end

        local problem = getOperationProblem(operation)

        if problem then
            failOperation(operation, problem)
            return
        end

        syncOperationSoundRecipients(operation)
    end

    if not isOperationCurrent(operation) then
        return
    end

    local problem = getOperationProblem(operation)

    if problem then
        failOperation(operation, problem)
        return
    end

    if operation.shouldAnchor then
        anchoredBoats[operation.vehicle] = true
    else
        anchoredBoats[operation.vehicle] = nil
    end

    Entity(operation.vehicle).state:set(
        STATE_KEY,
        operation.shouldAnchor,
        true
    )

    stopOperationSoundForNearbyPlayers(operation)
    clearOperation(operation)
    sendResult(
        operation.playerId,
        operation.requestId,
        operation.networkId,
        true,
        operation.shouldAnchor
    )
end

RegisterNetEvent(REQUEST_EVENT, function(networkId, requestId)
    local playerId = source

    if not isValidInteger(networkId, 1, 65535)
        or not isValidInteger(requestId, 1, 2147483647)
    then
        sendResult(playerId, 0, 0, false, false, 'Geçersiz demirleme isteği.')
        return
    end

    local now = GetGameTimer()
    local lastRequest = lastRequests[playerId]

    if lastRequest then
        local elapsed = now - lastRequest

        if elapsed >= 0 and elapsed < REQUEST_COOLDOWN_MS then
            sendResult(playerId, requestId, networkId, false, false, 'Lütfen tekrar denemeden önce kısa bir süre bekle.')
            return
        end
    end

    lastRequests[playerId] = now

    if operationsByPlayer[playerId] then
        sendResult(playerId, requestId, networkId, false, false, 'Demirleme işlemi zaten devam ediyor.')
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(networkId)

    if not isBoat(vehicle) then
        sendResult(playerId, requestId, networkId, false, false, 'Tekne bulunamadı.')
        return
    end

    if operationsByVehicle[vehicle] then
        sendResult(playerId, requestId, networkId, false, false, 'Bu teknenin demir işlemi zaten devam ediyor.')
        return
    end

    local playerPed = GetPlayerPed(playerId)

    if playerPed == 0
        or GetPedInVehicleSeat(vehicle, -1) ~= playerPed
    then
        sendResult(playerId, requestId, networkId, false, false, 'Demiri yalnızca teknenin sürücüsü kullanabilir.')
        return
    end

    -- The server table is authoritative. The replicated state bag is only the
    -- transport used to apply the result on clients.
    local wasAnchored = anchoredBoats[vehicle] == true
    local shouldAnchor = not wasAnchored

    if shouldAnchor
        and getHorizontalSpeed(vehicle) >= MAX_ANCHOR_HORIZONTAL_SPEED
    then
        sendResult(
            playerId,
            requestId,
            networkId,
            false,
            false,
            string.format(
                'Demir atmak için hızın %.0f km/sa altında olmalı.',
                MAX_ANCHOR_SPEED_KMH
            )
        )
        return
    end

    nextSoundToken = (nextSoundToken % 2147483647) + 1

    local operation = {
        playerId = playerId,
        requestId = requestId,
        networkId = networkId,
        vehicle = vehicle,
        wasAnchored = wasAnchored,
        shouldAnchor = shouldAnchor,
        soundToken = string.format('%d:%d', GetGameTimer(), nextSoundToken),
    }

    operationsByPlayer[playerId] = operation
    operationsByVehicle[vehicle] = operation

    startOperationSoundForNearbyPlayers(operation)

    TriggerClientEvent(
        START_EVENT,
        playerId,
        requestId,
        networkId,
        shouldAnchor,
        OPERATION_DURATION_MS,
        operation.soundToken
    )

    CreateThread(function()
        runOperation(operation)
    end)
end)

RegisterNetEvent(CANCEL_EVENT, function(networkId, requestId)
    local playerId = source

    if not isValidInteger(networkId, 1, 65535)
        or not isValidInteger(requestId, 1, 2147483647)
    then
        return
    end

    local operation = operationsByPlayer[playerId]

    if operation
        and operation.networkId == networkId
        and operation.requestId == requestId
    then
        stopOperationSoundForNearbyPlayers(operation)
        clearOperation(operation)
        sendResult(
            playerId,
            requestId,
            networkId,
            false,
            operation.wasAnchored,
            'Demirleme işlemi iptal edildi.'
        )
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(networkId)
    local isAnchored = isBoat(vehicle) and anchoredBoats[vehicle] == true

    -- A completion/rejection result may already be in flight. This response is
    -- sent afterwards, so the client will accept whichever final result arrived
    -- first and ignore the duplicate.
    sendResult(
        playerId,
        requestId,
        networkId,
        false,
        isAnchored,
        'Demirleme isteği iptal edildi.'
    )
end)

-- Entity owners can normally write replicated entity state bags. Keep the
-- server-owned table authoritative and immediately restore unexpected writes.
AddStateBagChangeHandler(STATE_KEY, nil, function(bagName, _, value)
    if resourceStopping then
        return
    end

    local networkId = type(bagName) == 'string'
        and tonumber(string.match(bagName, '^entity:(%d+)$'))

    if not networkId then
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(networkId)

    if not isBoat(vehicle) then
        return
    end

    local authoritativeState = anchoredBoats[vehicle] == true

    if value == authoritativeState then
        return
    end

    SetTimeout(0, function()
        if resourceStopping or not isBoat(vehicle) then
            return
        end

        Entity(vehicle).state:set(
            STATE_KEY,
            anchoredBoats[vehicle] == true,
            true
        )
    end)
end)

AddEventHandler('playerDropped', function()
    local playerId = source
    local operation = operationsByPlayer[playerId]

    if operation then
        stopOperationSoundForNearbyPlayers(operation)
        clearOperation(operation)
    end

    lastRequests[playerId] = nil
end)

AddEventHandler('entityRemoved', function(entity)
    local operation = operationsByVehicle[entity]

    if operation then
        failOperation(operation, 'Demirleme işlemi iptal edildi: tekne kaldırıldı.')
    end

    anchoredBoats[entity] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    resourceStopping = true
    TriggerClientEvent(PROXIMITY_SOUND_STOP_EVENT, -1, nil)

    for vehicle in pairs(anchoredBoats) do
        if DoesEntityExist(vehicle) then
            Entity(vehicle).state:set(STATE_KEY, false, true)
        end
    end
end)
