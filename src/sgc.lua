-- SGC-CC
-- Stargate Command ComputerCraft control system for JSG
-- Minecraft 1.20.1 Forge + Just Stargate Mod + CC:Tweaked
--
-- Security rules:
--   * JSG exceptions and JSG boolean failures are handled separately.
--   * Iris state is tri-state: OPEN / CLOSED / UNKNOWN. Unknown is never toggled.
--   * Iris toggles are serialized and remain locked until the iris reaches a
--     terminal state (or JSG explicitly rejects the toggle).
--   * Security events are handled in their own coroutine so menus/read() calls
--     cannot delay incoming-wormhole handling.
--
-- Temperature and direct JSG siren playback are intentionally not implemented.

local CONFIG = {
    data_file = "sgc_data",
    event_log_file = "sgc_events",
    max_log_entries = 200,
    refresh_interval = 0.5,
    auto_iris = true,
}

local EVENTS = {
    INCOMING = "stargate_wormhole_incoming",
    OPEN_FULLY = "stargate_wormhole_open_fully",
    CLOSE_FULLY = "stargate_wormhole_close_fully",
    TRAVELER = "stargate_event_horizon_traveler",
    IRIS_CODE = "stargate_iris_code_received",
    IRIS_STATE = "stargate_iris_state_changed",
    IRIS_TOGGLED = "stargate_iris_toggled",
    IRIS_DESTROYED = "stargate_iris_destroyed",
    IRIS_DAMAGED = "stargate_iris_damaged",
    IRIS_HIT = "stargate_iris_hit",
    IRIS_POWER = "stargate_iris_out_of_power",
    SPIN_START = "stargate_spin_start",
    SPIN_STOP = "stargate_spin_stop",
    CHEVRON = "stargate_chevron_engaged",
    CHEVRON_OPEN = "stargate_chevron_open",
    CHEVRON_LIT = "stargate_chevron_lit",
    CHEVRON_DIM = "stargate_chevron_dim",
    CHEVRON_CLOSE = "stargate_chevron_close",
    OPEN_FAILED = "stargate_attempt_open_failed",
    CLOSE_FAILED = "stargate_attempt_close_failed",
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
    iris_pending_direction = nil,
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
    events = {},
    addresses = {},
    selected_address = 1,
    mode = "AUTO",
    last_event = "System initialized",
}

-- pcall success is NOT JSG operation success.
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
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function address_to_string(address)
    if type(address) ~= "table" then return "UNKNOWN" end
    local out = {}
    for i, symbol in ipairs(address) do out[i] = tostring(symbol) end
    return #out > 0 and table.concat(out, " - ") or "NONE"
end

local function same_address(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        if tostring(a[i]):lower() ~= tostring(b[i]):lower() then return false end
    end
    return true
end

local function normalize_symbols(raw)
    local symbols = {}
    for token in tostring(raw):gmatch("%S+") do table.insert(symbols, token) end
    return symbols
end

local function load_table(path, fallback)
    if not fs.exists(path) then return fallback end
    local h = fs.open(path, "r")
    if not h then return fallback end
    local raw = h.readAll(); h.close()
    if not raw or raw == "" then return fallback end
    local fn = load(raw, path, "t", {})
    if not fn then return fallback end
    local ok, result = pcall(fn)
    return ok and type(result) == "table" and result or fallback
end

local function save_table(path, data)
    local h = fs.open(path, "w")
    if not h then return false end
    h.write(textutils.serialize(data)); h.close(); return true
end

local function save_data()
    save_table(CONFIG.data_file, { addresses = state.addresses, mode = state.mode })
end

local function load_data()
    local data = load_table(CONFIG.data_file, {})
    if type(data.addresses) == "table" then state.addresses = data.addresses end
    if data.mode == "AUTO" or data.mode == "MANUAL" then state.mode = data.mode end
    if #state.addresses == 0 then state.selected_address = 1 else state.selected_address = math.min(state.selected_address, #state.addresses) end
end

local function save_events()
    while #state.events > CONFIG.max_log_entries do table.remove(state.events, 1) end
    save_table(CONFIG.event_log_file, state.events)
end

local function load_events()
    local events = load_table(CONFIG.event_log_file, {})
    state.events = type(events) == "table" and events or {}
end

local function log_event(message)
    message = tostring(message)
    table.insert(state.events, now() .. "  " .. message)
    while #state.events > CONFIG.max_log_entries do table.remove(state.events, 1) end
    state.last_event = message
    save_events()
end

local function get_symbol_map()
    if not state.gate or not state.gate.getSymbolsMap then return nil end
    local ok, symbols = safe_call(state.gate.getSymbolsMap)
    return ok and type(symbols) == "table" and symbols or nil
end

local function canonical_symbol(symbol, symbol_map)
    local needle = tostring(symbol):lower()
    for _, valid in ipairs(symbol_map or {}) do
        if tostring(valid):lower() == needle then return tostring(valid) end
    end
end

local function validate_address(symbols)
    if type(symbols) ~= "table" or #symbols < 7 or #symbols > 9 then
        return false, "Address must contain 7-9 symbols"
    end
    local map = get_symbol_map()
    if not map then return false, "Unable to read the JSG symbol map" end
    local seen, normalized = {}, {}
    for i, symbol in ipairs(symbols) do
        local canonical = canonical_symbol(symbol, map)
        if not canonical then return false, "Invalid symbol at position " .. i .. ": " .. tostring(symbol) end
        local key = canonical:lower()
        if seen[key] then return false, "Duplicate symbol: " .. canonical end
        seen[key], normalized[i] = true, canonical
    end
    return true, normalized
end

local function refresh_gate()
    if not state.gate then
        state.connected = false; state.gate_merged = false; state.gate_status = nil; state.gate_initiating = nil
        state.energy = 0; state.max_energy = 0; state.iris_state = nil; state.iris_type = nil
        state.iris_durability_display = nil; state.iris_durability = nil; state.iris_max_durability = nil
        return false
    end

    local ok, merged, status, initiating = safe_call(state.gate.getGateStatus)
    if not ok then
        state.gate = nil; state.gate_name = nil; state.connected = false
        state.gate_merged = false; state.gate_status = nil; state.gate_initiating = nil
        return false
    end
    state.connected, state.gate_merged = true, merged == true
    state.gate_status, state.gate_initiating = status, initiating

    ok, state.energy = safe_call(state.gate.getEnergyStored); if not ok then state.energy = 0 end
    ok, state.max_energy = safe_call(state.gate.getMaxEnergyStored); if not ok then state.max_energy = 0 end
    ok, state.dialed_address = safe_call(state.gate.getDialedAddress); if not ok then state.dialed_address = nil end
    ok, state.gate_address = safe_call(state.gate.getStargateAddress); if not ok then state.gate_address = nil end

    if state.gate.getIrisState then
        ok, state.iris_state = safe_call(state.gate.getIrisState); if not ok then state.iris_state = nil end
    end
    if state.gate.getIrisType then
        ok, state.iris_type = safe_call(state.gate.getIrisType); if not ok then state.iris_type = nil end
    end
    if state.gate.getIrisDurability then
        local dok, display, current, maximum = safe_call(state.gate.getIrisDurability)
        if dok then
            state.iris_durability_display, state.iris_durability, state.iris_max_durability = display, current, maximum
        else
            state.iris_durability_display, state.iris_durability, state.iris_max_durability = nil, nil, nil
        end
    end

    -- A refresh may observe the terminal state before the state-change event is consumed.
    if state.iris_toggle_pending then
        local s = tostring(state.iris_state or ""):upper()
        if s == "OPENED" or s == "CLOSED" then
            if (state.iris_pending_direction == "OPEN" and s == "OPENED") or
               (state.iris_pending_direction == "CLOSE" and s == "CLOSED") then
                state.iris_toggle_pending, state.iris_pending_direction = false, nil
            end
        end
    end
    return true
end

local function find_gate()
    local gate = peripheral.find("stargate")
    if gate then return gate, "stargate" end
    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        if wrapped and wrapped.getGateStatus and wrapped.getEnergyStored and wrapped.dialAddress then
            return wrapped, name
        end
    end
end

local function ensure_gate()
    if state.gate then
        local ok = pcall(state.gate.getGateStatus)
        if ok then return true end
    end
    local gate, name = find_gate()
    if not gate then
        state.gate, state.gate_name, state.connected = nil, nil, false
        return false
    end
    state.gate, state.gate_name, state.connected = gate, name, true
    log_event("Gate connection established: " .. tostring(name))
    refresh_gate()
    return true
end

local function iris_bucket()
    local value = tostring(state.iris_state or ""):upper()
    if value == "OPENED" then return "open" end
    if value == "CLOSED" then return "closed" end
    if value == "OPENING" or value == "CLOSING" then return "transition" end
    return "unknown"
end

local function toggle_iris(direction, reason)
    if not state.gate or not state.gate.toggleIris then
        log_event("IRIS " .. direction .. " FAILED: toggleIris() unavailable")
        return false
    end
    if state.iris_toggle_pending then
        log_event("IRIS " .. direction .. " REFUSED: toggle already in progress")
        return false
    end

    refresh_gate()
    if not state.connected or not state.iris_state then
        log_event("IRIS " .. direction .. " REFUSED: iris state unknown")
        return false
    end

    local bucket = iris_bucket()
    if bucket == "unknown" or bucket == "transition" then
        log_event("IRIS " .. direction .. " REFUSED: iris state is " .. bucket)
        return false
    end
    if direction == "CLOSE" and bucket == "closed" then return true end
    if direction == "OPEN" and bucket == "open" then return true end
    if (direction == "CLOSE" and bucket ~= "open") or (direction == "OPEN" and bucket ~= "closed") then
        log_event("IRIS " .. direction .. " REFUSED: state changed before command")
        return false
    end

    -- Set BEFORE the JSG call: toggleIris is a main-thread call and may yield.
    state.iris_toggle_pending = true
    state.iris_pending_direction = direction
    local ok, success, code, message = safe_call(state.gate.toggleIris)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        state.iris_toggle_pending, state.iris_pending_direction = false, nil
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

local function dial_saved(index)
    local entry = state.addresses[index]
    if not entry then log_event("DIAL FAILED: no address selected"); return end
    if not ensure_gate() then log_event("DIAL FAILED: gate unavailable"); return end
    refresh_gate()
    if not state.gate or not state.gate.dialAddress then log_event("DIAL FAILED: dialAddress() unavailable"); return end

    local valid, symbols_or_error = validate_address(entry.symbols)
    if not valid then log_event("DIAL FAILED: " .. tostring(symbols_or_error)); return end
    local symbols = symbols_or_error

    if type(state.dialed_address) == "table" and #state.dialed_address > 0 then
        log_event("DIAL FAILED: gate already has a dialed address"); return
    end

    local ok, success, code, energy_map = safe_call(state.gate.getEnergyRequiredToDial, symbols)
    if not ok then log_event("DIAL PREFLIGHT FAILED: " .. tostring(energy_map)); return end
    if success ~= true then log_event("DIAL PREFLIGHT FAILED: " .. tostring(code or "unknown")); return end
    if type(energy_map) ~= "table" then log_event("DIAL PREFLIGHT FAILED: malformed energy response"); return end
    if energy_map.canOpen ~= true then log_event("DIAL PREFLIGHT FAILED: insufficient energy"); return end

    ok, success, code, message = safe_call(state.gate.dialAddress, symbols)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then log_event("DIAL FAILED: " .. detail); return end

    state.dialing, state.dial_chevrons, state.dial_target_count = true, 0, #symbols
    state.dial_last_symbol, state.incoming, state.incoming_address, state.alert = nil, false, nil, nil
    log_event("DIAL ACCEPTED: " .. tostring(entry.name) .. " [" .. address_to_string(symbols) .. "]")
end

local function abort_dial()
    if not state.gate or not state.gate.abortDialing then log_event("ABORT FAILED: unavailable"); return false end
    local ok, success, code, message = safe_call(state.gate.abortDialing)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then log_event("ABORT FAILED: " .. detail); return false end
    log_event("DIAL ABORT ACCEPTED"); return true
end

local function close_gate()
    if not state.gate or not state.gate.disengageGate then log_event("CLOSE FAILED: unavailable"); return false end
    local ok, success, code, message = safe_call(state.gate.disengageGate)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then log_event("CLOSE FAILED: " .. detail); return false end
    log_event("GATE CLOSE ACCEPTED"); return true
end

local function add_address()
    term.clear(); term.setCursorPos(1,1); print("=== ADD ADDRESS ==="); print("")
    write("Name: "); local name = trim(read())
    if name == "" then log_event("ADDRESS ADD CANCELLED"); return end
    write("Symbols (7-9, separated by spaces): "); local raw = read()
    local valid, normalized_or_error = validate_address(normalize_symbols(raw))
    if not valid then log_event("ADDRESS ADD FAILED: " .. tostring(normalized_or_error)); return end
    for _, e in ipairs(state.addresses) do
        if same_address(e.symbols, normalized_or_error) then log_event("ADDRESS ADD FAILED: duplicate address"); return end
    end
    table.insert(state.addresses, { name = name, symbols = normalized_or_error })
    state.selected_address = #state.addresses; save_data(); log_event("ADDRESS ADDED: " .. name)
end

local function edit_address(index)
    local entry = state.addresses[index]; if not entry then return end
    term.clear(); print("=== EDIT ADDRESS ==="); print("Current name: " .. tostring(entry.name))
    write("New name (blank = keep): "); local name = trim(read()); if name ~= "" then entry.name = name end
    print("Current symbols: " .. address_to_string(entry.symbols)); write("New symbols (blank = keep): ")
    local raw = read()
    if trim(raw) ~= "" then
        local valid, normalized_or_error = validate_address(normalize_symbols(raw))
        if not valid then log_event("ADDRESS EDIT FAILED: " .. tostring(normalized_or_error)); return end
        for i, e in ipairs(state.addresses) do
            if i ~= index and same_address(e.symbols, normalized_or_error) then log_event("ADDRESS EDIT FAILED: duplicate address"); return end
        end
        entry.symbols = normalized_or_error
    end
    save_data(); log_event("ADDRESS EDITED: " .. tostring(entry.name))
end

local function remove_address(index)
    local entry = state.addresses[index]; if not entry then return end
    table.remove(state.addresses, index)
    if #state.addresses == 0 then state.selected_address = 1 else state.selected_address = math.min(state.selected_address, #state.addresses) end
    save_data(); log_event("ADDRESS REMOVED: " .. tostring(entry.name))
end

local function status_text()
    if not state.connected then return "OFFLINE" end
    return state.gate_merged and tostring(state.gate_status or "UNKNOWN"):upper() or "NOT MERGED"
end

local function energy_text()
    if state.max_energy <= 0 then return "N/A" end
    return string.format("%d / %d (%d%%)", state.energy, state.max_energy, math.floor((state.energy / state.max_energy) * 100 + 0.5))
end

local function draw_header(title)
    term.setCursorPos(1,1); term.clearLine(); term.write("S T A R G A T E   C O M M A N D")
    term.setCursorPos(1,2); term.clearLine(); term.write("================================")
    term.setCursorPos(1,3); term.clearLine(); term.write("[ " .. title .. " ]")
end

local function draw_main()
    term.clear(); draw_header("MAIN CONTROL")
    term.setCursorPos(2,5); term.write("GATE:   " .. status_text())
    term.setCursorPos(2,6); term.write("ENERGY: " .. energy_text())
    term.setCursorPos(2,7); term.write("IRIS:   " .. tostring(state.iris_state or "UNKNOWN") .. " [" .. state.mode .. "]")
    term.setCursorPos(2,9); term.write("LOCAL:  " .. address_to_string(state.gate_address))
    term.setCursorPos(2,10); term.write("DIALED: " .. address_to_string(state.dialed_address))
    if state.dialing then
        term.setCursorPos(2,12); term.write(string.format("DIALING: %d / %d", state.dial_chevrons, state.dial_target_count))
        term.setCursorPos(2,13); term.write("LAST: " .. tostring(state.dial_last_symbol or "SPINNING"))
    end
    if state.incoming then
        term.setCursorPos(2,15); term.write("!!! INCOMING WORMHOLE !!!")
        term.setCursorPos(2,16); term.write("SOURCE: " .. tostring(state.incoming_address or "UNKNOWN"))
    end
    if state.alert then term.setCursorPos(2,17); term.write("ALERT: " .. tostring(state.alert):sub(1, 60)) end
    term.setCursorPos(2,19); term.write("1 ADDRESS BOOK")
    term.setCursorPos(2,20); term.write("2 DIAL SELECTED")
    term.setCursorPos(2,21); term.write("3 IRIS CONTROL")
    term.setCursorPos(2,22); term.write("4 EVENT LOG")
    term.setCursorPos(2,23); term.write("5 REFRESH")
    term.setCursorPos(2,24); term.write("Q SHUTDOWN")
    term.setCursorPos(2,26); term.write("LAST: " .. tostring(state.last_event):sub(1,55))
end

local function draw_addresses()
    term.clear(); draw_header("ADDRESS BOOK")
    if #state.addresses == 0 then term.setCursorPos(2,5); term.write("NO SAVED ADDRESSES") end
    local first = math.max(1, state.selected_address - 8); local last = math.min(#state.addresses, first + 14); local row = 5
    for i = first, last do
        local e = state.addresses[i]; term.setCursorPos(2,row)
        term.write(string.format("%s %02d %-18s %s", i == state.selected_address and ">" or " ", i, tostring(e.name):sub(1,18), address_to_string(e.symbols):sub(1,28))); row = row + 1
    end
    term.setCursorPos(2,22); term.write("UP/DOWN SELECT")
    term.setCursorPos(2,23); term.write("D DIAL  A ADD  E EDIT  R REMOVE")
    term.setCursorPos(2,24); term.write("ESC BACK")
end

local function draw_iris()
    term.clear(); draw_header("IRIS CONTROL")
    term.setCursorPos(2,5); term.write("STATE: " .. tostring(state.iris_state or "UNKNOWN"))
    term.setCursorPos(2,6); term.write("TYPE:  " .. tostring(state.iris_type or "UNKNOWN"))
    term.setCursorPos(2,7); term.write("DUR:   " .. tostring(state.iris_durability_display or "UNKNOWN"))
    term.setCursorPos(2,9); term.write("MODE:  " .. state.mode)
    term.setCursorPos(2,11); term.write("O OPEN")
    term.setCursorPos(2,12); term.write("C CLOSE")
    term.setCursorPos(2,13); term.write("A AUTO/MANUAL")
    term.setCursorPos(2,14); term.write("ESC BACK")
    term.setCursorPos(2,17); term.write("AUTO closes only when the current iris state is verified OPEN.")
    term.setCursorPos(2,18); term.write("UNKNOWN/TRANSITION states are never blindly toggled.")
end

local function draw_log()
    term.clear(); draw_header("EVENT LOG")
    local start = math.max(1, #state.events - 17); local row = 5
    for i = start, #state.events do term.setCursorPos(2,row); term.write(state.events[i]:sub(1,76)); row = row + 1; if row > 22 then break end end
    term.setCursorPos(2,24); term.write("ESC BACK")
end

local function address_menu()
    while state.running do
        draw_addresses()
        local e, key = os.pullEvent("key")
        if key == keys.up and #state.addresses > 0 then state.selected_address = math.max(1, state.selected_address - 1)
        elseif key == keys.down and #state.addresses > 0 then state.selected_address = math.min(#state.addresses, state.selected_address + 1)
        elseif key == keys.d then dial_saved(state.selected_address)
        elseif key == keys.a then add_address()
        elseif key == keys.e then edit_address(state.selected_address)
        elseif key == keys.r then remove_address(state.selected_address)
        elseif key == keys.esc then return end
    end
end

local function iris_menu()
    while state.running do
        draw_iris()
        local _, key = os.pullEvent("key")
        if key == keys.o then open_iris("manual")
        elseif key == keys.c then close_iris("manual")
        elseif key == keys.a then state.mode = state.mode == "AUTO" and "MANUAL" or "AUTO"; save_data(); log_event("IRIS MODE: " .. state.mode)
        elseif key == keys.esc then return end
    end
end

local function log_menu()
    while state.running do
        draw_log()
        local _, key = os.pullEvent("key")
        if key == keys.esc then return end
    end
end

local function ui_loop()
    while state.running do
        draw_main()
        local _, key = os.pullEvent("key")
        if key == keys.one then address_menu()
        elseif key == keys.two then dial_saved(state.selected_address)
        elseif key == keys.three then iris_menu()
        elseif key == keys.four then log_menu()
        elseif key == keys.five then ensure_gate(); refresh_gate(); log_event("Manual refresh requested")
        elseif key == keys.q then state.running = false; os.queueEvent("sgc_shutdown")
        end
    end
end

local function update_from_event(event, ...)
    if event == EVENTS.INCOMING then
        local size = ...
        state.incoming, state.alert = true, "UNSCHEDULED INCOMING ACTIVATION"
        state.incoming_address = "ADDRESS SIZE " .. tostring(size or "UNKNOWN")
        log_event("INCOMING DIAL DETECTED: " .. tostring(size or "UNKNOWN") .. " symbols")
        if CONFIG.auto_iris and state.mode == "AUTO" then close_iris("incoming wormhole") end

    elseif event == EVENTS.OPEN_FULLY then
        local address, initiating = ...
        state.incoming = initiating ~= true
        state.incoming_address = address_to_string(address)
        state.alert = state.incoming and "INCOMING CONNECTION ACTIVE" or nil
        state.dialing = false
        log_event((initiating == true and "OUTGOING" or "INCOMING") .. " WORMHOLE OPEN: " .. address_to_string(address))

    elseif event == EVENTS.CLOSE_FULLY then
        local address, reason, initiating = ...
        state.incoming = false; state.alert = nil; state.dialing = false
        log_event((initiating == true and "OUTGOING" or "INCOMING") .. " WORMHOLE CLOSED: " .. address_to_string(address) .. " [" .. tostring(reason) .. "]")

    elseif event == EVENTS.TRAVELER then
        local inbound, entity_type, uuid, name = ...
        if inbound == true then
            log_event("TRAVELER INBOUND: " .. tostring(name or entity_type or "unknown") .. " (" .. tostring(uuid or "no UUID") .. ")")
        else
            log_event("TRAVELER OUTBOUND: " .. tostring(name or entity_type or "unknown"))
        end

    elseif event == EVENTS.IRIS_STATE then
        local old_state, new_state = ...
        state.iris_state = new_state
        local upper = tostring(new_state or "ERROR"):upper()
        if (upper == "OPENED" or upper == "CLOSED") and state.iris_toggle_pending then
            state.iris_toggle_pending = false; state.iris_pending_direction = nil
        end
        log_event("IRIS STATE: " .. tostring(old_state) .. " -> " .. tostring(new_state))

    elseif event == EVENTS.IRIS_TOGGLED then
        local closed = ...
        log_event("IRIS TOGGLED: " .. tostring(closed))

    elseif event == EVENTS.IRIS_CODE then
        -- Never log the plaintext GDO/iris code.
        log_event("GDO/IRIS CODE RECEIVED")

    elseif event == EVENTS.IRIS_DESTROYED then
        state.iris_toggle_pending, state.iris_pending_direction = false, nil
        state.alert = "IRIS DESTROYED"
        log_event("IRIS DESTROYED")

    elseif event == EVENTS.IRIS_POWER then
        log_event("IRIS OUT OF POWER")
        state.alert = "IRIS OUT OF POWER"

    elseif event == EVENTS.IRIS_HIT then
        log_event("IRIS HIT")

    elseif event == EVENTS.IRIS_DAMAGED then
        local source, amount = ...
        log_event("IRIS DAMAGED: " .. tostring(source) .. " amount " .. tostring(amount))

    elseif event == EVENTS.SPIN_START then
        local direction, speed = ...
        state.ring_spinning, state.ring_direction, state.ring_speed = true, direction, speed
        log_event("RING SPIN START: " .. tostring(direction) .. " @ " .. tostring(speed))

    elseif event == EVENTS.SPIN_STOP then
        local top = ...
        state.ring_spinning = false; state.ring_direction, state.ring_speed = nil, nil
        log_event("RING SPIN STOP: " .. tostring(top or "NONE"))

    elseif event == EVENTS.CHEVRON then
        local source, symbol, chevron, count = ...
        state.dial_chevrons = tonumber(count) or state.dial_chevrons
        state.dial_last_symbol = symbol
        log_event("CHEVRON " .. tostring(chevron) .. " ENGAGED: " .. tostring(symbol) .. " [" .. tostring(source) .. "]")

    elseif event == EVENTS.CHEVRON_OPEN or event == EVENTS.CHEVRON_LIT or event == EVENTS.CHEVRON_CLOSE or event == EVENTS.CHEVRON_DIM then
        local chevron = ...
        log_event("CHEVRON EVENT: " .. event .. " #" .. tostring(chevron))

    elseif event == EVENTS.OPEN_FAILED then
        local reason = ...
        state.dialing = false; state.alert = "GATE OPEN FAILED"
        log_event("GATE OPEN FAILED: " .. tostring(reason))

    elseif event == EVENTS.CLOSE_FAILED then
        local reason = ...
        log_event("GATE CLOSE FAILED: " .. tostring(reason))
    end
end

-- Dedicated security/event loop. This coroutine never enters a UI read loop.
local function security_loop()
    while state.running do
        local packed = { os.pullEvent() }
        local event = packed[1]
        if event == "sgc_shutdown" then return end
        local ok, err = pcall(function()
            update_from_event(event, table.unpack(packed, 2))
        end)
        if not ok then log_event("EVENT HANDLER ERROR: " .. tostring(err)) end
    end
end

local function refresh_loop()
    while state.running do
        local timer = os.startTimer(CONFIG.refresh_interval)
        while state.running do
            local event, id = os.pullEvent()
            if event == "sgc_shutdown" then return end
            if event == "timer" and id == timer then break end
        end
        if not state.running then return end
        ensure_gate(); refresh_gate()
    end
end

local function startup_security()
    ensure_gate()
    refresh_gate()
    if CONFIG.auto_iris and state.mode == "AUTO" then
        local bucket = iris_bucket()
        if bucket == "open" then close_iris("startup fail-closed")
        elseif bucket == "unknown" or bucket == "transition" then
            log_event("STARTUP: iris state not safely actionable (" .. bucket .. ")")
        elseif bucket == "closed" then
            log_event("STARTUP: iris verified CLOSED")
        end
    end
end

load_data(); load_events(); log_event("SYSTEM STARTING")
startup_security()
parallel.waitForAny(ui_loop, security_loop, refresh_loop)
state.running = false
os.queueEvent("sgc_shutdown")
log_event("SYSTEM STOPPED")
