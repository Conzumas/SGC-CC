-- SGC-CC Glyph Reference
-- JSG symbol reference for a dedicated monitor computer.
--
-- Deployment:
--   * Run this program on a SECOND ComputerCraft computer.
--   * Connect that computer to the same wired modem network as the JSG gate.
--   * Connect a complete 3x3 monitor (or larger) to the second computer.
--   * Use LEFT/RIGHT to change pages and B or Q to exit.

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

local function draw_symbols(display, symbols, page)
    local previous = term.redirect(display)

    if display.setTextScale then
        display.setTextScale(0.5)
    end

    local width, height = display.getSize()
    local columns = 3
    local first_row = 6
    local footer_rows = 3
    local rows = math.max(1, math.min(13, height - first_row - footer_rows + 1))
    local column_width = math.max(1, math.floor(width / columns))
    local per_page = rows * columns
    local pages = math.max(1, math.ceil(#symbols / per_page))

    page = math.max(1, math.min(page, pages))
    local page_first = (page - 1) * per_page + 1

    display.clear()
    display.setCursorPos(1, 1)
    display.write("S T A R G A T E   G L Y P H   R E F E R E N C E")
    display.setCursorPos(1, 2)
    display.write("================================================")
    display.setCursorPos(1, 3)
    display.write("CODE = JSG SYMBOL-MAP INDEX")
    display.setCursorPos(1, 4)
    display.write(string.format("PAGE %d / %d    %d SYMBOLS    %d COLUMNS", page, pages, #symbols, columns))

    for local_index = 0, per_page - 1 do
        local index = page_first + local_index
        if index > #symbols then
            break
        end

        local column = math.floor(local_index / rows)
        local row = local_index % rows
        local x = 2 + column * column_width
        local y = first_row + row
        local symbol = tostring(symbols[index])
        local text = string.format("[%02d] %s", index, symbol)

        display.setCursorPos(x, y)
        display.write(text:sub(1, math.max(1, column_width - 2)))
    end

    display.setCursorPos(1, height - 2)
    display.write("LEFT/RIGHT PAGE    B/Q EXIT")
    display.setCursorPos(1, height - 1)
    display.write("INDEX = JSG MAP INDEX    EVERY GLYPH IS SHOWN")
    display.setCursorPos(1, height)
    display.write("SGC-CC | DEDICATED GLYPH REFERENCE")

    term.redirect(previous)
    return pages
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

local page = 1
while true do
    local pages = draw_symbols(monitor, symbols, page)
    local _, key = os.pullEvent("key")

    if key == keys.left then
        page = math.max(1, page - 1)
    elseif key == keys.right then
        page = math.min(pages, page + 1)
    elseif key == keys.b or key == keys.q then
        break
    end
end

term.redirect(term.native())
