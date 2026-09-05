-- SGC-CC
-- Stargate Command ComputerCraft control system for JSG
-- Target: Minecraft 1.20.1 Forge + Just Stargate Mod + CC:Tweaked
--
-- Security-critical design rules:
--   * pcall success is NOT JSG operation success.
--   * Iris toggling has exactly one choke point.
--   * The iris toggle lock is acquired before any yielding call.
--   * Unknown/transitional iris states are never blindly toggled.
--   * Security/event handling runs independently of the UI.

local release_iris_lock

local CONFIG = {
    data_file = "sgc_data",
    event_log_file = "sgc_events",
    max_log_entries = 200,
    refresh_interval = 0.5,
    iris_lock_timeout = 15,
    auto_iris = true,

    -- Disk alarms. These values are the measured burst lengths and are used
    -- to decide when the next replay may begin.
    audio = {
        incoming_drive = "drive_3",
        outgoing_drive = "drive_2",
        incoming_repeat_seconds = 1.5,
        outgoing_repeat_seconds = 1.5,
        poll_interval = 0.05,
    },
}

local state = {
    running = true,

    gate = nil,
    gate_name = nil,
    connected = false,
    gate_merged = false,
    gate_status = nil,
    gate_initiating = nil,
    gate_address = nil,
    dialed_address = nil,
    energy = 0,
    max_energy = 0,

    iris_state = nil,
    iris_type = nil,
    iris_durability_display = nil,
    iris_durability = nil,
    iris_max_durability = nil,
    iris_toggle_pending = false,
    iris_pending_token = nil,
    iris_pending_direction = nil,
    iris_pending_since = nil,

    incoming = false,
    incoming_address = nil,
    alert = nil,

    dialing = false,
    dial_chevrons = 0,
    dial_target_count = 0,
    dial_last_symbol = nil,
    ring_spinning = false,
    ring_direction = nil,
    ring_speed = nil,

    audio_alarm = nil,
    audio_alarm_since = nil,
    audio_last_drive = nil,
    audio_error_reported = {},

    events = {},
    addresses = {},
    selected_address = 1,
    mode = "AUTO",
    last_event = "System initialized",
}

-----------------------------------------------------------------------
-- Generic helpers
-----------------------------------------------------------------------

local function safe_call(fn, ...)
    if not fn then
        return false, nil, "missing_method", "Method is unavailable"
    end

    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        return false, nil, "lua_error", tostring(a)
    end

    return true, a, b, c, d
end

local function jsg_result(ok, success, code, message)
    if not ok then
        return false, "JSG/CC exception: " .. tostring(message)
    end

    if success ~= true then
        return false, tostring(code or "jsg_failure") .. ": " .. tostring(message or "JSG rejected the operation")
    end

    return true, message
end

local function now()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function address_to_string(address)
    if type(address) ~= "table" then
        return "UNKNOWN"
    end

    if #address == 0 then
        return "NONE"
    end

    local parts = {}
    for i, symbol in ipairs(address) do
        parts[i] = tostring(symbol)
    end

    return table.concat(parts, " - ")
end

local function same_address(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end

    for i = 1, #a do
        if tostring(a[i]):lower() ~= tostring(b[i]):lower() then
            return false
        end
    end

    return true
end

local function load_table(path, fallback)
    if not fs.exists(path) then
        return fallback
    end

    local handle = fs.open(path, "r")
    if not handle then
        return fallback
    end

    local raw = handle.readAll()
    handle.close()

    if not raw or raw == "" then
        return fallback
    end

    local fn = load(raw, path, "t", {})
    if not fn then
        return fallback
    end

    local ok, result = pcall(fn)
    if ok and type(result) == "table" then
        return result
    end

    return fallback
end

local function save_table(path, data)
    local handle = fs.open(path, "w")
    if not handle then
        return false
    end

    handle.write(textutils.serialize(data))
    handle.close()
    return true
end

local function save_data()
    save_table(CONFIG.data_file, {
        addresses = state.addresses,
        mode = state.mode,
    })
end

local function load_data()
    local data = load_table(CONFIG.data_file, {})

    if type(data.addresses) == "table" then
        state.addresses = data.addresses
    end

    if data.mode == "AUTO" or data.mode == "MANUAL" then
        state.mode = data.mode
    end

    state.selected_address = math.max(1, math.min(state.selected_address, math.max(1, #state.addresses)))
end

local function load_events()
    local events = load_table(CONFIG.event_log_file, {})
    state.events = type(events) == "table" and events or {}
end

local function save_events()
    while #state.events > CONFIG.max_log_entries do
        table.remove(state.events, 1)
    end
    save_table(CONFIG.event_log_file, state.events)
end

local function log_event(message)
    message = tostring(message)
    table.insert(state.events, now() .. "  " .. message)
    while #state.events > CONFIG.max_log_entries do
        table.remove(state.events, 1)
    end
    state.last_event = message
    save_events()
end

-----------------------------------------------------------------------
-- Gate discovery / state
-----------------------------------------------------------------------

local function clear_gate_state()
    state.connected = false
    state.gate_merged = false
    state.gate_status = nil
    state.gate_initiating = nil
    state.gate_address = nil
    state.dialed_address = nil
    state.energy = 0
    state.max_energy = 0
    state.iris_state = nil
    state.iris_type = nil
    state.iris_durability_display = nil
    state.iris_durability = nil
    state.iris_max_durability = nil
end

local function find_gate()
    local gate = peripheral.find("stargate")
    if gate then
        return gate, "stargate"
    end

    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        if wrapped and wrapped.getGateStatus and wrapped.getEnergyStored and wrapped.dialAddress then
            return wrapped, name
        end
    end

    return nil, nil
end

local function ensure_gate()
    local old_gate = state.gate

    if state.gate then
        local ok = pcall(state.gate.getGateStatus)
        if ok then
            state.connected = true
            return true
        end
    end

    local gate, name = find_gate()
    if not gate then
        if old_gate ~= nil then
            release_iris_lock()
        end
        state.gate = nil
        state.gate_name = nil
        clear_gate_state()
        return false
    end

    if old_gate ~= nil and gate ~= old_gate then
        release_iris_lock()
        log_event("Gate peripheral changed; invalidated pending iris toggle")
    end

    local was_connected = state.connected
    state.gate = gate
    state.gate_name = name
    state.connected = true

    if not was_connected then
        log_event("Gate connection established: " .. tostring(name))
    end

    return true
end

local function refresh_gate()
    if not state.gate then
        clear_gate_state()
        return false
    end

    local ok, merged, status, initiating = safe_call(state.gate.getGateStatus)
    if not ok then
        state.gate = nil
        state.gate_name = nil
        clear_gate_state()
        return false
    end

    state.connected = true
    state.gate_merged = merged == true
    state.gate_status = status
    state.gate_initiating = initiating

    ok, state.energy = safe_call(state.gate.getEnergyStored)
    if not ok then
        state.energy = 0
    end

    ok, state.max_energy = safe_call(state.gate.getMaxEnergyStored)
    if not ok then
        state.max_energy = 0
    end

    ok, state.dialed_address = safe_call(state.gate.getDialedAddress)
    if not ok then
        state.dialed_address = nil
    end

    ok, state.gate_address = safe_call(state.gate.getStargateAddress)
    if not ok then
        state.gate_address = nil
    end

    if state.gate.getIrisState then
        ok, state.iris_state = safe_call(state.gate.getIrisState)
        if not ok then
            state.iris_state = nil
        end
    end

    if state.gate.getIrisType then
        ok, state.iris_type = safe_call(state.gate.getIrisType)
        if not ok then
            state.iris_type = nil
        end
    end

    if state.gate.getIrisDurability then
        local durability_ok, display, current, maximum = safe_call(state.gate.getIrisDurability)
        if durability_ok then
            state.iris_durability_display = display
            state.iris_durability = current
            state.iris_max_durability = maximum
        else
            state.iris_durability_display = nil
            state.iris_durability = nil
            state.iris_max_durability = nil
        end
    end

    return true
end

-----------------------------------------------------------------------
-- Iris state / single choke point
-----------------------------------------------------------------------

local function iris_bucket()
    local value = tostring(state.iris_state or ""):lower()

    if value == "opened" then
        return "open"
    elseif value == "closed" then
        return "closed"
    elseif value == "opening" or value == "closing" then
        return "transition"
    end

    return "unknown"
end

release_iris_lock = function()
    state.iris_toggle_pending = false
    state.iris_pending_token = nil
    state.iris_pending_direction = nil
    state.iris_pending_since = nil
end

local function maybe_release_iris_lock()
    if not state.iris_toggle_pending then
        return
    end

    local bucket = iris_bucket()
    if state.iris_pending_direction == "CLOSE" and bucket == "closed" then
        release_iris_lock()
    elseif state.iris_pending_direction == "OPEN" and bucket == "open" then
        release_iris_lock()
    end
end

local function toggle_iris(direction, reason)
    direction = tostring(direction):upper()
    if direction ~= "OPEN" and direction ~= "CLOSE" then
        return false
    end

    if not state.gate or not state.gate.toggleIris then
        log_event("IRIS " .. direction .. " FAILED: toggleIris() unavailable")
        return false
    end

    if state.iris_toggle_pending then
        log_event("IRIS " .. direction .. " REFUSED: toggle already in progress")
        return false
    end

    local token = {}
    state.iris_toggle_pending = true
    state.iris_pending_token = token
    state.iris_pending_direction = direction
    state.iris_pending_since = os.epoch("utc")

    refresh_gate()

    if not state.connected or not state.iris_state then
        if state.iris_pending_token == token then
            release_iris_lock()
            log_event("IRIS " .. direction .. " REFUSED: iris state unknown")
        end
        return false
    end

    local bucket = iris_bucket()

    if bucket == "unknown" then
        if state.iris_pending_token == token then
            release_iris_lock()
            log_event("IRIS " .. direction .. " REFUSED: iris state unknown/error")
        end
        return false
    end

    if bucket == "transition" then
        if state.iris_pending_token == token then
            release_iris_lock()
            log_event("IRIS " .. direction .. " REFUSED: iris is already transitioning")
        end
        return false
    end

    if direction == "CLOSE" and bucket == "closed" then
        if state.iris_pending_token == token then
            release_iris_lock()
        end
        return true
    end

    if direction == "OPEN" and bucket == "open" then
        if state.iris_pending_token == token then
            release_iris_lock()
        end
        return true
    end

    if (direction == "CLOSE" and bucket ~= "open") or (direction == "OPEN" and bucket ~= "closed") then
        if state.iris_pending_token == token then
            release_iris_lock()
            log_event("IRIS " .. direction .. " REFUSED: state changed before command")
        end
        return false
    end

    local ok, success, code, message = safe_call(state.gate.toggleIris)

    if state.iris_pending_token ~= token then
        log_event("IRIS " .. direction .. " STALE COMPLETION IGNORED")
        return false
    end

    local worked, detail = jsg_result(ok, success, code, message)

    if not worked then
        release_iris_lock()
        log_event("IRIS " .. direction .. " FAILED: " .. detail)
        return false
    end

    state.iris_state = direction == "CLOSE" and "CLOSING" or "OPENING"
    log_event("IRIS " .. direction .. " ACCEPTED: " .. tostring(reason or "operator"))
    return true
end

local function close_iris(reason)
    return toggle_iris("CLOSE", reason)
end

local function open_iris(reason)
    return toggle_iris("OPEN", reason)
end

-----------------------------------------------------------------------
-- Address handling
-----------------------------------------------------------------------

local function get_symbol_map()
    if not state.gate or not state.gate.getSymbolsMap then
        return nil
    end

    local ok, symbols = safe_call(state.gate.getSymbolsMap)
    if ok and type(symbols) == "table" then
        return symbols
    end

    return nil
end

local function canonical_symbol(symbol, symbol_map)
    local needle = tostring(symbol):lower()
    for _, valid in ipairs(symbol_map or {}) do
        if tostring(valid):lower() == needle then
            return tostring(valid)
        end
    end

    return nil
end

local function validate_address(symbols)
    if type(symbols) ~= "table" or #symbols < 7 or #symbols > 9 then
        return false, "Address must contain 7-9 symbols"
    end

    local symbol_map = get_symbol_map()
    if not symbol_map then
        return false, "Unable to read the JSG symbol map"
    end

    local seen = {}
    local normalized = {}

    for i, symbol in ipairs(symbols) do
        local canonical = canonical_symbol(symbol, symbol_map)
        if not canonical then
            return false, "Invalid symbol at position " .. tostring(i) .. ": " .. tostring(symbol)
        end

        local key = canonical:lower()
        if seen[key] then
            return false, "Duplicate symbol: " .. canonical
        end

        seen[key] = true
        normalized[i] = canonical
    end

    return true, normalized
end

-- Interactive selector used by Address Book. It always starts from a fresh
-- getSymbolsMap() result and returns canonical symbol strings in selection
-- order. The caller runs validate_address() again before storing them.
local function glyph_picker(initial_symbols)
    local symbols = get_symbol_map()
    if not symbols or #symbols == 0 then
        log_event("GLYPH PICKER FAILED: unable to read the JSG symbol map")
        return nil
    end

    local selected = {}
    local order = {}
    local selected_count = 0

    for _, symbol in ipairs(initial_symbols or {}) do
        local canonical = canonical_symbol(symbol, symbols)
        local key = canonical and canonical:lower() or nil
        if canonical and not selected[key] then
            selected[key] = true
            table.insert(order, canonical)
            selected_count = selected_count + 1
        end
    end

    local cursor = 1

    while true do
        local width, height = term.getSize()
        local columns = width >= 60 and 3 or 2
        local column_width = math.max(1, math.floor(width / columns))
        local rows = math.max(1, height - 8)
        local per_page = rows * columns
        local pages = math.max(1, math.ceil(#symbols / per_page))
        local page = math.floor((cursor - 1) / per_page) + 1
        local page_first = (page - 1) * per_page + 1

        term.clear()
        header("SELECT GLYPHS")
        term.setCursorPos(2, 5)
        term.write(string.format("SELECTED: %d / 9    PAGE %d / %d", selected_count, page, pages))

        for local_index = 0, per_page - 1 do
            local index = page_first + local_index
            if index > #symbols then
                break
            end

            local column = math.floor(local_index / rows)
            local row = local_index % rows
            local x = 2 + column * column_width
            local y = 6 + row
            local symbol = symbols[index]
            local key_name = tostring(symbol):lower()
            local marker = selected[key_name] and "*" or " "
            local cursor_marker = cursor == index and ">" or " "
            local text = string.format("%s%s [%02d] %s", cursor_marker, marker, index, tostring(symbol))

            term.setCursorPos(x, y)
            term.clearLine()
            term.write(text:sub(1, math.max(1, column_width - 2)))
        end

        term.setCursorPos(2, height - 2)
        term.clearLine()
        term.write("ARROWS MOVE   SPACE SELECT   ENTER ACCEPT   B CANCEL")
        term.setCursorPos(2, height - 1)
        term.clearLine()
        term.write("7-9 GLYPHS REQUIRED   * = SELECTED")

        local _, key = os.pullEvent("key")

        if key == keys.up then
            cursor = cursor == 1 and #symbols or cursor - 1

        elseif key == keys.down then
            cursor = cursor == #symbols and 1 or cursor + 1

        elseif key == keys.left then
            local target = cursor - rows
            if target >= 1 then
                cursor = target
            end

        elseif key == keys.right then
            local target = cursor + rows
            if target <= #symbols then
                cursor = target
            end

        elseif key == keys.space then
            local symbol = symbols[cursor]
            local key_name = tostring(symbol):lower()

            if selected[key_name] then
                selected[key_name] = nil
                selected_count = selected_count - 1
                for i, value in ipairs(order) do
                    if tostring(value):lower() == key_name then
                        table.remove(order, i)
                        break
                    end
                end
            elseif selected_count < 9 then
                selected[key_name] = true
                selected_count = selected_count + 1
                table.insert(order, tostring(symbol))
            end

        elseif key == keys.enter then
            if selected_count < 7 then
                log_event("GLYPH PICKER: " .. tostring(selected_count) .. " selected; 7 minimum required")
            else
                return order
            end

        elseif key == keys.b then
            return nil
        end
    end
end

local function add_address()
    term.clear()
    print("=== ADD ADDRESS ===")
    print("")

    write("Name: ")
    local name = trim(read())
    if name == "" then
        log_event("ADDRESS ADD CANCELLED: empty name")
        return
    end

    local symbols = glyph_picker()
    if not symbols then
        log_event("ADDRESS ADD CANCELLED")
        return
    end

    local valid, normalized_or_error = validate_address(symbols)
    if not valid then
        log_event("ADDRESS ADD FAILED: " .. tostring(normalized_or_error))
        return
    end

    for _, entry in ipairs(state.addresses) do
        if same_address(entry.symbols, normalized_or_error) then
            log_event("ADDRESS ADD FAILED: duplicate address")
            return
        end
    end

    table.insert(state.addresses, {
        name = name,
        symbols = normalized_or_error,
    })
    state.selected_address = #state.addresses
    save_data()
    log_event("ADDRESS ADDED: " .. name)
end

local function edit_address(index)
    local entry = state.addresses[index]
    if not entry then
        return
    end

    term.clear()
    print("=== EDIT ADDRESS ===")
    print("Current name: " .. tostring(entry.name))
    print("Current symbols: " .. address_to_string(entry.symbols))
    print("")

    write("New name (blank = keep): ")
    local name = trim(read())
    if name ~= "" then
        entry.name = name
    end

    write("Edit symbols? (Y/N): ")
    local choice = trim(read()):upper()
    if choice == "Y" then
        local symbols = glyph_picker(entry.symbols)
        if not symbols then
            log_event("ADDRESS EDIT CANCELLED")
            return
        end

        local valid, normalized_or_error = validate_address(symbols)
        if not valid then
            log_event("ADDRESS EDIT FAILED: " .. tostring(normalized_or_error))
            return
        end

        entry.symbols = normalized_or_error
    end

    save_data()
    log_event("ADDRESS EDITED: " .. tostring(entry.name))
end

local function remove_address(index)
    local entry = state.addresses[index]
    if not entry then
        return
    end

    term.clear()
    print("Remove address: " .. tostring(entry.name))
    write("Type YES to confirm: ")

    if trim(read()) == "YES" then
        table.remove(state.addresses, index)
        state.selected_address = math.min(state.selected_address, math.max(1, #state.addresses))
        save_data()
        log_event("ADDRESS REMOVED: " .. tostring(entry.name))
    else
        log_event("ADDRESS REMOVE CANCELLED")
    end
end

-----------------------------------------------------------------------
-- Audio manager
-----------------------------------------------------------------------

local function audio_drive_for_alarm(kind)
    if kind == "incoming" then
        return CONFIG.audio.incoming_drive
    elseif kind == "outgoing" then
        return CONFIG.audio.outgoing_drive
    end

    return nil
end

local function audio_repeat_seconds(kind)
    if kind == "incoming" then
        return CONFIG.audio.incoming_repeat_seconds
    elseif kind == "outgoing" then
        return CONFIG.audio.outgoing_repeat_seconds
    end

    return nil
end

local function stop_alarm_audio()
    for _, drive in ipairs({ CONFIG.audio.incoming_drive, CONFIG.audio.outgoing_drive }) do
        pcall(disk.stopAudio, drive)
    end

    state.audio_alarm = nil
    state.audio_alarm_since = nil
    state.audio_last_drive = nil
end

local function set_alarm_audio(kind, reason)
    if kind ~= "incoming" and kind ~= "outgoing" then
        stop_alarm_audio()
        return
    end

    local drive = audio_drive_for_alarm(kind)
    if not drive then
        return
    end

    if state.audio_alarm == kind and state.audio_last_drive == drive then
        return
    end

    for _, other in ipairs({ CONFIG.audio.incoming_drive, CONFIG.audio.outgoing_drive }) do
        if other ~= drive then
            pcall(disk.stopAudio, other)
        end
    end

    state.audio_alarm = kind
    state.audio_alarm_since = nil
    state.audio_last_drive = drive
    log_event("AUDIO ALARM: " .. kind:upper() .. " / " .. tostring(reason or "event"))
end

local function audio_play_once(kind)
    local drive = audio_drive_for_alarm(kind)
    if not drive then
        return false
    end

    local ok_has, has_audio = pcall(disk.hasAudio, drive)
    if not ok_has or has_audio ~= true then
        local message = "AUDIO " .. kind:upper() .. " FAILED: " .. tostring(drive) .. " has no music disc"
        if not state.audio_error_reported[drive] then
            state.audio_error_reported[drive] = true
            log_event(message)
        end
        return false
    end

    local ok = pcall(disk.playAudio, drive)
    if not ok then
        local message = "AUDIO " .. kind:upper() .. " FAILED: unable to play " .. tostring(drive)
        if not state.audio_error_reported[drive] then
            state.audio_error_reported[drive] = true
            log_event(message)
        end
        return false
    end

    state.audio_error_reported[drive] = nil
    state.audio_alarm_since = os.epoch("utc")
    return true
end

local function audio_loop()
    while state.running do
        local kind = state.audio_alarm
        if kind then
            local repeat_seconds = audio_repeat_seconds(kind)
            if repeat_seconds then
                if not state.audio_alarm_since then
                    audio_play_once(kind)
                elseif (os.epoch("utc") - state.audio_alarm_since) >= repeat_seconds * 1000 then
                    -- Do not restart unless the requested alarm is still active.
                    if state.audio_alarm == kind then
                        audio_play_once(kind)
                    end
                end
            end
        else
            state.audio_alarm_since = nil
        end

        sleep(CONFIG.audio.poll_interval)
    end

    stop_alarm_audio()
end

-----------------------------------------------------------------------
-- Dialing
-----------------------------------------------------------------------

local function dial_saved(index)
    local entry = state.addresses[index]
    if not entry then
        log_event("DIAL FAILED: no address selected")
        return
    end

    if not ensure_gate() then
        log_event("DIAL FAILED: gate unavailable")
        return
    end

    refresh_gate()

    if not state.gate or not state.gate.dialAddress then
        log_event("DIAL FAILED: dialAddress() unavailable")
        return
    end

    local valid, symbols_or_error = validate_address(entry.symbols)
    if not valid then
        log_event("DIAL FAILED: " .. tostring(symbols_or_error))
        return
    end

    local symbols = symbols_or_error

    if type(state.dialed_address) == "table" and #state.dialed_address > 0 then
        log_event("DIAL FAILED: gate already has a dialed address")
        return
    end

    local energy_ok, energy_success, energy_code, energy_map = safe_call(
        state.gate.getEnergyRequiredToDial,
        symbols
    )

    if not energy_ok then
        log_event("DIAL PREFLIGHT FAILED: " .. tostring(energy_map))
        return
    end

    if energy_success ~= true then
        log_event("DIAL PREFLIGHT FAILED: " .. tostring(energy_code or "unknown") .. ": " .. tostring(energy_map or "JSG rejected address"))
        return
    end

    if type(energy_map) ~= "table" then
        log_event("DIAL PREFLIGHT FAILED: malformed energy response")
        return
    end

    if energy_map.canOpen ~= true then
        log_event("DIAL PREFLIGHT FAILED: insufficient energy")
        return
    end

    local ok, success, code, message = safe_call(state.gate.dialAddress, symbols)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        log_event("DIAL FAILED: " .. detail)
        return
    end

    state.dialing = true
    state.dial_chevrons = 0
    state.dial_target_count = #symbols
    state.dial_last_symbol = nil
    state.incoming = false
    state.incoming_address = nil
    state.alert = nil
    set_alarm_audio("outgoing", "outgoing dial accepted")

    log_event("DIAL ACCEPTED: " .. tostring(entry.name) .. " [" .. address_to_string(symbols) .. "]")
end

-----------------------------------------------------------------------
-- JSG event processing
-----------------------------------------------------------------------

local function handle_jsg_event(event, ...)
    local args = {...}

    if event == "stargate_wormhole_incoming" then
        local address_size = args[1]
        state.incoming = true
        state.incoming_address = "INCOMING DIAL (" .. tostring(address_size or "?") .. " SYMBOLS)"
        state.alert = "!!! INCOMING WORMHOLE !!!"
        set_alarm_audio("incoming", "incoming wormhole")
        log_event("INCOMING WORMHOLE DETECTED: " .. tostring(address_size or "unknown") .. " symbols")

        if CONFIG.auto_iris and state.mode == "AUTO" then
            close_iris("incoming wormhole")
        end

    elseif event == "stargate_spin_start" then
        state.ring_spinning = true
        state.ring_direction = args[1]
        state.ring_speed = args[2]
        log_event("RING SPIN START: " .. tostring(args[1] or "?") .. " @ " .. tostring(args[2] or "?"))

    elseif event == "stargate_spin_stop" then
        state.ring_spinning = false
        log_event("RING SPIN STOP: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_chevron_engaged" then
        local source, symbol, chevron, address_size = args[1], args[2], args[3], args[4]
        state.dial_chevrons = tonumber(address_size) or state.dial_chevrons
        state.dial_target_count = math.max(state.dial_target_count, state.dial_chevrons)
        state.dial_last_symbol = symbol

        if source == "INCOMING_WORMHOLE" then
            state.incoming = true
            state.alert = "!!! INCOMING WORMHOLE !!!"
            set_alarm_audio("incoming", "incoming chevron activity")
        end

        log_event("CHEVRON " .. tostring(chevron or "?") .. " ENGAGED: " .. tostring(symbol or "?") .. " [" .. tostring(source or "?") .. "]")

    elseif event == "stargate_chevron_open" then
        log_event("CHEVRON OPEN: " .. tostring(args[1] or "?"))

    elseif event == "stargate_chevron_lit" then
        log_event("CHEVRON LIT: " .. tostring(args[1] or "?"))

    elseif event == "stargate_chevron_dim" then
        log_event("CHEVRON DIM: " .. tostring(args[1] or "?"))

    elseif event == "stargate_chevron_close" then
        log_event("CHEVRON CLOSE: " .. tostring(args[1] or "?"))

    elseif event == "stargate_attempt_open_failed" then
        state.dialing = false
        if state.audio_alarm == "outgoing" then
            stop_alarm_audio()
        end
        log_event("GATE OPEN FAILED: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_attempt_close_failed" then
        log_event("GATE CLOSE FAILED: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_wormhole_open_fully" then
        local address, initiating = args[1], args[2]
        state.dialing = false
        state.dialed_address = address
        state.gate_initiating = initiating

        if initiating == false then
            state.incoming = true
            state.incoming_address = address_to_string(address)
            set_alarm_audio("incoming", "incoming wormhole open")
        else
            state.incoming = false
            state.alert = nil
            stop_alarm_audio()
        end

        log_event((initiating == false and "INCOMING" or "OUTGOING") .. " WORMHOLE OPEN: " .. address_to_string(address))

    elseif event == "stargate_wormhole_close_fully" then
        local address, reason, initiating = args[1], args[2], args[3]
        state.dialing = false
        state.ring_spinning = false
        state.dialed_address = nil
        state.incoming = false
        state.incoming_address = nil
        state.alert = nil
        stop_alarm_audio()
        log_event("WORMHOLE CLOSED: " .. address_to_string(address) .. " / " .. tostring(reason or "unknown") .. " / initiating=" .. tostring(initiating))

    elseif event == "stargate_wormhole_subspace_connected" then
        log_event("WORMHOLE SUBSPACE CONNECTED: initiating=" .. tostring(args[2]))

    elseif event == "stargate_wormhole_subspace_disconnected" then
        log_event("WORMHOLE SUBSPACE DISCONNECTED")

    elseif event == "stargate_wormhole_incoming_message" then
        log_event("INCOMING WORMHOLE MESSAGE RECEIVED")

    elseif event == "stargate_event_horizon_traveler" then
        local inbound, entity_type, uuid, player_name = args[1], args[2], args[3], args[4]
        if inbound == true then
            log_event("INBOUND TRAVELER: " .. tostring(player_name or entity_type or "unknown"))
        else
            log_event("OUTBOUND TRAVELER: " .. tostring(player_name or entity_type or "unknown"))
        end

    elseif event == "stargate_iris_code_received" then
        log_event("GDO/IRIS CODE RECEIVED: JSG received a code")

    elseif event == "stargate_iris_state_changed" then
        state.iris_state = args[2]
        log_event("IRIS STATE: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))
        maybe_release_iris_lock()

    elseif event == "stargate_iris_toggled" then
        log_event("IRIS TOGGLE EVENT: close=" .. tostring(args[1]))

    elseif event == "stargate_iris_type_changed" then
        state.iris_type = args[2]
        log_event("IRIS TYPE CHANGED: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))

    elseif event == "stargate_iris_damaged" then
        log_event("IRIS DAMAGED: " .. tostring(args[1] or "unknown") .. " amount=" .. tostring(args[2] or "?"))

    elseif event == "stargate_iris_hit" then
        log_event("IRIS HIT")

    elseif event == "stargate_iris_destroyed" then
        state.alert = "!!! IRIS DESTROYED !!!"
        log_event("!!! IRIS DESTROYED !!!: " .. tostring(args[1] or "unknown"))
        state.iris_state = nil
        release_iris_lock()

    elseif event == "stargate_iris_out_of_power" then
        state.alert = "!!! IRIS OUT OF POWER !!!"
        log_event("!!! IRIS OUT OF POWER !!!")

    end
end

-----------------------------------------------------------------------
-- Background loops
-----------------------------------------------------------------------

local function security_loop()
    while state.running do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "peripheral" or event == "peripheral_detach" then
            ensure_gate()
            refresh_gate()
            maybe_release_iris_lock()

        elseif event == "stargate_wormhole_incoming"
            or event == "stargate_spin_start"
            or event == "stargate_spin_stop"
            or event == "stargate_chevron_engaged"
            or event == "stargate_chevron_open"
            or event == "stargate_chevron_lit"
            or event == "stargate_chevron_dim"
            or event == "stargate_chevron_close"
            or event == "stargate_attempt_open_failed"
            or event == "stargate_attempt_close_failed"
            or event == "stargate_wormhole_open_fully"
            or event == "stargate_wormhole_close_fully"
            or event == "stargate_wormhole_subspace_connected"
            or event == "stargate_wormhole_subspace_disconnected"
            or event == "stargate_wormhole_incoming_message"
            or event == "stargate_event_horizon_traveler"
            or event == "stargate_iris_code_received"
            or event == "stargate_iris_state_changed"
            or event == "stargate_iris_toggled"
            or event == "stargate_iris_type_changed"
            or event == "stargate_iris_damaged"
            or event == "stargate_iris_hit"
            or event == "stargate_iris_destroyed"
            or event == "stargate_iris_out_of_power" then
            handle_jsg_event(event, p1, p2, p3, p4)
        end
    end
end

local function refresh_loop()
    while state.running do
        ensure_gate()
        refresh_gate()
        maybe_release_iris_lock()

        if state.iris_toggle_pending and state.iris_pending_since then
            local elapsed = os.epoch("utc") - state.iris_pending_since
            if elapsed >= CONFIG.iris_lock_timeout * 1000 then
                if not state.alert or state.alert ~= "IRIS TOGGLE STUCK - MANUAL CHECK REQUIRED" then
                    state.alert = "IRIS TOGGLE STUCK - MANUAL CHECK REQUIRED"
                    log_event("!!! IRIS TOGGLE STUCK - MANUAL CHECK REQUIRED !!!")
                end
            end
        end

        if CONFIG.auto_iris and state.mode == "AUTO" and state.gate and iris_bucket() == "open" then
            if state.incoming then
                close_iris("incoming/recovery")
            end
        end

        sleep(CONFIG.refresh_interval)
    end
end

-----------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------

local function status_text()
    if not state.connected then
        return "OFFLINE"
    end
    if not state.gate_merged then
        return "NOT MERGED"
    end
    return tostring(state.gate_status or "UNKNOWN"):upper()
end

local function energy_text()
    if not state.connected or not state.max_energy or state.max_energy <= 0 then
        return "N/A"
    end
    return string.format(
        "%d / %d (%d%%)",
        state.energy,
        state.max_energy,
        math.floor((state.energy / state.max_energy) * 100 + 0.5)
    )
end

local function clear_line(y)
    term.setCursorPos(1, y)
    term.clearLine()
end

local function header(title)
    clear_line(1)
    term.setCursorPos(1, 1)
    term.write("S T A R G A T E   C O M M A N D")
    clear_line(2)
    term.setCursorPos(1, 2)
    term.write("================================")
    clear_line(3)
    term.setCursorPos(1, 3)
    term.write("[ " .. tostring(title) .. " ]")
end

local function draw_main()
    term.clear()
    header("MAIN CONTROL")

    term.setCursorPos(2, 5)
    term.write("GATE:   " .. status_text())
    term.setCursorPos(2, 6)
    term.write("ENERGY: " .. energy_text())
    term.setCursorPos(2, 7)
    term.write("IRIS:   " .. tostring(state.iris_state or "UNKNOWN"):upper() .. "  [" .. state.mode .. "]")

    term.setCursorPos(2, 9)
    term.write("LOCAL ADDRESS:")
    term.setCursorPos(4, 10)
    local local_address = "UNKNOWN"
    if type(state.gate_address) == "table" then
        for _, address in pairs(state.gate_address) do
            if type(address) == "table" then
                local_address = address_to_string(address)
                break
            end
        end
    end
    term.write(local_address:sub(1, 74))

    term.setCursorPos(2, 12)
    term.write("DIALED ADDRESS:")
    term.setCursorPos(4, 13)
    term.write(address_to_string(state.dialed_address):sub(1, 74))

    if state.incoming then
        term.setCursorPos(2, 15)
        term.write("!!! INCOMING WORMHOLE !!!")
        term.setCursorPos(4, 16)
        term.write(tostring(state.incoming_address or "UNKNOWN"):sub(1, 74))
    end

    if state.dialing then
        term.setCursorPos(2, 17)
        term.write(string.format("DIALING: %d / %d", state.dial_chevrons, state.dial_target_count))
        if state.dial_last_symbol then
            term.setCursorPos(4, 18)
            term.write("LAST CHEVRON: " .. tostring(state.dial_last_symbol):sub(1, 60))
        end
    elseif state.ring_spinning then
        term.setCursorPos(2, 17)
        term.write("RING SPINNING: " .. tostring(state.ring_direction or "?") .. " @ " .. tostring(state.ring_speed or "?"))
    end

    term.setCursorPos(2, 20)
    term.write("1 ADDRESS BOOK")
    term.setCursorPos(2, 21)
    term.write("2 DIAL SELECTED")
    term.setCursorPos(2, 22)
    term.write("3 IRIS CONTROL")
    term.setCursorPos(2, 23)
    term.write("4 EVENT LOG")
    term.setCursorPos(2, 24)
    term.write("5 REFRESH")
    term.setCursorPos(2, 25)
    term.write("Q SHUTDOWN")

    if state.alert then
        term.setCursorPos(38, 20)
        term.write(tostring(state.alert):sub(1, 38))
    end

    term.setCursorPos(2, 27)
    term.write("LAST: " .. tostring(state.last_event):sub(1, 74))
end

local function draw_addresses()
    term.clear()
    header("ADDRESS BOOK")

    if #state.addresses == 0 then
        term.setCursorPos(2, 5)
        term.write("NO SAVED ADDRESSES")
    else
        local first = math.max(1, state.selected_address - 8)
        local last = math.min(#state.addresses, first + 14)
        local row = 5

        for i = first, last do
            local entry = state.addresses[i]
            local marker = i == state.selected_address and ">" or " "
            term.setCursorPos(2, row)
            term.write(string.format(
                "%s %02d %-18s %s",
                marker,
                i,
                tostring(entry.name):sub(1, 18),
                address_to_string(entry.symbols):sub(1, 30)
            ))
            row = row + 1
        end
    end

    term.setCursorPos(2, 22)
    term.write("UP/DOWN SELECT")
    term.setCursorPos(2, 23)
    term.write("D DIAL   A ADD   R REMOVE")
    term.setCursorPos(2, 24)
    term.write("E EDIT   B BACK")
end

local function address_menu()
    while state.running do
        draw_addresses()
        local _, key = os.pullEvent("key")

        if key == keys.up then
            state.selected_address = math.max(1, state.selected_address - 1)
        elseif key == keys.down then
            if #state.addresses > 0 then
                state.selected_address = math.min(#state.addresses, state.selected_address + 1)
            end
        elseif key == keys.d then
            dial_saved(state.selected_address)
        elseif key == keys.a then
            add_address()
        elseif key == keys.e then
            edit_address(state.selected_address)
        elseif key == keys.r then
            remove_address(state.selected_address)
        elseif key == keys.b then
            return
        end
    end
end

local function draw_iris()
    term.clear()
    header("IRIS CONTROL")

    term.setCursorPos(2, 5)
    term.write("STATE: " .. tostring(state.iris_state or "UNKNOWN"):upper())
    term.setCursorPos(2, 6)
    term.write("TYPE:  " .. tostring(state.iris_type or "UNKNOWN"):upper())
    term.setCursorPos(2, 7)
    term.write("MODE:  " .. state.mode)
    term.setCursorPos(2, 8)
    term.write("DURABILITY: " .. tostring(state.iris_durability_display or "UNKNOWN"))

    if state.iris_durability and state.iris_max_durability then
        term.setCursorPos(2, 9)
        term.write("CURRENT/MAX: " .. tostring(state.iris_durability) .. " / " .. tostring(state.iris_max_durability))
    end

    if state.iris_toggle_pending then
        term.setCursorPos(2, 11)
        term.write("TOGGLE: " .. tostring(state.iris_pending_direction) .. " IN PROGRESS")
    elseif state.alert then
        term.setCursorPos(2, 11)
        term.write(tostring(state.alert):sub(1, 74))
    end

    term.setCursorPos(2, 13)
    term.write("O OPEN (MANUAL ONLY)")
    term.setCursorPos(2, 14)
    term.write("C CLOSE")
    term.setCursorPos(2, 15)
    term.write("A TOGGLE AUTO/MANUAL")
    term.setCursorPos(2, 16)
    term.write("F FORCE-CLEAR STUCK SOFTWARE LOCK")
    term.setCursorPos(2, 17)
    term.write("B BACK")

    term.setCursorPos(2, 20)
    term.write("JSG handles native GDO/iris-code validation.")
    term.setCursorPos(2, 21)
    term.write("Unknown or transitioning iris states will not be blind-toggled.")
end

local function force_clear_iris_lock()
    if not state.iris_toggle_pending then
        log_event("FORCE CLEAR REFUSED: no iris toggle lock is active")
        return
    end

    term.clear()
    print("!!! WARNING !!!")
    print("This only clears the SGC SOFTWARE lock.")
    print("It does NOT move the physical iris.")
    print("")
    print("Only continue after physically verifying the iris state.")
    write("Type FORCE to continue: ")

    if trim(read()) == "FORCE" then
        release_iris_lock()
        state.iris_state = nil
        state.alert = "IRIS STATE MUST BE VERIFIED"
        log_event("IRIS SOFTWARE LOCK FORCE-CLEARED - STATE VERIFICATION REQUIRED")
    else
        log_event("IRIS SOFTWARE LOCK FORCE-CLEAR CANCELLED")
    end
end

local function iris_menu()
    while state.running do
        refresh_gate()
        draw_iris()
        local _, key = os.pullEvent("key")

        if key == keys.o then
            if state.mode == "MANUAL" then
                open_iris("manual control")
            else
                log_event("MANUAL OPEN BLOCKED: switch iris mode to MANUAL first")
            end

        elseif key == keys.c then
            close_iris("manual control")

        elseif key == keys.a then
            state.mode = state.mode == "AUTO" and "MANUAL" or "AUTO"
            save_data()
            log_event("IRIS MODE: " .. state.mode)
            if state.mode == "AUTO" and state.incoming then
                close_iris("AUTO enabled during incoming activation")
            end

        elseif key == keys.f then
            if state.iris_toggle_pending then
                force_clear_iris_lock()
            else
                log_event("FORCE CLEAR REFUSED: no iris toggle lock is active")
            end

        elseif key == keys.b then
            return
        end
    end
end

local function draw_log()
    term.clear()
    header("EVENT LOG")

    local start = math.max(1, #state.events - 19)
    local row = 5
    for i = start, #state.events do
        term.setCursorPos(2, row)
        term.write(tostring(state.events[i]):sub(1, 76))
        row = row + 1
        if row > 24 then break end
    end

    term.setCursorPos(2, 26)
    term.write("B BACK")
end

local function log_menu()
    while state.running do
        draw_log()
        local _, key = os.pullEvent("key")
        if key == keys.b then
            return
        end
    end
end

local function ui_loop()
    while state.running do
        draw_main()
        local _, key = os.pullEvent("key")

        if key == keys.one then
            address_menu()
        elseif key == keys.two then
            dial_saved(state.selected_address)
        elseif key == keys.three then
            iris_menu()
        elseif key == keys.four then
            log_menu()
        elseif key == keys.five then
            ensure_gate()
            refresh_gate()
            maybe_release_iris_lock()
            if CONFIG.auto_iris and state.mode == "AUTO" and state.incoming and iris_bucket() == "open" then
                close_iris("manual refresh fail-closed")
            end
            log_event("MANUAL REFRESH")
        elseif key == keys.q then
            state.running = false
        end
    end
end

-----------------------------------------------------------------------
-- Startup / shutdown
-----------------------------------------------------------------------

local function startup()
    term.setCursorBlink(false)
    term.clear()

    load_data()
    load_events()
    log_event("SGC SYSTEM STARTING")

    if ensure_gate() then
        refresh_gate()
        maybe_release_iris_lock()
        log_event("Gate status at startup: " .. status_text())

        if CONFIG.auto_iris and state.mode == "AUTO" and iris_bucket() == "open" then
            close_iris("startup fail-closed")
        end
    else
        log_event("NO STARGATE PERIPHERAL FOUND")
    end
end

startup()
parallel.waitForAny(security_loop, refresh_loop, audio_loop, ui_loop)
state.running = false
save_data()
save_events()
stop_alarm_audio()
term.clear()
term.setCursorPos(1, 1)
print("SGC system offline.")
