# Verified JSG ComputerCraft API

Target: Just Stargate Mod (JSG), Minecraft 1.20.1 branch.

This document intentionally lists only APIs verified from JSG source. Anything not listed is not assumed to exist.

## Stargate abstract CC methods

Verified methods in `StargateAbstractCCMethods`:

- `getJSGVersion()` -> one value: version string
- `getOpenedTime()` -> multiple values: success/code/minutes/seconds when connected
- `getStargateAddress()` -> one value: table keyed by symbol-type ID, containing address symbol lists
- `getDialedAddress()` -> one value: symbol-name list
- `getEnergyStored()` -> one value: stored energy
- `getMaxEnergyStored()` -> one value: maximum energy
- `getGateType()` -> one value: gate type or nil
- `getSymbolType()` -> one value: symbol-type ID or nil
- `getSymbolsMap()` -> one value: symbol-name list
- `getGateStatus()` -> multiple values, not a table:
  - `false, "not_merged"` when not merged
  - `true, "open", initiating` when engaged
  - `true, "<state>"` otherwise
- `getSymbolsNeeded(table)` -> multiple values: success/code/count or failure code
- `getEnergyRequiredToDial(table)` -> multiple values: success/code/energy-map or failure code

### Energy map

`getEnergyRequiredToDial(table)` returns an energy map containing:

- `open`
- `keepAlive`
- `canOpen`

`canOpen` reflects whether the gate currently has enough energy to meet the calculated opening cost.

## Classic gate CC methods

Verified methods in `StargateClassicCCMethods`:

- `toggleIris()`
- `getIrisState()`
- `getIrisType()`
- `getIrisDurability()`
- `sendMessage()`
- `sendMessageToIncomingTraveller()`
- `sendIrisCode(code)`
- `abortDialing()`
- `engageGate()`
- `disengageGate()`
- `engageSymbol(symbol)`
- `dialAddress(table_or_variadic)`
- `spinRing(...)`

### Important operation-result convention

Most mutating JSG CC methods return normal Lua values of the form:

`true, code, message, ...`

or

`false, code, message, ...`

A Lua/API exception can also be thrown. Therefore callers must handle both:

1. `pcall`/Lua failure, and
2. JSG returning `success == false`.

This applies to `toggleIris`, `dialAddress`, `abortDialing`, `engageGate`, `disengageGate`, `sendIrisCode`, and `engageSymbol`.

### Iris details

`toggleIris()`:

- fails if no iris is installed
- fails if the iris mode is not OC
- can fail because the iris is busy
- can fail because there is insufficient power
- returns a normal success/failure result; these conditions do not necessarily throw

`getIrisState()` returns the JSG iris state enum name. Verified enum values are:

- `OPENED`
- `CLOSED`
- `OPENING`
- `CLOSING`
- `ERROR`

`getIrisType()` returns the installed iris **type**, not the iris mode. The CC API reviewed here does not expose a separate `getIrisMode()` function.

`getIrisDurability()` returns three values:

1. formatted durability string
2. current durability
3. maximum durability

`sendIrisCode(code)` sends an iris/GDO code across an active connection. JSG performs the receiving-side iris-code processing.

## `dialAddress` behavior

JSG `dialAddress` explicitly supports both:

- `dialAddress({symbol1, symbol2, ...})`
- `dialAddress(symbol1, symbol2, ...)`

When a table is supplied as the first argument, JSG reconstructs its ordered values before creating the address. Do not replace the table form with `table.unpack` merely because the Java method accepts variadic Lua arguments.

A successful call returns:

`true, "dial_begun", address_string`

Common failure results include:

- `false, "stargate_failure_not_merged", ...`
- `false, "stargate_failure_busy", ...`
- `false, "stargate_failure_not_empty", ...`
- `false, "input_address_malformed", ...`

## Verified ComputerCraft events

- `stargate_spin_start`
- `stargate_spin_stop`
- `stargate_chevron_engaged`
- `stargate_chevron_open`
- `stargate_chevron_lit`
- `stargate_chevron_dim`
- `stargate_chevron_close`
- `stargate_attempt_open_failed`
- `stargate_attempt_close_failed`
- `stargate_wormhole_incoming`
- `stargate_wormhole_incoming_message`
- `stargate_wormhole_subspace_connected`
- `stargate_wormhole_open_unstable`
- `stargate_wormhole_open_fully`
- `stargate_wormhole_close_unstable`
- `stargate_wormhole_close_fully`
- `stargate_wormhole_subspace_disconnected`
- `stargate_event_horizon_unstable`
- `stargate_event_horizon_unstable_black_hole`
- `stargate_event_horizon_stabilized`
- `stargate_event_horizon_traveler`
- `stargate_iris_toggled`
- `stargate_iris_destroyed`
- `stargate_iris_code_received`
- `stargate_iris_state_changed`
- `stargate_iris_type_changed`
- `stargate_iris_damaged`
- `stargate_iris_hit`
- `stargate_iris_out_of_power`
- `stargate_ping`

### Important event payloads

`stargate_wormhole_incoming`:

- argument 1: incoming address size

`stargate_wormhole_open_fully`:

- argument 1: address name list
- argument 2: initiating-side boolean

`stargate_wormhole_close_fully`:

- argument 1: address name list
- argument 2: close reason
- argument 3: initiating-side boolean

`stargate_event_horizon_traveler` for a player:

- argument 1: inbound boolean
- argument 2: entity type
- argument 3: player UUID
- argument 4: player name

`stargate_iris_code_received`:

- argument 1: plaintext received code

The SGC event log must not record that plaintext code.

Chevron engaged event:

- argument 1: source (`DHD`, `REMOTE`, `BY_SPIN`, or `INCOMING_WORMHOLE`)
- argument 2: symbol name
- argument 3: chevron index
- argument 4: dialed-address size

`stargate_iris_state_changed`:

- argument 1: old iris state
- argument 2: new iris state

`stargate_iris_type_changed`:

- argument 1: old iris type
- argument 2: new iris type

## Not currently verified as CC APIs

### Temperature

JSG contains internal gate temperature behavior, but no CC-accessible temperature method was verified in the inspected 1.20.1 CC classes. Do not invent `getTemperature()`.

### Programmatic JSG siren playback

JSG provides siren sounds as music discs, but no direct Lua method for programmatic playback was verified in the inspected gate CC classes.

## Source of verification

JSG 1.20.1 source files reviewed:

- `StargateAbstractCCMethods.java`
- `StargateClassicCCMethods.java`
- `StargateComputerEvents.java`
- `EnumIrisState.java`

Repository: Tau-ri-Dev/Mod-JSG, branch `1.20.1`.
