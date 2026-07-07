--[[
    FS25_OperatingCosts
    Version: 1.0.0.0
    Author: Dude23

    Zweck:
    - monatliche Versicherung für Fahrzeuge und Geräte
    - monatlicher Unterhalt-Ausgleich für Gebäude/Placeables
    - monatliche Lagergutversicherung für eingelagerte Lagergüter

    Eigenes einblendbares Auswertungsfenster. Alle Kosten werden serverseitig berechnet und als Finanzbuchung erfasst.
]]

HP_OperatingCosts = {}
HP_OperatingCosts.VERSION = "1.0.0.0"
HP_OperatingCosts.MOD_NAME = g_currentModName or "FS25_OperatingCosts"
HP_OperatingCosts.DEBUG = false
HP_OperatingCosts.DIAGNOSTIC_LOGGING = false -- Nur bei gezielter Fehlersuche aktivieren.
HP_OperatingCosts.STORAGE_DIAGNOSTIC_LOGGING = false -- Nur fuer gezielte Lagerdiagnosen aktivieren.
HP_OperatingCosts.HISTORY_FILE_NAME = "operatingCostsHistory.xml"
HP_OperatingCosts.CONFIG_FILE_NAME = "operatingCostsConfig.xml"
HP_OperatingCosts.INPUT_ACTION_TOGGLE_WINDOW = "HP_OC_TOGGLE_WINDOW"
HP_OperatingCosts.DEFAULT_TOGGLE_LABEL = "Übersichtsmenü"

-- Standard-Monatswerte. Die Schlüssel easy/normal/hard werden aus der Wirtschaftsschwierigkeit abgeleitet.
-- Werte werden intern als Dezimalzahlen geführt: 0.0030 = 0,30 % pro Monat.
-- Im Savegame können sie in operatingCostsConfig.xml als Prozentwerte angepasst werden.
HP_OperatingCosts.DEFAULT_RATES = {
    easy = {
        motorVehicleInsurance = 0.0010,  -- 0,10 % des Neuwerts pro Monat
        implementInsurance    = 0.0005,  -- 0,05 % des Neuwerts pro Monat
        placeableUpkeep       = 0.0010,  -- 0,10 % des Baupreises pro Monat
        storedGoodsInsurance  = 0.00025  -- 0,025 % des Warenwerts pro Monat
    },
    normal = {
        motorVehicleInsurance = 0.0020,  -- 0,20 % des Neuwerts pro Monat
        implementInsurance    = 0.0010,  -- 0,10 % des Neuwerts pro Monat
        placeableUpkeep       = 0.0020,  -- 0,20 % des Baupreises pro Monat
        storedGoodsInsurance  = 0.00050  -- 0,050 % des Warenwerts pro Monat
    },
    hard = {
        motorVehicleInsurance = 0.0030,  -- 0,30 % des Neuwerts pro Monat
        implementInsurance    = 0.0015,  -- 0,15 % des Neuwerts pro Monat
        placeableUpkeep       = 0.0030,  -- 0,30 % des Baupreises pro Monat
        storedGoodsInsurance  = 0.00075  -- 0,075 % des Warenwerts pro Monat
    }
}
HP_OperatingCosts.RATES = {}


-- Fallback-Werte für Hofgebäude, die mit der Map bzw. mit dem Hofland kommen und keinen sauberen Baupreis liefern.
HP_OperatingCosts.FALLBACK_PLACEABLE_PRICES = {
    animal      = 150000,
    production  = 120000,
    silo        = 80000,
    farmhouse   = 150000,
    default     = 50000
}

-- --------------------------------------------------------------------------
-- Multiplayer-Benachrichtigung
-- --------------------------------------------------------------------------

HP_OperatingCostsNotificationEvent = {}
HP_OperatingCostsNotificationEvent_mt = Class(HP_OperatingCostsNotificationEvent, Event)
InitEventClass(HP_OperatingCostsNotificationEvent, "HP_OperatingCostsNotificationEvent")

function HP_OperatingCostsNotificationEvent.emptyNew()
    return Event.new(HP_OperatingCostsNotificationEvent_mt)
end

function HP_OperatingCostsNotificationEvent.new(farmId, text, notificationType)
    local self = HP_OperatingCostsNotificationEvent.emptyNew()
    self.farmId = farmId or 0
    self.text = text or ""
    self.notificationType = notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO
    return self
end

function HP_OperatingCostsNotificationEvent:readStream(streamId, connection)
    local farmIdBits = FarmManager ~= nil and FarmManager.FARM_ID_SEND_NUM_BITS or 8
    self.farmId = streamReadUIntN(streamId, farmIdBits)
    self.text = streamReadString(streamId)
    self.notificationType = streamReadUInt8(streamId)
    self:run(connection)
end

function HP_OperatingCostsNotificationEvent:writeStream(streamId, connection)
    local farmIdBits = FarmManager ~= nil and FarmManager.FARM_ID_SEND_NUM_BITS or 8
    streamWriteUIntN(streamId, self.farmId or 0, farmIdBits)
    streamWriteString(streamId, self.text or "")
    streamWriteUInt8(streamId, self.notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO)
end

function HP_OperatingCostsNotificationEvent:run(connection)
    if g_currentMission == nil or self.text == nil or self.text == "" then
        return
    end

    local localFarmId = nil
    if g_currentMission.getFarmId ~= nil then
        localFarmId = g_currentMission:getFarmId()
    elseif g_localPlayer ~= nil then
        localFarmId = g_localPlayer.farmId
    end

    if localFarmId == nil or self.farmId == 0 or localFarmId == self.farmId then
        g_currentMission:addIngameNotification(self.notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO, self.text)
    end
end

-- --------------------------------------------------------------------------
-- Grundstruktur
-- --------------------------------------------------------------------------

function HP_OperatingCosts:loadMap(mapName)
    self.mission = g_currentMission
    self.historyRecords = {}
    self.historyDirty = false
    self.configDirty = false
    self:resetRatesToDefaults()
    self:loadConfigFile()
    self:initHistoryWindowState()
    self:loadHistoryFile()
    self:installHistoryWindowHooks()
    self:installShopCostPreviewHooks()
    self:installSavegameHooks()
    self:registerHistoryWindowInputAction()
    self.moneyTypes = {
        vehicleInsurance = self:getMoneyType("VEHICLE_RUNNING_COSTS", "VEHICLE_RUNNING_COST", MoneyType.OTHER),
        storedGoodsInsurance = MoneyType.OTHER,
        upkeep = self:getMoneyType("PROPERTY_MAINTENANCE", nil, MoneyType.OTHER)
    }

    -- Eigene MoneyTypes werden bewusst nicht mehr registriert.
    -- FS25 übernimmt neue MoneyTypes nicht zuverlässig als eigene Zeile in der Finanzübersicht.
    -- Deshalb werden vorhandene Grundspiel-Kategorien genutzt:
    -- Fahrzeuge/Geräte -> vehicleRunningCost, Gebäude/Silos -> propertyMaintenance,
    -- Lagergutversicherung -> other.

    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    else
        Logging.warning("[HP_OperatingCosts] MessageType.PERIOD_CHANGED not available. Monthly operating costs disabled.")
    end

    self:debug("loaded")
end

function HP_OperatingCosts:deleteMap()
    self:setHistoryWindowVisible(false)

    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    self.mission = nil
end

function HP_OperatingCosts:createEmptyFarmTotals()
    return { vehicleInsurance = 0, storedGoodsInsurance = 0, upkeep = 0, entries = {} }
end

function HP_OperatingCosts:createEmptyDiagnostics()
    return {
        detectedMotorVehicles = 0, detectedImplements = 0, nonInsurableVehicleObjects = 0, leasedVehicleObjects = 0,
        motorVehicles = 0, implements = 0, vehiclesWithPrice = 0, vehiclesWithoutPrice = 0, vehicleInsuranceEntries = 0,
        placeables = 0, placeablesWithPrice = 0, placeablesWithoutPrice = 0, upkeepEntries = 0,
        storages = 0, storagesWithValue = 0, storageInsuranceEntries = 0
    }
end

function HP_OperatingCosts:getMoneyType(primaryName, fallbackName, defaultType)
    if MoneyType == nil then
        return defaultType
    end

    if primaryName ~= nil and MoneyType[primaryName] ~= nil then
        return MoneyType[primaryName]
    end

    if fallbackName ~= nil and MoneyType[fallbackName] ~= nil then
        return MoneyType[fallbackName]
    end

    return defaultType
end

-- --------------------------------------------------------------------------
-- Ereignisse
-- --------------------------------------------------------------------------

function HP_OperatingCosts:onPeriodChanged(period)
    local mission = g_currentMission
    if mission == nil or mission.getIsServer == nil or not mission:getIsServer() then
        return
    end

    local difficultyRaw = self:getEconomyDifficultyRawValue()
    local difficultyKey = self:getEconomyDifficultyKeyFromValue(difficultyRaw)
    local rates = self.RATES[difficultyKey] or self.RATES.normal
    local totalsByFarm = {}
    local diagnosticsByFarm = {}

    self:collectVehicleCosts(totalsByFarm, rates, diagnosticsByFarm)

    local seenStorageObjects = {}
    self:collectPlaceableCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)
    self:collectStandaloneStorageCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)

    local year, month, fsPeriod, eventPeriod, environmentPeriod = self:getCurrentYearAndMonth(period)

    self:diagnostic(string.format(
        "Wirtschaftsschwierigkeit erkannt als '%s' (Rohwert: %s), Tage pro Monat: %s, Abrechnung Jahr %s / Kalendermonat %s (FS-Periode: %s, Ereigniswert: %s, Environmentwert: %s)",
        tostring(difficultyKey),
        tostring(difficultyRaw),
        tostring(self:getDaysPerPeriod()),
        tostring(year),
        tostring(month),
        tostring(fsPeriod),
        tostring(eventPeriod),
        tostring(environmentPeriod)
    ))

    local farmIds = self:getDiagnosticFarmIds(totalsByFarm, diagnosticsByFarm)
    if #farmIds == 0 then
        self:diagnostic("Monatswechsel erkannt, aber keine eigenen Fahrzeuge, Geräte, Placeables oder Lager für eine Farm gefunden.")
    end

    for _, farmId in ipairs(farmIds) do
        local totals = totalsByFarm[farmId] or self:createEmptyFarmTotals()
        local vehicleInsurance = math.floor((totals.vehicleInsurance or 0) + 0.5)
        local storedGoodsInsurance = math.floor((totals.storedGoodsInsurance or 0) + 0.5)
        local upkeep = math.floor((totals.upkeep or 0) + 0.5)

        self:logMonthlyDiagnostics(farmId, year, month, totals, diagnosticsByFarm[farmId], vehicleInsurance, storedGoodsInsurance, upkeep)

        if vehicleInsurance > 0 or storedGoodsInsurance > 0 or upkeep > 0 then
            local existingRecord = self:getHistoryRecordForPeriod(farmId, year, month)
            if existingRecord ~= nil then
                local previousVehicleInsurance = tonumber(existingRecord.vehicleInsurance) or 0
                local previousStoredGoodsInsurance = tonumber(existingRecord.storedGoodsInsurance) or 0
                local previousUpkeep = tonumber(existingRecord.upkeep) or 0

                local vehicleDelta = math.max(0, vehicleInsurance - previousVehicleInsurance)
                local storedGoodsDelta = math.max(0, storedGoodsInsurance - previousStoredGoodsInsurance)
                local upkeepDelta = math.max(0, upkeep - previousUpkeep)
                local hasPositiveDelta = vehicleDelta > 0 or storedGoodsDelta > 0 or upkeepDelta > 0
                local needsRefresh = self:historyRecordNeedsRefresh(existingRecord, totals, vehicleInsurance, storedGoodsInsurance, upkeep)

                if hasPositiveDelta then
                    if vehicleDelta > 0 then
                        self:addMoney(farmId, -vehicleDelta, self.moneyTypes.vehicleInsurance)
                    end
                    if storedGoodsDelta > 0 then
                        self:addMoney(farmId, -storedGoodsDelta, self.moneyTypes.storedGoodsInsurance)
                    end
                    if upkeepDelta > 0 then
                        self:addMoney(farmId, -upkeepDelta, self.moneyTypes.upkeep)
                    end
                end

                if hasPositiveDelta or needsRefresh then
                    -- Die History wird immer mit den aktuellen Einzelposten erneuert, damit das Fenster
                    -- keine leeren Monatsdatensätze zeigt. Bereits gebuchte Summen werden dabei nicht
                    -- nach unten korrigiert; positive Differenzen wurden oben separat gebucht.
                    local displayVehicleInsurance = math.max(previousVehicleInsurance, vehicleInsurance)
                    local displayStoredGoodsInsurance = math.max(previousStoredGoodsInsurance, storedGoodsInsurance)
                    local displayUpkeep = math.max(previousUpkeep, upkeep)
                    self:writeHistory(farmId, year, month, fsPeriod, totals, displayVehicleInsurance, displayStoredGoodsInsurance, displayUpkeep)

                    if hasPositiveDelta then
                        local template = self:getText("notification_hpOperatingCostsMonthly", "Betriebskosten abgerechnet: Fahrzeug-/Geräteversicherung %s, Lagergutversicherung %s, Unterhalt %s.")
                        local message = string.format(template, self:formatMoney(vehicleDelta), self:formatMoney(storedGoodsDelta), self:formatMoney(upkeepDelta))
                        self:showNotification(farmId, message, FSBaseMission.INGAME_NOTIFICATION_INFO)
                        self:diagnostic(string.format(
                            "Vorhandene Abrechnung für Farm %s, Jahr %s / Kalendermonat %s wurde um positive Differenzen ergänzt: Fahrzeug/Gerät %s, Lagergut %s, Unterhalt %s.",
                            tostring(farmId),
                            tostring(year),
                            tostring(month),
                            self:formatMoney(vehicleDelta),
                            self:formatMoney(storedGoodsDelta),
                            self:formatMoney(upkeepDelta)
                        ))
                    else
                        self:diagnostic(string.format(
                            "Vorhandene Abrechnung für Farm %s, Jahr %s / Kalendermonat %s wurde im Fenster aktualisiert, ohne erneut Geld zu buchen.",
                            tostring(farmId),
                            tostring(year),
                            tostring(month)
                        ))
                    end
                else
                    self:diagnostic(string.format(
                        "Abrechnung für Farm %s, Jahr %s / Kalendermonat %s ist bereits vollständig vorhanden. Erneute Finanzbuchung wird verhindert.",
                        tostring(farmId),
                        tostring(year),
                        tostring(month)
                    ))
                end
            else
                if vehicleInsurance > 0 then
                    self:addMoney(farmId, -vehicleInsurance, self.moneyTypes.vehicleInsurance)
                end
                if storedGoodsInsurance > 0 then
                    self:addMoney(farmId, -storedGoodsInsurance, self.moneyTypes.storedGoodsInsurance)
                end
                if upkeep > 0 then
                    self:addMoney(farmId, -upkeep, self.moneyTypes.upkeep)
                end

                self:writeHistory(farmId, year, month, fsPeriod, totals, vehicleInsurance, storedGoodsInsurance, upkeep)

                local template = self:getText("notification_hpOperatingCostsMonthly", "Betriebskosten abgerechnet: Fahrzeug-/Geräteversicherung %s, Lagergutversicherung %s, Unterhalt %s.")
                local message = string.format(template, self:formatMoney(vehicleInsurance), self:formatMoney(storedGoodsInsurance), self:formatMoney(upkeep))
                self:showNotification(farmId, message, FSBaseMission.INGAME_NOTIFICATION_INFO)
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Kostenberechnung
-- --------------------------------------------------------------------------

function HP_OperatingCosts:getMissionVehicles(mission)
    if mission == nil then
        return nil
    end

    if mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles ~= nil then
        return mission.vehicleSystem.vehicles
    end

    -- Fallback für ältere oder abweichende Scriptstände. In FS25 liegt die relevante Liste
    -- normalerweise unter g_currentMission.vehicleSystem.vehicles.
    return mission.vehicles
end

function HP_OperatingCosts:collectVehicleCosts(totalsByFarm, rates, diagnosticsByFarm)
    local mission = g_currentMission
    local vehicles = self:getMissionVehicles(mission)
    if vehicles == nil then
        return
    end

    local seen = {}

    for _, vehicle in pairs(vehicles) do
        if vehicle ~= nil and not vehicle.isDeleted then
            local farmId = self:getOwnerFarmId(vehicle)
            if self:isValidFarmId(farmId) then
                local uniqueId = self:getUniqueObjectId(vehicle)
                if uniqueId == nil or not seen[uniqueId] then
                    if uniqueId ~= nil then
                        seen[uniqueId] = true
                    end

                    local isMotorVehicle = self:isMotorVehicle(vehicle)
                    local price = self:getVehiclePrice(vehicle)
                    local rate = isMotorVehicle and rates.motorVehicleInsurance or rates.implementInsurance
                    local insurance = 0
                    if price > 0 then
                        insurance = price * rate
                    end

                    local isInsurable, exclusionReason = self:isInsurableVehicleObject(vehicle)
                    local isOwned = self:isOwnedVehicle(vehicle)
                    local isBillable = isOwned and isInsurable
                    local diag = self:getDiagnostics(diagnosticsByFarm, farmId)

                    if isInsurable then
                        if isMotorVehicle then
                            diag.detectedMotorVehicles = diag.detectedMotorVehicles + 1
                        else
                            diag.detectedImplements = diag.detectedImplements + 1
                        end
                    else
                        diag.nonInsurableVehicleObjects = diag.nonInsurableVehicleObjects + 1
                    end

                    if isInsurable and not isOwned then
                        diag.leasedVehicleObjects = diag.leasedVehicleObjects + 1
                    end

                    self:logVehicleObjectDiagnostics(vehicle, farmId, isMotorVehicle, price, rate, insurance, isBillable, isInsurable, exclusionReason)

                    if isBillable then
                        if isMotorVehicle then
                            diag.motorVehicles = diag.motorVehicles + 1
                        else
                            diag.implements = diag.implements + 1
                        end

                        if price > 0 then
                            diag.vehiclesWithPrice = diag.vehiclesWithPrice + 1

                            -- Versicherung ist bewusst eine eigene Kostenart und wird nicht mit
                            -- vorhandenem dailyUpkeep verrechnet. Der dailyUpkeep des Spiels steht
                            -- eher für Wartung/Verschleiß/Unterhalt; eine Gegenrechnung würde dazu
                            -- führen, dass Standardfahrzeuge häufig überhaupt keine Versicherung zahlen.
                            if insurance > 0 then
                                diag.vehicleInsuranceEntries = diag.vehicleInsuranceEntries + 1
                                local category = isMotorVehicle and "vehicle" or "implement"
                                self:addCostEntry(totalsByFarm, farmId, "vehicleInsurance", insurance, category, self:getObjectName(vehicle), price, rate, "vehicleRunningCost")
                            end
                        else
                            diag.vehiclesWithoutPrice = diag.vehiclesWithoutPrice + 1
                        end
                    end
                end
            end
        end
    end
end

function HP_OperatingCosts:collectPlaceableCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil or mission.placeableSystem.placeables == nil then
        return
    end

    local daysPerPeriod = self:getDaysPerPeriod()

    for _, placeable in pairs(mission.placeableSystem.placeables) do
        if placeable ~= nil and not placeable.isDeleted then
            local farmId = self:getOwnerFarmId(placeable)
            if self:isValidFarmId(farmId) and self:isOwnedPlaceable(placeable) then
                local diag = self:getDiagnostics(diagnosticsByFarm, farmId)
                diag.placeables = diag.placeables + 1

                if self:hasStorageData(placeable) then
                    diag.storages = diag.storages + 1
                end

                local price = self:getPlaceablePrice(placeable)
                if price > 0 then
                    diag.placeablesWithPrice = diag.placeablesWithPrice + 1

                    local targetMonthly = price * rates.placeableUpkeep
                    local nativeMonthly = self:getNativeMonthlyUpkeep(placeable, daysPerPeriod)
                    local additional = math.max(0, targetMonthly - nativeMonthly)

                    if additional > 0 then
                        diag.upkeepEntries = diag.upkeepEntries + 1
                        self:addCostEntry(totalsByFarm, farmId, "upkeep", additional, "placeable", self:getObjectName(placeable), price, rates.placeableUpkeep, "propertyMaintenance", targetMonthly, nativeMonthly)
                    end
                else
                    diag.placeablesWithoutPrice = diag.placeablesWithoutPrice + 1
                end

                local storageInsurance, storedGoodsValue, storageTotals = self:getStoredGoodsInsurance(placeable, rates, seenStorageObjects, farmId, "Placeable")
                if storedGoodsValue > 0 then
                    diag.storagesWithValue = diag.storagesWithValue + 1
                    self:rememberStorageTotalsSignature(seenStorageObjects, farmId, storageTotals)
                end
                if storageInsurance > 0 then
                    diag.storageInsuranceEntries = diag.storageInsuranceEntries + 1
                    local storageName = self:formatStoredGoodsEntryName(self:getObjectName(placeable), storageTotals)
                    self:addCostEntry(totalsByFarm, farmId, "storedGoodsInsurance", storageInsurance, "storedGoods", storageName, storedGoodsValue, rates.storedGoodsInsurance, "other")
                end
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Hilfsfunktionen: Preise und Typen
-- --------------------------------------------------------------------------

function HP_OperatingCosts:getVehiclePrice(vehicle)
    local price = self:safeCall(vehicle, "getPrice")
    if price == nil or price <= 0 then
        price = vehicle.price
    end
    if (price == nil or price <= 0) and vehicle.configFileName ~= nil and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
        local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        if storeItem ~= nil then
            price = storeItem.price
        end
    end
    return tonumber(price) or 0
end

function HP_OperatingCosts:getPlaceablePrice(placeable)
    local price = self:safeCall(placeable, "getPrice")
    if price == nil or price <= 0 then
        price = placeable.price
    end
    if (price == nil or price <= 0) and placeable.storeItem ~= nil then
        price = placeable.storeItem.price
    end

    if price == nil or price <= 0 then
        price = self:getFallbackPlaceablePrice(placeable)
    end

    return tonumber(price) or 0
end

function HP_OperatingCosts:getFallbackPlaceablePrice(placeable)
    if placeable == nil then
        return 0
    end

    if placeable.spec_husbandryAnimals ~= nil or placeable.spec_animalHusbandry ~= nil then
        return self.FALLBACK_PLACEABLE_PRICES.animal
    end

    if placeable.spec_productionPoint ~= nil or placeable.spec_productions ~= nil then
        return self.FALLBACK_PLACEABLE_PRICES.production
    end

    if placeable.spec_silo ~= nil or placeable.spec_siloExtension ~= nil or placeable.spec_storage ~= nil then
        return self.FALLBACK_PLACEABLE_PRICES.silo
    end

    local name = ""
    if placeable.getName ~= nil then
        name = tostring(placeable:getName() or ""):lower()
    elseif placeable.storeItem ~= nil and placeable.storeItem.name ~= nil then
        name = tostring(placeable.storeItem.name):lower()
    end

    if string.find(name, "farmhouse") ~= nil or string.find(name, "wohn") ~= nil or string.find(name, "haus") ~= nil then
        return self.FALLBACK_PLACEABLE_PRICES.farmhouse
    end

    if placeable.boughtWithFarmland or placeable.isPreplaced then
        return self.FALLBACK_PLACEABLE_PRICES.default
    end

    return 0
end


function HP_OperatingCosts:getNativeMonthlyUpkeep(object, daysPerPeriod)
    local daily = self:safeCall(object, "getDailyUpkeep")
    if daily == nil then
        daily = 0
    end
    return math.max(0, tonumber(daily) or 0) * math.max(1, daysPerPeriod or 1)
end


function HP_OperatingCosts:getStoreItem(object)
    if object == nil then
        return nil
    end

    if object.storeItem ~= nil then
        return object.storeItem
    end

    if object.configFileName ~= nil and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
        local ok, storeItem = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, object.configFileName)
        if ok then
            return storeItem
        end
    end

    return nil
end

function HP_OperatingCosts:getStoreCategoryName(object)
    local storeItem = self:getStoreItem(object)
    if storeItem == nil then
        return "unknown"
    end

    local category = storeItem.categoryName or storeItem.category or storeItem.categoryText or storeItem.categoryTitle
    if category ~= nil and category ~= "" then
        return tostring(category)
    end

    if storeItem.categoryIndex ~= nil then
        return "categoryIndex=" .. tostring(storeItem.categoryIndex)
    end

    return "unknown"
end

function HP_OperatingCosts:getVehicleTypeName(vehicle)
    if vehicle == nil then
        return "unknown"
    end

    local typeName = vehicle.typeName or vehicle.vehicleType or vehicle.typeId or vehicle.xmlFilename
    if type(typeName) == "table" then
        typeName = typeName.name or typeName.typeName or typeName.className
    end

    if typeName ~= nil and typeName ~= "" then
        return tostring(typeName)
    end

    local storeItem = self:getStoreItem(vehicle)
    if storeItem ~= nil then
        typeName = storeItem.typeName or storeItem.typeId
        if typeName ~= nil and typeName ~= "" then
            return tostring(typeName)
        end
    end

    return "unknown"
end

function HP_OperatingCosts:getVehiclePropertyStateInfo(vehicle)
    local state = nil

    if vehicle ~= nil and vehicle.getPropertyState ~= nil then
        local ok, value = pcall(vehicle.getPropertyState, vehicle)
        if ok then
            state = value
        end
    end

    if state == nil and vehicle ~= nil then
        state = vehicle.propertyState
    end

    local label = "unknown"
    local leased = false

    if state ~= nil and VehiclePropertyState ~= nil then
        if VehiclePropertyState.OWNED ~= nil and state == VehiclePropertyState.OWNED then
            label = "OWNED(" .. tostring(state) .. ")"
        elseif VehiclePropertyState.LEASED ~= nil and state == VehiclePropertyState.LEASED then
            label = "LEASED(" .. tostring(state) .. ")"
            leased = true
        elseif VehiclePropertyState.MISSION ~= nil and state == VehiclePropertyState.MISSION then
            label = "MISSION(" .. tostring(state) .. ")"
        else
            label = tostring(state)
        end
    elseif state ~= nil then
        label = tostring(state)
    end

    return label, leased
end

function HP_OperatingCosts:getConfigFileShortName(object)
    local fileName = object ~= nil and object.configFileName or nil
    if fileName == nil or fileName == "" then
        return "unknown"
    end

    fileName = tostring(fileName)
    local shortName = string.match(fileName, "([^/\\]+)$")
    return shortName or fileName
end

function HP_OperatingCosts:getVehicleSpecializationList(vehicle)
    if vehicle == nil then
        return "none"
    end

    local names = {}
    local seen = {}

    local function addName(value)
        if value == nil then
            return
        end
        value = tostring(value)
        if value == "" or seen[value] then
            return
        end
        seen[value] = true
        table.insert(names, value)
    end

    if vehicle.specializationNames ~= nil then
        for _, name in pairs(vehicle.specializationNames) do
            addName(name)
        end
    end

    if vehicle.specializations ~= nil then
        for _, specialization in pairs(vehicle.specializations) do
            if type(specialization) == "string" then
                addName(specialization)
            elseif type(specialization) == "table" then
                addName(specialization.name or specialization.className or specialization.typeName)
                if specialization.classObject ~= nil then
                    addName(specialization.classObject.name or specialization.classObject.className or specialization.classObject.typeName)
                end
            end
        end
    end

    for key, value in pairs(vehicle) do
        if type(key) == "string" and string.sub(key, 1, 5) == "spec_" and value ~= nil then
            addName(key)
        end
    end

    table.sort(names)

    if #names == 0 then
        return "none"
    end

    local maxCount = 35
    if #names > maxCount then
        local trimmed = {}
        for i = 1, maxCount do
            table.insert(trimmed, names[i])
        end
        table.insert(trimmed, "...+" .. tostring(#names - maxCount))
        names = trimmed
    end

    return table.concat(names, ",")
end

function HP_OperatingCosts:formatDiagnosticNumber(value, decimals)
    value = tonumber(value) or 0
    decimals = decimals or 0
    return string.format("%." .. tostring(decimals) .. "f", value)
end

function HP_OperatingCosts:logVehicleObjectDiagnostics(vehicle, farmId, isMotorVehicle, price, rate, insurance, billable, insurable, exclusionReason)
    if not self.DIAGNOSTIC_LOGGING then
        return
    end

    local propertyStateLabel, leased = self:getVehiclePropertyStateInfo(vehicle)
    local classification = isMotorVehicle and "Fahrzeug" or "Geraet/Anhaenger"
    local reason = exclusionReason or ""
    if insurable and leased then
        reason = "Leasing"
    elseif insurable and not billable then
        reason = reason ~= "" and reason or "nicht abrechenbar"
    end

    self:diagnostic(string.format(
        "Fahrzeugobjekt: Farm=%s, Name='%s', StoreKategorie='%s', VehicleType='%s', Config='%s', Wert=%s, PropertyState=%s, Leasing=%s, Einstufung=%s, Versicherbar=%s, Ausschlussgrund='%s', Satz=%.6f, Versicherungsbetrag=%s, Abrechnung=%s, Spezialisierungen=%s",
        tostring(farmId),
        self:sanitizeLogText(self:getObjectName(vehicle)),
        self:sanitizeLogText(self:getStoreCategoryName(vehicle)),
        self:sanitizeLogText(self:getVehicleTypeName(vehicle)),
        self:sanitizeLogText(self:getConfigFileShortName(vehicle)),
        self:formatDiagnosticNumber(price, 2),
        self:sanitizeLogText(propertyStateLabel),
        leased and "ja" or "nein",
        classification,
        insurable and "ja" or "nein",
        self:sanitizeLogText(reason),
        tonumber(rate) or 0,
        self:formatDiagnosticNumber(insurance, 2),
        billable and "ja" or "nein",
        self:sanitizeLogText(self:getVehicleSpecializationList(vehicle))
    ))
end

function HP_OperatingCosts:sanitizeLogText(value)
    value = tostring(value or "")
    value = string.gsub(value, "[\r\n\t]", " ")
    value = string.gsub(value, "%s+", " ")
    if string.len(value) > 600 then
        value = string.sub(value, 1, 597) .. "..."
    end
    return value
end

function HP_OperatingCosts:isMotorVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.spec_motorized ~= nil or vehicle.getMotor ~= nil then
        return true
    end

    if vehicle.configFileName ~= nil and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
        local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        if storeItem ~= nil then
            if storeItem.specs ~= nil and storeItem.specs.power ~= nil then
                return true
            end
            local category = tostring(storeItem.categoryName or storeItem.category or ""):lower()
            if string.find(category, "tractor") ~= nil or string.find(category, "harvester") ~= nil or string.find(category, "car") ~= nil or string.find(category, "truck") ~= nil then
                return true
            end
        end
    end

    return false
end

function HP_OperatingCosts:isInsurableVehicleObject(vehicle)
    if vehicle == nil then
        return false, "kein Objekt"
    end

    local category = string.upper(tostring(self:getStoreCategoryName(vehicle) or ""))
    local vehicleType = string.lower(tostring(self:getVehicleTypeName(vehicle) or ""))

    -- Paletten, BigBags, Ballen und ähnliche Verbrauchs-/Lagerobjekte laufen in FS25
    -- technisch ebenfalls über das Vehicle-System. Sie sind aber keine Fahrzeuge,
    -- Anhänger oder landwirtschaftlichen Geräte und dürfen deshalb nicht über die
    -- Fahrzeug-/Geräteversicherung abgerechnet werden.
    local excludedCategories = {
        PALLETS = true,
        BIGBAGS = true,
        BIGBAGPALLETS = true,
        BALES = true,
        WOOD = true
    }

    if excludedCategories[category] then
        return false, "StoreKategorie " .. category
    end

    if string.find(vehicleType, "pallet") ~= nil then
        return false, "VehicleType pallet"
    end
    if string.find(vehicleType, "bigbag") ~= nil then
        return false, "VehicleType bigBag"
    end
    if string.find(vehicleType, "bale") ~= nil then
        return false, "VehicleType bale"
    end

    if vehicle.spec_pallet ~= nil then
        return false, "Spezialisierung pallet"
    end
    if vehicle.spec_bigBag ~= nil then
        return false, "Spezialisierung bigBag"
    end
    if vehicle.spec_bale ~= nil then
        return false, "Spezialisierung bale"
    end

    return true, ""
end

function HP_OperatingCosts:isOwnedVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.getPropertyState ~= nil and VehiclePropertyState ~= nil then
        local ok, state = pcall(vehicle.getPropertyState, vehicle)
        if ok then
            if VehiclePropertyState.LEASED ~= nil and state == VehiclePropertyState.LEASED then
                return false
            end
            if VehiclePropertyState.OWNED ~= nil then
                return state == VehiclePropertyState.OWNED
            end
        end
    end

    if vehicle.propertyState ~= nil and VehiclePropertyState ~= nil and VehiclePropertyState.LEASED ~= nil then
        return vehicle.propertyState ~= VehiclePropertyState.LEASED
    end

    return true
end

function HP_OperatingCosts:isOwnedPlaceable(placeable)
    if placeable == nil then
        return false
    end

    local farmId = self:getOwnerFarmId(placeable)
    if not self:isValidFarmId(farmId) then
        return false
    end

    if PlaceablePropertyState ~= nil then
        local state = nil
        if placeable.getPropertyState ~= nil then
            local ok, result = pcall(placeable.getPropertyState, placeable)
            if ok then
                state = result
            end
        elseif placeable.propertyState ~= nil then
            state = placeable.propertyState
        end

        if state ~= nil then
            -- Vorschauobjekte aus Shop/Baumenue nie abrechnen. Alle anderen Placeables
            -- mit echter Farmzuordnung gelten als abrechenbar, damit auch mit Farmland
            -- erworbene Karten-Silos und Hofgebaeude erfasst werden.
            if PlaceablePropertyState.CONSTRUCTION_PREVIEW ~= nil and state == PlaceablePropertyState.CONSTRUCTION_PREVIEW then
                return false
            end
            if PlaceablePropertyState.PREVIEW ~= nil and state == PlaceablePropertyState.PREVIEW then
                return false
            end
        end
    end

    return true
end

function HP_OperatingCosts:getStoredGoodsInsurance(placeable, rates, seenStorageObjects, ownerFarmId, sourceName)
    local totals, value = self:getStoredGoodsTotals(placeable, seenStorageObjects, ownerFarmId, sourceName or "Placeable")
    if value <= 0 then
        return 0, 0, totals
    end
    return value * rates.storedGoodsInsurance, value, totals
end

function HP_OperatingCosts:hasStorageData(placeable)
    if placeable == nil then
        return false
    end

    return placeable.getFillLevels ~= nil
        or placeable.spec_storage ~= nil
        or placeable.spec_silo ~= nil
        or placeable.spec_siloExtension ~= nil
        or placeable.spec_productionPoint ~= nil
        or placeable.spec_productions ~= nil
end

function HP_OperatingCosts:collectStandaloneStorageCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)
    local mission = g_currentMission
    local storages = self:getMissionStorageObjects(mission)
    if storages == nil or #storages == 0 then
        self:storageDiagnostic("StorageSystem: keine separaten Storage-Objekte gefunden")
        return
    end

    for _, storage in ipairs(storages) do
        local farmId = self:getStorageOwnerFarmId(storage)
        local farmIds = {}
        if self:isValidFarmId(farmId) then
            table.insert(farmIds, farmId)
        else
            -- Einige globale Storage-Objekte tragen selbst keine Farm-ID, liefern
            -- die Fuellstaende aber erst bei Abfrage mit Farm-ID. Dann werden
            -- alle echten Farmen defensiv ausprobiert.
            farmIds = self:getAllValidFarmIds()
            if #farmIds == 0 then
                self:storageDiagnostic(string.format(
                    "StorageSystem-Lager uebersprungen: Farm=%s, Name='%s'",
                    tostring(farmId),
                    tostring(self:getStorageObjectName(storage))
                ))
            end
        end

        for _, candidateFarmId in ipairs(farmIds) do
            local storageTotals = {}
            local added = self:collectStorageFillLevels(storage, storageTotals, seenStorageObjects, candidateFarmId, "StorageSystem")
            local storedGoodsValue = self:getStoredGoodsValueFromTotals(storageTotals)
            local storageInsurance = 0
            if storedGoodsValue > 0 then
                storageInsurance = storedGoodsValue * rates.storedGoodsInsurance
            end

            local diag = self:getDiagnostics(diagnosticsByFarm, candidateFarmId)
            diag.storages = diag.storages + 1
            if storedGoodsValue > 0 then
                diag.storagesWithValue = diag.storagesWithValue + 1
            end

            self:storageDiagnostic(string.format(
                "StorageSystem-Lager: Farm=%s, Name='%s', Werte=%s, Warenwert=%.2f, Versicherung=%.2f, hinzugefuegte_Fuelltypen=%s",
                tostring(candidateFarmId),
                tostring(self:getStorageObjectName(storage)),
                self:formatStorageTotals(storageTotals),
                storedGoodsValue,
                storageInsurance,
                tostring(added or 0)
            ))

            if storageInsurance > 0 then
                if self:hasStorageTotalsSignature(seenStorageObjects, candidateFarmId, storageTotals) then
                    self:storageDiagnostic(string.format(
                        "StorageSystem-Lager uebersprungen, weil dieselben Fuellstaende bereits ueber ein Placeable erfasst wurden: Farm=%s, Werte=%s",
                        tostring(candidateFarmId),
                        self:formatStorageTotals(storageTotals)
                    ))
                else
                    self:rememberStorageTotalsSignature(seenStorageObjects, candidateFarmId, storageTotals)
                    diag.storageInsuranceEntries = diag.storageInsuranceEntries + 1
                    local storageName = self:formatStoredGoodsEntryName(self:getStorageObjectName(storage), storageTotals)
                    self:addCostEntry(totalsByFarm, candidateFarmId, "storedGoodsInsurance", storageInsurance, "storedGoods", storageName, storedGoodsValue, rates.storedGoodsInsurance, "other")
                end
            end
        end
    end
end

function HP_OperatingCosts:getMissionStorageObjects(mission)
    local result = {}
    local seen = {}
    if mission == nil then
        return result
    end

    local systems = {
        mission.storageSystem,
        mission.storageSystems,
        mission.storageManager,
        mission.storages
    }

    for _, system in ipairs(systems) do
        self:collectStorageCandidates(result, seen, system, 0)
    end

    return result
end

function HP_OperatingCosts:collectStorageCandidates(result, seen, candidate, depth)
    if candidate == nil or type(candidate) ~= "table" or depth > 3 then
        return
    end

    if self:looksLikeStorageObject(candidate) then
        if not seen[candidate] then
            seen[candidate] = true
            table.insert(result, candidate)
        end
        return
    end

    local keys = {
        "storages", "storageIdToStorage", "storageNameToStorage", "farmStorages",
        "storageByFarmId", "storageById", "storageMap", "storageToPlaceable"
    }

    for _, key in ipairs(keys) do
        local value = candidate[key]
        if type(value) == "table" then
            for _, child in pairs(value) do
                self:collectStorageCandidates(result, seen, child, depth + 1)
            end
        end
    end

    -- Wenn direkt eine Liste von Storages uebergeben wurde, gibt es keine
    -- benannten Felder. Dann werden die direkten Tabellenwerte ebenfalls geprueft.
    if depth <= 1 then
        for _, child in pairs(candidate) do
            if type(child) == "table" then
                self:collectStorageCandidates(result, seen, child, depth + 1)
            end
        end
    end
end

function HP_OperatingCosts:looksLikeStorageObject(object)
    if object == nil or type(object) ~= "table" then
        return false
    end

    return object.getFillLevels ~= nil
        or object.getFillLevel ~= nil
        or object.fillLevels ~= nil
        or object.fillTypes ~= nil
end

function HP_OperatingCosts:getStoredGoodsTotals(placeable, seenStorageObjects, ownerFarmId, sourceName)
    local totals = {}
    local directTotals = {}

    -- Manche Silo-Klassen brauchen die Farm-ID als Parameter. Deshalb wird die
    -- Besitzerfarm jetzt konsequent an die Fuellstandsabfrage weitergereicht.
    local directCount = self:collectStorageFillLevels(placeable, directTotals, seenStorageObjects, ownerFarmId, sourceName or "PlaceableDirekt")
    if directCount ~= nil and directCount > 0 then
        totals = directTotals
    else
        self:collectStorageFillLevelsFromSpec(placeable.spec_storage, totals, seenStorageObjects, ownerFarmId, "spec_storage")
        self:collectStorageFillLevelsFromSpec(placeable.spec_silo, totals, seenStorageObjects, ownerFarmId, "spec_silo")
        self:collectStorageFillLevelsFromSpec(placeable.spec_siloExtension, totals, seenStorageObjects, ownerFarmId, "spec_siloExtension")
        self:collectStorageFillLevelsFromSpec(placeable.spec_productionPoint, totals, seenStorageObjects, ownerFarmId, "spec_productionPoint")
        self:collectStorageFillLevelsFromSpec(placeable.spec_productions, totals, seenStorageObjects, ownerFarmId, "spec_productions")
    end

    local value = self:getStoredGoodsValueFromTotals(totals)
    self:storageDiagnostic(string.format(
        "Placeable-Lager: Farm=%s, Name='%s', Quelle=%s, Werte=%s, Warenwert=%.2f",
        tostring(ownerFarmId),
        tostring(self:getObjectName(placeable)),
        tostring(sourceName or "Placeable"),
        self:formatStorageTotals(totals),
        value
    ))

    return totals, value
end


function HP_OperatingCosts:getStoredGoodsValueFromTotals(totals)
    local value = 0
    for fillTypeIndex, fillLevel in pairs(totals or {}) do
        local pricePerLiter = self:getPricePerLiter(fillTypeIndex)
        if pricePerLiter > 0 and fillLevel > 0 then
            value = value + fillLevel * pricePerLiter
        end
    end
    return value
end

function HP_OperatingCosts:collectStorageFillLevelsFromSpec(spec, totals, seenStorageObjects, ownerFarmId, sourceName)
    if spec == nil then
        return 0
    end

    local added = 0
    added = added + self:collectStorageFillLevels(spec.storage, totals, seenStorageObjects, ownerFarmId, tostring(sourceName or "spec") .. ".storage")

    if spec.storages ~= nil then
        for _, storage in pairs(spec.storages) do
            added = added + self:collectStorageFillLevels(storage, totals, seenStorageObjects, ownerFarmId, tostring(sourceName or "spec") .. ".storages")
        end
    end

    if spec.inputStorage ~= nil then
        added = added + self:collectStorageFillLevels(spec.inputStorage, totals, seenStorageObjects, ownerFarmId, tostring(sourceName or "spec") .. ".inputStorage")
    end

    if spec.outputStorage ~= nil then
        added = added + self:collectStorageFillLevels(spec.outputStorage, totals, seenStorageObjects, ownerFarmId, tostring(sourceName or "spec") .. ".outputStorage")
    end

    return added
end

function HP_OperatingCosts:collectStorageFillLevels(storage, totals, seenStorageObjects, ownerFarmId, sourceName)
    if storage == nil then
        return 0
    end

    if seenStorageObjects ~= nil and seenStorageObjects[storage] == true then
        return 0
    end

    local added = 0
    local function tryAddFillLevels(callDescription, ...)
        local ok, fillLevels = pcall(storage.getFillLevels, storage, ...)
        if ok and fillLevels ~= nil then
            local count = self:addStorageFillLevelsTable(totals, fillLevels, 0)
            if count > 0 then
                self:storageDiagnostic(string.format("Lager-Fuellstaende gelesen: Quelle=%s, Methode=%s, Anzahl=%s", tostring(sourceName), tostring(callDescription), tostring(count)))
            end
            return count
        end
        return 0
    end

    -- getFillLevels() ist die bevorzugte Quelle. Einige Silos liefern Werte nur,
    -- wenn die Farm-ID mitgegeben wird.
    if storage.getFillLevels ~= nil then
        added = added + tryAddFillLevels("getFillLevels()")
        if added == 0 and ownerFarmId ~= nil then
            added = added + tryAddFillLevels("getFillLevels(farmId)", ownerFarmId)
        end
    end

    if added == 0 and storage.fillLevels ~= nil then
        added = added + self:addStorageFillLevelsTable(totals, storage.fillLevels, 0)
        if added > 0 then
            self:storageDiagnostic(string.format("Lager-Fuellstaende gelesen: Quelle=%s, Methode=fillLevels, Anzahl=%s", tostring(sourceName), tostring(added)))
        end
    end

    if added == 0 and storage.getFillLevel ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for fillTypeIndex, _ in pairs(g_fillTypeManager.fillTypes) do
            local index = tonumber(fillTypeIndex)
            if index ~= nil then
                local ok, fillLevel = pcall(storage.getFillLevel, storage, index)
                if ok then
                    added = added + self:addStorageFillLevel(totals, index, fillLevel)
                end

                if ownerFarmId ~= nil then
                    local okWithFarm, fillLevelWithFarm = pcall(storage.getFillLevel, storage, index, ownerFarmId)
                    if okWithFarm then
                        added = added + self:addStorageFillLevel(totals, index, fillLevelWithFarm)
                    end
                end
            end
        end
        if added > 0 then
            self:storageDiagnostic(string.format("Lager-Fuellstaende gelesen: Quelle=%s, Methode=getFillLevel, Anzahl=%s", tostring(sourceName), tostring(added)))
        end
    end

    if added > 0 and seenStorageObjects ~= nil and type(storage) == "table" then
        seenStorageObjects[storage] = true
    end

    return added
end

function HP_OperatingCosts:addStorageFillLevelsTable(totals, fillLevels, depth)
    if type(fillLevels) ~= "table" then
        return 0
    end
    depth = depth or 0
    if depth > 4 then
        return 0
    end

    local added = 0
    for fillTypeKey, fillLevel in pairs(fillLevels) do
        local before = added
        added = added + self:addStorageFillLevel(totals, fillTypeKey, fillLevel)

        -- Manche FS-Strukturen verschachteln Fuellstaende erst nach Farm-ID oder
        -- Storage-ID. Wenn der Eintrag selbst keine Menge enthaelt, wird rekursiv gesucht.
        if added == before and type(fillLevel) == "table" and self:getStorageFillLevelAmount(fillLevel) <= 0 then
            added = added + self:addStorageFillLevelsTable(totals, fillLevel, depth + 1)
        end
    end
    return added
end

function HP_OperatingCosts:addStorageFillLevel(totals, fillTypeKey, fillLevel)
    local fillTypeIndex = self:getFillTypeIndexFromStorageKey(fillTypeKey, fillLevel)
    local amount = self:getStorageFillLevelAmount(fillLevel)

    if fillTypeIndex ~= nil and amount > 0 then
        totals[fillTypeIndex] = (totals[fillTypeIndex] or 0) + amount
        return 1
    end

    return 0
end

function HP_OperatingCosts:getStorageFillLevelAmount(fillLevel)
    if type(fillLevel) == "table" then
        return tonumber(fillLevel.fillLevel or fillLevel.level or fillLevel.amount or fillLevel.value or fillLevel.liters or fillLevel.fillAmount) or 0
    end

    return tonumber(fillLevel) or 0
end

function HP_OperatingCosts:getFillTypeIndexFromStorageKey(fillTypeKey, fillLevel)
    local index = tonumber(fillTypeKey)
    if index ~= nil then
        return index
    end

    if type(fillLevel) == "table" then
        index = tonumber(fillLevel.fillTypeIndex or fillLevel.index or fillLevel.fillType)
        if index ~= nil then
            return index
        end
        if fillLevel.fillTypeName ~= nil then
            fillTypeKey = fillLevel.fillTypeName
        elseif fillLevel.name ~= nil then
            fillTypeKey = fillLevel.name
        end
    end

    local name = tostring(fillTypeKey or "")
    if name ~= "" and g_fillTypeManager ~= nil then
        if g_fillTypeManager.getFillTypeByName ~= nil then
            local fillType = g_fillTypeManager:getFillTypeByName(string.upper(name)) or g_fillTypeManager:getFillTypeByName(name)
            if fillType ~= nil then
                return fillType.index
            end
        end
        if g_fillTypeManager.nameToIndex ~= nil then
            return g_fillTypeManager.nameToIndex[string.upper(name)] or g_fillTypeManager.nameToIndex[name]
        end
    end

    return nil
end

function HP_OperatingCosts:getPricePerLiter(fillTypeIndex)
    if fillTypeIndex == nil then
        return 0
    end

    local economy = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if economy ~= nil then
        if economy.getPricePerLiter ~= nil then
            local ok, value = pcall(economy.getPricePerLiter, economy, fillTypeIndex)
            if ok and value ~= nil then
                return tonumber(value) or 0
            end
        end
        if economy.getFillTypePrice ~= nil then
            local ok, value = pcall(economy.getFillTypePrice, economy, fillTypeIndex)
            if ok and value ~= nil then
                return tonumber(value) or 0
            end
        end
    end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil then
            return tonumber(fillType.pricePerLiter or fillType.price) or 0
        end
    end

    return 0
end

function HP_OperatingCosts:getAllValidFarmIds()
    local farmIds = {}

    if g_farmManager ~= nil and g_farmManager.farms ~= nil then
        for farmId, _ in pairs(g_farmManager.farms) do
            local numericFarmId = tonumber(farmId)
            if numericFarmId ~= nil and self:isValidFarmId(numericFarmId) then
                table.insert(farmIds, numericFarmId)
            end
        end
    end

    local missionFarmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local ok, value = pcall(g_currentMission.getFarmId, g_currentMission)
        if ok then
            missionFarmId = tonumber(value)
        end
    end

    if missionFarmId ~= nil and self:isValidFarmId(missionFarmId) then
        local exists = false
        for _, farmId in ipairs(farmIds) do
            if farmId == missionFarmId then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(farmIds, missionFarmId)
        end
    end

    table.sort(farmIds)
    return farmIds
end

function HP_OperatingCosts:getStorageOwnerFarmId(storage)
    local farmId = self:getOwnerFarmId(storage)
    if self:isValidFarmId(farmId) then
        return farmId
    end

    local relatedObjects = {
        storage.placeable, storage.owningPlaceable, storage.ownerPlaceable,
        storage.parentPlaceable, storage.station, storage.loadingStation,
        storage.unloadingStation, storage.owner
    }

    for _, object in ipairs(relatedObjects) do
        farmId = self:getOwnerFarmId(object)
        if self:isValidFarmId(farmId) then
            return farmId
        end
    end

    return farmId
end

function HP_OperatingCosts:getStorageObjectName(storage)
    if storage == nil then
        return "Lager"
    end

    local relatedNameObjects = {
        storage.placeable, storage.owningPlaceable, storage.ownerPlaceable,
        storage.parentPlaceable, storage.station, storage.loadingStation,
        storage.unloadingStation, storage.owner
    }

    for _, object in ipairs(relatedNameObjects) do
        if object ~= nil then
            local name = self:getObjectName(object)
            if name ~= nil and name ~= "" and name ~= "Unbekannt" then
                return name
            end
        end
    end

    return tostring(storage.name or storage.customName or storage.title or "Lager")
end

function HP_OperatingCosts:formatStorageTotals(totals)
    local parts = {}
    for fillTypeIndex, amount in pairs(totals or {}) do
        local name = self:getFillTypeDisplayName(fillTypeIndex)
        local price = self:getPricePerLiter(fillTypeIndex)
        table.insert(parts, string.format("%s=%.2fl@%.5f", tostring(name), tonumber(amount) or 0, tonumber(price) or 0))
    end
    if #parts == 0 then
        return "keine"
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

function HP_OperatingCosts:getStorageFillTypeNames(totals)
    local names = {}
    for fillTypeIndex, amount in pairs(totals or {}) do
        if (tonumber(amount) or 0) > 0 then
            table.insert(names, tostring(self:getFillTypeDisplayName(fillTypeIndex)))
        end
    end
    table.sort(names)
    return names
end

function HP_OperatingCosts:formatStoredGoodsEntryName(baseName, totals)
    local names = self:getStorageFillTypeNames(totals)
    if #names == 0 then
        return baseName or "Lager"
    end

    return string.format("%s (%s)", tostring(baseName or "Lager"), table.concat(names, ", "))
end

function HP_OperatingCosts:getStorageTotalsSignature(totals)
    local parts = {}
    for fillTypeIndex, amount in pairs(totals or {}) do
        amount = tonumber(amount) or 0
        if amount > 0 then
            table.insert(parts, string.format("%s=%.2f", tostring(fillTypeIndex), amount))
        end
    end

    if #parts == 0 then
        return nil
    end

    table.sort(parts)
    return table.concat(parts, "|")
end

function HP_OperatingCosts:rememberStorageTotalsSignature(seenStorageObjects, farmId, totals)
    if seenStorageObjects == nil then
        return
    end

    local signature = self:getStorageTotalsSignature(totals)
    if signature == nil then
        return
    end

    seenStorageObjects.__storedGoodsSignatures = seenStorageObjects.__storedGoodsSignatures or {}
    seenStorageObjects.__storedGoodsSignatures[string.format("%s:%s", tostring(farmId or 0), signature)] = true
end

function HP_OperatingCosts:hasStorageTotalsSignature(seenStorageObjects, farmId, totals)
    if seenStorageObjects == nil or seenStorageObjects.__storedGoodsSignatures == nil then
        return false
    end

    local signature = self:getStorageTotalsSignature(totals)
    if signature == nil then
        return false
    end

    return seenStorageObjects.__storedGoodsSignatures[string.format("%s:%s", tostring(farmId or 0), signature)] == true
end

function HP_OperatingCosts:getFillTypeDisplayName(fillTypeIndex)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil then
            return fillType.title or fillType.name or tostring(fillTypeIndex)
        end
    end
    return tostring(fillTypeIndex)
end

-- --------------------------------------------------------------------------
-- Allgemeine Hilfsfunktionen
-- --------------------------------------------------------------------------

function HP_OperatingCosts:getCurrentRates()
    local difficulty = self:getEconomyDifficultyKey()
    return self.RATES[difficulty] or self.RATES.normal
end

function HP_OperatingCosts:getEconomyDifficultyKey()
    return self:getEconomyDifficultyKeyFromValue(self:getEconomyDifficultyRawValue())
end

function HP_OperatingCosts:getEconomyDifficultyRawValue()
    local mission = g_currentMission
    local difficulty = nil

    if mission ~= nil and mission.missionInfo ~= nil then
        difficulty = mission.missionInfo.economicDifficulty or mission.missionInfo.difficulty
    end

    if difficulty == nil and g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then
        local ok, value = pcall(g_gameSettings.getValue, g_gameSettings, "economicDifficulty")
        if ok then
            difficulty = value
        end
    end

    return difficulty
end

function HP_OperatingCosts:getEconomyDifficultyKeyFromValue(difficulty)
    if type(difficulty) == "number" then
        if difficulty <= 1 then
            return "easy"
        elseif difficulty == 2 then
            return "normal"
        else
            return "hard"
        end
    end

    difficulty = tostring(difficulty or "normal"):lower()
    if string.find(difficulty, "easy") ~= nil or string.find(difficulty, "leicht") ~= nil then
        return "easy"
    end
    if string.find(difficulty, "hard") ~= nil or string.find(difficulty, "schwer") ~= nil then
        return "hard"
    end

    return "normal"
end

function HP_OperatingCosts:getDaysPerPeriod()
    local mission = g_currentMission
    if mission ~= nil then
        if mission.environment ~= nil and mission.environment.daysPerPeriod ~= nil then
            return tonumber(mission.environment.daysPerPeriod) or 1
        end
        if mission.missionInfo ~= nil and mission.missionInfo.daysPerPeriod ~= nil then
            return tonumber(mission.missionInfo.daysPerPeriod) or 1
        end
    end
    return 1
end

function HP_OperatingCosts:getOwnerFarmId(object)
    if object == nil then
        return nil
    end
    if object.getOwnerFarmId ~= nil then
        local ok, value = pcall(object.getOwnerFarmId, object)
        if ok then
            return value
        end
    end
    return object.ownerFarmId or object.farmId
end

function HP_OperatingCosts:isValidFarmId(farmId)
    if farmId == nil or farmId <= 0 then
        return false
    end
    if FarmlandManager ~= nil and farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return false
    end
    if FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end

    -- Einige vorplatzierte Map-Objekte können technische Besitzer-IDs tragen
    -- (im Test z. B. Farm 15), ohne dass dazu eine echte Spielerfarm existiert.
    -- Diese Objekte dürfen nicht abgerechnet werden.
    if g_farmManager ~= nil and g_farmManager.getFarmById ~= nil then
        local ok, farm = pcall(g_farmManager.getFarmById, g_farmManager, farmId)
        if ok and farm == nil then
            return false
        end
    end

    return true
end

function HP_OperatingCosts:getUniqueObjectId(object)
    if object == nil then
        return nil
    end

    if object.getUniqueId ~= nil then
        local ok, value = pcall(object.getUniqueId, object)
        if ok and value ~= nil then
            return tostring(value)
        end
    end

    if object.id ~= nil then
        return tostring(object.id)
    end

    return nil
end

function HP_OperatingCosts:addCostEntry(totalsByFarm, farmId, key, amount, category, objectName, baseValue, rate, moneyCategory, targetValue, existingValue)
    if amount == nil or amount <= 0 then
        return
    end

    local totals = totalsByFarm[farmId]
    if totals == nil then
        totals = self:createEmptyFarmTotals()
        totalsByFarm[farmId] = totals
    end

    totals[key] = (totals[key] or 0) + amount
    table.insert(totals.entries, {
        type = key,
        category = category or "unknown",
        name = objectName or "unknown",
        amount = amount,
        baseValue = baseValue or 0,
        rate = rate or 0,
        moneyCategory = moneyCategory or "other",
        targetValue = targetValue or 0,
        existingValue = existingValue or 0
    })
end


function HP_OperatingCosts:getDiagnostics(diagnosticsByFarm, farmId)
    if diagnosticsByFarm == nil or farmId == nil then
        return self:createEmptyDiagnostics()
    end

    local diag = diagnosticsByFarm[farmId]
    if diag == nil then
        diag = self:createEmptyDiagnostics()
        diagnosticsByFarm[farmId] = diag
    end

    return diag
end

function HP_OperatingCosts:getDiagnosticFarmIds(totalsByFarm, diagnosticsByFarm)
    local farmIdsById = {}
    if totalsByFarm ~= nil then
        for farmId, _ in pairs(totalsByFarm) do
            farmIdsById[farmId] = true
        end
    end
    if diagnosticsByFarm ~= nil then
        for farmId, _ in pairs(diagnosticsByFarm) do
            farmIdsById[farmId] = true
        end
    end

    local farmIds = {}
    for farmId, _ in pairs(farmIdsById) do
        table.insert(farmIds, farmId)
    end

    table.sort(farmIds, function(a, b)
        return tostring(a) < tostring(b)
    end)

    return farmIds
end

function HP_OperatingCosts:logMonthlyDiagnostics(farmId, year, month, totals, diagnostics, vehicleInsurance, storedGoodsInsurance, upkeep)
    diagnostics = diagnostics or self:getDiagnostics(nil, farmId)

    self:diagnostic(string.format(
        "Farm %s, Jahr %s / Kalendermonat %s: Erkannte_Fahrzeuge=%s, Erkannte_Geraete/Anhaenger=%s, Abgerechnete_Fahrzeuge=%s, Abgerechnete_Geraete/Anhaenger=%s, Nicht_versicherbare_Objekte=%s, Leasing_Objekte=%s, Fahrzeuge_mit_Wert=%s, Fahrzeuge_ohne_Wert=%s, Placeables=%s, Placeables_mit_Wert=%s, Placeables_ohne_Wert=%s, Lager=%s, Lager_mit_Warenwert=%s, Buchungsposten_Fahrzeugversicherung=%s, Buchungsposten_Lagergutversicherung=%s, Buchungsposten_Unterhalt=%s, Summe_Fahrzeugversicherung=%s, Summe_Lagergutversicherung=%s, Summe_Unterhalt=%s, Gesamtsumme=%s",
        tostring(farmId),
        tostring(year),
        tostring(month),
        tostring(diagnostics.detectedMotorVehicles or 0),
        tostring(diagnostics.detectedImplements or 0),
        tostring(diagnostics.motorVehicles or 0),
        tostring(diagnostics.implements or 0),
        tostring(diagnostics.nonInsurableVehicleObjects or 0),
        tostring(diagnostics.leasedVehicleObjects or 0),
        tostring(diagnostics.vehiclesWithPrice or 0),
        tostring(diagnostics.vehiclesWithoutPrice or 0),
        tostring(diagnostics.placeables or 0),
        tostring(diagnostics.placeablesWithPrice or 0),
        tostring(diagnostics.placeablesWithoutPrice or 0),
        tostring(diagnostics.storages or 0),
        tostring(diagnostics.storagesWithValue or 0),
        tostring(diagnostics.vehicleInsuranceEntries or 0),
        tostring(diagnostics.storageInsuranceEntries or 0),
        tostring(diagnostics.upkeepEntries or 0),
        self:formatMoney(vehicleInsurance or 0),
        self:formatMoney(storedGoodsInsurance or 0),
        self:formatMoney(upkeep or 0),
        self:formatMoney((vehicleInsurance or 0) + (storedGoodsInsurance or 0) + (upkeep or 0))
    ))
end

function HP_OperatingCosts:diagnostic(message)
    if self.DIAGNOSTIC_LOGGING and Logging ~= nil and Logging.info ~= nil then
        Logging.info("[HP_OperatingCosts] Diagnose: %s", tostring(message))
    end
end

function HP_OperatingCosts:storageDiagnostic(message)
    if self.STORAGE_DIAGNOSTIC_LOGGING and Logging ~= nil and Logging.info ~= nil then
        Logging.info("[HP_OperatingCosts] Lagerdiagnose: %s", tostring(message))
    end
end


function HP_OperatingCosts:getObjectName(object)
    if object == nil then
        return "unknown"
    end

    if object.getName ~= nil then
        local ok, name = pcall(object.getName, object)
        if ok and name ~= nil and name ~= "" then
            return tostring(name)
        end
    end

    if object.storeItem ~= nil and object.storeItem.name ~= nil then
        return tostring(object.storeItem.name)
    end

    if object.configFileName ~= nil and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
        local storeItem = g_storeManager:getItemByXMLFilename(object.configFileName)
        if storeItem ~= nil and storeItem.name ~= nil then
            return tostring(storeItem.name)
        end
    end

    return "unknown"
end

function HP_OperatingCosts:getCalendarMonthFromPeriod(period)
    local periodNumber = tonumber(period)
    if periodNumber == nil then
        return 1, nil
    end

    local periodIndex = math.floor(periodNumber)

    -- FS nutzt fuer Jahreszeiten/Growth-Perioden nicht den normalen Kalendermonat.
    -- Periode 1 entspricht Maerz, Periode 8 entspricht Oktober. Fuer die Diagnose
    -- und die History-Datei wird daraus der normale Kalendermonat 1-12 gebildet.
    if periodIndex < 1 then
        periodIndex = periodIndex + 1
    end

    while periodIndex > 12 do
        periodIndex = periodIndex - 12
    end

    local calendarMonth = (periodIndex % 12) + 2
    if calendarMonth > 12 then
        calendarMonth = calendarMonth - 12
    end

    return calendarMonth, periodIndex
end

function HP_OperatingCosts:getCurrentYearAndMonth(period)
    local mission = g_currentMission
    local year = 1
    local eventPeriod = tonumber(period)
    local environmentPeriod = nil

    if mission ~= nil and mission.environment ~= nil then
        year = tonumber(mission.environment.currentYear or mission.environment.currentYearIndex or mission.environment.year) or year
        environmentPeriod = tonumber(mission.environment.currentPeriod)
    end

    if mission ~= nil and mission.missionInfo ~= nil then
        year = tonumber(mission.missionInfo.currentYear or year) or year
    end

    local rawPeriod = environmentPeriod or eventPeriod or 1
    local calendarMonth, normalizedPeriod = self:getCalendarMonthFromPeriod(rawPeriod)

    return year, calendarMonth, normalizedPeriod or rawPeriod, eventPeriod, environmentPeriod
end

function HP_OperatingCosts:getSavegameFilePath(fileName)
    local mission = g_currentMission
    if mission == nil or mission.missionInfo == nil then
        return nil
    end

    local dir = mission.missionInfo.savegameDirectory
    if dir == nil or dir == "" then
        return nil
    end

    local last = string.sub(dir, -1)
    if last ~= "/" and last ~= "\\" then
        dir = dir .. "/"
    end

    return dir .. tostring(fileName or "")
end

function HP_OperatingCosts:getSavegameHistoryPath()
    return self:getSavegameFilePath(self.HISTORY_FILE_NAME)
end

function HP_OperatingCosts:getSavegameConfigPath()
    return self:getSavegameFilePath(self.CONFIG_FILE_NAME)
end

function HP_OperatingCosts:getHistoryPeriodKey(farmId, year, month)
    return string.format("%s|%s|%s",
        tostring(tonumber(farmId) or 0),
        tostring(tonumber(year) or 0),
        tostring(tonumber(month) or 0)
    )
end


function HP_OperatingCosts:getHistoryRecordForPeriod(farmId, year, month)
    local key = self:getHistoryPeriodKey(farmId, year, month)
    local bestRecord = nil

    for _, record in ipairs(self.historyRecords or {}) do
        if self:getHistoryPeriodKey(record.farmId, record.year, record.month) == key then
            if bestRecord == nil or self:isHistoryRecordBetter(record, bestRecord) then
                bestRecord = record
            end
        end
    end

    return bestRecord
end

function HP_OperatingCosts:isHistoryRecordBetter(candidate, current)
    if current == nil then
        return true
    end

    local candidateEntries = #(candidate.entries or {})
    local currentEntries = #(current.entries or {})
    if candidateEntries ~= currentEntries then
        return candidateEntries > currentEntries
    end

    local candidateTotal = (tonumber(candidate.vehicleInsurance) or 0) + (tonumber(candidate.storedGoodsInsurance) or 0) + (tonumber(candidate.upkeep) or 0)
    local currentTotal = (tonumber(current.vehicleInsurance) or 0) + (tonumber(current.storedGoodsInsurance) or 0) + (tonumber(current.upkeep) or 0)
    return candidateTotal >= currentTotal
end

function HP_OperatingCosts:historyRecordNeedsRefresh(record, totals, vehicleInsurance, storedGoodsInsurance, upkeep)
    if record == nil then
        return true
    end

    local entryCount = #(record.entries or {})
    local totalsEntryCount = 0
    if totals ~= nil and totals.entries ~= nil then
        totalsEntryCount = #totals.entries
    end

    if entryCount == 0 and totalsEntryCount > 0 then
        return true
    end

    if vehicleInsurance > 0 and not self:historyRecordHasEntryType(record, "vehicleInsurance") and self:totalsHasEntryType(totals, "vehicleInsurance") then
        return true
    end

    if storedGoodsInsurance > 0 and not self:historyRecordHasEntryType(record, "storedGoodsInsurance") and self:totalsHasEntryType(totals, "storedGoodsInsurance") then
        return true
    end

    if upkeep > 0 and not self:historyRecordHasEntryType(record, "upkeep") and self:totalsHasEntryType(totals, "upkeep") then
        return true
    end

    return false
end

function HP_OperatingCosts:totalsHasEntryType(totals, entryType)
    if totals == nil or totals.entries == nil then
        return false
    end

    for _, entry in ipairs(totals.entries) do
        if entry.type == entryType then
            return true
        end
    end

    return false
end

function HP_OperatingCosts:historyRecordHasEntryType(record, entryType)
    if record == nil or record.entries == nil then
        return false
    end

    for _, entry in ipairs(record.entries) do
        if entry.type == entryType then
            return true
        end
    end

    return false
end

function HP_OperatingCosts:removeHistoryRecordsForPeriod(farmId, year, month)
    local key = self:getHistoryPeriodKey(farmId, year, month)
    local cleaned = {}
    local removed = 0

    for _, record in ipairs(self.historyRecords or {}) do
        if self:getHistoryPeriodKey(record.farmId, record.year, record.month) == key then
            removed = removed + 1
        else
            table.insert(cleaned, record)
        end
    end

    if removed > 0 then
        self.historyRecords = cleaned
    end

    return removed
end

function HP_OperatingCosts:deduplicateHistoryRecords()
    if self.historyRecords == nil then
        return 0
    end

    local latestByKey = {}
    local order = {}

    for _, record in ipairs(self.historyRecords) do
        local key = self:getHistoryPeriodKey(record.farmId, record.year, record.month)
        if latestByKey[key] == nil then
            table.insert(order, key)
            latestByKey[key] = record
        elseif self:isHistoryRecordBetter(record, latestByKey[key]) then
            latestByKey[key] = record
        end
    end

    local cleaned = {}
    for _, key in ipairs(order) do
        table.insert(cleaned, latestByKey[key])
    end

    local removed = #self.historyRecords - #cleaned
    if removed > 0 then
        self.historyRecords = cleaned
    end

    return removed
end

function HP_OperatingCosts:sortHistoryRecords()
    self.historyRecords = self.historyRecords or {}

    table.sort(self.historyRecords, function(a, b)
        local ay = tonumber(a.year) or 0
        local by = tonumber(b.year) or 0
        if ay ~= by then
            return ay < by
        end

        local am = tonumber(a.month) or 0
        local bm = tonumber(b.month) or 0
        if am ~= bm then
            return am < bm
        end

        return (tonumber(a.farmId) or 0) < (tonumber(b.farmId) or 0)
    end)
end

function HP_OperatingCosts:writeHistory(farmId, year, month, fsPeriod, totals, vehicleInsurance, storedGoodsInsurance, upkeep)
    self.historyRecords = self.historyRecords or {}

    local record = {
        farmId = farmId,
        year = year,
        month = month,
        fsPeriod = fsPeriod,
        vehicleInsurance = vehicleInsurance or 0,
        storedGoodsInsurance = storedGoodsInsurance or 0,
        upkeep = upkeep or 0,
        entries = {}
    }

    if totals ~= nil and totals.entries ~= nil then
        for _, entry in ipairs(totals.entries) do
            table.insert(record.entries, {
                type = entry.type,
                category = entry.category,
                name = entry.name,
                amount = entry.amount or 0,
                baseValue = entry.baseValue or 0,
                rate = entry.rate or 0,
                moneyCategory = entry.moneyCategory,
                targetValue = entry.targetValue or 0,
                existingValue = entry.existingValue or 0
            })
        end
    end

    local removedExisting = self:removeHistoryRecordsForPeriod(farmId, year, month)
    if removedExisting > 0 then
        self:diagnostic(string.format(
            "Vor dem Schreiben wurden %s vorhandene History-Buchung(en) für Farm %s, Jahr %s / Kalendermonat %s ersetzt.",
            tostring(removedExisting),
            tostring(farmId),
            tostring(year),
            tostring(month)
        ))
    end

    table.insert(self.historyRecords, record)
    self:sortHistoryRecords()
    self.historyDirty = true
end

function HP_OperatingCosts:saveHistoryFile(path)
    -- FS25 erlaubt in der Mod-Sandbox io.open nur im Schreibmodus.
    -- XMLFile.create/setValue erzeugte ohne passende Schema-Datei im Test Log-Fehler
    -- "Unable to get schema for xml file". Deshalb wird die Protokolldatei hier
    -- bewusst als einfache XML-Datei im Schreibmodus neu aufgebaut.
    local ok, err = pcall(function()
        self:saveHistoryWithWriteOnlyFile(path)
    end)

    if ok then
        self:diagnostic("operatingCostsHistory.xml geschrieben: " .. tostring(path))
        return
    end

    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[HP_OperatingCosts] Could not write operatingCostsHistory.xml: %s", tostring(err))
    end
end

function HP_OperatingCosts:saveHistoryWithWriteOnlyFile(path)
    if io == nil or io.open == nil then
        return
    end

    local output = io.open(path, "w")
    if output == nil then
        error("io.open failed")
    end

    output:write("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
    output:write("<operatingCostsHistory version=\"" .. self:xmlEscape(self.VERSION) .. "\">\n")

    for _, record in ipairs(self.historyRecords or {}) do
        local total = (record.vehicleInsurance or 0) + (record.storedGoodsInsurance or 0) + (record.upkeep or 0)
        output:write(string.format("    <billing year=\"%s\" month=\"%s\" period=\"%s\" farmId=\"%s\" vehicleInsurance=\"%.2f\" storedGoodsInsurance=\"%.2f\" upkeep=\"%.2f\" total=\"%.2f\">\n",
            self:xmlEscape(record.year), self:xmlEscape(record.month), self:xmlEscape(record.fsPeriod), self:xmlEscape(record.farmId), record.vehicleInsurance or 0, record.storedGoodsInsurance or 0, record.upkeep or 0, total))

        for _, entry in ipairs(record.entries or {}) do
            output:write(string.format("        <entry type=\"%s\" category=\"%s\" name=\"%s\" amount=\"%.2f\" baseValue=\"%.2f\" rate=\"%.6f\" moneyCategory=\"%s\" targetValue=\"%.2f\" existingValue=\"%.2f\" />\n",
                self:xmlEscape(entry.type), self:xmlEscape(entry.category), self:xmlEscape(entry.name), entry.amount or 0, entry.baseValue or 0, entry.rate or 0, self:xmlEscape(entry.moneyCategory), entry.targetValue or 0, entry.existingValue or 0))
        end

        output:write("    </billing>\n")
    end

    output:write("</operatingCostsHistory>\n")
    output:close()
end

function HP_OperatingCosts:xmlEscape(value)
    value = tostring(value or "")
    value = string.gsub(value, "&", "&amp;")
    value = string.gsub(value, "<", "&lt;")
    value = string.gsub(value, ">", "&gt;")
    value = string.gsub(value, "\"", "&quot;")
    value = string.gsub(value, "'", "&apos;")
    return value
end

function HP_OperatingCosts:addMoney(farmId, amount, moneyType)
    if amount == nil or amount == 0 or g_currentMission == nil then
        return
    end

    if g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(amount, farmId, moneyType or MoneyType.OTHER, true, true)
    end
end

function HP_OperatingCosts:showNotification(farmId, text, notificationType)
    if text == nil or text == "" or g_currentMission == nil then
        return
    end

    if g_server ~= nil and g_currentMission.getIsMultiplayer ~= nil and g_currentMission:getIsMultiplayer() then
        g_server:broadcastEvent(HP_OperatingCostsNotificationEvent.new(farmId, text, notificationType), nil, nil, nil)
    end

    if g_currentMission.getIsClient == nil or g_currentMission:getIsClient() then
        local localFarmId = nil
        if g_currentMission.getFarmId ~= nil then
            localFarmId = g_currentMission:getFarmId()
        elseif g_localPlayer ~= nil then
            localFarmId = g_localPlayer.farmId
        end

        if localFarmId == nil or localFarmId == farmId then
            g_currentMission:addIngameNotification(notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO, text)
        end
    end
end

function HP_OperatingCosts:formatMoney(amount)
    amount = tonumber(amount) or 0

    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, value = pcall(g_i18n.formatMoney, g_i18n, amount, 0, true, true)
        if ok and value ~= nil then
            return value
        end

        ok, value = pcall(g_i18n.formatMoney, g_i18n, amount, 0)
        if ok and value ~= nil then
            return value
        end
    end

    return string.format("%d €", math.floor(amount + 0.5))
end

function HP_OperatingCosts:getMoneyDecimalSeparator()
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local samples = {
            { 1.5, 2, true, true },
            { 1.5, 2 },
            { 1.5, 1, true, true },
            { 1.5, 1 }
        }

        local unpackFn = (table ~= nil and table.unpack) or unpack
        for _, sample in ipairs(samples) do
            local ok, value = pcall(g_i18n.formatMoney, g_i18n, unpackFn(sample))
            if ok and value ~= nil then
                local digits = tostring(value):match("%d([%.,])%d")
                if digits ~= nil then
                    return digits
                end
            end
        end
    end

    return ","
end

function HP_OperatingCosts:ensureMoneyHasTwoDecimals(text)
    text = tostring(text or "")

    local firstDigit = string.find(text, "%d")
    if firstDigit == nil then
        return text
    end

    local lastDigit = nil
    for i = firstDigit, #text do
        local char = string.sub(text, i, i)
        if string.match(char, "%d") then
            lastDigit = i
        end
    end

    if lastDigit == nil or lastDigit < firstDigit then
        return text
    end

    local prefix = string.sub(text, 1, firstDigit - 1)
    local numberText = string.sub(text, firstDigit, lastDigit)
    local suffix = string.sub(text, lastDigit + 1)

    local lastComma = nil
    local lastDot = nil
    for i = 1, #numberText do
        local char = string.sub(numberText, i, i)
        if char == "," then
            lastComma = i
        elseif char == "." then
            lastDot = i
        end
    end

    local decimalPos = nil
    if lastComma ~= nil or lastDot ~= nil then
        decimalPos = math.max(lastComma or 0, lastDot or 0)
        local digitsAfter = #numberText - decimalPos
        if digitsAfter > 2 then
            decimalPos = nil
        end
    end

    if decimalPos ~= nil and decimalPos > 0 then
        local decimalSep = string.sub(numberText, decimalPos, decimalPos)
        local decimals = string.sub(numberText, decimalPos + 1)
        decimals = string.gsub(decimals, "%D", "")

        if #decimals == 0 then
            decimals = "00"
        elseif #decimals == 1 then
            decimals = decimals .. "0"
        else
            decimals = string.sub(decimals, 1, 2)
        end

        local integerPart = string.sub(numberText, 1, decimalPos - 1)
        return prefix .. integerPart .. decimalSep .. decimals .. suffix
    end

    return prefix .. numberText .. self:getMoneyDecimalSeparator() .. "00" .. suffix
end

function HP_OperatingCosts:formatMoneyDetailed(amount)
    amount = tonumber(amount) or 0

    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, value = pcall(g_i18n.formatMoney, g_i18n, amount, 2, true, true)
        if ok and value ~= nil then
            return self:ensureMoneyHasTwoDecimals(value)
        end

        ok, value = pcall(g_i18n.formatMoney, g_i18n, amount, 2)
        if ok and value ~= nil then
            return self:ensureMoneyHasTwoDecimals(value)
        end
    end

    local sign = ""
    if amount < 0 then
        sign = "-"
        amount = math.abs(amount)
    end
    return string.format("%s%.2f €", sign, amount)
end

function HP_OperatingCosts:getText(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n.getText ~= nil then
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
    elseif g_i18n ~= nil and g_i18n.getText ~= nil then
        local ok, value = pcall(g_i18n.getText, g_i18n, key)
        if ok and value ~= nil and value ~= "" then
            return value
        end
    end
    return fallback
end

function HP_OperatingCosts:safeCall(object, methodName)
    if object == nil or methodName == nil or object[methodName] == nil then
        return nil
    end

    local ok, result = pcall(object[methodName], object)
    if ok then
        return result
    end

    return nil
end

function HP_OperatingCosts:debug(message)
    if self.DEBUG and Logging ~= nil and Logging.info ~= nil then
        Logging.info("[HP_OperatingCosts] %s", tostring(message))
    end
end



-- --------------------------------------------------------------------------
-- Savegame-Konfiguration fuer anpassbare Prozentsaetze
-- --------------------------------------------------------------------------

function HP_OperatingCosts:copyRatesTable(source)
    local copy = {}
    for difficultyKey, rates in pairs(source or {}) do
        copy[difficultyKey] = {}
        for rateKey, value in pairs(rates or {}) do
            copy[difficultyKey][rateKey] = tonumber(value) or 0
        end
    end
    return copy
end

function HP_OperatingCosts:resetRatesToDefaults()
    self.RATES = self:copyRatesTable(self.DEFAULT_RATES)
end

function HP_OperatingCosts:getDifficultyKeysForConfig()
    return { "easy", "normal", "hard" }
end

function HP_OperatingCosts:getRateKeysForConfig()
    return { "motorVehicleInsurance", "implementInsurance", "placeableUpkeep", "storedGoodsInsurance" }
end

function HP_OperatingCosts:readConfigPercent(xmlId, key, defaultDecimal)
    local percent = nil

    if getXMLString ~= nil then
        local raw = getXMLString(xmlId, key)
        if raw ~= nil and raw ~= "" then
            raw = string.gsub(tostring(raw), ",", ".")
            percent = tonumber(raw)
        end
    end

    if percent == nil and getXMLFloat ~= nil then
        percent = getXMLFloat(xmlId, key)
    end

    if percent == nil then
        return tonumber(defaultDecimal) or 0
    end

    percent = math.max(0, tonumber(percent) or 0)
    return percent / 100
end

function HP_OperatingCosts:loadConfigFile()
    local path = self:getSavegameConfigPath()
    if path == nil then
        return
    end

    if fileExists ~= nil and not fileExists(path) then
        -- Die Datei wird beim nächsten Speichern mit den Standardwerten erzeugt.
        self.configDirty = true
        return
    end

    if loadXMLFile == nil then
        self.configDirty = true
        return
    end

    local ok, result = pcall(function()
        local xmlId = loadXMLFile("hpOperatingCostsConfig", path)
        if xmlId == nil or xmlId == 0 then
            self.configDirty = true
            return false
        end

        local configuredRates = self:copyRatesTable(self.DEFAULT_RATES)
        for _, difficultyKey in ipairs(self:getDifficultyKeysForConfig()) do
            local difficultyPath = string.format("operatingCostsConfig.rates.%s", difficultyKey)
            for _, rateKey in ipairs(self:getRateKeysForConfig()) do
                configuredRates[difficultyKey][rateKey] = self:readConfigPercent(
                    xmlId,
                    string.format("%s#%sPercent", difficultyPath, rateKey),
                    self.DEFAULT_RATES[difficultyKey][rateKey]
                )
            end
        end

        if delete ~= nil then
            delete(xmlId)
        end

        self.RATES = configuredRates
        return true
    end)

    if not ok then
        self:resetRatesToDefaults()
        self.configDirty = true
        if Logging ~= nil and Logging.warning ~= nil then
            Logging.warning("[HP_OperatingCosts] Could not read operatingCostsConfig.xml: %s", tostring(result))
        end
    end
end

function HP_OperatingCosts:saveConfigFile(path)
    local ok, err = pcall(function()
        self:saveConfigWithWriteOnlyFile(path)
    end)

    if ok then
        self:diagnostic("operatingCostsConfig.xml geschrieben: " .. tostring(path))
        return true
    end

    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[HP_OperatingCosts] Could not write operatingCostsConfig.xml: %s", tostring(err))
    end
    return false
end

function HP_OperatingCosts:saveConfigWithWriteOnlyFile(path)
    if io == nil or io.open == nil then
        return
    end

    local output = io.open(path, "w")
    if output == nil then
        error("io.open failed")
    end

    output:write("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
    output:write("<operatingCostsConfig version=\"" .. self:xmlEscape(self.VERSION) .. "\">\n")
    output:write("    <!-- Werte sind Prozentwerte pro Monat. Beispiel: 0.30 bedeutet 0,30 % monatlich. -->\n")
    output:write("    <rates>\n")

    for _, difficultyKey in ipairs(self:getDifficultyKeysForConfig()) do
        local rates = (self.RATES and self.RATES[difficultyKey]) or self.DEFAULT_RATES[difficultyKey]
        output:write(string.format(
            "        <%s motorVehicleInsurancePercent=\"%.6f\" implementInsurancePercent=\"%.6f\" placeableUpkeepPercent=\"%.6f\" storedGoodsInsurancePercent=\"%.6f\" />\n",
            difficultyKey,
            (tonumber(rates.motorVehicleInsurance) or 0) * 100,
            (tonumber(rates.implementInsurance) or 0) * 100,
            (tonumber(rates.placeableUpkeep) or 0) * 100,
            (tonumber(rates.storedGoodsInsurance) or 0) * 100
        ))
    end

    output:write("    </rates>\n")
    output:write("</operatingCostsConfig>\n")
    output:close()
end

-- --------------------------------------------------------------------------
-- Savegame-Anbindung fuer operatingCostsHistory.xml
-- --------------------------------------------------------------------------

function HP_OperatingCosts:installSavegameHooks()
    if self.savegameHookInstalled == true or Utils == nil or Utils.appendedFunction == nil or FSBaseMission == nil or FSBaseMission.saveSavegame == nil then
        return
    end

    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function(mission, ...)
        if HP_OperatingCosts ~= nil then
            HP_OperatingCosts:onSavegame(mission)
        end
    end)

    self.savegameHookInstalled = true
end

function HP_OperatingCosts:onSavegame(mission)
    local activeMission = mission or g_currentMission
    if activeMission ~= nil and activeMission.getIsServer ~= nil and not activeMission:getIsServer() then
        return
    end

    local hasHistoryChanges = self.historyDirty == true
    local hasConfigChanges = self.configDirty == true
    if not hasHistoryChanges and not hasConfigChanges then
        return
    end

    if hasHistoryChanges then
        local historyPath = self:getSavegameHistoryPath()
        if historyPath ~= nil then
            self:saveHistoryFile(historyPath)
            self.historyDirty = false
        end
    end

    if hasConfigChanges then
        local configPath = self:getSavegameConfigPath()
        if configPath ~= nil and self:saveConfigFile(configPath) then
            self.configDirty = false
        end
    end
end

function HP_OperatingCosts:removeFutureHistoryRecords()
    if self.historyRecords == nil or #self.historyRecords == 0 then
        return 0
    end

    local mission = g_currentMission
    local hasReliablePeriod = mission ~= nil and mission.environment ~= nil and mission.environment.currentPeriod ~= nil
    if not hasReliablePeriod then
        return 0
    end

    local currentYear, currentMonth = self:getCurrentYearAndMonth(nil)
    currentYear = tonumber(currentYear)
    currentMonth = tonumber(currentMonth)
    if currentYear == nil or currentMonth == nil then
        return 0
    end

    local cleaned = {}
    local removed = 0
    for _, record in ipairs(self.historyRecords) do
        local year = tonumber(record.year) or 0
        local month = tonumber(record.month) or 0
        if year > currentYear or (year == currentYear and month > currentMonth) then
            removed = removed + 1
        else
            table.insert(cleaned, record)
        end
    end

    if removed > 0 then
        self.historyRecords = cleaned
        self:sortHistoryRecords()
    end

    return removed
end

-- --------------------------------------------------------------------------
-- Shop-Vorschau fuer erwartete Betriebskosten
-- --------------------------------------------------------------------------

function HP_OperatingCosts:installShopCostPreviewHooks()
    if Utils == nil or Utils.appendedFunction == nil then
        return
    end

    if self.shopCostPreviewHookInstalled ~= true and ShopConfigScreen ~= nil and ShopConfigScreen.draw ~= nil then
        ShopConfigScreen.draw = Utils.appendedFunction(ShopConfigScreen.draw, function(screen, ...)
            if HP_OperatingCosts ~= nil then
                HP_OperatingCosts:drawShopCostPreview(screen)
            end
        end)
        self.shopCostPreviewHookInstalled = true
    end

    if self.constructionCostPreviewHookInstalled ~= true and ConstructionScreen ~= nil and ConstructionScreen.draw ~= nil then
        ConstructionScreen.draw = Utils.appendedFunction(ConstructionScreen.draw, function(screen, ...)
            if HP_OperatingCosts ~= nil then
                HP_OperatingCosts:drawConstructionCostPreview(screen)
            end
        end)
        self.constructionCostPreviewHookInstalled = true
    end
end

function HP_OperatingCosts:getCurrentRateSet()
    local difficultyRaw = self:getEconomyDifficultyRawValue()
    local difficultyKey = self:getEconomyDifficultyKeyFromValue(difficultyRaw)
    return self.RATES[difficultyKey] or self.RATES.normal, difficultyKey
end

function HP_OperatingCosts:getDifficultyLabel(difficultyKey)
    if difficultyKey == "easy" then
        return self:getText("hpOc_difficultyEasy", "Einfach")
    elseif difficultyKey == "hard" then
        return self:getText("hpOc_difficultyHard", "Schwer")
    end
    return self:getText("hpOc_difficultyNormal", "Normal")
end

function HP_OperatingCosts:getShopBuyVehicleData(screen)
    if screen == nil then
        return nil
    end

    local candidates = {
        screen.buyVehicleData,
        screen.vehicleData,
        screen.currentBuyVehicleData,
        screen.buyData
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.storeItem ~= nil then
            return candidate
        end
    end

    return nil
end

function HP_OperatingCosts:getShopStoreItem(screen, buyData)
    if buyData ~= nil and buyData.storeItem ~= nil then
        return buyData.storeItem
    end

    if screen == nil then
        return nil
    end

    local candidates = {
        screen.storeItem,
        screen.currentStoreItem,
        screen.selectedStoreItem,
        screen.shopItem,
        screen.currentItem,
        screen.item
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.price ~= nil then
            return candidate
        end
    end

    return nil
end

function HP_OperatingCosts:getShopConfigurations(screen, buyData)
    if buyData ~= nil and buyData.configurations ~= nil then
        return buyData.configurations
    end

    if screen ~= nil then
        return screen.configurations or screen.currentConfigurations or screen.vehicleConfigurations or screen.selectedConfigurations
    end

    return nil
end

function HP_OperatingCosts:getShopSaleItem(screen, buyData)
    if buyData ~= nil and buyData.saleItem ~= nil then
        return buyData.saleItem
    end
    if screen ~= nil then
        return screen.saleItem or screen.currentSaleItem
    end
    return nil
end

function HP_OperatingCosts:getShopPreviewPrice(screen, storeItem, buyData)
    if storeItem == nil then
        return 0
    end

    local configurations = self:getShopConfigurations(screen, buyData)
    local saleItem = self:getShopSaleItem(screen, buyData)

    if g_currentMission ~= nil and g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getBuyPrice ~= nil then
        local ok, price = pcall(g_currentMission.economyManager.getBuyPrice, g_currentMission.economyManager, storeItem, configurations, saleItem)
        if ok and tonumber(price) ~= nil and tonumber(price) > 0 then
            return tonumber(price)
        end
    end

    local candidates = {}
    if buyData ~= nil then
        table.insert(candidates, buyData.price)
    end
    if screen ~= nil then
        table.insert(candidates, screen.price)
        table.insert(candidates, screen.currentPrice)
        table.insert(candidates, screen.totalPrice)
        table.insert(candidates, screen.buyPrice)
    end
    table.insert(candidates, storeItem.price)

    for _, candidate in ipairs(candidates) do
        candidate = tonumber(candidate)
        if candidate ~= nil and candidate > 0 then
            return candidate
        end
    end

    return 0
end

function HP_OperatingCosts:getShopStoreCategory(storeItem)
    if storeItem == nil then
        return ""
    end
    return string.upper(tostring(storeItem.categoryName or storeItem.category or storeItem.categoryText or storeItem.categoryTitle or ""))
end

function HP_OperatingCosts:isInsurableShopStoreItem(storeItem)
    if storeItem == nil then
        return false
    end

    local category = self:getShopStoreCategory(storeItem)
    local excludedCategories = {
        PALLETS = true,
        BIGBAGS = true,
        BIGBAGPALLETS = true,
        BALES = true,
        WOOD = true,
        ANIMALS = true,
        OBJECTS = true
    }

    if excludedCategories[category] then
        return false
    end

    local xmlFilename = tostring(storeItem.xmlFilename or ""):lower()
    if string.find(xmlFilename, "pallet") ~= nil or string.find(xmlFilename, "bigbag") ~= nil or string.find(xmlFilename, "bale") ~= nil then
        return false
    end

    if storeItem.isVehicle == false and storeItem.vehicleType == nil and storeItem.typeName == nil and storeItem.xmlFilename == nil then
        return false
    end

    return true
end

function HP_OperatingCosts:isMotorVehicleStoreItem(storeItem)
    if storeItem == nil then
        return false
    end

    if storeItem.specs ~= nil then
        if storeItem.specs.power ~= nil or storeItem.specs.maxSpeed ~= nil then
            local category = self:getShopStoreCategory(storeItem)
            if string.find(category, "HEADER") == nil and string.find(category, "CUTTER") == nil then
                return true
            end
        end
    end

    local category = self:getShopStoreCategory(storeItem)
    local motorKeywords = {
        "TRACTOR", "HARVESTER", "FORAGEHARVESTER", "COTTON", "GRAPE", "OLIVE",
        "POTATO", "BEET", "CAR", "TRUCK", "LOADER", "TELEHANDLER", "SKIDSTEER"
    }

    for _, keyword in ipairs(motorKeywords) do
        if string.find(category, keyword) ~= nil then
            return true
        end
    end

    local typeName = string.upper(tostring(storeItem.typeName or storeItem.vehicleType or ""))
    if string.find(typeName, "MOTORIZED") ~= nil or string.find(typeName, "TRACTOR") ~= nil or string.find(typeName, "HARVESTER") ~= nil then
        return true
    end

    return false
end

function HP_OperatingCosts:getShopItemName(storeItem)
    if storeItem == nil then
        return ""
    end

    local brand = ""
    if storeItem.brand ~= nil then
        if type(storeItem.brand) == "table" then
            brand = tostring(storeItem.brand.title or storeItem.brand.name or "")
        else
            brand = tostring(storeItem.brand or "")
        end
    elseif storeItem.brandName ~= nil then
        brand = tostring(storeItem.brandName)
    end

    local name = tostring(storeItem.name or storeItem.title or "")
    if brand ~= "" and name ~= "" and string.find(string.lower(name), string.lower(brand), 1, true) == nil then
        return brand .. " " .. name
    end
    return name
end

function HP_OperatingCosts:getShopCostPreviewData(screen)
    local buyData = self:getShopBuyVehicleData(screen)
    local storeItem = self:getShopStoreItem(screen, buyData)
    if storeItem == nil or not self:isInsurableShopStoreItem(storeItem) then
        return nil
    end

    local price = self:getShopPreviewPrice(screen, storeItem, buyData)
    if price <= 0 then
        return nil
    end

    local rates, difficultyKey = self:getCurrentRateSet()
    local isMotorVehicle = self:isMotorVehicleStoreItem(storeItem)
    local rate = isMotorVehicle and rates.motorVehicleInsurance or rates.implementInsurance
    local leased = buyData ~= nil and buyData.leaseVehicle == true
    local monthlyInsurance = 0
    if not leased then
        monthlyInsurance = price * rate
    end

    return {
        storeItem = storeItem,
        name = self:getShopItemName(storeItem),
        price = price,
        rate = rate,
        isMotorVehicle = isMotorVehicle,
        leased = leased,
        monthlyInsurance = monthlyInsurance,
        difficultyKey = difficultyKey,
        difficultyLabel = self:getDifficultyLabel(difficultyKey)
    }
end

function HP_OperatingCosts:drawShopCostPreview(screen)
    if renderText == nil then
        return
    end

    local data = self:getShopCostPreviewData(screen)
    if data == nil then
        return
    end

    local x = 0.705
    local y = 0.205
    local w = 0.275
    local h = data.leased and 0.148 or 0.128

    if drawFilledRect ~= nil then
        drawFilledRect(x, y, w, h, 0.02, 0.025, 0.03, 0.86)
        drawFilledRect(x, y + h - 0.004, w, 0.004, 0.75, 0.75, 0.75, 0.50)
    end

    local title = self:getText("hpOc_shopPreviewTitle", "Erwartete Betriebskosten")
    local category = data.isMotorVehicle and self:getText("hpOc_shopPreviewVehicle", "Fahrzeug") or self:getText("hpOc_shopPreviewImplement", "Gerät/Anhänger")
    local insuredValue = self:getText("hpOc_shopPreviewInsuredValue", "Versicherungswert") .. ": " .. self:formatMoney(data.price)
    local difficulty = self:getText("hpOc_shopPreviewDifficulty", "Wirtschaft") .. ": " .. data.difficultyLabel
    local monthly = self:getText("hpOc_shopPreviewMonthlyInsurance", "Versicherung pro Monat") .. ": " .. self:formatMoney(data.monthlyInsurance)
    local rate = self:getText("hpOc_shopPreviewRate", "Satz") .. ": " .. string.format("%.3f %%", (tonumber(data.rate) or 0) * 100)

    self:drawWindowText(x + 0.010, y + h - 0.026, 0.015, title, true)
    self:drawMutedWindowText(x + 0.010, y + h - 0.048, 0.0125, category .. " | " .. difficulty)
    self:drawMutedWindowText(x + 0.010, y + h - 0.069, 0.0125, insuredValue)
    self:drawMutedWindowText(x + 0.010, y + h - 0.090, 0.0125, monthly)
    self:drawMutedWindowText(x + 0.010, y + h - 0.111, 0.0125, rate)

    if data.leased then
        self:drawWindowText(x + 0.010, y + 0.014, 0.0115, self:getText("hpOc_shopPreviewLeaseNote", "Leasing/Miete wird aktuell nicht abgerechnet."), false, nil, {1.0, 0.82, 0.45, 1})
    end
end


-- --------------------------------------------------------------------------
-- Baumenü-Vorschau fuer erwarteten Gebaeudeunterhalt
-- --------------------------------------------------------------------------

function HP_OperatingCosts:getConstructionBuyPlaceableData(screen)
    if screen == nil then
        return nil
    end

    local candidates = {
        screen.buyPlaceableData,
        screen.placeableData,
        screen.currentBuyPlaceableData,
        screen.buyData,
        screen.currentPlaceableData
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.storeItem ~= nil then
            return candidate
        end
    end

    return nil
end

function HP_OperatingCosts:getConstructionSelectedItem(screen)
    if screen == nil then
        return nil
    end

    local selectedIndex = nil
    if screen.itemList ~= nil then
        selectedIndex = screen.itemList.selectedIndex
        if selectedIndex == nil and screen.itemList.getSelectedIndex ~= nil then
            local ok, value = pcall(screen.itemList.getSelectedIndex, screen.itemList)
            if ok then
                selectedIndex = value
            end
        end
    end

    local currentCategory = screen.currentCategory
    local currentTab = screen.currentTab or 1
    if selectedIndex ~= nil and screen.items ~= nil and currentCategory ~= nil then
        local categoryItems = screen.items[currentCategory]
        local tabItems = categoryItems ~= nil and categoryItems[currentTab] or nil
        if tabItems ~= nil and tabItems[selectedIndex] ~= nil then
            return tabItems[selectedIndex]
        end
    end

    local candidates = {
        screen.selectedItem,
        screen.currentItem,
        screen.item,
        screen.currentConstructionItem,
        screen.activeItem
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and (candidate.storeItem ~= nil or candidate.displayItem ~= nil or candidate.price ~= nil) then
            return candidate
        end
    end

    return nil
end

function HP_OperatingCosts:getConstructionStoreItem(screen, item, buyData)
    if buyData ~= nil and buyData.storeItem ~= nil then
        return buyData.storeItem
    end

    if item ~= nil then
        if item.displayItem ~= nil and item.displayItem.storeItem ~= nil then
            return item.displayItem.storeItem
        end
        if item.storeItem ~= nil then
            return item.storeItem
        end
    end

    if screen ~= nil then
        local candidates = {
            screen.storeItem,
            screen.currentStoreItem,
            screen.selectedStoreItem
        }

        for _, candidate in ipairs(candidates) do
            if type(candidate) == "table" and candidate.price ~= nil then
                return candidate
            end
        end
    end

    return nil
end

function HP_OperatingCosts:getConstructionConfigurations(screen, item, buyData)
    if buyData ~= nil and buyData.configurations ~= nil then
        return buyData.configurations
    end

    if item ~= nil then
        if item.configurations ~= nil then
            return item.configurations
        end
        if item.displayItem ~= nil and item.displayItem.configurations ~= nil then
            return item.displayItem.configurations
        end
    end

    if screen ~= nil then
        return screen.configurations or screen.currentConfigurations or screen.placeableConfigurations or screen.selectedConfigurations
    end

    return nil
end

function HP_OperatingCosts:getConstructionPreviewPrice(screen, item, storeItem, buyData)
    if storeItem == nil then
        return 0
    end

    local configurations = self:getConstructionConfigurations(screen, item, buyData)

    if g_currentMission ~= nil and g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getBuyPrice ~= nil then
        local ok, price = pcall(g_currentMission.economyManager.getBuyPrice, g_currentMission.economyManager, storeItem, configurations, nil)
        if ok and tonumber(price) ~= nil and tonumber(price) > 0 then
            return tonumber(price)
        end
    end

    local candidates = {}
    if buyData ~= nil then
        table.insert(candidates, buyData.price)
    end
    if item ~= nil then
        table.insert(candidates, item.price)
        if item.displayItem ~= nil then
            table.insert(candidates, item.displayItem.price)
        end
    end
    table.insert(candidates, storeItem.price)

    for _, candidate in ipairs(candidates) do
        candidate = tonumber(candidate)
        if candidate ~= nil and candidate > 0 then
            return candidate
        end
    end

    return 0
end

function HP_OperatingCosts:getConstructionNumericValue(value)
    if type(value) == "number" then
        return value
    end

    if type(value) == "string" then
        value = string.gsub(value, ",", ".")
        return tonumber(value)
    end

    if type(value) == "table" then
        local keys = {"value", "dailyUpkeep", "upkeep", "amount", "price"}
        for _, key in ipairs(keys) do
            local result = self:getConstructionNumericValue(value[key])
            if result ~= nil then
                return result
            end
        end
    end

    return nil
end

function HP_OperatingCosts:getConstructionNativeMonthlyUpkeep(storeItem, item, buyData)
    local candidates = {}

    if buyData ~= nil then
        table.insert(candidates, buyData.dailyUpkeep)
        table.insert(candidates, buyData.upkeep)
    end

    if item ~= nil then
        table.insert(candidates, item.dailyUpkeep)
        table.insert(candidates, item.upkeep)
        if item.displayItem ~= nil then
            table.insert(candidates, item.displayItem.dailyUpkeep)
            table.insert(candidates, item.displayItem.upkeep)
        end
    end

    if storeItem ~= nil then
        table.insert(candidates, storeItem.dailyUpkeep)
        table.insert(candidates, storeItem.upkeep)
        if storeItem.specs ~= nil then
            table.insert(candidates, storeItem.specs.dailyUpkeep)
            table.insert(candidates, storeItem.specs.upkeep)
        end
    end

    for _, candidate in ipairs(candidates) do
        local daily = self:getConstructionNumericValue(candidate)
        if daily ~= nil and daily > 0 then
            return daily * math.max(1, self:getDaysPerPeriod())
        end
    end

    return 0
end

function HP_OperatingCosts:getConstructionCategoryLabel(screen, item, storeItem)
    if screen ~= nil and screen.currentCategory ~= nil and screen.categories ~= nil then
        local category = screen.categories[screen.currentCategory]
        if category ~= nil then
            local title = category.title or category.name
            if title ~= nil and title ~= "" then
                return tostring(title)
            end
        end
    end

    if item ~= nil then
        local title = item.categoryTitle or item.categoryName or item.category
        if title ~= nil and title ~= "" then
            return tostring(title)
        end
    end

    if storeItem ~= nil then
        local title = storeItem.categoryTitle or storeItem.categoryName or storeItem.category or storeItem.typeName
        if title ~= nil and title ~= "" then
            return tostring(title)
        end
    end

    return self:getText("hpOc_constructionPreviewCategoryPlaceable", "Gebäude/Placeable")
end

function HP_OperatingCosts:isConstructionPreviewStoreItem(storeItem)
    if storeItem == nil then
        return false
    end

    if storeItem.price == nil and storeItem.xmlFilename == nil then
        return false
    end

    local xmlFilename = tostring(storeItem.xmlFilename or ""):lower()
    if xmlFilename == "" and storeItem.price == nil then
        return false
    end

    return true
end

function HP_OperatingCosts:getConstructionCostPreviewData(screen)
    local buyData = self:getConstructionBuyPlaceableData(screen)
    local item = self:getConstructionSelectedItem(screen)
    local storeItem = self:getConstructionStoreItem(screen, item, buyData)

    if not self:isConstructionPreviewStoreItem(storeItem) then
        return nil
    end

    local price = self:getConstructionPreviewPrice(screen, item, storeItem, buyData)
    if price <= 0 then
        return nil
    end

    local rates, difficultyKey = self:getCurrentRateSet()
    local targetMonthly = price * rates.placeableUpkeep
    local nativeMonthly = self:getConstructionNativeMonthlyUpkeep(storeItem, item, buyData)
    local monthlyUpkeep = math.max(0, targetMonthly - nativeMonthly)

    return {
        storeItem = storeItem,
        price = price,
        rate = rates.placeableUpkeep,
        targetMonthly = targetMonthly,
        nativeMonthly = nativeMonthly,
        monthlyUpkeep = monthlyUpkeep,
        categoryLabel = self:getConstructionCategoryLabel(screen, item, storeItem),
        difficultyKey = difficultyKey,
        difficultyLabel = self:getDifficultyLabel(difficultyKey)
    }
end

function HP_OperatingCosts:drawConstructionCostPreview(screen)
    if renderText == nil then
        return
    end

    local data = self:getConstructionCostPreviewData(screen)
    if data == nil then
        return
    end

    local x = 0.705
    local y = 0.145
    local w = 0.275
    local h = 0.150

    if drawFilledRect ~= nil then
        drawFilledRect(x, y, w, h, 0.02, 0.025, 0.03, 0.86)
        drawFilledRect(x, y + h - 0.004, w, 0.004, 0.75, 0.75, 0.75, 0.50)
    end

    local title = self:getText("hpOc_constructionPreviewTitle", "Erwartete Betriebskosten")
    local category = self:getText("hpOc_constructionPreviewCategory", "Kategorie") .. ": " .. data.categoryLabel
    local difficulty = self:getText("hpOc_constructionPreviewDifficulty", "Wirtschaft") .. ": " .. data.difficultyLabel
    local baseValue = self:getText("hpOc_constructionPreviewBaseValue", "Bemessungswert") .. ": " .. self:formatMoney(data.price)
    local native = self:getText("hpOc_constructionPreviewNativeUpkeep", "Vorhandener Unterhalt") .. ": " .. self:formatMoney(data.nativeMonthly or 0)
    local additional = self:getText("hpOc_constructionPreviewMonthlyUpkeep", "Zusätzlicher Unterhalt") .. ": " .. self:formatMoney(data.monthlyUpkeep)

    local lineX = x + 0.010
    local topY = y + h - 0.026
    local gap = 0.022

    self:drawWindowText(lineX, topY, 0.015, title, true)
    self:drawMutedWindowText(lineX, topY - gap, 0.0125, self:shortenText(category, 40))
    self:drawMutedWindowText(lineX, topY - gap * 2, 0.0125, difficulty)
    self:drawMutedWindowText(lineX, topY - gap * 3, 0.0125, baseValue)
    self:drawMutedWindowText(lineX, topY - gap * 4, 0.0125, native)
    self:drawMutedWindowText(lineX, topY - gap * 5, 0.0125, additional)
end

-- --------------------------------------------------------------------------
-- Einblendbares History-Fenster
-- --------------------------------------------------------------------------

function HP_OperatingCosts:initHistoryWindowState()
    self.historyWindow = self.historyWindow or {}
    self.historyWindow.visible = self.historyWindow.visible or false
    self.historyWindow.category = self.historyWindow.category or "total"
    self.historyWindow.periodMode = self.historyWindow.periodMode or "month"
    self.historyWindow.selectedYear = self.historyWindow.selectedYear
    self.historyWindow.selectedMonth = self.historyWindow.selectedMonth
    self.historyWindow.clickAreas = {}
    self.historyWindow.maxRows = 12
    self.historyWindow.scrollOffset = tonumber(self.historyWindow.scrollOffset) or 0
    self.historyWindow.inputLocked = self.historyWindow.inputLocked or false
    self.historyWindow.cameraBackup = self.historyWindow.cameraBackup or nil
    self.historyWindow.gameInputBlocked = self.historyWindow.gameInputBlocked or false
    self.blockHistoryWindowKeyRelease = self.blockHistoryWindowKeyRelease or nil
    self:ensureHistorySelection()
end

function HP_OperatingCosts:installHistoryWindowHooks()
    if self.drawHookInstalled ~= true and FSBaseMission ~= nil and FSBaseMission.draw ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
        FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
            if HP_OperatingCosts ~= nil then
                HP_OperatingCosts:installShopCostPreviewHooks()
                HP_OperatingCosts:drawHistoryWindow()
            end
        end)
        self.drawHookInstalled = true
    end

    -- Sicherheitsgurt gegen das ESC-Menü im Hintergrund: Falls das Grundspiel
    -- trotz sichtbarer Betriebskosten-Übersicht versucht, das ESC-Menü zu öffnen,
    -- wird dieser Öffnungsversuch verworfen.
    if self.menuOpenHookInstalled ~= true and InGameMenu ~= nil and InGameMenu.setIsVisible ~= nil and Utils ~= nil and Utils.overwrittenFunction ~= nil then
        InGameMenu.setIsVisible = Utils.overwrittenFunction(InGameMenu.setIsVisible, function(menu, superFunc, isVisible, ...)
            if HP_OperatingCosts ~= nil and HP_OperatingCosts.historyWindow ~= nil and HP_OperatingCosts.historyWindow.visible == true and isVisible == true then
                return
            end
            return superFunc(menu, isVisible, ...)
        end)
        self.menuOpenHookInstalled = true
    end

    if self.inputHookInstalled ~= true and PlayerInputComponent ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
        local registerCallback = function(inputComponent, ...)
            if HP_OperatingCosts ~= nil then
                HP_OperatingCosts:registerHistoryWindowInputAction()
            end
        end

        if PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
            PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, registerCallback)
        end

        if PlayerInputComponent.registerActionEvents ~= nil then
            PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, registerCallback)
        end

        self.inputHookInstalled = true
    end
end

function HP_OperatingCosts:registerHistoryWindowInputAction()
    if self.toggleWindowActionEventId ~= nil then
        return
    end

    if g_inputBinding == nil or g_inputBinding.registerActionEvent == nil then
        return
    end

    local action = nil
    if InputAction ~= nil then
        action = InputAction.HP_OC_TOGGLE_WINDOW
    end
    action = action or self.INPUT_ACTION_TOGGLE_WINDOW

    local contextName = nil
    if PlayerInputComponent ~= nil then
        contextName = PlayerInputComponent.INPUT_CONTEXT_NAME
    end
    contextName = contextName or g_inputBinding.currentContextName

    if g_inputBinding.beginActionEventsModification ~= nil then
        g_inputBinding:beginActionEventsModification(contextName)
    end

    local ok, eventId = g_inputBinding:registerActionEvent(action, self, HP_OperatingCosts.onToggleHistoryWindowInput, false, true, false, true)
    if ok and eventId ~= nil then
        self.toggleWindowActionEventId = eventId
        if g_inputBinding.setActionEventActive ~= nil then
            g_inputBinding:setActionEventActive(eventId, true)
        end
        if g_inputBinding.setActionEventText ~= nil then
            g_inputBinding:setActionEventText(eventId, self:getText("input_HP_OC_TOGGLE_WINDOW", self.DEFAULT_TOGGLE_LABEL))
        end
        if g_inputBinding.setActionEventTextPriority ~= nil and GS_PRIO_LOW ~= nil then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
        end
        if g_inputBinding.setActionEventTextVisibility ~= nil then
            g_inputBinding:setActionEventTextVisibility(eventId, true)
        end
    end

    if g_inputBinding.endActionEventsModification ~= nil then
        g_inputBinding:endActionEventsModification()
    end
end

function HP_OperatingCosts:onToggleHistoryWindowInput(actionName, inputValue, callbackState, isAnalog)
    if inputValue ~= nil and inputValue <= 0 then
        return
    end

    self:toggleHistoryWindow()
end

function HP_OperatingCosts:toggleHistoryWindow()
    self.historyWindow = self.historyWindow or {}
    self:setHistoryWindowVisible(self.historyWindow.visible ~= true)
end

function HP_OperatingCosts:setHistoryWindowVisible(visible)
    self.historyWindow = self.historyWindow or {}
    visible = visible == true

    if visible and self.historyWindow.visible ~= true then
        if g_gui ~= nil then
            local guiVisible = false
            if g_gui.getIsGuiVisible ~= nil then
                guiVisible = g_gui:getIsGuiVisible()
            end
            if g_gui.getIsDialogVisible ~= nil then
                guiVisible = guiVisible or g_gui:getIsDialogVisible()
            end
            if guiVisible then
                return
            end
        end

        self:loadHistoryFile()
        self:selectCurrentHistoryMonth()
        self:repairCurrentHistoryDetailsForWindow()
        self:resetHistoryScroll()
        self.historyWindow.visible = true
        self:setHistoryWindowInputLock(true)
        return
    end

    if not visible and self.historyWindow.visible == true then
        self.historyWindow.visible = false
        self:setHistoryWindowInputLock(false)
    elseif not visible then
        self:setHistoryWindowInputLock(false)
    end
end

function HP_OperatingCosts:setHistoryWindowInputLock(locked)
    self.historyWindow = self.historyWindow or {}

    if locked == true then
        if self.historyWindow.inputLocked == true then
            self:keepHistoryWindowInputLockActive()
            return
        end

        self.historyWindow.inputLocked = true

        self:setHistoryWindowGameInputBlocked(true)

        if g_inputBinding ~= nil then
            if g_inputBinding.getShowMouseCursor ~= nil then
                local ok, previousState = pcall(g_inputBinding.getShowMouseCursor, g_inputBinding)
                if ok then
                    self.historyWindow.previousMouseCursorState = previousState == true
                end
            end

            if g_inputBinding.setShowMouseCursor ~= nil then
                pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, true, true)
            end
        end

        if g_currentMission ~= nil then
            self.historyWindow.previousPlayerFrozenState = g_currentMission.isPlayerFrozen == true
            g_currentMission.isPlayerFrozen = true
        end

        self:lockHistoryWindowVehicleCamera(true)
        self:lockHistoryWindowPlayerCamera(true)
        return
    end

    if self.historyWindow.inputLocked ~= true then
        return
    end

    self.historyWindow.inputLocked = false

    self:lockHistoryWindowVehicleCamera(false)
    self:lockHistoryWindowPlayerCamera(false)
    self:setHistoryWindowGameInputBlocked(false)

    if g_currentMission ~= nil and self.historyWindow.previousPlayerFrozenState ~= nil then
        g_currentMission.isPlayerFrozen = self.historyWindow.previousPlayerFrozenState == true
    end
    self.historyWindow.previousPlayerFrozenState = nil

    if g_inputBinding ~= nil and g_inputBinding.setShowMouseCursor ~= nil then
        local previousState = self.historyWindow.previousMouseCursorState == true
        pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, previousState)
    end
    self.historyWindow.previousMouseCursorState = nil
end

function HP_OperatingCosts:keepHistoryWindowInputLockActive()
    if self.historyWindow == nil or self.historyWindow.visible ~= true then
        return
    end

    self:setHistoryWindowGameInputBlocked(true)

    if g_inputBinding ~= nil and g_inputBinding.setShowMouseCursor ~= nil then
        pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, true, true)
    end

    if g_currentMission ~= nil then
        g_currentMission.isPlayerFrozen = true
    end

    self:lockHistoryWindowVehicleCamera(true)
    self:lockHistoryWindowPlayerCamera(true)
end

function HP_OperatingCosts:setHistoryWindowGameInputBlocked(blocked)
    self.historyWindow = self.historyWindow or {}

    if g_inputBinding == nil then
        return
    end

    if blocked == true then
        if self.historyWindow.gameInputBlocked == true then
            return
        end

        self.historyWindow.gameInputBlocked = true
        self.historyWindow.blockedInputContexts = {}

        local contexts = self:getHistoryWindowInputContextsToBlock()
        if g_inputBinding.setContextEventsActive ~= nil then
            for _, contextName in ipairs(contexts) do
                if contextName ~= nil and contextName ~= "" then
                    local ok = pcall(g_inputBinding.setContextEventsActive, g_inputBinding, contextName, false)
                    if ok then
                        table.insert(self.historyWindow.blockedInputContexts, contextName)
                    end
                end
            end
        end

        return
    end

    if self.historyWindow.gameInputBlocked ~= true then
        return
    end

    self.historyWindow.gameInputBlocked = false

    if g_inputBinding.setContextEventsActive ~= nil then
        for _, contextName in ipairs(self.historyWindow.blockedInputContexts or {}) do
            pcall(g_inputBinding.setContextEventsActive, g_inputBinding, contextName, true)
        end
    end

    self.historyWindow.blockedInputContexts = nil
end

function HP_OperatingCosts:getHistoryWindowInputContextsToBlock()
    local contexts = {}
    local seen = {}

    local function add(contextName)
        if contextName ~= nil and contextName ~= "" and seen[contextName] ~= true then
            table.insert(contexts, contextName)
            seen[contextName] = true
        end
    end

    if g_inputBinding ~= nil and g_inputBinding.currentContextName ~= nil then
        add(g_inputBinding.currentContextName)
    end
    if PlayerInputComponent ~= nil then
        add(PlayerInputComponent.INPUT_CONTEXT_NAME)
    end
    if Vehicle ~= nil then
        add(Vehicle.INPUT_CONTEXT_NAME)
    end

    local mission = g_currentMission
    if mission ~= nil and mission.playerInputComponent ~= nil then
        add(mission.playerInputComponent.INPUT_CONTEXT_NAME)
        add(mission.playerInputComponent.inputContextName)
        add(mission.playerInputComponent.inputContext)
    end
    if g_localPlayer ~= nil and g_localPlayer.playerInputComponent ~= nil then
        add(g_localPlayer.playerInputComponent.INPUT_CONTEXT_NAME)
        add(g_localPlayer.playerInputComponent.inputContextName)
        add(g_localPlayer.playerInputComponent.inputContext)
    end

    -- Fallbacks für abweichende Scriptstände und globale Spielaktionen wie ESC/F1.
    add("PLAYER")
    add("VEHICLE")
    add("ONFOOT")
    add("GAMEPLAY")
    add("GLOBAL")
    add("CAMERA")
    add("PLAYER_CAMERA")
    add("VEHICLE_CAMERA")
    add("PLAYER_MOVEMENT")
    add("PLAYER_ACTIONS")
    add("LOOK")
    add("MENU")

    return contexts
end

function HP_OperatingCosts:getControlledVehicleForWindowLock()
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
        return g_currentMission.controlledVehicle
    end

    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, vehicle = pcall(g_localPlayer.getCurrentVehicle, g_localPlayer)
        if ok then
            return vehicle
        end
    end

    return nil
end

function HP_OperatingCosts:lockHistoryWindowVehicleCamera(locked)
    self.historyWindow = self.historyWindow or {}

    if locked == true then
        local vehicle = self:getControlledVehicleForWindowLock()
        if vehicle == nil or vehicle.spec_enterable == nil or vehicle.spec_enterable.cameras == nil then
            return
        end

        if self.historyWindow.cameraBackup ~= nil and self.historyWindow.cameraBackup.vehicle == vehicle then
            return
        end

        if self.historyWindow.cameraBackup ~= nil then
            self:lockHistoryWindowVehicleCamera(false)
        end

        local backup = { vehicle = vehicle, cameras = {} }
        for index, camera in ipairs(vehicle.spec_enterable.cameras) do
            backup.cameras[index] = {
                isRotatable = camera.isRotatable,
                storedIsRotatable = camera.storedIsRotatable
            }
            camera.isRotatable = false
            camera.storedIsRotatable = false
        end
        self.historyWindow.cameraBackup = backup
        return
    end

    local backup = self.historyWindow.cameraBackup
    if backup == nil or backup.vehicle == nil or backup.vehicle.spec_enterable == nil or backup.vehicle.spec_enterable.cameras == nil then
        self.historyWindow.cameraBackup = nil
        return
    end

    for index, cameraState in pairs(backup.cameras or {}) do
        local camera = backup.vehicle.spec_enterable.cameras[index]
        if camera ~= nil then
            camera.isRotatable = cameraState.isRotatable
            camera.storedIsRotatable = cameraState.storedIsRotatable
        end
    end

    self.historyWindow.cameraBackup = nil
end

function HP_OperatingCosts:getHistoryWindowPlayerCameraTargets()
    local targets = {}
    local seen = {}

    local function add(camera)
        if type(camera) == "table" and seen[camera] ~= true then
            if camera.isRotatable ~= nil or camera.storedIsRotatable ~= nil then
                table.insert(targets, camera)
                seen[camera] = true
            end
        end
    end

    if g_localPlayer ~= nil then
        add(g_localPlayer.camera)
        add(g_localPlayer.playerCamera)
        add(g_localPlayer.handToolCamera)

        if type(g_localPlayer.cameras) == "table" then
            for _, camera in pairs(g_localPlayer.cameras) do
                add(camera)
            end
        end
    end

    return targets
end

function HP_OperatingCosts:lockHistoryWindowPlayerCamera(locked)
    self.historyWindow = self.historyWindow or {}

    if locked == true then
        if self.historyWindow.playerCameraBackup ~= nil then
            return
        end

        local backups = {}
        for _, camera in ipairs(self:getHistoryWindowPlayerCameraTargets()) do
            table.insert(backups, {
                camera = camera,
                isRotatable = camera.isRotatable,
                storedIsRotatable = camera.storedIsRotatable
            })

            if camera.isRotatable ~= nil then
                camera.isRotatable = false
            end
            if camera.storedIsRotatable ~= nil then
                camera.storedIsRotatable = false
            end
        end

        self.historyWindow.playerCameraBackup = backups
        return
    end

    for _, backup in ipairs(self.historyWindow.playerCameraBackup or {}) do
        if backup.camera ~= nil then
            if backup.isRotatable ~= nil then
                backup.camera.isRotatable = backup.isRotatable
            end
            if backup.storedIsRotatable ~= nil then
                backup.camera.storedIsRotatable = backup.storedIsRotatable
            end
        end
    end

    self.historyWindow.playerCameraBackup = nil
end

function HP_OperatingCosts:getLocalFarmId()
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local ok, farmId = pcall(g_currentMission.getFarmId, g_currentMission)
        if ok and farmId ~= nil and farmId > 0 then
            return farmId
        end
    end

    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil and g_localPlayer.farmId > 0 then
        return g_localPlayer.farmId
    end

    return nil
end

function HP_OperatingCosts:getFarmDisplayName(farmId)
    farmId = tonumber(farmId)
    if farmId == nil then
        return self:getText("hpOc_farm", "Farm") .. " -"
    end

    local farm = nil
    if g_farmManager ~= nil and g_farmManager.getFarmById ~= nil then
        local ok, result = pcall(g_farmManager.getFarmById, g_farmManager, farmId)
        if ok then
            farm = result
        end
    end

    if farm == nil and g_currentMission ~= nil and g_currentMission.farmManager ~= nil and g_currentMission.farmManager.getFarmById ~= nil then
        local ok, result = pcall(g_currentMission.farmManager.getFarmById, g_currentMission.farmManager, farmId)
        if ok then
            farm = result
        end
    end

    if farm ~= nil then
        local name = farm.name or farm.farmName or farm.nickname
        if name ~= nil and tostring(name) ~= "" then
            return tostring(name)
        end
    end

    return self:getText("hpOc_farm", "Farm") .. " " .. tostring(farmId)
end

function HP_OperatingCosts:ensureHistorySelection()
    self.historyWindow = self.historyWindow or {}
    local selectedYear = tonumber(self.historyWindow.selectedYear)
    local selectedMonth = tonumber(self.historyWindow.selectedMonth)

    if selectedYear ~= nil and selectedMonth ~= nil then
        return
    end

    self:selectCurrentHistoryMonth(false)
end

function HP_OperatingCosts:selectCurrentHistoryMonth(forceMonthMode)
    self.historyWindow = self.historyWindow or {}

    local year, month = self:getCurrentYearAndMonth(nil)
    self.historyWindow.selectedYear = tonumber(year) or 1
    self.historyWindow.selectedMonth = tonumber(month) or 1

    if forceMonthMode ~= false then
        self.historyWindow.periodMode = "month"
    end
end

function HP_OperatingCosts:resetHistoryScroll()
    self.historyWindow = self.historyWindow or {}
    self.historyWindow.scrollOffset = 0
end


function HP_OperatingCosts:repairCurrentHistoryDetailsForWindow()
    local window = self.historyWindow or {}
    local localFarmId = self:getLocalFarmId()
    if localFarmId == nil then
        return
    end

    local year, month, fsPeriod = self:getCurrentYearAndMonth(nil)
    if tonumber(window.selectedYear) ~= tonumber(year) or tonumber(window.selectedMonth) ~= tonumber(month) then
        return
    end

    local record = self:getHistoryRecordForPeriod(localFarmId, year, month)
    if record == nil then
        return
    end

    local entryCount = #(record.entries or {})
    if entryCount > 0 then
        return
    end

    local difficultyRaw = self:getEconomyDifficultyRawValue()
    local difficultyKey = self:getEconomyDifficultyKeyFromValue(difficultyRaw)
    local rates = self.RATES[difficultyKey] or self.RATES.normal
    local totalsByFarm = {}
    local diagnosticsByFarm = {}

    self:collectVehicleCosts(totalsByFarm, rates, diagnosticsByFarm)
    local seenStorageObjects = {}
    self:collectPlaceableCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)
    self:collectStandaloneStorageCosts(totalsByFarm, rates, diagnosticsByFarm, seenStorageObjects)

    local totals = totalsByFarm[localFarmId]
    if totals == nil or totals.entries == nil or #totals.entries == 0 then
        return
    end

    local displayVehicleInsurance = math.max(tonumber(record.vehicleInsurance) or 0, math.floor((totals.vehicleInsurance or 0) + 0.5))
    local displayStoredGoodsInsurance = math.max(tonumber(record.storedGoodsInsurance) or 0, math.floor((totals.storedGoodsInsurance or 0) + 0.5))
    local displayUpkeep = math.max(tonumber(record.upkeep) or 0, math.floor((totals.upkeep or 0) + 0.5))

    self:writeHistory(localFarmId, year, month, fsPeriod, totals, displayVehicleInsurance, displayStoredGoodsInsurance, displayUpkeep)
    self:diagnostic(string.format(
        "Leerer History-Datensatz für Farm %s, Jahr %s / Kalendermonat %s wurde beim Öffnen des Fensters mit aktuellen Einzelposten ergänzt.",
        tostring(localFarmId),
        tostring(year),
        tostring(month)
    ))
end

function HP_OperatingCosts:getHistoryCategories()
    return {
        { key = "total", label = self:getText("hpOc_tabTotal", "Gesamt") },
        { key = "vehicleInsurance", label = self:getText("hpOc_tabVehicleInsurance", "Fahrzeug-/Geräteversicherung") },
        { key = "storedGoodsInsurance", label = self:getText("hpOc_tabStoredGoodsInsurance", "Lagergutversicherung") },
        { key = "upkeep", label = self:getText("hpOc_tabUpkeep", "Unterhalt") }
    }
end

function HP_OperatingCosts:getHistoryPeriodModes()
    return {
        { key = "month", label = self:getText("hpOc_periodMonth", "Monat") },
        { key = "year", label = self:getText("hpOc_periodYear", "Jahr") },
        { key = "all", label = self:getText("hpOc_periodAll", "Alle Jahre") }
    }
end

function HP_OperatingCosts:getRecordCategoryAmount(record, category)
    if record == nil then
        return 0
    end

    if category == "vehicleInsurance" then
        return tonumber(record.vehicleInsurance) or 0
    elseif category == "storedGoodsInsurance" then
        return tonumber(record.storedGoodsInsurance) or 0
    elseif category == "upkeep" then
        return tonumber(record.upkeep) or 0
    end

    return (tonumber(record.vehicleInsurance) or 0) + (tonumber(record.storedGoodsInsurance) or 0) + (tonumber(record.upkeep) or 0)
end

function HP_OperatingCosts:getFilteredHistoryRecords()
    local window = self.historyWindow or {}
    local localFarmId = self:getLocalFarmId()
    local selectedYear = tonumber(window.selectedYear) or 1
    local selectedMonth = tonumber(window.selectedMonth) or 1
    local records = {}

    for _, record in ipairs(self.historyRecords or {}) do
        local recordFarmId = tonumber(record.farmId)
        local recordYear = tonumber(record.year) or 0
        local recordMonth = tonumber(record.month) or 0
        local farmMatches = localFarmId == nil or recordFarmId == localFarmId
        local periodMatches = false

        if window.periodMode == "all" then
            periodMatches = true
        elseif window.periodMode == "year" then
            periodMatches = recordYear == selectedYear
        else
            periodMatches = recordYear == selectedYear and recordMonth == selectedMonth
        end

        if farmMatches and periodMatches then
            table.insert(records, record)
        end
    end

    table.sort(records, function(a, b)
        local ay = tonumber(a.year) or 0
        local by = tonumber(b.year) or 0
        if ay ~= by then
            return ay < by
        end
        local am = tonumber(a.month) or 0
        local bm = tonumber(b.month) or 0
        if am ~= bm then
            return am < bm
        end
        return (tonumber(a.farmId) or 0) < (tonumber(b.farmId) or 0)
    end)

    return records
end

function HP_OperatingCosts:getHistorySummary(records)
    local summary = {
        vehicleInsurance = 0,
        storedGoodsInsurance = 0,
        upkeep = 0,
        total = 0,
        entries = 0
    }

    for _, record in ipairs(records or {}) do
        summary.vehicleInsurance = summary.vehicleInsurance + (tonumber(record.vehicleInsurance) or 0)
        summary.storedGoodsInsurance = summary.storedGoodsInsurance + (tonumber(record.storedGoodsInsurance) or 0)
        summary.upkeep = summary.upkeep + (tonumber(record.upkeep) or 0)
        summary.total = summary.vehicleInsurance + summary.storedGoodsInsurance + summary.upkeep
        summary.entries = summary.entries + #(record.entries or {})
    end

    return summary
end

function HP_OperatingCosts:collectHistoryRows(records)
    local window = self.historyWindow or {}
    local category = window.category or "total"
    local rows = {}

    if window.periodMode == "month" then
        for _, record in ipairs(records or {}) do
            local hadEntries = false
            for _, entry in ipairs(record.entries or {}) do
                hadEntries = true
                if category == "total" or entry.type == category then
                    table.insert(rows, {
                        year = tonumber(record.year) or 0,
                        month = tonumber(record.month) or 0,
                        name = entry.name or "unknown",
                        category = self:getEntryTypeLabel(entry.type),
                        amount = tonumber(entry.amount) or 0,
                        baseValue = tonumber(entry.baseValue) or 0,
                        rate = tonumber(entry.rate) or 0,
                        moneyCategory = entry.moneyCategory or ""
                    })
                end
            end

            if not hadEntries then
                self:addFallbackHistoryRows(rows, record, category)
            end
        end

        table.sort(rows, function(a, b)
            if a.amount ~= b.amount then
                return a.amount > b.amount
            end
            return tostring(a.name) < tostring(b.name)
        end)
    elseif window.periodMode == "year" then
        local byMonth = {}
        for month = 1, 12 do
            byMonth[month] = { month = month, vehicleInsurance = 0, storedGoodsInsurance = 0, upkeep = 0, total = 0 }
        end
        for _, record in ipairs(records or {}) do
            local month = tonumber(record.month) or 0
            if byMonth[month] ~= nil then
                byMonth[month].vehicleInsurance = byMonth[month].vehicleInsurance + (tonumber(record.vehicleInsurance) or 0)
                byMonth[month].storedGoodsInsurance = byMonth[month].storedGoodsInsurance + (tonumber(record.storedGoodsInsurance) or 0)
                byMonth[month].upkeep = byMonth[month].upkeep + (tonumber(record.upkeep) or 0)
                byMonth[month].total = byMonth[month].vehicleInsurance + byMonth[month].storedGoodsInsurance + byMonth[month].upkeep
            end
        end
        for month = 1, 12 do
            local row = byMonth[month]
            if self:getRecordCategoryAmount(row, category) > 0 then
                table.insert(rows, row)
            end
        end
    else
        local byYear = {}
        for _, record in ipairs(records or {}) do
            local year = tonumber(record.year) or 0
            byYear[year] = byYear[year] or { year = year, vehicleInsurance = 0, storedGoodsInsurance = 0, upkeep = 0, total = 0 }
            byYear[year].vehicleInsurance = byYear[year].vehicleInsurance + (tonumber(record.vehicleInsurance) or 0)
            byYear[year].storedGoodsInsurance = byYear[year].storedGoodsInsurance + (tonumber(record.storedGoodsInsurance) or 0)
            byYear[year].upkeep = byYear[year].upkeep + (tonumber(record.upkeep) or 0)
            byYear[year].total = byYear[year].vehicleInsurance + byYear[year].storedGoodsInsurance + byYear[year].upkeep
        end
        for _, row in pairs(byYear) do
            table.insert(rows, row)
        end
        table.sort(rows, function(a, b)
            return (tonumber(a.year) or 0) < (tonumber(b.year) or 0)
        end)
    end

    return rows
end

function HP_OperatingCosts:addFallbackHistoryRows(rows, record, category)
    local function addRow(entryType, amount)
        amount = tonumber(amount) or 0
        if amount <= 0 then
            return
        end
        if category ~= "total" and category ~= entryType then
            return
        end
        table.insert(rows, {
            year = tonumber(record.year) or 0,
            month = tonumber(record.month) or 0,
            name = self:getText("hpOc_total", "Gesamt"),
            category = self:getEntryTypeLabel(entryType),
            amount = amount,
            baseValue = 0,
            rate = 0,
            moneyCategory = ""
        })
    end

    addRow("vehicleInsurance", record.vehicleInsurance)
    addRow("storedGoodsInsurance", record.storedGoodsInsurance)
    addRow("upkeep", record.upkeep)
end

function HP_OperatingCosts:getHistoryRowsTotal(rows)
    local total = 0
    local window = self.historyWindow or {}
    local category = window.category or "total"

    for _, row in ipairs(rows or {}) do
        if window.periodMode == "month" then
            total = total + (tonumber(row.amount) or 0)
        else
            total = total + self:getRecordCategoryAmount(row, category)
        end
    end

    return total
end
function HP_OperatingCosts:getHistoryFooterTotal(rows, summary, category)
    local window = self.historyWindow or {}
    if window.periodMode == "month" and summary ~= nil then
        if category == "vehicleInsurance" then
            return tonumber(summary.vehicleInsurance) or 0
        elseif category == "storedGoodsInsurance" then
            return tonumber(summary.storedGoodsInsurance) or 0
        elseif category == "upkeep" then
            return tonumber(summary.upkeep) or 0
        end

        return tonumber(summary.total) or 0
    end

    return self:getHistoryRowsTotal(rows)
end


function HP_OperatingCosts:clampHistoryScrollOffset(rowCount, visibleRows)
    self.historyWindow = self.historyWindow or {}
    rowCount = tonumber(rowCount) or 0
    visibleRows = math.max(1, tonumber(visibleRows) or 1)
    local maxOffset = math.max(0, rowCount - visibleRows)
    local offset = tonumber(self.historyWindow.scrollOffset) or 0

    if offset < 0 then
        offset = 0
    elseif offset > maxOffset then
        offset = maxOffset
    end

    self.historyWindow.scrollOffset = offset
    return offset, maxOffset
end

function HP_OperatingCosts:drawHistoryScrollBar(x, tableTop, totalRowY, rowCount, visibleRows, scrollOffset, maxOffset)
    if drawFilledRect == nil or rowCount <= visibleRows then
        return
    end

    local trackX = x + 0.721
    local trackY = totalRowY + 0.032
    local trackH = math.max(0.05, tableTop - trackY - 0.004)
    local trackW = 0.010

    drawFilledRect(trackX, trackY, trackW, trackH, 0.08, 0.10, 0.12, 0.92)

    local thumbH = math.max(0.026, trackH * (visibleRows / math.max(rowCount, 1)))
    local travel = math.max(0, trackH - thumbH)
    local thumbY = trackY + travel
    if maxOffset > 0 then
        thumbY = trackY + travel * (1 - (scrollOffset / maxOffset))
    end

    drawFilledRect(trackX + 0.0015, thumbY, trackW - 0.003, thumbH, 0.75, 0.75, 0.75, 0.70)

    self:addHistoryClickArea("scrollPageUp", trackX - 0.004, thumbY + thumbH, trackW + 0.008, math.max(0.001, trackY + trackH - thumbY - thumbH), nil)
    self:addHistoryClickArea("scrollPageDown", trackX - 0.004, trackY, trackW + 0.008, math.max(0.001, thumbY - trackY), nil)
end

function HP_OperatingCosts:scrollHistoryRows(delta, pageSize)
    self.historyWindow = self.historyWindow or {}
    local step = tonumber(delta) or 0
    if pageSize ~= nil then
        step = step * math.max(1, tonumber(pageSize) or 1)
    end
    self.historyWindow.scrollOffset = math.max(0, (tonumber(self.historyWindow.scrollOffset) or 0) + step)
end

function HP_OperatingCosts:getEntryTypeLabel(entryType)
    if entryType == "vehicleInsurance" then
        return self:getText("hpOc_tabVehicleInsurance", "Fahrzeug-/Geräteversicherung")
    elseif entryType == "storedGoodsInsurance" then
        return self:getText("hpOc_tabStoredGoodsInsurance", "Lagergutversicherung")
    elseif entryType == "upkeep" then
        return self:getText("hpOc_tabUpkeep", "Unterhalt")
    end
    return tostring(entryType or "")
end

function HP_OperatingCosts:formatMonthName(month)
    local names = {
        self:getText("hpOc_month01", "Januar"),
        self:getText("hpOc_month02", "Februar"),
        self:getText("hpOc_month03", "März"),
        self:getText("hpOc_month04", "April"),
        self:getText("hpOc_month05", "Mai"),
        self:getText("hpOc_month06", "Juni"),
        self:getText("hpOc_month07", "Juli"),
        self:getText("hpOc_month08", "August"),
        self:getText("hpOc_month09", "September"),
        self:getText("hpOc_month10", "Oktober"),
        self:getText("hpOc_month11", "November"),
        self:getText("hpOc_month12", "Dezember")
    }
    return names[tonumber(month) or 0] or tostring(month or "")
end

function HP_OperatingCosts:addHistoryClickArea(id, x, y, width, height, data)
    if self.historyWindow == nil then
        return
    end
    self.historyWindow.clickAreas = self.historyWindow.clickAreas or {}
    table.insert(self.historyWindow.clickAreas, { id = id, x = x, y = y, width = width, height = height, data = data })
end

function HP_OperatingCosts:drawButton(id, x, y, width, height, text, active, data)
    if drawFilledRect ~= nil then
        if active then
            drawFilledRect(x, y, width, height, 0.18, 0.42, 0.62, 0.92)
        else
            drawFilledRect(x, y, width, height, 0.08, 0.10, 0.12, 0.88)
        end
        drawFilledRect(x, y, width, 0.0015, 0.75, 0.75, 0.75, 0.45)
    end
    self:drawWindowText(x + 0.006, y + height * 0.28, 0.014, text, active, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    self:addHistoryClickArea(id, x, y, width, height, data)
end

function HP_OperatingCosts:drawWindowText(x, y, size, text, bold, alignment, color)
    if renderText == nil then
        return
    end

    if setTextAlignment ~= nil and alignment ~= nil then
        setTextAlignment(alignment)
    elseif setTextAlignment ~= nil and RenderText ~= nil then
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    if setTextBold ~= nil then
        setTextBold(bold == true)
    end
    if setTextColor ~= nil then
        if color ~= nil then
            setTextColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
        else
            setTextColor(1, 1, 1, 1)
        end
    end

    renderText(x, y, size, tostring(text or ""))

    if setTextBold ~= nil then
        setTextBold(false)
    end
    if setTextColor ~= nil then
        setTextColor(1, 1, 1, 1)
    end
end

function HP_OperatingCosts:drawMutedWindowText(x, y, size, text)
    self:drawWindowText(x, y, size, text, false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil, {0.78, 0.82, 0.84, 1})
end

function HP_OperatingCosts:drawHistoryWindow()
    local window = self.historyWindow
    if window == nil or window.visible ~= true then
        return
    end

    if drawFilledRect == nil or renderText == nil then
        return
    end

    window.clickAreas = {}
    self:ensureHistorySelection()

    local x = 0.115
    local y = 0.165
    local w = 0.77
    local h = 0.67
    local top = y + h

    drawFilledRect(x, y, w, h, 0.015, 0.018, 0.020, 0.94)
    drawFilledRect(x, top - 0.055, w, 0.055, 0.05, 0.07, 0.09, 0.96)
    drawFilledRect(x, y, w, 0.002, 0.75, 0.75, 0.75, 0.35)
    drawFilledRect(x, top - 0.002, w, 0.002, 0.75, 0.75, 0.75, 0.35)

    self:drawWindowText(x + 0.018, top - 0.038, 0.021, self:getText("hpOc_title", "Betriebskosten-Auswertung"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    self:drawButton("close", x + w - 0.068, top - 0.043, 0.050, 0.026, self:getText("hpOc_close", "Schließen"), false)

    local tabX = x + 0.018
    local tabY = top - 0.094
    local categories = self:getHistoryCategories()
    local tabWidths = { 0.082, 0.190, 0.152, 0.090 }
    for index, category in ipairs(categories) do
        local bw = tabWidths[index] or 0.120
        self:drawButton("category", tabX, tabY, bw, 0.029, category.label, window.category == category.key, { category = category.key })
        tabX = tabX + bw + 0.006
    end

    local modeX = x + 0.018
    local modeY = top - 0.136
    local modes = self:getHistoryPeriodModes()
    for _, mode in ipairs(modes) do
        self:drawButton("periodMode", modeX, modeY, 0.088, 0.028, mode.label, window.periodMode == mode.key, { periodMode = mode.key })
        modeX = modeX + 0.094
    end

    local navX = x + 0.330
    local navText = ""
    if window.periodMode == "month" then
        navText = string.format("%s %s", self:formatMonthName(window.selectedMonth), tostring(window.selectedYear or 1))
        self:drawButton("prevMonth", navX, modeY, 0.036, 0.028, "<", false)
        self:drawButton("nextMonth", navX + 0.248, modeY, 0.036, 0.028, ">", false)
        self:drawWindowText(navX + 0.047, modeY + 0.007, 0.016, navText, true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    elseif window.periodMode == "year" then
        navText = string.format("%s %s", self:getText("hpOc_year", "Jahr"), tostring(window.selectedYear or 1))
        self:drawButton("prevYear", navX, modeY, 0.036, 0.028, "<", false)
        self:drawButton("nextYear", navX + 0.170, modeY, 0.036, 0.028, ">", false)
        self:drawWindowText(navX + 0.047, modeY + 0.007, 0.016, navText, true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    else
        self:drawWindowText(navX, modeY + 0.007, 0.016, self:getText("hpOc_allYears", "Alle gespeicherten Jahre"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    end

    local records = self:getFilteredHistoryRecords()
    local summary = self:getHistorySummary(records)
    local localFarmId = self:getLocalFarmId()
    local farmText = self:getFarmDisplayName(localFarmId)
    self:drawMutedWindowText(x + w - 0.118, modeY + 0.007, 0.013, self:shortenText(farmText, 22))

    local summaryY = top - 0.188
    drawFilledRect(x + 0.018, summaryY - 0.010, w - 0.036, 0.052, 0.025, 0.030, 0.035, 0.92)
    self:drawWindowText(x + 0.032, summaryY + 0.017, 0.014, self:getText("hpOc_total", "Gesamt") .. ": " .. self:formatMoneyDetailed(summary.total), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    self:drawMutedWindowText(x + 0.185, summaryY + 0.017, 0.012, self:getText("hpOc_tabVehicleInsurance", "Fahrzeug-/Geräteversicherung") .. ": " .. self:formatMoneyDetailed(summary.vehicleInsurance))
    self:drawMutedWindowText(x + 0.435, summaryY + 0.017, 0.012, self:getText("hpOc_tabStoredGoodsInsurance", "Lagergutversicherung") .. ": " .. self:formatMoneyDetailed(summary.storedGoodsInsurance))
    self:drawMutedWindowText(x + 0.650, summaryY + 0.017, 0.012, self:getText("hpOc_tabUpkeep", "Unterhalt") .. ": " .. self:formatMoneyDetailed(summary.upkeep))

    local rows = self:collectHistoryRows(records)
    local tableTop = summaryY - 0.034
    local lineHeight = 0.030
    local totalRowY = y + 0.052
    local visibleRows = math.max(1, math.floor((tableTop - totalRowY - lineHeight) / lineHeight))
    window.maxRows = visibleRows

    if #records == 0 then
        self:resetHistoryScroll()
        self:drawWindowText(x + 0.032, tableTop - 0.018, 0.015, self:getText("hpOc_noHistory", "Für diese Auswahl liegen noch keine gespeicherten Betriebskosten vor."), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawMutedWindowText(x + 0.032, tableTop - 0.050, 0.012, self:getText("hpOc_noHistoryHint", "Nach dem nächsten Monatswechsel wird operatingCostsHistory.xml automatisch ergänzt."))
        return
    end

    drawFilledRect(x + 0.018, tableTop, w - 0.036, 0.026, 0.08, 0.10, 0.12, 0.95)
    if window.periodMode == "month" then
        self:drawWindowText(x + 0.032, tableTop + 0.007, 0.012, self:getText("hpOc_object", "Objekt"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.370, tableTop + 0.007, 0.012, self:getText("hpOc_type", "Art"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.630, tableTop + 0.007, 0.012, self:getText("hpOc_amount", "Betrag"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    elseif window.periodMode == "year" then
        self:drawWindowText(x + 0.032, tableTop + 0.007, 0.012, self:getText("hpOc_month", "Monat"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.250, tableTop + 0.007, 0.012, self:getText("hpOc_selectedCategory", "Ausgewählte Kategorie"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.630, tableTop + 0.007, 0.012, self:getText("hpOc_amount", "Betrag"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    else
        self:drawWindowText(x + 0.032, tableTop + 0.007, 0.012, self:getText("hpOc_year", "Jahr"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.250, tableTop + 0.007, 0.012, self:getText("hpOc_selectedCategory", "Ausgewählte Kategorie"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        self:drawWindowText(x + 0.630, tableTop + 0.007, 0.012, self:getText("hpOc_amount", "Betrag"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    end

    local scrollOffset, maxOffset = self:clampHistoryScrollOffset(#rows, visibleRows)
    local rowsToDraw = math.min(visibleRows, math.max(0, #rows - scrollOffset))
    for visibleIndex = 1, rowsToDraw do
        local rowIndex = scrollOffset + visibleIndex
        local row = rows[rowIndex]
        local rowY = tableTop - (visibleIndex * lineHeight)
        if visibleIndex % 2 == 0 then
            drawFilledRect(x + 0.018, rowY - 0.001, w - 0.036, 0.026, 0.030, 0.035, 0.040, 0.78)
        end

        if window.periodMode == "month" then
            self:drawWindowText(x + 0.032, rowY + 0.006, 0.011, self:shortenText(row.name, 44), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
            self:drawMutedWindowText(x + 0.370, rowY + 0.006, 0.011, self:shortenText(row.category, 30))
            self:drawWindowText(x + 0.630, rowY + 0.006, 0.011, self:formatMoneyDetailed(row.amount), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        elseif window.periodMode == "year" then
            self:drawWindowText(x + 0.032, rowY + 0.006, 0.011, self:formatMonthName(row.month), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
            self:drawMutedWindowText(x + 0.250, rowY + 0.006, 0.011, self:getSelectedCategoryLabel())
            self:drawWindowText(x + 0.630, rowY + 0.006, 0.011, self:formatMoneyDetailed(self:getRecordCategoryAmount(row, window.category)), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        else
            self:drawWindowText(x + 0.032, rowY + 0.006, 0.011, tostring(row.year), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
            self:drawMutedWindowText(x + 0.250, rowY + 0.006, 0.011, self:getSelectedCategoryLabel())
            self:drawWindowText(x + 0.630, rowY + 0.006, 0.011, self:formatMoneyDetailed(self:getRecordCategoryAmount(row, window.category)), false, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
        end
    end

    self:drawHistoryScrollBar(x, tableTop, totalRowY, #rows, visibleRows, scrollOffset, maxOffset)

    drawFilledRect(x + 0.018, totalRowY - 0.001, w - 0.036, 0.027, 0.08, 0.10, 0.12, 0.95)
    self:drawWindowText(x + 0.032, totalRowY + 0.006, 0.012, self:getText("hpOc_total", "Gesamt"), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)
    if window.periodMode == "month" then
        self:drawMutedWindowText(x + 0.370, totalRowY + 0.006, 0.011, self:getSelectedCategoryLabel())
    else
        self:drawMutedWindowText(x + 0.250, totalRowY + 0.006, 0.011, self:getSelectedCategoryLabel())
    end
    self:drawWindowText(x + 0.630, totalRowY + 0.006, 0.012, self:formatMoneyDetailed(self:getHistoryFooterTotal(rows, summary, window.category)), true, RenderText ~= nil and RenderText.ALIGN_LEFT or nil)

    if #rows > visibleRows then
        local infoText = string.format(self:getText("hpOc_moreRows", "Einträge %s-%s von %s"), tostring(scrollOffset + 1), tostring(scrollOffset + rowsToDraw), tostring(#rows))
        self:drawMutedWindowText(x + 0.032, y + 0.030, 0.012, infoText)
    end

    self:drawMutedWindowText(x + 0.032, y + 0.010, 0.010, self:getText("hpOc_footer", "Klicke auf Reiter, Zeitraum und Pfeile. Die Daten stammen aus operatingCostsHistory.xml."))
end

function HP_OperatingCosts:getSelectedCategoryLabel()
    local selected = self.historyWindow ~= nil and self.historyWindow.category or "total"
    for _, category in ipairs(self:getHistoryCategories()) do
        if category.key == selected then
            return category.label
        end
    end
    return tostring(selected)
end

function HP_OperatingCosts:shortenText(text, maxLength)
    text = tostring(text or "")
    maxLength = tonumber(maxLength) or 40
    if string.len(text) <= maxLength then
        return text
    end
    return string.sub(text, 1, maxLength - 3) .. "..."
end

function HP_OperatingCosts:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    local window = self.historyWindow
    if window == nil or window.visible ~= true then
        return eventUsed
    end

    local numericButton = tonumber(button)
    if numericButton == 4 then
        self:scrollHistoryRows(-1)
        return true
    elseif numericButton == 5 then
        self:scrollHistoryRows(1)
        return true
    end

    if isDown ~= true then
        return true
    end

    for _, area in ipairs(window.clickAreas or {}) do
        if posX >= area.x and posX <= area.x + area.width and posY >= area.y and posY <= area.y + area.height then
            self:handleHistoryWindowClick(area)
            return true
        end
    end

    return true
end

function HP_OperatingCosts:handleHistoryWindowClick(area)
    if area == nil or self.historyWindow == nil then
        return
    end

    local id = area.id
    local data = area.data or {}

    if id == "close" then
        self:setHistoryWindowVisible(false)
    elseif id == "category" and data.category ~= nil then
        self.historyWindow.category = data.category
        self:resetHistoryScroll()
    elseif id == "periodMode" and data.periodMode ~= nil then
        self.historyWindow.periodMode = data.periodMode
        self:resetHistoryScroll()
    elseif id == "prevMonth" then
        self:shiftSelectedMonth(-1)
        self:resetHistoryScroll()
    elseif id == "nextMonth" then
        self:shiftSelectedMonth(1)
        self:resetHistoryScroll()
    elseif id == "prevYear" then
        self.historyWindow.selectedYear = (tonumber(self.historyWindow.selectedYear) or 1) - 1
        self:resetHistoryScroll()
    elseif id == "nextYear" then
        self.historyWindow.selectedYear = (tonumber(self.historyWindow.selectedYear) or 1) + 1
        self:resetHistoryScroll()
    elseif id == "scrollPageUp" then
        self:scrollHistoryRows(-1, self.historyWindow.maxRows or 10)
    elseif id == "scrollPageDown" then
        self:scrollHistoryRows(1, self.historyWindow.maxRows or 10)
    end
end

function HP_OperatingCosts:shiftSelectedMonth(delta)
    self.historyWindow = self.historyWindow or {}
    local year = tonumber(self.historyWindow.selectedYear) or 1
    local month = tonumber(self.historyWindow.selectedMonth) or 1
    month = month + (tonumber(delta) or 0)
    while month < 1 do
        month = month + 12
        year = year - 1
    end
    while month > 12 do
        month = month - 12
        year = year + 1
    end
    self.historyWindow.selectedYear = year
    self.historyWindow.selectedMonth = month
end

function HP_OperatingCosts:keyEvent(unicode, sym, modifier, isDown, eventUsed)
    if self.blockHistoryWindowKeyRelease ~= nil then
        if sym == self.blockHistoryWindowKeyRelease and isDown ~= true then
            self.blockHistoryWindowKeyRelease = nil
            return true
        end
    end

    local window = self.historyWindow
    if window == nil or window.visible ~= true then
        return eventUsed
    end

    if Input ~= nil and sym == Input.KEY_esc then
        if isDown == true then
            self.blockHistoryWindowKeyRelease = sym
            self:setHistoryWindowVisible(false)
        end
        return true
    end

    if isDown == true and Input ~= nil then
        if sym == Input.KEY_pageup then
            self:scrollHistoryRows(-1, window.maxRows or 10)
        elseif sym == Input.KEY_pagedown then
            self:scrollHistoryRows(1, window.maxRows or 10)
        elseif sym == Input.KEY_up then
            self:scrollHistoryRows(-1)
        elseif sym == Input.KEY_down then
            self:scrollHistoryRows(1)
        end
    end

    return true
end

function HP_OperatingCosts:update(dt)
    if self.historyWindow ~= nil and self.historyWindow.visible == true then
        self:keepHistoryWindowInputLockActive()
    end
end

function HP_OperatingCosts:loadHistoryFile()
    local path = self:getSavegameHistoryPath()
    if path == nil then
        return
    end

    if fileExists ~= nil and not fileExists(path) then
        return
    end

    if loadXMLFile == nil then
        return
    end

    local ok, result = pcall(function()
        local xmlId = loadXMLFile("hpOperatingCostsHistory", path)
        if xmlId == nil or xmlId == 0 then
            return false
        end

        local function readString(key, defaultValue)
            if getXMLString ~= nil then
                return getXMLString(xmlId, key) or defaultValue
            end
            return defaultValue
        end

        local function readFloat(key, defaultValue)
            if getXMLFloat ~= nil then
                return getXMLFloat(xmlId, key) or defaultValue
            end
            return tonumber(readString(key, nil)) or defaultValue
        end

        local function readInt(key, defaultValue)
            if getXMLInt ~= nil then
                return getXMLInt(xmlId, key) or defaultValue
            end
            return math.floor((tonumber(readString(key, nil)) or defaultValue or 0) + 0.5)
        end

        local records = {}
        local index = 0
        while hasXMLProperty ~= nil and hasXMLProperty(xmlId, string.format("operatingCostsHistory.billing(%d)", index)) do
            local key = string.format("operatingCostsHistory.billing(%d)", index)
            local record = {
                year = readInt(key .. "#year", 1),
                month = readInt(key .. "#month", 1),
                fsPeriod = readInt(key .. "#period", 1),
                farmId = readInt(key .. "#farmId", 0),
                vehicleInsurance = readFloat(key .. "#vehicleInsurance", 0),
                storedGoodsInsurance = readFloat(key .. "#storedGoodsInsurance", 0),
                upkeep = readFloat(key .. "#upkeep", 0),
                entries = {}
            }

            local entryIndex = 0
            while hasXMLProperty(xmlId, string.format("%s.entry(%d)", key, entryIndex)) do
                local entryKey = string.format("%s.entry(%d)", key, entryIndex)
                table.insert(record.entries, {
                    type = readString(entryKey .. "#type", ""),
                    category = readString(entryKey .. "#category", ""),
                    name = readString(entryKey .. "#name", "unknown"),
                    amount = readFloat(entryKey .. "#amount", 0),
                    baseValue = readFloat(entryKey .. "#baseValue", 0),
                    rate = readFloat(entryKey .. "#rate", 0),
                    moneyCategory = readString(entryKey .. "#moneyCategory", ""),
                    targetValue = readFloat(entryKey .. "#targetValue", 0),
                    existingValue = readFloat(entryKey .. "#existingValue", 0)
                })
                entryIndex = entryIndex + 1
            end

            table.insert(records, record)
            index = index + 1
        end

        if delete ~= nil then
            delete(xmlId)
        end

        self.historyRecords = records
        local beforeCleanup = #records
        local removedDuplicates = self:deduplicateHistoryRecords()
        self:diagnostic(string.format("operatingCostsHistory.xml gelesen: %s Buchungen", tostring(beforeCleanup)))

        if removedDuplicates > 0 then
            self:diagnostic(string.format(
                "Doppelte History-Buchungen gleicher Farm/Jahr/Monat bereinigt: %s entfernt, %s verbleiben.",
                tostring(removedDuplicates),
                tostring(#(self.historyRecords or {}))
            ))

            self.historyDirty = true
        end

        local removedFutureRecords = self:removeFutureHistoryRecords()
        if removedFutureRecords > 0 then
            self:diagnostic(string.format(
                "Zukunfts-Buchungen aus operatingCostsHistory.xml im Arbeitsspeicher ignoriert: %s entfernt.",
                tostring(removedFutureRecords)
            ))
            self.historyDirty = true
        end

        return true
    end)

    if not ok and Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[HP_OperatingCosts] Could not read operatingCostsHistory.xml: %s", tostring(result))
    end
end

addModEventListener(HP_OperatingCosts)
