-- SGC-CC Glyph Reference
-- Lists the exact symbol names exposed by the connected JSG stargate.
--
-- If a monitor is attached, the glyph table is rendered there while
-- keyboard input remains on the computer. Otherwise the computer terminal
-- is used directly.

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

local function draw_symbols(display, symbols, input_term)
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
    local columns = width >= 60 and 3 or 2
    local rows = math.max(1, height - 6)
    local per_page = columns * rows
    local pages = math.max(1, math.ceil(#symbols / per_page))
    local page = 1

    while true do
        display.setCursorPos(1, 5)
        display.clearLine()
        display.write(string.format("PAGE %d / %d    %d SYMBOLS", page, pages, #symbols))

        local column_width = math.floor(width / columns)
        for row = 0, rows - 1 do
            for column = 0, columns - 1 do
                local index = (page - 1) * per_page + row + column * rows + 1
                local symbol = symbols[index]
                local x = 2 + column * column_width
                local y = 6 + row

                display.setCursorPos(x, y)
                display.clearLine()
                if symbol then
                    local text = string.format("[%02d] %s", index, tostring(symbol))
                    display.write(text:sub(1, column_width - 2))
                end
            end
        end

        display.setCursorPos(2, height - 1)
        display.clearLine()
        display.write("LEFT/RIGHT PAGE   B BACK")

        term.redirect(input_term)
        local _, key = os.pullEvent("key")
        term.redirect(display)

        if key == keys.left then
            page = math.max(1, page - 1)
        elseif key == keys.right then
            page = math.min(pages, page + 1)
        elseif key == keys.b then
            break
        end
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

local input_term = term.current()
local monitor = find_monitor()
local display = monitor or input_term

draw_symbols(display, symbols, input_term)
