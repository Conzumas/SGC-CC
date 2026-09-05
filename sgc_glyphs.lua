-- SGC-CC Glyph Reference
-- Lists the exact symbol names exposed by the connected JSG stargate.
--
-- This is intentionally a separate utility so the main control program
-- remains unchanged while the glyph/address input workflow is tested.

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

local function get_symbols(gate)
    local ok, symbols = pcall(gate.getSymbolsMap)
    if not ok or type(symbols) ~= "table" then
        return nil
    end

    return symbols
end

local function draw_symbols(symbols)
    term.clear()
    term.setCursorPos(1, 1)
    term.write("S T A R G A T E   G L Y P H   R E F E R E N C E")
    term.setCursorPos(1, 2)
    term.write("================================================")
    term.setCursorPos(1, 3)
    term.write("JSG symbol order shown below; use these names in SGC.")

    local width, height = term.getSize()
    local columns = 2
    local rows = math.max(1, height - 6)
    local per_page = columns * rows
    local pages = math.max(1, math.ceil(#symbols / per_page))
    local page = 1

    while true do
        term.setCursorPos(1, 5)
        term.clearLine()
        term.write(string.format("PAGE %d / %d", page, pages))

        for row = 0, rows - 1 do
            for column = 0, columns - 1 do
                local index = (page - 1) * per_page + row + column * rows + 1
                local symbol = symbols[index]
                local x = 2 + column * math.floor(width / columns)
                local y = 6 + row

                term.setCursorPos(x, y)
                term.clearLine()
                if symbol then
                    local text = string.format("[%02d] %s", index, tostring(symbol))
                    term.write(text:sub(1, math.floor(width / columns) - 2))
                end
            end
        end

        term.setCursorPos(2, height - 1)
        term.write("LEFT/RIGHT PAGE   B BACK")

        local _, key = os.pullEvent("key")
        if key == keys.left then
            page = math.max(1, page - 1)
        elseif key == keys.right then
            page = math.min(pages, page + 1)
        elseif key == keys.b then
            return
        end
    end
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

draw_symbols(symbols)
