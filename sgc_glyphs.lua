-- SGC-CC Glyph Reference
-- Lists the exact symbol names exposed by the connected JSG stargate.
--
-- When a monitor is attached, the complete reference is rendered once and
-- the program exits so the computer remains available for other programs.
-- Without a monitor, the reference is shown on the computer terminal.

local function find_gate()
    local gate = peripheral.find("stargate")
    if gate and gate.getSymbolsMap then
        return gate
    end

    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        if wrapped and wrapped.getSymbolsMap then
            return wrapped
        end
    end

    return nil
end

local function find_monitor()
    local monitor = peripheral.find("monitor")
    if monitor then
        return monitor
    end

    return nil
end

local function get_symbols(gate)
    local ok, symbols = pcall(gate.getSymbolsMap)
    if not ok or type(symbols) ~= "table" then
        return nil
    end

    return symbols
end

local function draw_symbols(display, symbols)
    local previous = term.redirect(display)

    if display.setTextScale then
        display.setTextScale(0.5)
    end

    display.clear()
    display.setCursorPos(1, 1)
    display.write("S T A R G A T E   G L Y P H   R E F E R E N C E")
    display.setCursorPos(1, 2)
    display.write("================================================")
    display.setCursorPos(1, 3)
    display.write("CODE = JSG symbol-map index")

    local width, height = display.getSize()
    local columns = 3
    local column_width = math.floor(width / columns)
    local rows = math.max(1, height - 5)
    local capacity = columns * rows

    display.setCursorPos(1, 5)
    display.clearLine()
    display.write(string.format("%d SYMBOLS   3 COLUMNS   %d AVAILABLE SLOTS", #symbols, capacity))

    for index, symbol in ipairs(symbols) do
        local zero = index - 1
        local column = math.floor(zero / rows)
        local row = zero % rows

        if column >= columns then
            break
        end

        local x = 2 + column * column_width
        local y = 6 + row
        local text = string.format("[%02d] %s", index, tostring(symbol))

        display.setCursorPos(x, y)
        display.clearLine()
        display.write(text:sub(1, column_width - 2))
    end

    term.redirect(previous)
end

local gate = find_gate()
if not gate then
    print("No JSG stargate peripheral found.")
    return
end

local symbols = get_symbols(gate)
if not symbols then
    print("Unable to read JSG symbol map.")
    return
end

local monitor = find_monitor()
local display = monitor or term.current()
draw_symbols(display, symbols)
