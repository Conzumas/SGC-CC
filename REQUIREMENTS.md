# SGC-CC Requirements

## Target environment

- Minecraft 1.20.1 Forge
- Just Stargate Mod (JSG)
- CC:Tweaked
- Physical JSG iris installed at the gate

## Core goals

Build an SGC-style ComputerCraft control program that is reliable enough to operate the user's Stargate automatically while providing a useful command-center interface.

## Functional requirements

### 1. Address book

- Store named Stargate addresses persistently.
- Recall saved addresses.
- Add, edit, and remove entries.
- Display addresses in the UI.

### 2. Dialing

- Dial a saved address.
- Support manual address entry.
- Show dialing progress and gate state.
- Handle failed/aborted dialing without leaving the UI in a false state.

### 3. Iris security

- AUTO mode is the normal/default operating mode.
- On an incoming wormhole, close the iris automatically if possible.
- Keep the iris closed while an incoming connection is unauthorized.
- Support JSG's GDO/iris-code mechanism so authorized travelers can open the iris remotely.
- Provide manual OPEN/CLOSE control when appropriate.
- If the program restarts or loses the gate peripheral, fail closed when technically possible.
- Record iris events in the event log.

### 4. Incoming activation warning

- Detect incoming wormholes.
- Present a prominent incoming-activation warning.
- Identify the incoming address when JSG provides it.
- Distinguish incoming versus outgoing activations.

### 5. Alarms

JSG provides gate siren sounds as music discs. Investigate whether those sounds can be triggered programmatically through an available CC/JSG interface. Do not invent an API for this; mark it unsupported if no verified programmatic route exists.

Desired behavior:

- Incoming/offworld activation alarm.
- Gate activation/deactivation feedback where appropriate.
- Alarm should not block the main control loop.

### 6. Gate monitoring

Display, when exposed by the verified JSG CC API:

- Gate connection/state.
- Stored energy.
- Maximum energy.
- Energy percentage.
- Dialed address.
- Local gate address.

Temperature is desired, but must remain explicitly unimplemented until a JSG 1.20.1 CC-accessible temperature API is verified.

### 7. Event log

Maintain a persistent or session event log showing useful SGC events, including:

- Incoming dial detected.
- Gate opened/closed.
- Iris closed/opened.
- GDO/iris code received.
- Traveler detected.
- Dial failures.
- Iris damage/destruction/out-of-power events.

Do not expose plaintext iris/GDO codes in the normal event log.

### 8. UI

The interface should feel like an SGC computer rather than a generic Lua menu.

Main areas should include:

- Gate status.
- Energy status.
- Iris status/control.
- Address book.
- Dial controls.
- Incoming activation warning.
- Event log.

## Safety/reliability rules

1. Never assume a JSG method exists without verification.
2. Never silently treat an unknown gate or iris state as safe/open.
3. Prefer fail-closed behavior for iris security.
4. Peripheral loss must not crash the entire program.
5. Event handling must not prevent the UI from updating.
6. Persist address-book data so a reboot does not erase it.
7. Keep the implementation modular enough that JSG API changes can be isolated.
