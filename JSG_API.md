# Verified JSG ComputerCraft API

Target: Just Stargate Mod (JSG), Minecraft 1.20.1 branch.

This document intentionally lists only APIs verified from JSG source. Anything not listed is not assumed to exist.

## Stargate abstract CC methods

Verified methods in `StargateAbstractCCMethods`:

- `getJSGVersion()`
- `getOpenedTime()`
- `getStargateAddress()`
- `getDialedAddress()`
- `getEnergyStored()`
- `getMaxEnergyStored()`
- `getGateType()`
- `getSymbolType()`
- `getSymbolsMap()`
- `getGateStatus()`
- `getSymbolsNeeded(table)`
- `getEnergyRequiredToDial(table)`

### Important return details

`getEnergyStored()` uses JSG's true stored-energy value.

`getMaxEnergyStored()` uses JSG's true maximum-energy value.

`getGateStatus()` returns a table describing whether the gate is merged and its current state. When engaged, it also includes the initiating-side flag.

`getStargateAddress()` returns address data keyed by symbol-type ID.

`getDialedAddress()` returns the current dialed address as a list of symbol names.

`getEnergyRequiredToDial(table)` returns values for `open`, `keepAlive`, and `canOpen`.

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
- `dialAddress(...)`
- `spinRing(...)`

### Iris details

`toggleIris()` requires an iris and requires the iris mode to be OC. It toggles the local iris state.

`getIrisState()` returns the JSG iris state enum name.

`getIrisType()` returns the JSG iris type enum name.

`getIrisDurability()` returns current and maximum durability values.

`sendIrisCode(code)` sends an iris/GDO code across an active connection using JSG's `ComputerCodeSender` mechanism.

The receiving side also exposes the `stargate_iris_code_received` ComputerCraft event.

## Verified ComputerCraft events

From `StargateComputerEvents`:

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

## Event payloads verified during source review

### `stargate_wormhole_incoming`

Carries the incoming address size.

### `stargate_wormhole_open_fully`

Carries the address name list and an initiating-side boolean.

### `stargate_wormhole_close_fully`

Carries the address name list, close reason, and initiating-side boolean.

### `stargate_event_horizon_traveler`

Carries an inbound boolean and entity type. For players, JSG also provides UUID/name information.

### `stargate_iris_code_received`

Carries the received code string. The SGC UI should not normally print/store this plaintext code in its event log.

### `stargate_iris_state_changed`

Carries old and new iris states.

### `stargate_iris_out_of_power`

No payload.

### Chevron events

Chevron-engaged events include source, symbol name, chevron index, and dialed-address size. Sources include DHD, REMOTE, BY_SPIN, and INCOMING_WORMHOLE.

## Not currently verified as a CC API

### Temperature

JSG has internal gate temperature behavior, but no `getTemperature()`-style CC method was verified in the inspected 1.20.1 CC classes. The SGC program must not invent one. Temperature monitoring remains pending API verification.

### Programmatic JSG siren playback

JSG provides siren sounds as music discs. The inspected gate CC classes did not expose a direct Lua method for playing those gate sounds. A programmatic route must be separately verified before implementation.

## Source of verification

JSG 1.20.1 source files reviewed:

- `StargateAbstractCCMethods.java`
- `StargateClassicCCMethods.java`
- `StargateComputerEvents.java`
- `StargateAbstractBaseBE.java`

Repository: Tau-ri-Dev/Mod-JSG, branch `1.20.1`.
