# SGC-CC

Stargate Command-style ComputerCraft control system for Just Stargate Mod (JSG) on Minecraft 1.20.1.

## Project status

Early design / API verification phase. The goal is to build a reliable SGC computer program with address management, dialing, iris security, GDO compatibility, alarms, monitoring, and event logging.

## Repository structure

- `REQUIREMENTS.md` — functional requirements and intended behavior.
- `JSG_API.md` — verified JSG ComputerCraft API and event reference.
- `src/` — ComputerCraft Lua source code.

## Development rule

Do not invent JSG APIs. If a method, event, or capability has not been verified against the target JSG version/source, mark it as unverified and investigate before implementing it.
