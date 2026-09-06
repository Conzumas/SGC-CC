from pathlib import Path

p = Path('src/sgc.lua')
s = p.read_text()

def once(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 match, found {n}')
    s = s.replace(old, new, 1)

once(
'''    iris_authorized = false,
    iris_open_pending = false,
''',
'''    iris_authorized = false,
    iris_open_pending = false,
    iris_sgc_locked = false,
    iris_reopen_pending = false,
''', 'state fields')

once(
'''    state.iris_authorized = false
    state.iris_open_pending = false
    iris_toggle_reservation = nil
''',
'''    state.iris_authorized = false
    state.iris_open_pending = false
    state.iris_sgc_locked = false
    state.iris_reopen_pending = false
    iris_toggle_reservation = nil
''', 'clear_gate_state')

once(
'''    if old_gate ~= nil and gate ~= old_gate then
        log_event("Gate peripheral changed")
        iris_toggle_reservation = nil
        state.iris_open_pending = false
    end
''',
'''    if old_gate ~= nil and gate ~= old_gate then
        log_event("Gate peripheral changed")
        iris_toggle_reservation = nil
        state.iris_open_pending = false
        state.iris_sgc_locked = false
        state.iris_reopen_pending = false
    end
''', 'peripheral change')

start = s.index('-----------------------------------------------------------------------\n-- Iris security\n-----------------------------------------------------------------------')
end = s.index('-----------------------------------------------------------------------\n-- Address handling\n-----------------------------------------------------------------------', start)
iris = '''-----------------------------------------------------------------------
-- Iris security
-----------------------------------------------------------------------

local function toggle_iris_guarded(target_state, reason)
    local now_ms = os.epoch("utc")

    if iris_toggle_reservation then
        if state.iris_state == iris_toggle_reservation.target_state then
            log_event("IRIS TOGGLE CONFIRMED: " .. tostring(iris_toggle_reservation.target_state))
            iris_toggle_reservation = nil
        elseif now_ms - iris_toggle_reservation.created_at > IRIS_TOGGLE_RESERVATION_TIMEOUT_MS then
            log_event("IRIS TOGGLE RESERVATION EXPIRED: " .. tostring(iris_toggle_reservation.target_state))
            iris_toggle_reservation = nil
        else
            return false, "iris_toggle_busy"
        end
    end

    if not state.gate or not state.gate.toggleIris then
        return false, "toggleIris() unavailable"
    end

    iris_toggle_reservation = { target_state = target_state, created_at = now_ms }
    local ok, success, code, message = safe_call(state.gate.toggleIris)
    local worked, detail = jsg_result(ok, success, code, message)
    if not worked then
        iris_toggle_reservation = nil
        log_event("IRIS TOGGLE FAILED: " .. tostring(detail))
        return false, detail
    end

    log_event("IRIS TOGGLE ACCEPTED: " .. tostring(reason or "security request") .. " -> " .. tostring(target_state))
    return true
end

local function close_iris_for_incoming(reason)
    if not state.gate or not state.gate.toggleIris then
        state.alert = "!!! IRIS CONTROL UNAVAILABLE !!!"
        log_event("IRIS LOCK FAILED: toggleIris() unavailable")
        return false
    end

    if state.iris_state == "CLOSED" then
        return true
    end

    if state.iris_state == "CLOSING" then
        state.iris_sgc_locked = true
        return true
    end

    if state.iris_state ~= "OPENED" and state.iris_state ~= "OPENING" then
        return false
    end

    local worked, detail = toggle_iris_guarded("CLOSED", reason or "incoming security lock")
    if not worked then
        if detail == "iris_toggle_busy" then
            if iris_toggle_reservation and iris_toggle_reservation.target_state == "CLOSED" then
                state.iris_sgc_locked = true
            end
            return true
        end
        state.alert = "!!! IRIS LOCK FAILED !!!"
        log_event("IRIS LOCK FAILED: " .. tostring(detail))
        return false
    end

    state.iris_sgc_locked = true
    state.iris_reopen_pending = false
    log_event("IRIS CLOSED: " .. tostring(reason or "incoming security lock"))
    return true
end

local function reopen_iris_after_disconnect(reason)
    if not state.iris_sgc_locked then
        state.iris_reopen_pending = false
        return true
    end

    if not state.gate or not state.gate.toggleIris then
        state.iris_reopen_pending = true
        log_event("IRIS REOPEN DEFERRED: toggleIris() unavailable")
        return false
    end

    if state.iris_state == "OPENED" then
        state.iris_sgc_locked = false
        state.iris_reopen_pending = false
        log_event("IRIS RESTORED OPEN: already open")
        return true
    end

    if state.iris_state == "CLOSING" or state.iris_state == "OPENING" then
        state.iris_reopen_pending = true
        return true
    end

    if state.iris_state ~= "CLOSED" then
        state.iris_reopen_pending = true
        log_event("IRIS REOPEN DEFERRED: state=" .. tostring(state.iris_state or "UNKNOWN"))
        return false
    end

    local worked, detail = toggle_iris_guarded("OPENED", reason or "wormhole disconnected")
    if not worked then
        state.iris_reopen_pending = true
        if detail ~= "iris_toggle_busy" then
            state.alert = "!!! IRIS REOPEN FAILED !!!"
            log_event("IRIS REOPEN FAILED: " .. tostring(detail))
        end
        return false
    end

    state.iris_reopen_pending = false
    log_event("IRIS REOPEN REQUESTED: " .. tostring(reason or "wormhole disconnected"))
    return true
end

local function process_gdo_code(received_code)
    state.iris_authorized = false
    if not state.incoming then
        log_event("GDO AUTH REJECTED: no incoming connection")
        return false
    end
    if type(CONFIG.gdo_code) ~= "string" or CONFIG.gdo_code == "" then
        state.alert = "!!! GDO CODE NOT CONFIGURED !!!"
        log_event("GDO AUTH REJECTED: local GDO code is not configured")
        return false
    end
    if tostring(received_code) ~= CONFIG.gdo_code then
        log_event("GDO AUTH REJECTED: invalid code")
        return false
    end
    if not state.gate or not state.gate.toggleIris then
        state.alert = "!!! IRIS CONTROL UNAVAILABLE !!!"
        log_event("GDO AUTHENTICATED BUT IRIS CONTROL IS UNAVAILABLE")
        return false
    end

    state.iris_authorized = true
    if state.iris_state == "CLOSED" then
        local worked, detail = toggle_iris_guarded("OPENED", "GDO authenticated")
        if not worked then
            if detail == "iris_toggle_busy" then
                state.iris_open_pending = true
                log_event("GDO AUTHENTICATED: iris toggle pending behind active reservation")
                return true
            end
            state.iris_authorized = false
            state.alert = "!!! IRIS OPEN FAILED !!!"
            log_event("GDO AUTHENTICATED; IRIS OPEN FAILED: " .. tostring(detail))
            return false
        end
        state.iris_open_pending = false
    elseif state.iris_state == "OPENED" then
        state.iris_open_pending = false
    else
        state.iris_open_pending = true
        log_event("GDO AUTHENTICATED: iris state " .. tostring(state.iris_state or "UNKNOWN") .. "; opening pending")
    end

    state.alert = nil
    log_event("GDO AUTHENTICATED: IRIS OPEN AUTHORIZED")
    return true
end

local function enforce_incoming_iris_lock()
    if state.incoming and not state.iris_authorized then
        close_iris_for_incoming("incoming connection")
    elseif not state.incoming and state.iris_reopen_pending then
        reopen_iris_after_disconnect("pending disconnect restoration")
    end
end

'''
s = s[:start] + iris + s[end:]

old = '''    elseif event == "stargate_wormhole_close_fully" then
        local address, reason, initiating = args[1], args[2], args[3]
        state.iris_authorized = false
        state.iris_open_pending = false
        state.dialing = false
        state.ring_spinning = false
        state.dialed_address = nil
        state.incoming = false
        state.incoming_address = nil
        state.alert = nil
        iris_toggle_reservation = nil
        stop_alarm_audio()
        log_event("WORMHOLE CLOSED: " .. address_to_string(address) .. " / " .. tostring(reason or "unknown") .. " / initiating=" .. tostring(initiating))
'''
new = '''    elseif event == "stargate_wormhole_close_fully" then
        local address, reason, initiating = args[1], args[2], args[3]
        state.iris_authorized = false
        state.iris_open_pending = false
        state.dialing = false
        state.ring_spinning = false
        state.dialed_address = nil
        state.incoming = false
        state.incoming_address = nil
        state.alert = nil
        stop_alarm_audio()

        if state.iris_sgc_locked then
            state.iris_reopen_pending = true
            reopen_iris_after_disconnect("wormhole disconnected")
        end

        log_event("WORMHOLE CLOSED: " .. address_to_string(address) .. " / " .. tostring(reason or "unknown") .. " / initiating=" .. tostring(initiating))
'''
once(old, new, 'wormhole close')

old = '''    elseif event == "stargate_iris_state_changed" then
        state.iris_state = args[2]
        state.iris_last_state_change = tostring(args[2] or "UNKNOWN")
        state.iris_last_state_change_at = os.epoch("utc")

        if iris_toggle_reservation and state.iris_state == iris_toggle_reservation.target_state then
            log_event("IRIS TOGGLE CONFIRMED: " .. tostring(state.iris_state))
            iris_toggle_reservation = nil
        elseif state.iris_state == "ERROR" then
            iris_toggle_reservation = nil
        end

        if state.iris_state == "OPENED" then
            state.iris_open_pending = false
        elseif state.iris_state == "CLOSED" and state.incoming and state.iris_authorized and state.iris_open_pending then
            state.iris_open_pending = false
            local worked, detail = toggle_iris_guarded("OPENED", "pending GDO authorization")
            if not worked then
                state.iris_open_pending = true
                state.alert = "!!! IRIS OPEN FAILED !!!"
                log_event("PENDING GDO OPEN FAILED: " .. tostring(detail))
            else
                log_event("PENDING GDO OPEN: iris close confirmed; opening authorized")
            end
        end

        log_event("IRIS STATE: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))
'''
new = '''    elseif event == "stargate_iris_state_changed" then
        state.iris_state = args[2]
        state.iris_last_state_change = tostring(args[2] or "UNKNOWN")
        state.iris_last_state_change_at = os.epoch("utc")

        if iris_toggle_reservation and state.iris_state == iris_toggle_reservation.target_state then
            log_event("IRIS TOGGLE CONFIRMED: " .. tostring(state.iris_state))
            iris_toggle_reservation = nil
        elseif state.iris_state == "ERROR" then
            iris_toggle_reservation = nil
        end

        if state.iris_state == "OPENED" then
            state.iris_open_pending = false
            if state.iris_reopen_pending then
                state.iris_reopen_pending = false
                state.iris_sgc_locked = false
                log_event("IRIS RESTORED OPEN: disconnect recovery confirmed")
            end
        elseif state.iris_state == "CLOSED" then
            if state.incoming and state.iris_authorized and state.iris_open_pending then
                state.iris_open_pending = false
                local worked, detail = toggle_iris_guarded("OPENED", "pending GDO authorization")
                if not worked then
                    state.iris_open_pending = true
                    state.alert = "!!! IRIS OPEN FAILED !!!"
                    log_event("PENDING GDO OPEN FAILED: " .. tostring(detail))
                else
                    log_event("PENDING GDO OPEN: iris close confirmed; opening authorized")
                end
            elseif not state.incoming and state.iris_reopen_pending then
                reopen_iris_after_disconnect("disconnect restoration after iris close")
            end
        end

        log_event("IRIS STATE: " .. tostring(args[1]) .. " -> " .. tostring(args[2]))
'''
once(old, new, 'iris state event')

old = '''    elseif event == "stargate_iris_destroyed" then
        state.alert = "!!! IRIS DESTROYED !!!"
        state.iris_state = nil
        state.iris_attack_active = true
        state.iris_last_hit_at = os.epoch("utc")
        iris_toggle_reservation = nil
        state.iris_open_pending = false
        log_event("!!! IRIS DESTROYED !!!: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_iris_out_of_power" then
        state.alert = "!!! IRIS OUT OF POWER !!!"
        log_event("!!! IRIS OUT OF POWER !!!")
'''
new = '''    elseif event == "stargate_iris_destroyed" then
        state.alert = "!!! IRIS DESTROYED !!!"
        state.iris_state = nil
        state.iris_attack_active = true
        state.iris_last_hit_at = os.epoch("utc")
        iris_toggle_reservation = nil
        state.iris_open_pending = false
        state.iris_sgc_locked = false
        state.iris_reopen_pending = false
        log_event("!!! IRIS DESTROYED !!!: " .. tostring(args[1] or "unknown"))

    elseif event == "stargate_iris_out_of_power" then
        state.alert = "!!! IRIS OUT OF POWER !!!"
        state.iris_sgc_locked = false
        state.iris_reopen_pending = false
        state.iris_open_pending = false
        iris_toggle_reservation = nil
        log_event("!!! IRIS OUT OF POWER !!!")
'''
once(old, new, 'iris failure events')

p.write_text(s)
print(f'patched {len(s)} bytes')
