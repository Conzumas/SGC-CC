-- SGC-CC: Stargate Command ComputerCraft control system for JSG
-- Target: Minecraft 1.20.1 Forge + JSG + CC:Tweaked
--
-- This program deliberately uses only JSG APIs verified in JSG_API.md.
-- Temperature and direct JSG siren playback are intentionally not implemented.

local CONFIG = {
    data_file = "sgc_data",
    event_log_file = "sgc_events",
    max_log_entries = 200,
    ui_refresh = 0.5,
    auto_iris = true,
}

local state = {
    gate = nil,
    connected = false,
    gate_status = nil,
    gate_address = nil,
    dialed_address = nil,
    energy = 0,
    max_energy = 0,
    iris_state = nil,
    iris_type = nil,
    iris_durability = nil,
    incoming = false,
    incoming_address = nil,
    alert = nil,
    last_event = "System initialized",
    events = {},
    addresses = {},
    selected_address = 1,
    mode = "AUTO",
}

local function safe_call(fn, ...)
    if not fn then
        return false, "missing method"
    end

    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        return false, tostring(a)
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

local function serialize_data(data)
    if textutils and textutils.serialize then
        return textutils.serialize(data)
    end
    return "return " .. tostring(data)
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
    handle.write(serialize_data(data))
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
end

local function load_events()
    state.events = load_table(CONFIG.event_log_file, {})
    if type(state.events) ~= "table" then
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
    local entry = now() .. "  " .. tostring(message)
    table.insert(state.events, entry)
    while #state.events > CONFIG.max_log_entries do
        table.remove(state.events, 1)
    end
    state.last_event = tostring(message)
    save_events()
end

local function address_to_string(address)
    if type(address) ~= "table" then
        return "UNKNOWN"
    end
    local parts = {}
    for i, symbol in ipairs(address) do
        parts[i] = tostring(symbol)
    end
    return table.concat(parts, "-")
end

local function address_key(address)
    return address_to_string(address)
end

local function refresh_gate()
    if not state.gate then
        state.connected = false
        return
    end

    state.connected = true

    local ok, status = safe_call(state.gate.getGateStatus)
    if ok then
        state.gate_status = status
    end

    ok, state.energy = safe_call(state.gate.getEnergyStored)
    if not ok then state.energy = 0 end

    ok, state.max_energy = safe_call(state.gate.getMaxEnergyStored)
    if not ok then state.max_energy = 0 end

    ok, state.dialed_address = safe_call(state.gate.getDialedAddress)
    if not ok then state.dialed_address = nil end

    ok, state.gate_address = safe_call(state.gate.getStargateAddress)
    if not ok then state.gate_address = nil end

    if state.gate.getIrisState then
        ok, state.iris_state = safe_call(state.gate.getIrisState)
        if not ok then state.iris_state = nil end
    else
        state.iris_state = nil
    end

    if state.gate.getIrisType then
        ok, state.iris_type = safe_call(state.gate.getIrisType)
        if not ok then state.iris_type = nil end
    else
        state.iris_type = nil
    end

    if state.gate.getIrisDurability then
        ok, state.iris_durability = safe_call(state.gate.getIrisDurability)
        if not ok then state.iris_durability = nil end
    else
        state.iris_durability = nil
    end
end

local function find_gate()
    -- JSG exposes its ComputerCraft methods through its own CC integration.
    -- Use peripheral discovery rather than assuming a made-up peripheral name.
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        local wrapped = peripheral.wrap(name)
        if wrapped and wrapped.getGateStatus and wrapped.getEnergyStored then
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
    if gate then
        state.gate = gate
        state.connected = true
        log_event("Gate computer connection established: " .. tostring(name))
        return true
    end

    state.gate = nil
    state.connected = false
    return false
end

local function iris_is_closed()
    if not state.iris_state then
        return false
    end
    local value = string.lower(tostring(state.iris_state))
    return value == "closed" or value == "closing"
end

local function iris_is_open()
    if not state.iris_state then
        return false
    end
    local value = string.lower(tostring(state.iris_state))
    return value == "open" or value == "opening"
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

    if state.iris_type and string.lower(tostring(state.iris_type)) ~= "oc" then
        log_event("IRIS CLOSE FAILED: JSG iris is not in OC mode")
        return false
    end

    local ok, err = safe_call(state.gate.toggleIris)
    if not ok then
        log_event("IRIS CLOSE FAILED: " .. tostring(err))
        return false
    end

    log_event("IRIS CLOSE COMMAND: " .. tostring(reason or "security"))
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

    if state.iris_type and string.lower(tostring(state.iris_type)) ~= "oc" then
        log_event("IRIS OPEN FAILED: JSG iris is not in OC mode")
        return false
    end

    local ok, err = safe_call(state.gate.toggleIris)
    if not ok then
        log_event("IRIS OPEN FAILED: " .. tostring(err))
        return false
    end

    log_event("IRIS OPEN COMMAND: " .. tostring(reason or "manual"))
    return true
end

local function automatic_incoming_security()
    if not CONFIG.auto_iris or state.mode ~= "AUTO" then
        return
    end

    -- Incoming wormhole security is fail-closed: attempt closure immediately.
    close_iris("incoming wormhole")
end

local function dial_saved(index)
    local entry = state.addresses[index]
    if not entry then
        log_event("DIAL FAILED: no address selected")
        return
    end

    if not state.gate or not state.gate.dialAddress then
        log_event("DIAL FAILED: gate dialAddress() unavailable")
        return
    end

    local symbols = entry.symbols
    if type(symbols) ~= "table" or #symbols < 7 then
        log_event("DIAL FAILED: address must contain at least 7 symbols")
        return
    end

    local ok, err = safe_call(state.gate.dialAddress, symbols)
    if not ok then
        log_event("DIAL FAILED: " .. tostring(err))
        return
    end

    log_event("DIAL COMMAND: " .. tostring(entry.name) .. " [" .. address_to_string(symbols) .. "]")
end

local function draw_header(title)
    term.setCursorPos(1, 1)
    term.clearLine()
    term.write("S T A R G A T E   C O M M A N D")
    term.setCursorPos(1, 2)
    term.clearLine()
    term.write("--------------------------------")
    term.setCursorPos(1, 3)
    term.clearLine()
    term.write("[ " .. tostring(title) .. " ]")
end

local function status_text()
    if not state.connected then
        return "OFFLINE"
    end
    if type(state.gate_status) == "table" then
        if state.gate_status[2] then
            return tostring(state.gate_status[2]):upper()
        end
        if state.gate_status.state then
            return tostring(state.gate_status.state):upper()
        end
    end
    return "CONNECTED"
end

local function energy_text()
    if not state.max_energy or state.max_energy <= 0 then
        return "N/A"
    end
    local pct = math.floor((state.energy / state.max_energy) * 100 + 0.5)
    return string.format("%d / %d (%d%%)", state.energy, state.max_energy, pct)
end

local function iris_text()
    if not state.iris_state then
        return "UNKNOWN"
    end
    return tostring(state.iris_state):upper()
end

local function draw_main()
    term.clear()
    draw_header("MAIN CONTROL")

    term.setCursorPos(2, 5)
    term.write("GATE:   " .. status_text())
    term.setCursorPos(2, 6)
    term.write("ENERGY: " .. energy_text())
    term.setCursorPos(2, 7)
    term.write("IRIS:   " .. iris_text() .. "  [" .. state.mode .. "]")

    term.setCursorPos(2, 9)
    term.write("LOCAL ADDRESS:")
    term.setCursorPos(4, 10)
    term.write(address_to_string(state.gate_address))

    term.setCursorPos(2, 12)
    term.write("DIALED ADDRESS:")
    term.setCursorPos(4, 13)
    term.write(address_to_string(state.dialed_address))

    if state.incoming then
        term.setCursorPos(2, 15)
        term.write("!!! INCOMING WORMHOLE !!!")
        term.setCursorPos(4, 16)
        term.write("SOURCE: " .. tostring(state.incoming_address or "UNKNOWN"))
    end

    term.setCursorPos(2, 18)
    term.write("1 ADDRESS BOOK")
    term.setCursorPos(2, 19)
    term.write("2 DIAL SELECTED")
    term.setCursorPos(2, 20)
    term.write("3 IRIS CONTROL")
    term.setCursorPos(2, 21)
    term.write("4 EVENT LOG")
    term.setCursorPos(2, 22)
    term.write("5 REFRESH")
    term.setCursorPos(2, 23)
    term.write("Q SHUTDOWN")

    term.setCursorPos(2, 25)
    term.write("LAST: " .. tostring(state.last_event):sub(1, 55))
end

local function draw_addresses()
    term.clear()
    draw_header("ADDRESS BOOK")

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
            term.write(string.format("%s %02d %-18s %s", marker, i, tostring(entry.name):sub(1, 18), address_to_string(entry.symbols):sub(1, 25)))
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
    draw_header("IRIS CONTROL")

    term.setCursorPos(2, 5)
    term.write("STATE: " .. iris_text())
    term.setCursorPos(2, 6)
    term.write("TYPE:  " .. tostring(state.iris_type or "UNKNOWN"))

    local durability = state.iris_durability
    if type(durability) == "table" then
        term.setCursorPos(2, 7)
        term.write("DURABILITY: " .. tostring(durability[1] or "?") .. " / " .. tostring(durability[2] or "?"))
    end

    term.setCursorPos(2, 9)
    term.write("MODE: " .. state.mode)
    term.setCursorPos(2, 11)
    term.write("O OPEN")
    term.setCursorPos(2, 12)
    term.write("C CLOSE")
    term.setCursorPos(2, 13)
    term.write("A TOGGLE AUTO/MANUAL")
    term.setCursorPos(2, 14)
    term.write("ESC BACK")

    term.setCursorPos(2, 17)
    term.write("AUTO MODE closes the iris on incoming activation.")
    term.setCursorPos(2, 18)
    term.write("JSG GDO/iris-code handling remains native to JSG.")
end

local function draw_log()
    term.clear()
    draw_header("EVENT LOG")

    local start = math.max(1, #state.events - 16)
    local row = 5
    for i = start, #state.events do
        term.setCursorPos(2, row)
        term.write(tostring(state.events[i]):sub(1, 76))
        row = row + 1
        if row > 22 then break end
    end

    term.setCursorPos(2, 24)
    term.write("ESC BACK")
end

local function add_address()
    term.clear()
    draw_header("ADD ADDRESS")
    print("Enter a name:")
    local name = trim(read())
    print("Enter symbols separated by spaces:")
    local raw = read()
    local symbols = {}
    for symbol in string.gmatch(raw, "%S+") do
        table.insert(symbols, symbol)
    end

    if name == "" or #symbols < 7 then
        log_event("ADDRESS ADD FAILED: name and at least 7 symbols required")
        return
    end

    table.insert(state.addresses, {
        name = name,
        symbols = symbols,
    })
    state.selected_address = #state.addresses
    save_data()
    log_event("ADDRESS ADDED: " .. name)
end

local function remove_address()
    local entry = state.addresses[state.selected_address]
    if not entry then
        return
    end

    table.remove(state.addresses, state.selected_address)
    if state.selected_address > #state.addresses then
        state.selected_address = math.max(1, #state.addresses)
    end
    save_data()
    log_event("ADDRESS REMOVED: " .. tostring(entry.name))
end

local function address_menu()
    while true do
        refresh_gate()
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
        elseif key == keys.a then
            add_address()
        elseif key == keys.r then
            remove_address()
        elseif key == keys.d then
            dial_saved(state.selected_address)
        elseif key == keys.e then
            -- Editing is intentionally deferred until a symbol-validation UI is added.
            log_event("ADDRESS EDIT: not implemented in initial build")
        elseif key == keys.escape then
            return
        end
    end
end

local function iris_menu()
    while true do
        refresh_gate()
        draw_iris()
        local event, key = os.pullEvent("key")

        if key == keys.o then
            open_iris("manual control")
        elseif key == keys.c then
            close_iris("manual control")
        elseif key == keys.a then
            state.mode = (state.mode == "AUTO") and "MANUAL" or "AUTO"
            save_data()
            log_event("IRIS MODE: " .. state.mode)
            if state.mode == "AUTO" then
                automatic_incoming_security()
            end
        elseif key == keys.escape then
            return
        end
    end
end

local function log_menu()
    while true do
        draw_log()
        local event, key = os.pullEvent("key")
        if key == keys.escape then
            return
        end
    end
end

local function handle_event(event, ...)
    local args = { ... }

    if event == "stargate_wormhole_incoming" then
        state.incoming = true
        state.incoming_address = "UNKNOWN"
        log_event("INCOMING DIAL DETECTED (address size: " .. tostring(args[1] or "?") .. ")")
        state.alert = "INCOMING"
        automatic_incoming_security()

    elseif event == "stargate_wormhole_open_fully" then
        local address = args[1]
        local initiating = args[2]
        if not initiating then
            state.incoming = true
            state.incoming_address = address_to_string(address)
            log_event("INCOMING GATE OPEN: " .. state.incoming_address)
            automatic_incoming_security()
        else
            log_event("OUTGOING GATE OPEN: " .. address_to_string(address))
        end

    elseif event == "stargate_wormhole_close_fully" then
        local address = args[1]
        local reason = args[2]
        local initiating = args[3]
        state.incoming = false
        state.alert = nil
        log_event((initiating and "OUTGOING" or "INCOMING") .. " GATE CLOSED: " .. address_to_string(address) .. " reason=" .. tostring(reason or "unknown"))

    elseif event == "stargate_event_horizon_traveler" then
        local inbound = args[1]
        local entity_type = args[2]
        local player_name = args[4]
        if inbound then
            log_event("INBOUND TRAVELER: " .. tostring(entity_type) .. (player_name and (" / " .. tostring(player_name)) or ""))
        else
            log_event("OUTBOUND TRAVELER: " .. tostring(entity_type))
        end

    elseif event == "stargate_iris_code_received" then
        -- Do not log the plaintext GDO code.
        log_event("GDO/IRIS CODE RECEIVED")

    elseif event == "stargate_iris_state_changed" then
        local old_state = args[1]
        local new_state = args[2]
        log_event("IRIS STATE: " .. tostring(old_state) .. " -> " .. tostring(new_state))

    elseif event == "stargate_iris_toggled" then
        log_event("IRIS TOGGLED")

    elseif event == "stargate_iris_damaged" then
        log_event("WARNING: IRIS DAMAGED")

    elseif event == "stargate_iris_hit" then
        log_event("WARNING: IRIS HIT")

    elseif event == "stargate_iris_destroyed" then
        log_event("CRITICAL: IRIS DESTROYED")

    elseif event == "stargate_iris_out_of_power" then
        log_event("CRITICAL: IRIS OUT OF POWER")

    elseif event == "stargate_attempt_open_failed" then
        log_event("GATE OPEN ATTEMPT FAILED")

    elseif event == "stargate_attempt_close_failed" then
        log_event("GATE CLOSE ATTEMPT FAILED")

    elseif event == "stargate_wormhole_subspace_connected" then
        log_event("WORMHOLE SUBSPACE CONNECTED")

    elseif event == "stargate_wormhole_subspace_disconnected" then
        log_event("WORMHOLE SUBSPACE DISCONNECTED")
    end
end

local function main_loop()
    while true do
        refresh_gate()
        draw_main()

        local timer = os.startTimer(CONFIG.ui_refresh)
        local event = { os.pullEvent() }
        os.cancelTimer(timer)

        if event[1] == "timer" then
            -- periodic refresh
        elseif event[1] == "key" then
            local key = event[2]
            if key == keys.one then
                address_menu()
            elseif key == keys.two then
                dial_saved(state.selected_address)
            elseif key == keys.three then
                iris_menu()
            elseif key == keys.four then
                log_menu()
            elseif key == keys.five then
                refresh_gate()
            elseif key == keys.q then
                return
            end
        elseif event[1] == "peripheral" or event[1] == "peripheral_detach" then
            ensure_gate()
        elseif event[1]:sub(1, 9) == "stargate_" then
            handle_event(table.unpack(event, 1, #event))
        end
    end
end

local function boot()
    term.clear()
    term.setCursorPos(1, 1)
    print("SGC-CC INITIALIZING...")
    print("JSG / CC:Tweaked control system")

    load_data()
    load_events()
    ensure_gate()

    -- If an iris is present, refresh its state immediately. We do not blindly
    -- toggle it because toggleIris() is state-dependent and fail-closed behavior
    -- must never accidentally open an already-closed iris.
    refresh_gate()
    if state.mode == "AUTO" and state.connected and state.iris_state then
        log_event("SECURITY MODE: AUTO")
    end

    sleep(1)
    main_loop()
end

local ok, err = xpcall(boot, debug.traceback)
if not ok then
    term.clear()
    term.setCursorPos(1, 1)
    print("SGC-CC CRITICAL ERROR")
    print(tostring(err))
    print("")
    print("The program stopped instead of continuing with an unsafe state.")
    print("Check the event log and JSG/CC connection before restarting.")
end
