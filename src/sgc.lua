-- SGC-CC
-- Stargate Command ComputerCraft control system for JSG
-- Target: Minecraft 1.20.1 Forge + Just Stargate Mod + CC:Tweaked
--
-- Security-critical design rules:
--   * pcall success is NOT JSG operation success.
--   * Iris is monitored here; JSG owns iris/GDO mechanics.
--   * Security/event handling runs independently of the UI.

local CONFIG = {
    data_file = "sgc_data",
    event_log_file = "sgc_events",
    max_log_entries = 200,
    refresh_interval = 0.5,

    -- Disk alarms. These values are the measured burst lengths and are used
    -- to decide when the next replay may begin.
    audio = {
        incoming_drive = "drive_3",
        outgoing_drive = "drive_2",
        incoming_repeat_seconds = 1.5,
        outgoing_repeat_seconds = 1.5,
        poll_interval = 0.05,
    },

    -- Iris telemetry stays live for a short period after a hit so the
    -- monitor remains visibly in an active/alarm state after an impact.
    iris_attack_hold_ms = 5000,
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
    jsg_version = nil,
    gate_type = nil,
    symbol_type = nil,

    iris_state = nil,
    iris_type = nil,
    iris_durability_display = nil,
    iris_durability = nil,
    iris_max_durability = nil,
    iris_last_state_change = nil,
    iris_last_state_change_at = nil,
    iris_hit_count = 0,
    iris_damage_total = 0,
    iris_last_damage = nil,
    iris_last_hit_at = nil,
    iris_attack_active = false,

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
        return fallback, true
    end

    local handle = fs.open(path, "r")
    if not handle then
        return fallback, false, "Unable to open " .. tostring(path)
    end

    local raw = handle.readAll()
    handle.close()

    if not raw or raw == "" then
        return fallback, false, "File is empty: " .. tostring(path)
    end

    local result = textutils.unserialize(raw)
    if type(result) == "table" then
        return result, true
    end

    return fallback, false, "Invalid serialized data in " .. tostring(path)
end

local function save_table(path, data)
    local raw = textutils.serialize(data)
    local handle = fs.open(path, "w")
    if not handle then
        return false, "Unable to open " .. tostring(path) .. " for writing"
    end

    handle.write(raw)
    handle.close()

    if not fs.exists(path) then
        return false, "File was not created: " .. tostring(path)
    end

    local size = fs.getSize(path)
    if not size or size <= 0 then
        return false, "File is empty after write: " .. tostring(path)
    end

    return true
end

local function save_data()
    return save_table(CONFIG.data_file, {
        addresses = state.addresses,
    })
end

local function load_data()
    local data, ok, error_message = load_table(CONFIG.data_file, {})

    if type(data.addresses) == "table" then
        state.addresses = data.addresses
    end

    state.selected_address = math.max(1, math.min(state.selected_address, math.max(1, #state.addresses)))
    return ok, error_message
end

local function load_events()
    local events, ok = load_table(CONFIG.event_log_file, {})
    if ok and type(events) == "table" then
        state.events = events
    else
        state.events = {}
    end
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


local function report_data_save_failure(action, message)
    state.alert = "!!! ADDRESS DATA SAVE FAILED !!!"
    state.last_event = "ADDRESS DATA SAVE FAILED: " .. tostring(message or "unknown error")
    if action then
        state.last_event = "ADDRESS " .. tostring(action):upper() .. " SAVE FAILED: " .. tostring(message or "unknown error")
    end
    log_event(state.last_event)
end

-----------------------------------------------------------------------
-- UI helpers
-----------------------------------------------------------------------

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

local function draw_controls(lines)
    local width, height = term.getSize()
    local start = math.max(1, height - #lines + 1)

    for i, line in ipairs(lines) do
        local y = start + i - 1
        if y <= height then
            clear_line(y)
            term.setCursorPos(2, y)
            term.write(tostring(line):sub(1, math.max(0, width - 2)))
        end
    end
end

local function remaining_time_text(epoch_ms)
    if not epoch_ms then
        return "UNKNOWN"
    end

    local delta = math.max(0, os.epoch("utc") - epoch_ms)
    return string.format("%0.1fs AGO", delta / 1000)
end

local function wrap_text(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)

    local lines = {}
    while #text > width do
        local cut = width
        local space = text:sub(1, width):match("^.*() ")
        if space and space > math.floor(width * 0.55) then
            cut = space - 1
        end
        table.insert(lines, text:sub(1, cut))
        text = text:sub(cut + 1):gsub("^%s+", "")
    end
    table.insert(lines, text)
    return lines
end

local ui_timer = nil

local function ensure_ui_timer()
    if not ui_timer then
        ui_timer = os.startTimer(CONFIG.refresh_interval)
    end
    return ui_timer
end

local function renew_ui_timer()
    ui_timer = os.startTimer(CONFIG.refresh_interval)
    return ui_timer
end

-----------------------------------------------------------------------
-- Gate discovery / monitoring state
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
    state.jsg_version = nil
    state.gate_type = nil
    state.symbol_type = nil
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
        state.gate = nil
        state.gate_name = nil
        clear_gate_state()
        return false
    end

    if old_gate ~= nil and gate ~= old_gate then
        log_event("Gate peripheral changed")
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

    ok, state.jsg_version = safe_call(state.gate.getJSGVersion)
    if not ok then
        state.jsg_version = nil
    end

    ok, state.gate_type = safe_call(state.gate.getGateType)
    if not ok then
        state.gate_type = nil
    end

    ok, state.symbol_type = safe_call(state.gate.getSymbolType)
    if not ok then
        state.symbol_type = nil
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
    else
        state.iris_state = nil
    end

    if state.gate.getIrisType then
        ok, state.iris_type = safe_call(state.gate.getIrisType)
        if not ok then
            state.iris_type = nil
        end
    else
        state.iris_type = nil
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
    else
        state.iris_durability_display = nil
        state.iris_durability = nil
        state.iris_max_durability = nil
    end

    if state.iris_last_hit_at then
        state.iris_attack_active = (os.epoch("utc") - state.iris_last_hit_at) <= CONFIG.iris_attack_hold_ms
    else
        state.iris_attack_active = false
    end

    return true
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
    for index, valid in ipairs(symbol_map or {}) do
        if tostring(valid):lower() == needle then
            return tostring(valid), index
        end
    end

    return nil, nil
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
        local columns = width >= 80 and 2 or 1
        local footer_rows = 3
        local first_row = 6
        local last_row = math.max(first_row, height - footer_rows - 1)
        local rows = math.max(1, last_row - first_row + 1)
        local column_width = math.max(1, math.floor(width / columns))
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
            local y = first_row + row
            local symbol = symbols[index]
            local key_name = tostring(symbol):lower()
            local marker = selected[key_name] and "*" or " "
            local cursor_marker = cursor == index and ">" or " "
            local text = string.format("%s%s [%02d] %s", cursor_marker, marker, index, tostring(symbol))

            term.setCursorPos(x, y)
            term.clearLine()
            term.write(text:sub(1, math.max(1, column_width - 2)))
        end

        draw_controls({
            "ARROWS MOVE   SPACE SELECT   ENTER ACCEPT   B CANCEL",
            "LEFT/RIGHT PAGE   HOME/END FIRST/LAST   7-9 REQUIRED",
            "* = SELECTED   INDEX = JSG MAP INDEX   ORDER = DIAL SEQUENCE",
        })

        local _, key = os.pullEvent("key")

        if key == keys.up then
            cursor = math.max(1, cursor - 1)
        elseif key == keys.down then
            cursor = math.min(#symbols, cursor + 1)
        elseif key == keys.left then
            if page > 1 then
                cursor = page_first - per_page
            end
        elseif key == keys.right then
            if page < pages then
                cursor = math.min(#symbols, page_first + per_page)
            end
        elseif key == keys.home then
            cursor = 1
        elseif key == keys['end'] then
            cursor = #symbols
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
    header("ADD ADDRESS")
    term.setCursorPos(2, 5)
    term.write("ENTER THE DESTINATION NAME")
    term.setCursorPos(2, 7)
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

    local saved, save_error = save_data()
    if not saved then
        report_data_save_failure("ADD", save_error)
        return
    end

    state.alert = nil
    log_event("ADDRESS ADDED: " .. name)
end

local function edit_address(index)
    local entry = state.addresses[index]
    if not entry then
        return
    end

    term.clear()
    header("EDIT ADDRESS")
    term.setCursorPos(2, 5)
    term.write("CURRENT NAME: " .. tostring(entry.name))
    term.setCursorPos(2, 6)
    term.write("CURRENT GLYPHS: " .. address_to_string(entry.symbols):sub(1, 58))
    term.setCursorPos(2, 8)
    write("New name (blank = keep): ")
    local name = trim(read())
    if name ~= "" then
        entry.name = name
    end

    write("Edit glyphs? (Y/N): ")
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

    local saved, save_error = save_data()
    if not saved then
        report_data_save_failure("EDIT", save_error)
        return
    end

    state.alert = nil
    log_event("ADDRESS EDITED: " .. tostring(entry.name))
end

local function remove_address(index)
    local entry = state.addresses[index]
    if not entry then
        return
    end

    term.clear()
    header("REMOVE ADDRESS")
    term.setCursorPos(2, 5)
    term.write("REMOVE: " .. tostring(entry.name))
    term.setCursorPos(2, 7)
    write("Type YES to confirm: ")

    if trim(read()) == "YES" then
        table.remove(state.addresses, index)
        state.selected_address = math.min(state.selected_address, math.max(1, #state.addresses))

        local saved, save_error = save_data()
        if not saved then
            report_data_save_failure("REMOVE", save_error)
            return
        end

        state.alert = nil
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

    if kind == "outgoing" and state.audio_alarm == "incoming" then
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

    -- JSG's own dialAddress() is the authority for address validity. The
    -- energy preflight is still useful, but a JSG address_malformed response
    -- here is not treated as a final rejection because JSG performs its full
    -- address/origin handling again when dialAddress() is invoked.
    local energy_ok, energy_success, energy_code, energy_map = safe_call(
        state.gate.getEnergyRequiredToDial,
        symbols
    )

    if not energy_ok then
        log_event("DIAL PREFLIGHT ERROR: " .. tostring(energy_map))
        return
    end

    if energy_success ~= true then
        local reason = tostring(energy_code or "unknown") .. ": " .. tostring(energy_map or "JSG rejected the address")
        if tostring(energy_code) == "address_malformed" then
            log_event("DIAL PREFLIGHT WARNING: " .. reason .. "; proceeding to JSG dial")
        else
            log_event("DIAL PREFLIGHT FAILED: " .. reason)
            return
        end
    elseif type(energy_map) ~= "table" then
        log_event("DIAL PREFLIGHT ERROR: malformed energy response")
        return
    elseif energy_map.canOpen ~= true then
        log_event("DIAL PREFLIGHT FAILED: insufficient energy")
        return
    end

    local ok, success, code, message = safe_call(state.gate.dialAddress, symbols)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        log_event("DIAL FAILED: " .. detail)
        state.alert = "!!! DIAL FAILED !!!"
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
        state.alert = "!!! GATE OPEN FAILED !!!"
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
        state.iris_last_state_change = tostring(args[2] or "UNKNOWN")
        state.iris_last_state_change_at = os.epoch("utc")
        log_event("IRIS STATE: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))

    elseif event == "stargate_iris_toggled" then
        log_event("IRIS TOGGLE EVENT: close=" .. tostring(args[1]))

    elseif event == "stargate_iris_type_changed" then
        state.iris_type = args[2]
        log_event("IRIS TYPE CHANGED: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))

    elseif event == "stargate_iris_damaged" then
        local source = args[1]
        local damage = tonumber(args[2])
        state.iris_attack_active = true
        state.iris_last_hit_at = os.epoch("utc")
        if damage then
            state.iris_last_damage = damage
            state.iris_damage_total = state.iris_damage_total + damage
        end
        log_event("IRIS DAMAGED: " .. tostring(source or "unknown") .. " amount=" .. tostring(args[2] or "?"))

    elseif event == "stargate_iris_hit" then
        state.iris_hit_count = state.iris_hit_count + 1
        state.iris_attack_active = true
        state.iris_last_hit_at = os.epoch("utc")
        log_event("IRIS HIT")

    elseif event == "stargate_iris_destroyed" then
        state.alert = "!!! IRIS DESTROYED !!!"
        state.iris_state = nil
        state.iris_attack_active = true
        state.iris_last_hit_at = os.epoch("utc")
        log_event("!!! IRIS DESTROYED !!!: " .. tostring(args[1] or "unknown"))

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

local function local_address_text()
    local local_address = "UNKNOWN"
    if type(state.gate_address) == "table" then
        for _, address in pairs(state.gate_address) do
            if type(address) == "table" then
                local_address = address_to_string(address)
                break
            end
        end
    end
    return local_address
end

local function draw_main()
    term.clear()
    header("MAIN CONTROL")

    term.setCursorPos(2, 5)
    term.write("GATE:   " .. status_text())
    term.setCursorPos(2, 6)
    term.write("ENERGY: " .. energy_text())
    term.setCursorPos(2, 7)
    term.write("IRIS:   " .. tostring(state.iris_state or "UNKNOWN"):upper())

    term.setCursorPos(2, 9)
    term.write("LOCAL ADDRESS:")
    term.setCursorPos(4, 10)
    term.write(local_address_text():sub(1, 74))

    term.setCursorPos(2, 12)
    term.write("DIALED ADDRESS:")
    term.setCursorPos(4, 13)
    term.write(address_to_string(state.dialed_address):sub(1, 74))

    local _, height = term.getSize()
    local content_last = math.max(5, height - 2)
    local row = 15

    if state.incoming and row <= content_last then
        term.setCursorPos(2, row)
        term.write("!!! INCOMING WORMHOLE !!!")
        row = row + 1
        if row <= content_last then
            term.setCursorPos(4, row)
            term.write(tostring(state.incoming_address or "UNKNOWN"):sub(1, 74))
            row = row + 1
        end
    end

    if state.dialing and row <= content_last then
        term.setCursorPos(2, row)
        term.write(string.format("DIALING: %d / %d", state.dial_chevrons, state.dial_target_count))
        row = row + 1
        if state.dial_last_symbol and row <= content_last then
            term.setCursorPos(4, row)
            term.write("LAST CHEVRON: " .. tostring(state.dial_last_symbol):sub(1, 60))
            row = row + 1
        end
    elseif state.ring_spinning and row <= content_last then
        term.setCursorPos(2, row)
        term.write("RING SPINNING: " .. tostring(state.ring_direction or "?") .. " @ " .. tostring(state.ring_speed or "?"))
        row = row + 1
    end

    if state.last_event and row <= content_last then
        term.setCursorPos(2, row)
        term.write("LAST: " .. tostring(state.last_event):sub(1, 74))
        row = row + 1
    end

    if state.alert and row <= content_last then
        term.setCursorPos(2, row)
        term.write("ALERT: " .. tostring(state.alert):sub(1, 65))
    end

    draw_controls({
        "1 ADDRESS BOOK   2 DIAL SELECTED   3 IRIS MONITOR",
        "4 EVENT LOG      5 REFRESH         Q SHUTDOWN",
    })
end

local function draw_addresses()
    term.clear()
    header("ADDRESS BOOK")

    if #state.addresses == 0 then
        term.setCursorPos(2, 5)
        term.write("NO SAVED ADDRESSES")
    else
        local _, height = term.getSize()
        local footer_rows = 2
        local first_row = 5
        local last_row = math.max(first_row, height - footer_rows - 1)
        local visible = math.max(1, last_row - first_row + 1)
        local first = math.max(1, state.selected_address - math.floor(visible / 2))
        local last = math.min(#state.addresses, first + visible - 1)
        first = math.max(1, last - visible + 1)

        local row = first_row
        for i = first, last do
            local entry = state.addresses[i]
            local marker = i == state.selected_address and ">" or " "
            local name = tostring(entry.name):sub(1, 18)
            local glyphs = address_to_string(entry.symbols):sub(1, math.max(1, math.min(30, math.floor(term.getSize() / 3))))
            term.setCursorPos(2, row)
            term.write(string.format("%s %02d %-18s %s", marker, i, name, glyphs))
            row = row + 1
        end
    end

    draw_controls({
        "UP/DOWN SELECT   V VIEW GLYPHS   D DIAL",
        "A ADD   E EDIT   R REMOVE   B BACK",
    })
end

local function address_details_menu()
    while state.running do
        local entry = state.addresses[state.selected_address]
        if not entry then
            return
        end

        term.clear()
        header("ADDRESS DETAILS")
        term.setCursorPos(2, 5)
        term.write("NAME: " .. tostring(entry.name):sub(1, 70))
        term.setCursorPos(2, 6)
        term.write("GLYPHS: " .. tostring(#entry.symbols) .. "   POSITION / MAP INDEX / JSG NAME")

        local width, height = term.getSize()
        local first_row = 7
        local footer_rows = 3
        local last_row = math.max(first_row, height - footer_rows - 1)
        local visible = math.max(1, last_row - first_row + 1)
        local symbol_map = get_symbol_map() or {}

        for pos = 1, math.min(#entry.symbols, visible) do
            local symbol, map_index = canonical_symbol(entry.symbols[pos], symbol_map)
            symbol = symbol or tostring(entry.symbols[pos])
            term.setCursorPos(2, first_row + pos - 1)
            term.write(string.format("%02d  MAP[%02d]  %s", pos, tonumber(map_index) or 0, symbol):sub(1, math.max(1, width - 2)))
        end

        draw_controls({
            "D DIAL   E EDIT   R REMOVE",
            "B BACK   UP/DOWN CHANGE ADDRESS",
            "MAP INDEX + JSG NAME = UNAMBIGUOUS GLYPH IDENTIFIER",
        })

        local _, key = os.pullEvent("key")
        if key == keys.d then
            dial_saved(state.selected_address)
            renew_ui_timer()
        elseif key == keys.e then
            edit_address(state.selected_address)
            renew_ui_timer()
        elseif key == keys.r then
            remove_address(state.selected_address)
            renew_ui_timer()
        elseif key == keys.b then
            return
        elseif key == keys.up then
            state.selected_address = math.max(1, state.selected_address - 1)
        elseif key == keys.down then
            if #state.addresses > 0 then
                state.selected_address = math.min(#state.addresses, state.selected_address + 1)
            end
        end
    end
end

local function address_menu()
    ensure_ui_timer()

    while state.running do
        draw_addresses()
        local event, p1 = os.pullEvent()

        if event == "key" then
            local key = p1
            if key == keys.up then
                state.selected_address = math.max(1, state.selected_address - 1)
            elseif key == keys.down then
                if #state.addresses > 0 then
                    state.selected_address = math.min(#state.addresses, state.selected_address + 1)
                end
            elseif key == keys.d then
                dial_saved(state.selected_address)
                renew_ui_timer()
            elseif key == keys.a then
                add_address()
                renew_ui_timer()
            elseif key == keys.e then
                edit_address(state.selected_address)
                renew_ui_timer()
            elseif key == keys.r then
                remove_address(state.selected_address)
                renew_ui_timer()
            elseif key == keys.v then
                address_details_menu()
                renew_ui_timer()
            elseif key == keys.b then
                return
            end
        elseif event == "timer" and p1 == ui_timer then
            renew_ui_timer()
        end
    end
end

local function draw_iris_monitor()
    term.clear()
    header("IRIS CONTROL / TELEMETRY")

    local iris_state = tostring(state.iris_state or "UNKNOWN"):upper()
    local iris_type = tostring(state.iris_type or "UNKNOWN"):upper()
    local attack = state.iris_attack_active and "DETECTED" or "NONE"
    local durability = tostring(state.iris_durability_display or "UNKNOWN")
    local current_max = "UNKNOWN"
    local percent = "UNKNOWN"

    if state.iris_durability and state.iris_max_durability then
        current_max = tostring(state.iris_durability) .. " / " .. tostring(state.iris_max_durability)
        if tonumber(state.iris_max_durability) and tonumber(state.iris_max_durability) > 0 then
            percent = string.format("%d%%", math.floor((state.iris_durability / state.iris_max_durability) * 100 + 0.5))
        end
    end

    term.setCursorPos(2, 5)
    term.write("CONTROL LINK: ONLINE / JSG-GDO TELEMETRY")
    term.setCursorPos(2, 6)
    term.write("IRIS STATE:   " .. iris_state .. "   TYPE: " .. iris_type)
    term.setCursorPos(2, 7)
    term.write("DURABILITY:   " .. durability .. " / " .. percent)
    term.setCursorPos(2, 8)
    term.write("CURRENT/MAX:  " .. current_max)
    term.setCursorPos(2, 9)
    term.write("ATTACK: " .. attack .. "   HITS: " .. tostring(state.iris_hit_count))
    term.setCursorPos(2, 10)
    term.write("DAMAGE TOTAL: " .. tostring(state.iris_damage_total) .. "   LAST: " .. tostring(state.iris_last_damage or "NONE"))
    term.setCursorPos(2, 11)
    term.write("LAST HIT:     " .. remaining_time_text(state.iris_last_hit_at))
    term.setCursorPos(2, 12)
    term.write("STATE CHANGE: " .. tostring(state.iris_last_state_change or "NONE"))
    term.setCursorPos(2, 13)
    term.write("LAST CHANGE:  " .. remaining_time_text(state.iris_last_state_change_at))
    term.setCursorPos(2, 14)
    term.write("THERMAL:      NOT EXPOSED BY JSG CC API")
    term.setCursorPos(2, 15)
    term.write("JSG VERSION:  " .. tostring(state.jsg_version or "UNKNOWN"))
    term.setCursorPos(2, 16)
    term.write("GATE:         " .. tostring(state.gate_type or "UNKNOWN") .. " / SYMBOL: " .. tostring(state.symbol_type or "UNKNOWN"))
    if state.alert then
        term.setCursorPos(2, 17)
        term.write("ALERT: " .. tostring(state.alert):sub(1, math.max(1, term.getSize() - 8)))
    end

    draw_controls({
        "R FORCE REFRESH   B BACK",
        "LIVE TELEMETRY: AUTO-REFRESH   JSG RETAINS CONTROL",
    })
end

local function iris_monitor_menu()
    ensure_ui_timer()

    while state.running do
        refresh_gate()
        draw_iris_monitor()
        local event, p1 = os.pullEvent()
        if event == "key" then
            if p1 == keys.r then
                refresh_gate()
                log_event("IRIS MONITOR REFRESH")
            elseif p1 == keys.b then
                return
            end
        elseif event == "timer" and p1 == ui_timer then
            refresh_gate()
            renew_ui_timer()
        end
    end
end

local function draw_log()
    term.clear()
    header("EVENT LOG")

    local width, height = term.getSize()
    local footer_rows = 1
    local first_row = 5
    local last_row = math.max(first_row, height - footer_rows - 1)
    local visible = math.max(1, last_row - first_row + 1)
    local wrapped_entries = {}

    for i = #state.events, 1, -1 do
        local lines = wrap_text(state.events[i], math.max(1, width - 3))
        for j = #lines, 1, -1 do
            table.insert(wrapped_entries, 1, lines[j])
        end
        if #wrapped_entries >= visible then
            break
        end
    end

    local start = math.max(1, #wrapped_entries - visible + 1)
    local row = first_row
    for i = start, #wrapped_entries do
        term.setCursorPos(2, row)
        term.write(tostring(wrapped_entries[i]):sub(1, math.max(1, width - 2)))
        row = row + 1
        if row > last_row then
            break
        end
    end

    draw_controls({
        "B BACK",
    })
end

local function log_menu()
    ensure_ui_timer()

    while state.running do
        draw_log()
        local event, p1 = os.pullEvent()
        if event == "key" and p1 == keys.b then
            return
        elseif event == "timer" and p1 == ui_timer then
            renew_ui_timer()
        end
    end
end

local function ui_loop()
    ensure_ui_timer()

    while state.running do
        draw_main()
        local event, p1 = os.pullEvent()

        if event == "key" then
            if p1 == keys.one then
                address_menu()
                renew_ui_timer()
            elseif p1 == keys.two then
                dial_saved(state.selected_address)
                renew_ui_timer()
            elseif p1 == keys.three then
                iris_monitor_menu()
                renew_ui_timer()
            elseif p1 == keys.four then
                log_menu()
                renew_ui_timer()
            elseif p1 == keys.five then
                ensure_gate()
                refresh_gate()
                log_event("MANUAL REFRESH")
                renew_ui_timer()
            elseif p1 == keys.q then
                state.running = false
            end
        elseif event == "timer" and p1 == ui_timer then
            renew_ui_timer()
        end
    end
end

-----------------------------------------------------------------------
-- Startup / shutdown
-----------------------------------------------------------------------

local function startup()
    term.setCursorBlink(false)
    term.clear()

    local data_ok, data_error = load_data()
    load_events()
    log_event("SGC SYSTEM STARTING")

    if not data_ok then
        state.alert = "!!! ADDRESS DATA LOAD FAILED !!!"
        log_event("ADDRESS DATA LOAD FAILED: " .. tostring(data_error or "unknown error") .. ". Starting with in-memory address book.")
    end

    if ensure_gate() then
        refresh_gate()
        log_event("Gate status at startup: " .. status_text())
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
