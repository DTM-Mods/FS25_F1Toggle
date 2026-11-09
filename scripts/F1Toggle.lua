-- F1 Toggle
-- Choose which entries show in the F1 help box. Every entry is an action event registered with g_inputBinding,
-- and the box only shows events whose text is visible. This mod wraps the InputBinding functions that register
-- events and set their text visibility, and forces the text off for actions the player hid. The key still works.
-- The list of entries is a section in ESC > Settings > General; choices are saved in modSettings.

F1Toggle = {}
F1Toggle.MOD_NAME = g_currentModName
F1Toggle.SETTINGS_FILENAME = "F1Toggle.xml"
F1Toggle.XML_ROOT = "f1Toggle"
F1Toggle.SETTINGS_VERSION = 1

-- Action name -> true for the actions the player hid
F1Toggle.hiddenActions = {}
-- Action name -> {label = text shown in F1, wasShown = its text was visible this session, saved = listed in the settings file}
F1Toggle.actions = {}
-- Event id -> {actionName, target, wantsVisible = the visibility the owner of the event asked for}
F1Toggle.events = {}
-- Events registered since the last update; their owner may hide them right after registering
F1Toggle.newEvents = {}
-- Actions whose visibility changed while a menu was open, applied again once it closes
F1Toggle.pendingActions = {}

-- ---------------------------------------------------------------------------------------------
-- Input binding hooks
-- ---------------------------------------------------------------------------------------------

local function packResults(...)
    return select("#", ...), {...}
end

-- Called with the class table by some mods (AutoDrive), so the class functions are wrapped, not the instance.
-- Savegames re-source mod scripts, so the hooks are installed once and call the current F1Toggle table.
function F1Toggle.installInputHooks()
    if InputBinding == nil or InputBinding.f1tHooked then
        return
    end
    InputBinding.f1tHooked = true
    InputBinding.f1tSetActionEventTextVisibility = InputBinding.setActionEventTextVisibility

    InputBinding.registerActionEvent = Utils.overwrittenFunction(InputBinding.registerActionEvent,
        function(inputBinding, superFunc, actionName, target, ...)
            local count, results = packResults(superFunc(inputBinding, actionName, target, ...))
            local eventId = results[2]
            if eventId ~= nil and type(actionName) == "string" and F1Toggle ~= nil then
                F1Toggle:onActionEventRegistered(inputBinding, eventId, actionName, target)
            end
            return unpack(results, 1, count)
        end)

    InputBinding.setActionEventTextVisibility = Utils.overwrittenFunction(InputBinding.setActionEventTextVisibility,
        function(inputBinding, superFunc, eventId, isVisible, ...)
            local event = F1Toggle ~= nil and F1Toggle.events[eventId] or nil
            if event ~= nil then
                event.wantsVisible = isVisible
                if isVisible then
                    F1Toggle:getAction(event.actionName).wasShown = true
                end
                if F1Toggle.hiddenActions[event.actionName] then
                    isVisible = false
                end
            end
            return superFunc(inputBinding, eventId, isVisible, ...)
        end)

    InputBinding.setActionEventText = Utils.overwrittenFunction(InputBinding.setActionEventText,
        function(inputBinding, superFunc, eventId, text, ...)
            local event = F1Toggle ~= nil and F1Toggle.events[eventId] or nil
            if event ~= nil and type(text) == "string" and text ~= "" then
                F1Toggle:getAction(event.actionName).label = text
            end
            return superFunc(inputBinding, eventId, text, ...)
        end)

    InputBinding.removeActionEvent = Utils.overwrittenFunction(InputBinding.removeActionEvent,
        function(inputBinding, superFunc, eventId, ...)
            if F1Toggle ~= nil and eventId ~= nil then
                F1Toggle.events[eventId] = nil
                F1Toggle.newEvents[eventId] = nil
            end
            return superFunc(inputBinding, eventId, ...)
        end)

    InputBinding.removeActionEventsByTarget = Utils.overwrittenFunction(InputBinding.removeActionEventsByTarget,
        function(inputBinding, superFunc, target, ...)
            if F1Toggle ~= nil and target ~= nil then
                for eventId, event in pairs(F1Toggle.events) do
                    if event.target == target then
                        F1Toggle.events[eventId] = nil
                        F1Toggle.newEvents[eventId] = nil
                    end
                end
            end
            return superFunc(inputBinding, target, ...)
        end)
end

-- Sets the text visibility without going through the hook. Pcall: the event may be gone already.
function F1Toggle.setEventTextVisibility(eventId, isVisible)
    local setVisibility = InputBinding.f1tSetActionEventTextVisibility
    if setVisibility ~= nil and g_inputBinding ~= nil then
        pcall(setVisibility, g_inputBinding, eventId, isVisible)
    end
end

function F1Toggle:onActionEventRegistered(inputBinding, eventId, actionName, target)
    self.events[eventId] = {actionName = actionName, target = target, wantsVisible = true}
    self.newEvents[eventId] = true
    self:getAction(actionName)

    if self.hiddenActions[actionName] then
        F1Toggle.setEventTextVisibility(eventId, false)
    end
end

function F1Toggle:getAction(actionName)
    local action = self.actions[actionName]
    if action == nil then
        action = {wasShown = false, saved = false}
        self.actions[actionName] = action
    end
    return action
end

-- Applies the hidden state of an action to all its events
function F1Toggle:applyAction(actionName)
    local isHidden = self.hiddenActions[actionName] == true
    for eventId, event in pairs(self.events) do
        if event.actionName == actionName then
            F1Toggle.setEventTextVisibility(eventId, event.wantsVisible ~= false and not isHidden)
        end
    end
end

function F1Toggle:setActionHidden(actionName, isHidden)
    self.hiddenActions[actionName] = isHidden and true or nil
    self:applyAction(actionName)
    -- Events of the vehicle or player context may not be reachable while the menu is open
    self.pendingActions[actionName] = true
    self:saveSettings()
end

-- ---------------------------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------------------------

-- The name the game shows for an action whose text was never set by its owner
function F1Toggle.getInputActionDisplayName(actionName)
    if g_inputBinding == nil then
        return nil
    end
    local ok, inputAction = pcall(function()
        if type(g_inputBinding.getActionByName) == "function" then
            return g_inputBinding:getActionByName(actionName)
        end
        return g_inputBinding.nameActions ~= nil and g_inputBinding.nameActions[actionName] or nil
    end)
    if not ok or type(inputAction) ~= "table" then
        return nil
    end
    local name = inputAction.displayNamePositive or inputAction.displayName
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

function F1Toggle:getActionLabel(actionName)
    local action = self.actions[actionName]
    local label = (action ~= nil and action.label) or F1Toggle.getInputActionDisplayName(actionName) or actionName
    return (tostring(label):gsub("%s+", " "))
end

-- The actions listed in the settings: the ones seen in the F1 box this session and the hidden ones, by label
function F1Toggle:getListedActionNames()
    local names = {}
    for actionName, action in pairs(self.actions) do
        if action.wasShown or self.hiddenActions[actionName] then
            table.insert(names, actionName)
        end
    end
    for actionName in pairs(self.hiddenActions) do
        if self.actions[actionName] == nil then
            table.insert(names, actionName)
        end
    end

    local labels = {}
    for _, actionName in ipairs(names) do
        labels[actionName] = utf8ToLower(self:getActionLabel(actionName))
    end
    table.sort(names, function(a, b)
        if labels[a] ~= labels[b] then
            return labels[a] < labels[b]
        end
        return a < b
    end)
    return names
end

-- ---------------------------------------------------------------------------------------------
-- Settings page: one Shown/Hidden row per action at the end of ESC > Settings > General
-- ---------------------------------------------------------------------------------------------

function F1Toggle.installSettingsHooks()
    if InGameMenuSettingsFrame == nil or InGameMenuSettingsFrame.f1tHooked
        or type(InGameMenuSettingsFrame.onFrameOpen) ~= "function" then
        return
    end
    InGameMenuSettingsFrame.f1tHooked = true

    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen,
        function(settingsFrame)
            if F1Toggle ~= nil then
                F1Toggle:buildSettingsRows(settingsFrame)
            end
        end)
end

local function updateFocusIds(element)
    if element == nil then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements or {}) do
        updateFocusIds(child)
    end
end

-- A binary option row of the general settings: a container whose elements[1] is the option and elements[2] the title
function F1Toggle.getSettingsRowTemplate(settingsFrame)
    local option = settingsFrame.checkActiveSuspensionCamera or settingsFrame.checkCameraCollision
    if option ~= nil and option.parent ~= nil then
        return option.parent
    end
    return settingsFrame.checkWoodHarvesterAutoCutBox
end

function F1Toggle.getSectionHeaderTemplate(layout)
    for _, element in ipairs(layout.elements) do
        if element.name == "sectionHeader" and not element.f1tRow then
            return element
        end
    end
    return nil
end

function F1Toggle.removeSettingsRows(layout)
    for i = #layout.elements, 1, -1 do
        local element = layout.elements[i]
        if element.f1tRow then
            element:delete()
        end
    end
end

function F1Toggle:buildSettingsRows(settingsFrame)
    local layout = settingsFrame.generalSettingsLayout or settingsFrame.gameSettingsLayout
    local template = F1Toggle.getSettingsRowTemplate(settingsFrame)
    if layout == nil or template == nil then
        if not self.warnedMissingSettings then
            Logging.warning("[%s] Could not find the general settings layout or a toggle row to copy; the settings list is unavailable. Use the console commands or edit modSettings/%s/%s.",
                self.MOD_NAME, self.MOD_NAME, self.SETTINGS_FILENAME)
            self.warnedMissingSettings = true
        end
        return
    end

    -- Rebuilt on every open: the list grows as new entries show up
    F1Toggle.removeSettingsRows(layout)

    local actionNames = self:getListedActionNames()
    if #actionNames == 0 then
        layout:invalidateLayout()
        return
    end

    local headerTemplate = F1Toggle.getSectionHeaderTemplate(layout)
    if headerTemplate ~= nil then
        local header = headerTemplate:clone(layout)
        header.f1tRow = true
        header:setText(g_i18n:getText("f1t_section"))
        updateFocusIds(header)
    end

    for _, actionName in ipairs(actionNames) do
        self:addSettingsRow(settingsFrame, layout, template, actionName)
    end

    layout:invalidateLayout()
end

function F1Toggle:addSettingsRow(settingsFrame, layout, template, actionName)
    local row = template:clone(layout)
    row.f1tRow = true
    updateFocusIds(row)

    local option = row.elements[1]
    local title = row.elements[2]
    if option == nil or title == nil then
        row:delete()
        return
    end

    title:setText(self:getActionLabel(actionName))
    local tooltip = option.elements ~= nil and option.elements[1] or nil
    if tooltip ~= nil and type(tooltip.setText) == "function" then
        tooltip:setText(string.format(g_i18n:getText("f1t_tooltip"), actionName))
    end

    -- The focus manager ignores input from elements whose target name differs from the current GUI
    local rowTarget = {name = settingsFrame.name}
    function rowTarget.onClickRow(_, state, element)
        local isShown = state == BinaryOptionElement.STATE_RIGHT
        if element ~= nil and type(element.getIsChecked) == "function" then
            isShown = element:getIsChecked()
        end
        F1Toggle:setActionHidden(actionName, not isShown)
    end

    option.target = rowTarget
    option:setCallback("onClickCallback", "onClickRow")
    option:setDisabled(false)
    option:setTexts({g_i18n:getText("f1t_hidden"), g_i18n:getText("f1t_shown")})
    option:setIsChecked(not self.hiddenActions[actionName], true, false)

    if type(row.reloadFocusHandling) == "function" then
        row:reloadFocusHandling(true)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Settings file: modSettings/FS25_F1Toggle/F1Toggle.xml, the same for all savegames
-- ---------------------------------------------------------------------------------------------

function F1Toggle:getSettingsDirectory()
    return string.format("%smodSettings/%s/", getUserProfileAppPath(), self.MOD_NAME)
end

function F1Toggle:loadSettings()
    local path = self:getSettingsDirectory() .. self.SETTINGS_FILENAME
    if not fileExists(path) then
        return
    end

    local xmlFile = loadXMLFile("f1Toggle_settings", path)
    if xmlFile == nil or xmlFile == 0 then
        return
    end

    local i = 0
    while true do
        local key = string.format("%s.action(%d)", self.XML_ROOT, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local actionName = getXMLString(xmlFile, key .. "#name")
        if actionName ~= nil and actionName ~= "" then
            local action = self:getAction(actionName)
            action.saved = true
            action.savedLabel = getXMLString(xmlFile, key .. "#text")
            if getXMLBool(xmlFile, key .. "#hidden") then
                self.hiddenActions[actionName] = true
            end
        end
        i = i + 1
    end
    delete(xmlFile)
end

-- Writes every action seen so far, so the file can be edited by hand too
function F1Toggle:saveSettings()
    local directory = self:getSettingsDirectory()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(directory)

    local xmlFile = createXMLFile("f1Toggle_settings", directory .. self.SETTINGS_FILENAME, self.XML_ROOT)
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("[%s] Could not save %s", self.MOD_NAME, directory .. self.SETTINGS_FILENAME)
        return
    end

    local names = {}
    for actionName, action in pairs(self.actions) do
        if action.saved or action.wasShown or self.hiddenActions[actionName] then
            table.insert(names, actionName)
        end
    end
    for actionName in pairs(self.hiddenActions) do
        if self.actions[actionName] == nil then
            table.insert(names, actionName)
        end
    end
    table.sort(names)

    setXMLInt(xmlFile, self.XML_ROOT .. "#version", self.SETTINGS_VERSION)
    for i, actionName in ipairs(names) do
        local key = string.format("%s.action(%d)", self.XML_ROOT, i - 1)
        local action = self.actions[actionName]
        local label = (action ~= nil and (action.label or action.savedLabel)) or self:getActionLabel(actionName)
        setXMLString(xmlFile, key .. "#name", actionName)
        setXMLString(xmlFile, key .. "#text", (tostring(label):gsub("%s+", " ")))
        setXMLBool(xmlFile, key .. "#hidden", self.hiddenActions[actionName] == true)
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

-- ---------------------------------------------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------------------------------------------

function F1Toggle:consoleList()
    local lines = {}
    for _, actionName in ipairs(self:getListedActionNames()) do
        table.insert(lines, string.format("%-7s %-40s %s", self.hiddenActions[actionName] and "hidden" or "shown",
            self:getActionLabel(actionName), actionName))
    end
    if #lines == 0 then
        return "No F1 help entries seen yet"
    end
    return table.concat(lines, "\n")
end

function F1Toggle:consoleShowAll()
    local actionNames = {}
    for actionName in pairs(self.hiddenActions) do
        table.insert(actionNames, actionName)
    end
    self.hiddenActions = {}
    for _, actionName in ipairs(actionNames) do
        self:applyAction(actionName)
    end
    self:saveSettings()
    return string.format("Showing all F1 help entries again (%d were hidden)", #actionNames)
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

function F1Toggle:loadMap()
    F1Toggle.installSettingsHooks()
    addConsoleCommand("f1tList", "Lists the F1 help entries and whether they are hidden", "consoleList", self)
    addConsoleCommand("f1tShowAll", "Shows all hidden F1 help entries again", "consoleShowAll", self)
end

function F1Toggle:deleteMap()
    self:saveSettings()
    removeConsoleCommand("f1tList")
    removeConsoleCommand("f1tShowAll")
    self.events = {}
    self.newEvents = {}
    self.pendingActions = {}
end

function F1Toggle:update(dt)
    -- An entry counts as seen when its text is still visible a frame after it was registered
    if next(self.newEvents) ~= nil then
        for eventId in pairs(self.newEvents) do
            local event = self.events[eventId]
            if event ~= nil and event.wantsVisible ~= false then
                self:getAction(event.actionName).wasShown = true
            end
        end
        self.newEvents = {}
    end

    if next(self.pendingActions) ~= nil and not (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        for actionName in pairs(self.pendingActions) do
            self:applyAction(actionName)
        end
        self.pendingActions = {}
    end
end

F1Toggle.installInputHooks()
F1Toggle.installSettingsHooks()
F1Toggle:loadSettings()

addModEventListener(F1Toggle)
