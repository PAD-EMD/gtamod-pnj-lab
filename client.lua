-- ============================================================
-- gather_peds : donne une destination aux PNJ (ou les fait suivre le joueur).
--
--   /gather                    téléporte les PNJ sur toi
--   /gather walk               les fait marcher jusqu'à toi
--   /gather tp waypoint        les téléporte sur le repère de la carte
--   /gather walk 215 -810 30   les fait aller aux coordonnées x y z
--   /gather follow             active/désactive le suivi continu du joueur
--
-- Si la ressource foule_throttle est démarrée et a une foule de spawnée,
-- les ordres ciblent cette foule entière (quel que soit son effectif).
-- Sinon, ils ciblent les PNJ ambiants chargés autour du joueur.
-- ============================================================

local CONFIG = {
    SPREAD_RADIUS = 4.0,      -- rayon (m) du cercle où ils se placent (évite de les empiler)
    INCLUDE_ANIMALS = false,  -- true : inclut aussi les animaux
    INCLUDE_DEAD = false,     -- true : inclut les PNJ morts
    CONTROL_TIMEOUT = 300,    -- ms max pour prendre le contrôle d'un PNJ qui n'est pas encore à nous
    CONTROL_BATCH = 25,       -- PNJ traités par frame (évite un freeze avec une grosse foule)
    COLLISION_TIMEOUT = 2000, -- ms max pour charger la collision d'une zone jamais visitée (ex: waypoint lointain)
    FOLLOW_INTERVAL = 1000,   -- ms entre deux rafraîchissements de destination en mode suivi
}

local FOULE_RESOURCE = 'foule_throttle'

-- Bumpé à chaque nouvel ordre (manuel ou tick de suivi). Un ordre en cours compare
-- son propre jeton à cette valeur : s'il ne correspond plus, un ordre plus récent
-- l'a remplacé, donc il s'arrête au lieu de continuer à se battre pour les mêmes PNJ.
local orderGeneration = 0

local followEnabled = false
local followLoopActive = false

local function notify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end

-- Altitude du sol. 2e valeur = false si la collision n'a pas pu être chargée
-- à temps à ces coordonnées (fallbackZ utilisé à la place) — typiquement une
-- zone jamais visitée, comme un waypoint posé loin du joueur.
local function groundZ(x, y, fallbackZ)
    local deadline = GetGameTimer() + CONFIG.COLLISION_TIMEOUT
    repeat
        RequestCollisionAtCoord(x, y, fallbackZ)
        Wait(0)
        for height = 1000.0, 0.0, -50.0 do
            local found, z = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, height, false)
            if found then return z, true end
        end
    until GetGameTimer() > deadline
    return fallbackZ, false
end

-- Retourne la liste des PNJ ambiants chargés autour du joueur (repli quand
-- aucune foule foule_throttle n'est disponible)
local function collectAmbientPeds()
    local list = {}
    for _, ped in ipairs(GetGamePool('CPed')) do
        local ok = DoesEntityExist(ped)
            and not IsPedAPlayer(ped)                       -- jamais les vrais joueurs
            and not IsPedInAnyVehicle(ped, true)            -- on laisse les conducteurs et passagers
            and (CONFIG.INCLUDE_DEAD or not IsEntityDead(ped))
            and (CONFIG.INCLUDE_ANIMALS or IsPedHuman(ped))
        if ok then list[#list + 1] = ped end
    end
    return list
end

-- Retourne la foule spawnée par foule_throttle, ou une liste vide si cette
-- ressource n'est pas démarrée ou n'a rien de spawné
local function collectCrowdPeds()
    if GetResourceState(FOULE_RESOURCE) ~= 'started' then
        return {}
    end

    local ok, crowd = pcall(function()
        return exports[FOULE_RESOURCE]:GetCrowd()
    end)

    if not ok or not crowd then
        return {}
    end

    local list = {}
    for _, entry in ipairs(crowd) do
        if entry.ped and DoesEntityExist(entry.ped) then
            list[#list + 1] = entry.ped
        end
    end
    return list
end

-- Les PNJ à commander : la foule foule_throttle si elle existe, sinon les PNJ
-- ambiants. C'est ce qui permet de donner une destination à la foule entière
-- quel que soit son effectif (10, 300, 1000...).
local function targetPeds()
    local crowd = collectCrowdPeds()
    if #crowd > 0 then
        return crowd
    end
    return collectAmbientPeds()
end

-- Demande le contrôle de tous les PNJ sans bloquer (un seul appel réseau par
-- PNJ, pas d'attente ici). Appelé une fois avant de parcourir la liste, pour
-- que le contrôle ait des chances d'être déjà acquis au moment où chaque PNJ
-- est réellement traité plus bas.
local function requestControlOfAll(peds)
    for _, ped in ipairs(peds) do
        if DoesEntityExist(ped) and not NetworkHasControlOfEntity(ped) then
            NetworkRequestControlOfEntity(ped)
        end
    end
end

-- Point d'arrivée de chaque PNJ : sur un cercle autour du centre
local function slotAround(center, index, total)
    local angle = index * 2.399963                          -- angle d'or : répartition régulière
    local radius = CONFIG.SPREAD_RADIUS * math.sqrt(index / total)
    return center.x + math.cos(angle) * radius, center.y + math.sin(angle) * radius
end

-- Donne une destination (téléportation ou marche) à la foule entière. Un nouvel
-- ordre (manuel ou tick de suivi) bumpe orderGeneration : celui-ci s'arrête dès
-- qu'il se rend compte qu'un ordre plus récent l'a remplacé, ce qui permet de
-- changer de direction en cours de route et de donner des ordres à la suite
-- sans qu'ils ne se battent pour les mêmes PNJ.
local function gather(mode, center)
    orderGeneration = orderGeneration + 1
    local token = orderGeneration

    local peds = targetPeds()

    if #peds == 0 then
        notify('Aucun PNJ à déplacer.')
        return
    end

    requestControlOfAll(peds)

    local moved, skipped = 0, 0

    for index, ped in ipairs(peds) do
        if token ~= orderGeneration then
            -- Un ordre plus récent a pris le relais : on arrête ici
            return
        end

        local gotControl = false

        if DoesEntityExist(ped) then
            if NetworkHasControlOfEntity(ped) then
                gotControl = true
            else
                local deadline = GetGameTimer() + CONFIG.CONTROL_TIMEOUT
                while not NetworkHasControlOfEntity(ped) and GetGameTimer() < deadline do
                    Wait(0)
                end
                gotControl = NetworkHasControlOfEntity(ped)
            end
        end

        if gotControl then
            local x, y = slotAround(center, index, #peds)
            local z = groundZ(x, y, center.z)

            if mode == 'tp' then
                ClearPedTasksImmediately(ped)
                SetEntityCoords(ped, x, y, z, false, false, false, false)
            else
                ClearPedTasks(ped)
                -- speed 2.0 = course, flags 786603 = comportement standard de déplacement
                TaskGoToCoordAnyMeans(ped, x, y, z, 2.0, 0, false, 786603, 0.0)
            end
            moved = moved + 1
        else
            skipped = skipped + 1
        end

        if index % CONFIG.CONTROL_BATCH == 0 then Wait(0) end   -- on ne bloque jamais le jeu
    end

    notify(('PNJ rassemblés : %d (ignorés : %d)'):format(moved, skipped))
end

-- Boucle de suivi : tant que followEnabled, redonne périodiquement la position
-- du joueur comme destination de marche. Idempotent : un appel alors que la
-- boucle tourne déjà ne lance pas de deuxième thread.
local function startFollowLoop()
    if followLoopActive then return end
    followLoopActive = true

    CreateThread(function()
        while followEnabled do
            gather('walk', GetEntityCoords(PlayerPedId()))
            Wait(CONFIG.FOLLOW_INTERVAL)
        end
        followLoopActive = false
    end)
end

-- Lit les arguments : [tp|walk] [waypoint | x y z]
local function parseDestination(args)
    local playerCoords = GetEntityCoords(PlayerPedId())
    local index = 1
    local mode = 'tp'

    local first = args[index] and args[index]:lower() or nil
    if first == 'tp' or first == 'walk' then
        mode = first
        index = index + 1
    end

    local target = args[index] and args[index]:lower() or nil

    if target == nil then
        return mode, playerCoords
    elseif target == 'waypoint' then
        local blip = GetFirstBlipInfoId(8)
        if not DoesBlipExist(blip) then return nil, 'Aucun repère sur la carte.' end
        local c = GetBlipInfoIdCoord(blip)
        local z, loaded = groundZ(c.x, c.y, playerCoords.z)
        if not loaded then
            return nil, 'Impossible de charger le terrain au niveau du repère (zone jamais visitée). Rapproche-toi puis réessaie.'
        end
        return mode, vector3(c.x, c.y, z)
    else
        local x, y, z = tonumber(args[index]), tonumber(args[index + 1]), tonumber(args[index + 2])
        if not (x and y and z) then return nil, 'Utilisation : /gather [tp|walk] [waypoint | x y z]' end
        return mode, vector3(x + 0.0, y + 0.0, z + 0.0)
    end
end

RegisterCommand('gather', function(source, args)
    local first = args[1] and args[1]:lower() or nil

    if first == 'follow' then
        followEnabled = not followEnabled

        if followEnabled then
            notify('Suivi activé : les PNJ vont suivre le joueur.')
            startFollowLoop()
        else
            notify('Suivi désactivé.')
        end

        return
    end

    -- Un ordre de destination explicite reprend toujours la main sur le suivi
    if followEnabled then
        followEnabled = false
        notify('Suivi désactivé (ordre direct donné).')
    end

    local mode, center = parseDestination(args)
    if not mode then notify(center) return end
    CreateThread(function() gather(mode, center) end)
end, false)

-- Coupe le suivi si la ressource est arrêtée (sinon le thread tournerait dans le vide)
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        followEnabled = false
    end
end)