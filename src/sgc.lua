-- SGC-CC
-- Stargate Command ComputerCraft control system for JSG
-- Target: Minecraft 1.20.1 Forge + Just Stargate Mod + CC:Tweaked
--
-- API rule: only use JSG methods/events verified against the 1.20.1 source.
-- Temperature and direct JSG siren playback are intentionally not implemented.

local CONFIG = {
    data_file = "sgc_data",
    event_log_file = "sgc_events",
    max_log_entries = 200,
    refresh_interval = 0.5,
    auto_iris = true,
}

local state = {
    gate = nil,
    connected = false,
    gate_name = nil,

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

    last_event = "System initialized",
    events = {},
    addresses = {},
    selected_address = 1,
    mode = "AUTO",

    running = true,
    current_screen = "MAIN",
}

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

local function now()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function serialize(data)
    return textutils.serialize(data)
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

    handle.write(serialize(data))
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

    if state.selected_address > #state.addresses then
        state.selected_address = math.max(1, #state.addresses)
    end
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

local function jsg_result(ok, success, code, message)
    if not ok then
        return false, "JSG/CC exception: " .. tostring(message)
    end

    if success ~= true then
        return false, tostring(code or "jsg_failure") .. ": " .. tostring(message or "JSG rejected the operation")
    end

    return true, message
end

local function address_to_string(address)
    if type(address) ~= "table" then
        return "UNKNOWN"
    end

    local parts = {}
    for i, symbol in ipairs(address) do
        parts[i] = tostring(symbol)
    end

    if #parts == 0 then
        return "NONE"
    end

    return table.concat(parts, " - ")
end

local function same_address(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if #a ~= #b then
        return false
    end

    for i = 1, #a do
        if tostring(a[i]):lower() ~= tostring(b[i]):lower() then
            return false
        end
    end

    return true
end

local function normalize_symbols(raw)
    local symbols = {}
    for token in tostring(raw):gmatch("%S+") do
        table.insert(symbols, token)
    end
    return symbols
end

local function get_symbol_map()
    if not state.gate or not state.gate.getSymbolsMap then
        return nil
    end

    local ok, symbols = safe_call(state.gate.getSymbolsMap)
    if not ok or type(symbols) ~= "table" then
        return nil
    end

    return symbols
end

local function symbol_is_valid(symbol, symbol_map)
    local needle = tostring(symbol):lower()
    for _, valid in ipairs(symbol_map or {}) do
        if tostring(valid):lower() == needle then
            return true, tostring(valid)
        end
    end
    return false, symbol
end

local function validate_address_symbols(symbols, require_full)
    if type(symbols) ~= "table" then
        return false, "Address is not a table"
    end

    if #symbols < 7 or #symbols > 9 then
        return false, "Address must contain 7-9 symbols"
    end

    local symbol_map = get_symbol_map()
    if not symbol_map then
        return false, "Unable to read the gate symbol map"
    end

    local seen = {}
    local normalized = {}

    for i, symbol in ipairs(symbols) do
        local valid, canonical = symbol_is_valid(symbol, symbol_map)
        if not valid then
            return false, "Invalid symbol at position " .. tostring(i) .. ": " .. tostring(symbol)
        end

        local key = canonical:lower()
        if seen[key] then
            return false, "Duplicate symbol: " .. canonical
        end

        seen[key] = true
        normalized[i] = canonical
    end

    if require_full and #normalized ~= #symbols then
        return false, "Address validation failed"
    end

    return true, normalized
end

local function refresh_gate()
    if not state.gate then
        state.connected = false
        state.gate_merged = false
        state.gate_status = nil
        state.gate_initiating = nil
        state.energy = 0
        state.max_energy = 0
        state.iris_state = nil
        state.iris_type = nil
        state.iris_durability_display = nil
        state.iris_durability = nil
        state.iris_max_durability = nil
        return false
    end

    local ok, merged, status, initiating = safe_call(state.gate.getGateStatus)
    if not ok then
        state.gate = nil
        state.connected = false
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
        state.connected = false
        return false
    end

    state.gate = gate
    state.gate_name = name
    state.connected = true
    log_event("Gate connection established: " .. tostring(name))
    refresh_gate()

    if CONFIG.auto_iris and state.mode == "AUTO" then
        -- Startup/recovery is fail-closed when the gate exposes OC iris control.
        local iris_value = tostring(state.iris_state or ""):lower()
        if iris_value == "opened" or iris_value == "opening" then
            -- Do not assume the command succeeded: close_iris checks JSG's result boolean.
            return true
        end
    end

    return true
end

local function iris_is_closed()
    local value = tostring(state.iris_state or ""):lower()
    return value == "closed" or value == "closing"
end

local function iris_is_open()
    local value = tostring(state.iris_state or ""):lower()
    return value == "opened" or value == "opening"
end

local function close_iris(reason)
    if not state.gate or not state.gate.toggleIris then
        log_event("IRIS CLOSE FAILED: no supported iris control")
        return false
    end

    refresh_gate()

    if iris_is_closed() then
        return true
    end

    if tostring(state.iris_type or ""):lower() == "null" then
        log_event("IRIS CLOSE FAILED: no iris installed")
        return false
    end

    local iris_type = tostring(state.iris_type or ""):lower()
    if iris_type ~= "oc" then
        log_event("IRIS CLOSE FAILED: iris mode/type is not OC")
        return false
    end

    local ok, success, code, message = safe_call(state.gate.toggleIris)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        log_event("IRIS CLOSE FAILED: " .. detail)
        return false
    end

    log_event("IRIS CLOSE ACCEPTED: " .. tostring(reason or "security"))
    return true
end

local function open_iris(reason)
    if not state.gate or not state.gate.toggleIris then
        log_event("IRIS OPEN FAILED: no supported iris control")
        return false
    end

    refresh_gate()

    if iris_is_open() then
        return true
    end

    local iris_type = tostring(state.iris_type or ""):lower()
    if iris_type ~= "oc" then
        log_event("IRIS OPEN FAILED: iris mode/type is not OC")
        return false
    end

    local ok, success, code, message = safe_call(state.gate.toggleIris)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        log_event("IRIS OPEN FAILED: " .. detail)
        return false
    end

    log_event("IRIS OPEN ACCEPTED: " .. tostring(reason or "manual"))
    return true
end

local function dial_saved(index)
    local entry = state.addresses[index]
    if not entry then
        log_event("DIAL FAILED: no address selected")
        return
    end

    ensure_gate()
    refresh_gate()

    if not state.gate or not state.gate.dialAddress then
        log_event("DIAL FAILED: dialAddress() unavailable")
        return
    end

    local valid, symbols_or_error = validate_address_symbols(entry.symbols, true)
    if not valid then
        log_event("DIAL FAILED: " .. tostring(symbols_or_error))
        return
    end

    local symbols = symbols_or_error

    if state.dialed_address and #state.dialed_address > 0 then
        log_event("DIAL FAILED: gate already has a dialed address")
        return
    end

    local energy_ok, energy_success, energy_code, energy_payload = safe_call(
        state.gate.getEnergyRequiredToDial,
        symbols
    )

    if not energy_ok then
        log_event("DIAL PREFLIGHT FAILED: " .. tostring(energy_payload))
        return
    end

    if energy_success ~= true then
        log_event("DIAL PREFLIGHT FAILED: " .. tostring(energy_code or "unknown") .. ": " .. tostring(energy_payload or "JSG rejected address"))
        return
    end

    local energy_map = energy_payload
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
    state.alert = nil

    log_event("DIAL ACCEPTED: " .. tostring(entry.name) .. " [" .. address_to_string(symbols) .. "]")
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

    write("Symbols (7-9, separated by spaces): ")
    local raw = read()
    local symbols = normalize_symbols(raw)

    local valid, normalized_or_error = validate_address_symbols(symbols, true)
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
    write("New name (blank = keep): ")
    local name = trim(read())
    if name ~= "" then
        entry.name = name
    end

    print("Current symbols: " .. address_to_string(entry.symbols))
    write("New symbols (blank = keep): ")
    local raw = read()
    if trim(raw) ~= "" then
        local symbols = normalize_symbols(raw)
        local valid, normalized_or_error = validate_address_symbols(symbols, true)
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
    local answer = trim(read())

    if answer == "YES" then
        table.remove(state.addresses, index)
        state.selected_address = math.min(state.selected_address, math.max(1, #state.addresses))
        save_data()
        log_event("ADDRESS REMOVED: " .. tostring(entry.name))
    else
        log_event("ADDRESS REMOVE CANCELLED")
    end
end

local function handle_jsg_event(event, ...)
    local args = {...}

    if event == "stargate_wormhole_incoming" then
        local address_size = args[1]
        state.incoming = true
        state.incoming_address = "INCOMING DIAL (" .. tostring(address_size or "?") .. " SYMBOLS)"
        state.alert = "!!! INCOMING WORMHOLE !!!"
        log_event("INCOMING WORMHOLE DETECTED: " .. tostring(address_size or "unknown") .. " symbols")

        if CONFIG.auto_iris and state.mode == "AUTO" then
            close_iris("incoming wormhole")
        end

    elseif event == "stargate_chevron_engaged" then
        local source = args[1]
        local symbol = args[2]
        local chevron = args[3]
        local address_size = args[4]

        state.dial_chevrons = tonumber(address_size) or (tonumber(chevron) or state.dial_chevrons)
        state.dial_target_count = math.max(state.dial_target_count, state.dial_chevrons)
        state.dial_last_symbol = symbol

        if source == "INCOMING_WORMHOLE" then
            state.incoming = true
            state.alert = "!!! INCOMING WORMHOLE !!!"
        end

        log_event("CHEVRON " .. tostring(chevron or "?") .. " ENGAGED: " .. tostring(symbol or "?") .. " [" .. tostring(source or "?") .. "]")

    elseif event == "stargate_spin_start" then
        state.ring_spinning = true
        state.ring_direction = args[1]
        state.ring_speed = args[2]
        log_event("RING SPIN START: " .. tostring(args[1] or "?") .. " @ " .. tostring(args[2] or "?") )

    elseif event == "stargate_spin_stop" then
        state.ring_spinning = false
        log_event("RING SPIN STOP: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_attempt_open_failed" then
        state.dialing = false
        log_event("GATE OPEN FAILED: " .. tostring(args[1] or "unknown") .. " / " .. tostring(args[2] or "unknown"))

    elseif event == "stargate_attempt_close_failed" then
        log_event("GATE CLOSE FAILED: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_wormhole_open_fully" then
        local address = args[1]
        local initiating = args[2]
        state.dialing = false
        state.dialed_address = address
        state.gate_initiating = initiating

        if initiating == false then
            state.incoming = true
            if type(address) == "table" then
                state.incoming_address = address_to_string(address)
            end
        else
            state.incoming = false
            state.alert = nil
        end

        log_event((initiating == false and "INCOMING" or "OUTGOING") .. " WORMHOLE OPEN: " .. address_to_string(address))

    elseif event == "stargate_wormhole_close_fully" then
        local address = args[1]
        local reason = args[2]
        local initiating = args[3]

        state.dialing = false
        state.ring_spinning = false
        state.dialed_address = nil
        state.incoming = false
        state.incoming_address = nil
        state.alert = nil

        log_event("WORMHOLE CLOSED: " .. address_to_string(address) .. " / " .. tostring(reason or "unknown") .. " / initiating=" .. tostring(initiating))

    elseif event == "stargate_wormhole_subspace_disconnected" then
        log_event("WORMHOLE SUBSPACE DISCONNECTED")

    elseif event == "stargate_event_horizon_traveler" then
        local inbound = args[1]
        local entity_type = args[2]
        local player_name = args[4]

        if inbound == true then
            if player_name then
                log_event("INBOUND TRAVELER: " .. tostring(player_name) .. " (" .. tostring(entity_type) .. ")")
            else
                log_event("INBOUND TRAVELER: " .. tostring(entity_type or "unknown"))
            end
        else
            log_event("OUTBOUND TRAVELER: " .. tostring(player_name or entity_type or "unknown"))
        end

    elseif event == "stargate_iris_code_received" then
        -- Never write the plaintext code to the log or screen.
        log_event("GDO/IRIS CODE RECEIVED: JSG received a code")

    elseif event == "stargate_iris_state_changed" then
        local old_state = args[1]
        local new_state = args[2]
        state.iris_state = new_state
        log_event("IRIS STATE: " .. tostring(old_state) .. " -> " .. tostring(new_state))

    elseif event == "stargate_iris_toggled" then
        log_event("IRIS TOGGLE EVENT: close=" .. tostring(args[1]))

    elseif event == "stargate_iris_damaged" then
        log_event("IRIS DAMAGED: " .. tostring(args[1] or "unknown") .. " amount=" .. tostring(args[2] or "?"))

    elseif event == "stargate_iris_hit" then
        log_event("IRIS HIT")

    elseif event == "stargate_iris_destroyed" then
        log_event("!!! IRIS DESTROYED !!!: " .. tostring(args[1] or "unknown"))
        state.alert = "!!! IRIS DESTROYED !!!"

    elseif event == "stargate_iris_out_of_power" then
        log_event("!!! IRIS OUT OF POWER !!!")
        state.alert = "!!! IRIS OUT OF POWER !!!"

    elseif event == "stargate_iris_type_changed" then
        state.iris_type = args[2]
        log_event("IRIS TYPE CHANGED: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))

    elseif event == "stargate_attempt_open_failed" then
        log_event("GATE OPEN ATTEMPT FAILED: " .. tostring(args[1] or "unknown"))
    end
end

local function security_loop()
    while state.running do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "peripheral" or event == "peripheral_detach" then
            ensure_gate()
            refresh_gate()

        elseif event == "stargate_wormhole_incoming"
            or event == "stargate_chevron_engaged"
            or event == "stargate_spin_start"
            or event == "stargate_spin_stop"
            or event == "stargate_attempt_open_failed"
            or event == "stargate_attempt_close_failed"
            or event == "stargate_wormhole_open_fully"
            or event == "stargate_wormhole_close_fully"
            or event == "stargate_wormhole_subspace_disconnected"
            or event == "stargate_event_horizon_traveler"
            or event == "stargate_iris_code_received"
            or event == "stargate_iris_state_changed"
            or event == "stargate_iris_toggled"
            or event == "stargate_iris_damaged"
            or event == "stargate_iris_hit"
            or event == "stargate_iris_destroyed"
            or event == "stargate_iris_out_of_power"
            or event == "stargate_iris_type_changed" then
            handle_jsg_event(event, p1, p2, p3, p4)
        end
    end
end

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

    local pct = math.floor((state.energy / state.max_energy) * 100 + 0.5)
    return string.format("%d / %d (%d%%)", state.energy, state.max_energy, pct)
end

local function iris_text()
    return tostring(state.iris_state or "UNKNOWN"):upper()
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
    term.write("IRIS:   " .. iris_text() .. "  [" .. state.mode .. "]")

    term.setCursorPos(2, 9)
    term.write("LOCAL ADDRESS:")
    term.setCursorPos(4, 10)
    term.write(address_to_string(nil))

    if type(state.gate_address) == "table" then
        local first_key = nil
        for key in pairs(state.gate_address) do
            first_key = key
            break
        end
        if first_key and type(state.gate_address[first_key]) == "table" then
            term.setCursorPos(4, 10)
            term.write(address_to_string(state.gate_address[first_key]):sub(1, 74))
        end
    end

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
            local marker = (i == state.selected_address) and ">" or " "
            term.setCursorPos(2, row)
            term.write(string.format(
                "%s %02d %-18s %s",
                marker,
                i,
                tostring(entry.name):sub(1, 18),
                address_to_string(entry.symbols):sub(1, 28)
            ))
            row = row + 1
        end
    end

    term.setCursorPos(2, 22)
    term.write("UP/DOWN SELECT")
    term.setCursorPos(2, 23)
    term.write("D DIAL   A ADD   R REMOVE")
    term.setCursorPos(2, 24)
    term.write("E EDIT   ESC BACK")
end

local function draw_iris()
    term.clear()
    header("IRIS CONTROL")

    term.setCursorPos(2, 5)
    term.write("STATE: " .. iris_text())
    term.setCursorPos(2, 6)
    term.write("TYPE:  " .. tostring(state.iris_type or "UNKNOWN"))

    term.setCursorPos(2, 7)
    term.write("MODE:  " .. state.mode)

    if state.iris_durability_display then
        term.setCursorPos(2, 8)
        term.write("DURABILITY: " .. tostring(state.iris_durability_display))
    end

    if state.iris_durability and state.iris_max_durability then
        term.setCursorPos(2, 9)
        term.write("CURRENT/MAX: " .. tostring(state.iris_durability) .. " / " .. tostring(state.iris_max_durability))
    end

    term.setCursorPos(2, 12)
    term.write("O OPEN")
    term.setCursorPos(2, 13)
    term.write("C CLOSE")
    term.setCursorPos(2, 14)
    term.write("A TOGGLE AUTO/MANUAL")
    term.setCursorPos(2, 15)
    term.write("ESC BACK")

    term.setCursorPos(2, 18)
    term.write("AUTO closes the iris on incoming activation.")
    term.setCursorPos(2, 19)
    term.write("JSG remains responsible for native GDO/iris-code processing.")
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
        if row > 24 then
            break
        end
    end

    term.setCursorPos(2, 26)
    term.write("ESC BACK")
end

local function address_menu()
    while state.running do
        draw_addresses()
        local event, key = os.pullEvent("key")

        if key == keys.up then
            if #state.addresses > 0 then
                state.selected_address = math.max(1, state.selected_address - 1)
            end
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
        elseif key == keys.esc then
            return
        end
    end
end

local function iris_menu()
    while state.running do
        refresh_gate()
        draw_iris()
        local event, key = os.pullEvent("key")

        if key == keys.o then
            if state.mode == "MANUAL" then
                open_iris("manual control")
            else
                log_event("MANUAL OPEN BLOCKED: switch iris mode to MANUAL first")
            end
        elseif key == keys.c then
            close_iris("manual control")
        elseif key == keys.a then
            if state.mode == "AUTO" then
                state.mode = "MANUAL"
            else
                state.mode = "AUTO"
                if state.incoming then
                    close_iris("AUTO mode enabled during incoming activation")
                end
            end
            save_data()
            log_event("IRIS MODE: " .. state.mode)
        elseif key == keys.esc then
            return
        end
    end
end

local function log_menu()
    while state.running do
        draw_log()
        local event, key = os.pullEvent("key")
        if key == keys.esc then
            return
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

local function ui_loop()
    while state.running do
        state.current_screen = "MAIN"
        draw_main()

        local event, key = os.pullEvent("key")

        if key == keys.one then
            state.current_screen = "ADDRESS"
            address_menu()
        elseif key == keys.two then
            dial_saved(state.selected_address)
        elseif key == keys.three then
            state.current_screen = "IRIS"
            iris_menu()
        elseif key == keys.four then
            state.current_screen = "LOG"
            log_menu()
        elseif key == keys.five then
            ensure_gate()
            refresh_gate()
            log_event("MANUAL REFRESH")
        elseif key == keys.q then
            state.running = false
        end
    end
end

local function startup()
    term.setCursorBlink(false)
    term.clear()

    load_data()
    load_events()
    log_event("SGC SYSTEM STARTING")

    if ensure_gate() then
        refresh_gate()
        log_event("Gate status at startup: " .. status_text())

        if CONFIG.auto_iris and state.mode == "AUTO" then
            if iris_is_open() then
                close_iris("startup fail-closed")
            end
        end
    else
        log_event("NO STARGATE PERIPHERAL FOUND")
    end
end

startup()
parallel.waitForAny(security_loop, refresh_loop, ui_loop)
state.running = false

save_data()
save_events()
term.clear()
term.setCursorPos(1, 1)
print("SGC system offline.")
