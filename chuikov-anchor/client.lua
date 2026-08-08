local COMMAND_NAME = 'demir'
local DEFAULT_KEY = 'G'

-- Only horizontal movement is checked, so wave-induced vertical bobbing does
-- not count towards the anchoring speed limit.
local MAX_ANCHOR_SPEED_KMH = 13.0
local MAX_ANCHOR_HORIZONTAL_SPEED = MAX_ANCHOR_SPEED_KMH / 3.6
local REQUEST_ACCEPT_TIMEOUT_MS = 3000
local RESPONSE_GRACE_MS = 3000
local CANCEL_RESPONSE_TIMEOUT_MS = 2000

local STATE_KEY = 'chuikov-anchor:anchored'
local REQUEST_EVENT = 'chuikov-anchor:server:setAnchored'
local CANCEL_EVENT = 'chuikov-anchor:server:cancelOperation'
local START_EVENT = 'chuikov-anchor:client:operationStarted'
local RESULT_EVENT = 'chuikov-anchor:client:result'
local PROXIMITY_SOUND_START_EVENT = 'chuikov-anchor:client:startProximitySound'
local PROXIMITY_SOUND_STOP_EVENT = 'chuikov-anchor:client:stopProximitySound'

local CHAIN_SOUND_NAME = 'Clamp'
local CHAIN_SOUND_SET = 'CRANE_SOUNDS'
local ANCHOR_FINISH_SOUND = 'Attach_Container'
local UNANCHOR_FINISH_SOUND = 'Detach_Container'
local AUDIO_BANKS = {
    'Crane',
    'Crane_Stress',
    'Crane_Impact_Sweeteners',
}

local anchoredBoats = {}
local pendingStateBags = {}
local proximitySounds = {}
local pendingRequest = nil
local activeOperationSound = nil
local audioBanksRequested = false
local audioBankRequestMade = false
local nextRequestId = 0

local function notify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, false)
end

local function isBoat(vehicle)
    return vehicle ~= 0
        and DoesEntityExist(vehicle)
        and IsEntityAVehicle(vehicle)
        and IsThisModelABoat(GetEntityModel(vehicle))
end

local function getHorizontalSpeed(vehicle)
    local velocity = GetEntityVelocity(vehicle)
    return math.sqrt(
        velocity.x * velocity.x
        + velocity.y * velocity.y
    )
end

local function requestAnchorAudioBanks()
    if audioBanksRequested then
        return true
    end

    audioBankRequestMade = true
    local allBanksReady = true

    for _, bankName in ipairs(AUDIO_BANKS) do
        if not RequestAmbientAudioBank(bankName, false) then
            allBanksReady = false
        end
    end

    audioBanksRequested = allBanksReady
    return allBanksReady
end

local function getCustomSound(shouldAnchor)
    if type(AnchorConfig) ~= 'table'
        or AnchorConfig.useCustomSounds ~= true
        or type(AnchorConfig.sounds) ~= 'table'
    then
        return nil
    end

    local soundFile = shouldAnchor
        and AnchorConfig.sounds.anchorDrop
        or AnchorConfig.sounds.anchorRaise

    if type(soundFile) ~= 'string' or soundFile == '' then
        return nil
    end

    return soundFile, tonumber(AnchorConfig.soundVolume) or 0.75
end

local function getCustomSoundMaxDistance()
    local maxDistance = type(AnchorConfig) == 'table'
        and tonumber(AnchorConfig.soundMaxDistance)
        or nil

    if not maxDistance or maxDistance <= 0.0 then
        return 35.0
    end

    return maxDistance
end

local function stopOperationSound(requestId, completed, anchored)
    local operationSound = activeOperationSound

    if not operationSound
        or (requestId and operationSound.requestId ~= requestId)
    then
        return
    end

    activeOperationSound = nil

    if operationSound.customSound then
        SendNUIMessage({
            action = 'stopAnchorSound',
            soundId = operationSound.customSoundId,
        })
    elseif operationSound.soundId then
        StopSound(operationSound.soundId)
        ReleaseSoundId(operationSound.soundId)
    end

    if completed
        and not operationSound.customSound
        and isBoat(operationSound.vehicle)
    then
        requestAnchorAudioBanks()
        PlaySoundFromEntity(
            -1,
            anchored and ANCHOR_FINISH_SOUND or UNANCHOR_FINISH_SOUND,
            operationSound.vehicle,
            CHAIN_SOUND_SET,
            false,
            0
        )
    end
end

local function startOperationSound(requestId, vehicle, shouldAnchor, soundToken)
    stopOperationSound(nil, false, false)

    if not isBoat(vehicle) then
        return
    end

    local customSoundFile = getCustomSound(shouldAnchor)
    local operationSound = {
        requestId = requestId,
        vehicle = vehicle,
        customSound = customSoundFile ~= nil,
        customSoundId = soundToken,
    }

    activeOperationSound = operationSound

    if customSoundFile then
        return
    end

    CreateThread(function()
        for _ = 1, 20 do
            if requestAnchorAudioBanks() then
                break
            end

            Wait(50)
        end

        if not audioBanksRequested
            or activeOperationSound ~= operationSound
            or not pendingRequest
            or pendingRequest.id ~= requestId
            or pendingRequest.phase ~= 'running'
            or not isBoat(vehicle)
        then
            return
        end

        local soundId = GetSoundId()

        if soundId == -1 then
            return
        end

        PlaySoundFromEntity(
            soundId,
            CHAIN_SOUND_NAME,
            vehicle,
            CHAIN_SOUND_SET,
            false,
            0
        )

        operationSound.soundId = soundId
    end)
end

-- Preload the crane/chain-like sound bank so the first anchor operation is not
-- silent while GTA is still mounting the bank.
CreateThread(function()
    local customDropSound = getCustomSound(true)
    local customRaiseSound = getCustomSound(false)

    if customDropSound and customRaiseSound then
        return
    end

    for _ = 1, 20 do
        if requestAnchorAudioBanks() then
            return
        end

        Wait(250)
    end
end)

local function stopProximitySound(soundToken)
    proximitySounds[soundToken] = nil
    SendNUIMessage({
        action = 'stopAnchorSound',
        soundId = soundToken,
    })
end

local function stopAllProximitySounds()
    proximitySounds = {}
    SendNUIMessage({
        action = 'stopAllAnchorSounds',
    })
end

local function getProximitySoundVolume(soundEntry)
    local soundX = soundEntry.x
    local soundY = soundEntry.y
    local soundZ = soundEntry.z
    local vehicle = NetworkGetEntityFromNetworkId(soundEntry.networkId)

    if isBoat(vehicle) then
        local vehicleCoords = GetEntityCoords(vehicle)
        soundX = vehicleCoords.x
        soundY = vehicleCoords.y
        soundZ = vehicleCoords.z
    end

    local playerCoords = GetEntityCoords(PlayerPedId())
    local deltaX = playerCoords.x - soundX
    local deltaY = playerCoords.y - soundY
    local deltaZ = playerCoords.z - soundZ
    local distance = math.sqrt(
        deltaX * deltaX
        + deltaY * deltaY
        + deltaZ * deltaZ
    )

    if distance >= soundEntry.maxDistance then
        return 0.0
    end

    return soundEntry.baseVolume
        * (1.0 - distance / soundEntry.maxDistance)
end

RegisterNetEvent(PROXIMITY_SOUND_START_EVENT, function(
    soundToken,
    networkId,
    shouldAnchor,
    x,
    y,
    z,
    durationMs
)
    if source ~= 65535
        or type(soundToken) ~= 'string'
        or soundToken == ''
        or #soundToken > 128
        or type(networkId) ~= 'number'
        or networkId ~= networkId
        or networkId < 1
        or networkId > 65535
        or networkId % 1 ~= 0
        or type(shouldAnchor) ~= 'boolean'
        or type(x) ~= 'number'
        or x ~= x
        or type(y) ~= 'number'
        or y ~= y
        or type(z) ~= 'number'
        or z ~= z
        or type(durationMs) ~= 'number'
        or durationMs ~= durationMs
        or durationMs % 1 ~= 0
        or durationMs < 1000
        or durationMs > 10000
    then
        return
    end

    local soundFile, baseVolume = getCustomSound(shouldAnchor)

    if not soundFile then
        return
    end

    local soundEntry = {
        networkId = networkId,
        x = x,
        y = y,
        z = z,
        baseVolume = math.max(0.0, math.min(1.0, baseVolume)),
        maxDistance = getCustomSoundMaxDistance(),
    }
    local initialVolume = getProximitySoundVolume(soundEntry)

    proximitySounds[soundToken] = soundEntry

    SendNUIMessage({
        action = 'playAnchorSound',
        soundId = soundToken,
        file = soundFile,
        volume = initialVolume,
    })

    SetTimeout(durationMs + RESPONSE_GRACE_MS, function()
        if proximitySounds[soundToken] == soundEntry then
            stopProximitySound(soundToken)
        end
    end)
end)

RegisterNetEvent(PROXIMITY_SOUND_STOP_EVENT, function(soundToken)
    if source ~= 65535 then
        return
    end

    if soundToken == nil then
        stopAllProximitySounds()
        return
    end

    if type(soundToken) ~= 'string'
        or soundToken == ''
        or #soundToken > 128
    then
        return
    end

    stopProximitySound(soundToken)
end)

CreateThread(function()
    while true do
        Wait(200)

        if next(proximitySounds) ~= nil then
            for soundToken, soundEntry in pairs(proximitySounds) do
                SendNUIMessage({
                    action = 'setAnchorSoundVolume',
                    soundId = soundToken,
                    volume = getProximitySoundVolume(soundEntry),
                })
            end
        end
    end
end)

local function cancelPendingOperation(requestId, networkId, timeoutMessage)
    if not pendingRequest
        or pendingRequest.id ~= requestId
        or pendingRequest.networkId ~= networkId
    then
        return
    end

    pendingRequest.phase = 'cancelling'
    stopOperationSound(requestId, false, false)
    TriggerServerEvent(CANCEL_EVENT, networkId, requestId)

    SetTimeout(CANCEL_RESPONSE_TIMEOUT_MS, function()
        if not pendingRequest
            or pendingRequest.id ~= requestId
            or pendingRequest.networkId ~= networkId
            or pendingRequest.phase ~= 'cancelling'
        then
            return
        end

        pendingRequest = nil
        notify(timeoutMessage)
    end)
end

local function applyAnchorState(vehicle, anchored)
    if not isBoat(vehicle) then
        return
    end

    if anchored then
        -- Use GTA's boat anchor instead of freezing the entity. This holds the
        -- horizontal position while leaving buoyancy and wave movement active.
        SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, true)
        SetBoatAnchor(vehicle, true)
        anchoredBoats[vehicle] = NetworkHasControlOfEntity(vehicle)
        return
    end

    SetBoatAnchor(vehicle, false)
    SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, false)
    anchoredBoats[vehicle] = nil
end

AddStateBagChangeHandler(STATE_KEY, nil, function(bagName, _, value)
    local vehicle = GetEntityFromStateBagName(bagName)

    if vehicle ~= 0 then
        pendingStateBags[bagName] = nil
        applyAnchorState(vehicle, value == true)
        return
    end

    if value ~= true then
        pendingStateBags[bagName] = nil
        return
    end

    -- The state bag may arrive just before its entity is streamed in. Keep
    -- waiting until either the entity appears or a later state cancels it.
    if pendingStateBags[bagName] then
        return
    end

    pendingStateBags[bagName] = true

    CreateThread(function()
        local attempts = 0

        while pendingStateBags[bagName] and attempts < 80 do
            Wait(250)
            attempts = attempts + 1
            vehicle = GetEntityFromStateBagName(bagName)

            if vehicle ~= 0 then
                pendingStateBags[bagName] = nil
                applyAnchorState(vehicle, Entity(vehicle).state[STATE_KEY] == true)
                return
            end
        end

        pendingStateBags[bagName] = nil
    end)
end)

RegisterNetEvent(START_EVENT, function(
    requestId,
    networkId,
    shouldAnchor,
    durationMs,
    soundToken
)
    if source ~= 65535
        or not pendingRequest
        or pendingRequest.id ~= requestId
        or pendingRequest.networkId ~= networkId
        or pendingRequest.phase ~= 'requested'
        or type(shouldAnchor) ~= 'boolean'
        or type(durationMs) ~= 'number'
        or durationMs ~= durationMs
        or durationMs % 1 ~= 0
        or durationMs < 1000
        or durationMs > 10000
        or type(soundToken) ~= 'string'
        or soundToken == ''
        or #soundToken > 128
    then
        return
    end

    pendingRequest.phase = 'running'
    pendingRequest.shouldAnchor = shouldAnchor

    local vehicle = NetworkGetEntityFromNetworkId(networkId)
    pendingRequest.vehicle = vehicle

    if shouldAnchor then
        notify('Demir atılıyor...')
    else
        notify('Demir alınıyor...')
    end

    startOperationSound(requestId, vehicle, shouldAnchor, soundToken)

    SetTimeout(durationMs + RESPONSE_GRACE_MS, function()
        if not pendingRequest
            or pendingRequest.id ~= requestId
            or pendingRequest.networkId ~= networkId
            or pendingRequest.phase ~= 'running'
        then
            return
        end

        cancelPendingOperation(
            requestId,
            networkId,
            'Demirleme işlemi zaman aşımına uğradı.'
        )
    end)
end)

RegisterNetEvent(RESULT_EVENT, function(requestId, networkId, success, anchored, message)
    if source ~= 65535
        or not pendingRequest
        or pendingRequest.id ~= requestId
        or pendingRequest.networkId ~= networkId
    then
        return
    end

    stopOperationSound(requestId, success, anchored)
    pendingRequest = nil

    if not success then
        notify(message or 'Demirleme işlemi başarısız oldu.')
        return
    end

    if anchored then
        notify('Tekne demirlendi.')
    else
        notify('Teknenin demiri kaldırıldı.')
    end
end)

RegisterCommand(COMMAND_NAME, function()
    if pendingRequest then
        notify('Demirleme işlemi zaten devam ediyor.')
        return
    end

    local playerPed = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(playerPed, false)

    if not isBoat(vehicle) then
        notify('Demiri kullanmak için bir teknede olmalısın.')
        return
    end

    if GetPedInVehicleSeat(vehicle, -1) ~= playerPed then
        notify('Demiri yalnızca teknenin sürücüsü kullanabilir.')
        return
    end

    local shouldAnchor = Entity(vehicle).state[STATE_KEY] ~= true

    if shouldAnchor then
        local horizontalSpeed = getHorizontalSpeed(vehicle)

        if horizontalSpeed >= MAX_ANCHOR_HORIZONTAL_SPEED then
            notify(string.format(
                'Demir atmak için hızın %.0f km/sa altında olmalı. Hız: %.1f km/sa',
                MAX_ANCHOR_SPEED_KMH,
                horizontalSpeed * 3.6
            ))
            return
        end
    end

    if not NetworkGetEntityIsNetworked(vehicle) then
        notify('Bu tekne ağ üzerinde kayıtlı değil.')
        return
    end

    local networkId = NetworkGetNetworkIdFromEntity(vehicle)

    if networkId == 0 then
        notify('Teknenin ağ kimliği alınamadı.')
        return
    end

    nextRequestId = (nextRequestId % 2147483647) + 1
    local requestId = nextRequestId

    pendingRequest = {
        id = requestId,
        networkId = networkId,
        phase = 'requested',
    }

    TriggerServerEvent(REQUEST_EVENT, networkId, requestId)

    SetTimeout(REQUEST_ACCEPT_TIMEOUT_MS, function()
        if not pendingRequest
            or pendingRequest.id ~= requestId
            or pendingRequest.networkId ~= networkId
            or pendingRequest.phase ~= 'requested'
        then
            return
        end

        cancelPendingOperation(
            requestId,
            networkId,
            'Demirleme isteği zaman aşımına uğradı.'
        )
    end)
end, false)

RegisterKeyMapping(
    COMMAND_NAME,
    'Tekne demirini indir / kaldır',
    'keyboard',
    DEFAULT_KEY
)

-- Reapply the native anchor once when this client gains network control. Doing
-- it every tick could continually move the anchor point as the boat bobs.
CreateThread(function()
    while true do
        Wait(1000)

        for vehicle, previouslyHadControl in pairs(anchoredBoats) do
            if not isBoat(vehicle) then
                anchoredBoats[vehicle] = nil
            elseif Entity(vehicle).state[STATE_KEY] == true then
                local hasControl = NetworkHasControlOfEntity(vehicle)

                if hasControl and not previouslyHadControl then
                    SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, true)
                    SetBoatAnchor(vehicle, true)
                end

                anchoredBoats[vehicle] = hasControl
            else
                applyAnchorState(vehicle, false)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    stopOperationSound(nil, false, false)
    stopAllProximitySounds()

    if pendingRequest then
        TriggerServerEvent(
            CANCEL_EVENT,
            pendingRequest.networkId,
            pendingRequest.id
        )
        pendingRequest = nil
    end

    if audioBankRequestMade then
        ReleaseAmbientAudioBank()
        audioBanksRequested = false
        audioBankRequestMade = false
    end

    for vehicle in pairs(anchoredBoats) do
        if isBoat(vehicle) then
            SetBoatAnchor(vehicle, false)
            SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, false)
        end
    end
end)
