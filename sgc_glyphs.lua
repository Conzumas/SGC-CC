-- SGC-CC Glyph Reference
-- One-page JSG symbol reference for a dedicated monitor computer.
--
-- Deployment:
--   * Run this program on a SECOND ComputerCraft computer.
--   * Connect that computer to the same wired modem network as the JSG gate.
--   * Connect a complete 3x3 monitor (or larger) to the second computer.
--   * The program draws the reference once and exits.

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
    return peripheral.find("monitor")
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

    local width, height = display.getSize()
    local columns = 3
    local column_width = math.floor(width / columns)
    local rows = height - 5
    local capacity = columns * rows

    display.clear()
    display.setCursorPos(1, 1)
    display.write("S T A R G A T E   G L Y P H   R E F E R E N C E")
    display.setCursorPos(1, 2)
    display.write("================================================")
    display.setCursorPos(1, 3)
    display.write("CODE = JSG SYMBOL-MAP INDEX")

    display.setCursorPos(1, 5)
    display.clearLine()
    display.write(string.format("%d SYMBOLS   3 COLUMNS   %d DISPLAY SLOTS", #symbols, capacity))

    if #symbols > capacity then
        display.setCursorPos(1, 6)
        display.clearLine()
        display.write("MONITOR TOO SMALL: 3x3 OR LARGER REQUIRED")
        term.redirect(previous)
        return false
    end

    for index, symbol in ipairs(symbols) do
        local zero = index - 1
        local column = math.floor(zero / rows)
        local row = zero % rows
        local x = 2 + column * column_width
        local y = 6 + row
        local text = string.format("[%02d] %s", index, tostring(symbol))

        display.setCursorPos(x, y)
        display.clearLine()
        display.write(text:sub(1, column_width - 2))
    end

    display.setCursorPos(1, height)
    display.clearLine()
    display.write("SGC-CC | DEDICATED GLYPH REFERENCE")

    term.redirect(previous)
    return true
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
if not monitor then
    print("No monitor found. Connect a complete 3x3 monitor or larger.")
    return
end

draw_symbols(monitor, symbols)
