_addon.name    = 'LootTracker'
_addon.author  = ''
_addon.version = '1.3'
_addon.commands = {'loottracker', 'lt'}

res     = require('resources')
config  = require('config')
texts   = require('texts')
packets = require('packets')
require('sets')
local https = require('ssl.https')
local ltn12 = require('ltn12')

--------------------------------------------------------------------------------
-- Default settings
--------------------------------------------------------------------------------
local defaults = {}
defaults.display = {}
defaults.display.pos = {}
defaults.display.pos.x = 100
defaults.display.pos.y = 100
defaults.display.bg = {}
defaults.display.bg.red     = 0
defaults.display.bg.green   = 0
defaults.display.bg.blue    = 0
defaults.display.bg.alpha   = 160
defaults.display.bg.visible = true
defaults.display.text = {}
defaults.display.text.font  = 'Consolas'
defaults.display.text.size  = 11
defaults.display.text.red   = 255
defaults.display.text.green = 255
defaults.display.text.blue  = 255
defaults.display.text.alpha = 255
defaults.display.flags = {}
defaults.display.flags.draggable = true

defaults.recent = {}
defaults.recent.pos = {}
defaults.recent.pos.x = 100
defaults.recent.pos.y = 300
defaults.recent.bg = {}
defaults.recent.bg.red     = 0
defaults.recent.bg.green   = 0
defaults.recent.bg.blue    = 0
defaults.recent.bg.alpha   = 160
defaults.recent.bg.visible = true
defaults.recent.text = {}
defaults.recent.text.font  = 'Consolas'
defaults.recent.text.size  = 11
defaults.recent.text.red   = 255
defaults.recent.text.green = 255
defaults.recent.text.blue  = 255
defaults.recent.text.alpha = 255
defaults.recent.flags = {}
defaults.recent.flags.draggable = true

defaults.prices = {}
defaults.prices.pos = {}
defaults.prices.pos.x = 330
defaults.prices.pos.y = 100
defaults.prices.bg = {}
defaults.prices.bg.red     = 0
defaults.prices.bg.green   = 0
defaults.prices.bg.blue    = 0
defaults.prices.bg.alpha   = 160
defaults.prices.bg.visible = true
defaults.prices.text = {}
defaults.prices.text.font  = 'Consolas'
defaults.prices.text.size  = 11
defaults.prices.text.red   = 255
defaults.prices.text.green = 255
defaults.prices.text.blue  = 255
defaults.prices.text.alpha = 255
defaults.prices.flags = {}
defaults.prices.flags.draggable = true

defaults.AutoDrop = false
defaults.SellList = S{}   -- item names (lowercase) to auto-sell
defaults.Server   = ''    -- FFXIAH server name (lowercase), e.g. 'ragnarok'

local settings = config.load(defaults)

--------------------------------------------------------------------------------
-- Color-stripping (same escape sequences as eatp_logger)
--------------------------------------------------------------------------------
local COLOR_PAT   = '[' .. string.char(0x1e, 0x1f) .. '].'
local COLOR_RESET = string.char(0x7f)
local function strip_colors(s)
    return (s:gsub(COLOR_PAT, ''):gsub(COLOR_RESET, ''))
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local RECENT_MAX        = 10
local PRICE_CACHE_TTL   = 86400     -- 24 hours
local PRICE_CACHE_PATH  = windower.addon_path .. 'data/price_cache.lua'
local NPC_PRICES_PATH   = windower.windower_path .. 'addons/Pricer/data/prices.lua'
local SERVER_IDS = {
    asura=28, bahamut=1, bismarck=25, carbuncle=6, cerberus=23,
    fenrir=7, lakshmi=27, leviathan=11, odin=12, phoenix=5,
    quetzalcoatl=16, ragnarok=20, shiva=2, siren=17, sylph=8, valefor=9,
    -- inactive
    alexander=10, caitsith=15, diabolos=14, fairy=30, garuda=22,
    gilgamesh=19, hades=32, ifrit=13, kujata=24, midgardsormr=29,
    pandemonium=21, ramuh=4, remora=31, seraph=26, titan=3, unicorn=18,
}

local function get_server_sid()
    if settings.Server == '' then return nil end
    return SERVER_IDS[settings.Server:lower()]
end

local function server_display_name()
    if settings.Server == '' then return nil end
    return settings.Server:sub(1,1):upper() .. settings.Server:sub(2)
end

local DROP_DELAY   = 0.5
local SELL_DELAY   = 1.0   -- seconds between each step in the sell sequence
local inventory_id = res.bags:with('english', 'Inventory').id

--------------------------------------------------------------------------------
-- Loot tracking state
--------------------------------------------------------------------------------
local loot        = {}   -- loot[item_id] = { name, count }
local drop_order  = {}   -- item_ids in first-seen order
local recent      = {}   -- last 10 drop names, newest at end
local total_drops = 0
local visible     = true
local price_cache = {}   -- price_cache[item_id] = most recent AH sale price

--------------------------------------------------------------------------------
-- FindAll snapshot state
--------------------------------------------------------------------------------
local findall_snap = nil

--------------------------------------------------------------------------------
-- Item copy state
--------------------------------------------------------------------------------
local last_confirmed_item = nil

--------------------------------------------------------------------------------
-- Sell state
--------------------------------------------------------------------------------
local sell_queue  = {}   -- list of { index, id, count, name }
local selling     = false

--------------------------------------------------------------------------------
-- Displays
--------------------------------------------------------------------------------
local display        = texts.new('', settings.display, settings)
local recent_display = texts.new('', settings.recent, settings)
local price_display  = texts.new('', settings.prices, settings)

local function update_display()
    if not visible or #drop_order == 0 then
        display:hide()
        return
    end

    local lines = { ('\\cs(255,200,80)[ LootTracker ]  %d drop%s this session\\cr'):format(
        total_drops, total_drops == 1 and '' or 's') }

    local sorted = {}
    for _, id in ipairs(drop_order) do
        sorted[#sorted + 1] = loot[id]
    end
    table.sort(sorted, function(a, b) return a.name:lower() < b.name:lower() end)

    for _, entry in ipairs(sorted) do
        if entry.count > 1 then
            lines[#lines + 1] = ('  \\cs(200,220,255)%s\\cr  x%d'):format(entry.name, entry.count)
        else
            lines[#lines + 1] = ('  \\cs(200,220,255)%s\\cr'):format(entry.name)
        end
    end

    display:text(table.concat(lines, '\n'))
    display:show()
end

local function update_recent()
    if not visible or #recent == 0 then
        recent_display:hide()
        return
    end

    local lines = { '\\cs(255,200,80)[ Recent Drops ]\\cr' }
    for i = #recent, 1, -1 do
        lines[#lines + 1] = ('  \\cs(200,220,255)%s\\cr'):format(recent[i])
    end

    recent_display:text(table.concat(lines, '\n'))
    recent_display:show()
end

--------------------------------------------------------------------------------
-- FindAll snapshot
--------------------------------------------------------------------------------
local function load_snapshot(silent)
    if not windower.ffxi.get_info().logged_in then
        if not silent then
            windower.add_to_chat(207, 'LootTracker: Must be logged in to load FindAll snapshot.')
        end
        return
    end

    local player_name = windower.ffxi.get_player().name
    local path = windower.windower_path .. 'addons/findAll/data/' .. player_name .. '.lua'

    if not windower.file_exists(path) then
        if not silent then
            windower.add_to_chat(207, 'LootTracker: FindAll snapshot not found for ' .. player_name .. '.')
            windower.add_to_chat(207, 'LootTracker: Install FindAll and run //findall once to generate it.')
        end
        return
    end

    local ok, result = pcall(dofile, path)
    if ok and type(result) == 'table' then
        findall_snap = result
        if not silent then
            windower.add_to_chat(207, 'LootTracker: FindAll snapshot loaded for ' .. player_name .. '.')
        end
    else
        findall_snap = nil
        windower.add_to_chat(207, 'LootTracker: Failed to parse FindAll snapshot: ' .. tostring(result))
    end
end

local function is_in_slip(item_id)
    if not findall_snap then return false end
    local key = tostring(item_id)
    for bag_name, contents in pairs(findall_snap) do
        if bag_name:match('^slip') and type(contents) == 'table' and contents[key] then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Shared stack analysis
--------------------------------------------------------------------------------
local function is_exclusive(item_data)
    local f = item_data.flags
    if not f or type(f) ~= 'table' then return false end
    return f['Ex'] or f['Exclusive'] or f['ex'] or false
end

local function run_shared_stacks()
    local data_path = windower.windower_path .. 'addons/findAll/data/'

    local snapshots = {}
    for _, filename in ipairs(windower.get_dir(data_path)) do
        local char_name = filename:match('^(.+)%.lua$')
        if char_name then
            local ok, snap = pcall(dofile, data_path .. filename)
            if ok and type(snap) == 'table' then
                local totals = {}
                for bag_name, contents in pairs(snap) do
                    if bag_name ~= 'key items' and type(contents) == 'table' then
                        for id_str, count in pairs(contents) do
                            local id = tonumber(id_str)
                            if id then totals[id] = (totals[id] or 0) + count end
                        end
                    end
                end
                snapshots[char_name] = totals
            end
        end
    end

    local char_count = 0
    for _ in pairs(snapshots) do char_count = char_count + 1 end

    if char_count < 2 then
        windower.add_to_chat(207, 'LootTracker: Need FindAll snapshots for at least 2 characters to compare.')
        return
    end

    local item_chars = {}
    for char_name, totals in pairs(snapshots) do
        for item_id, count in pairs(totals) do
            if count > 0 then
                if not item_chars[item_id] then item_chars[item_id] = {} end
                item_chars[item_id][#item_chars[item_id] + 1] = { name = char_name, count = count }
            end
        end
    end

    local results = {}
    for item_id, chars in pairs(item_chars) do
        if #chars >= 2 then
            local d = res.items[item_id]
            if d and d.stack and d.stack > 1 and not is_exclusive(d) then
                results[#results + 1] = { name = d.en, chars = chars }
            end
        end
    end

    if #results == 0 then
        windower.add_to_chat(207, 'LootTracker: No shared stackable/transferrable items found.')
        return
    end

    table.sort(results, function(a, b) return a.name:lower() < b.name:lower() end)

    windower.add_to_chat(207, ('LootTracker: %d shared item%s across %d characters:'):format(
        #results, #results == 1 and '' or 's', char_count))
    for _, entry in ipairs(results) do
        table.sort(entry.chars, function(a, b) return a.name:lower() < b.name:lower() end)
        local parts = {}
        for _, c in ipairs(entry.chars) do
            parts[#parts + 1] = ('%s x%d'):format(c.name, c.count)
        end
        windower.add_to_chat(207, ('  %s: %s'):format(entry.name, table.concat(parts, ', ')))
    end
end

--------------------------------------------------------------------------------
-- Auto-drop helpers
--------------------------------------------------------------------------------
local function exec_drop(index, count)
    windower.ffxi.drop_item(index, count)
end

local function check_and_drop(index, item_id, count, delay)
    if item_id == 0 or not is_in_slip(item_id) then return false end
    local item_name = (res.items[item_id] and res.items[item_id].en) or ('Item #' .. item_id)
    windower.add_to_chat(207, ('LootTracker: Dropping %s — already in slip storage.'):format(item_name))
    windower.send_command(('wait %s; lua c loottracker _drop %d %d'):format(delay, index, count))
    return true
end

local function find_droppable()
    local inventory = windower.ffxi.get_items('inventory')
    local matches   = {}
    for index, item in pairs(inventory) do
        if type(item) == 'table' and item.id ~= 0 and is_in_slip(item.id) then
            local name = (res.items[item.id] and res.items[item.id].en) or ('Item #' .. item.id)
            matches[#matches + 1] = { index = index, id = item.id, count = item.count, name = name }
        end
    end
    table.sort(matches, function(a, b) return a.name:lower() < b.name:lower() end)
    return matches
end

local function preview_drop()
    load_snapshot(true)
    if not findall_snap then
        windower.add_to_chat(207, 'LootTracker: No FindAll snapshot loaded. Run //lt refresh first.')
        return
    end
    local matches = find_droppable()
    if #matches == 0 then
        windower.add_to_chat(207, 'LootTracker: No inventory items matched slip storage.')
        return
    end
    windower.add_to_chat(207, ('LootTracker: %d item%s would be dropped (run //lt drop to execute):'):format(
        #matches, #matches == 1 and '' or 's'))
    for _, entry in ipairs(matches) do
        windower.add_to_chat(207, ('  - %s'):format(entry.name))
    end
end

local function scan_and_drop()
    load_snapshot(true)
    if not findall_snap then
        windower.add_to_chat(207, 'LootTracker: No FindAll snapshot loaded. Run //lt refresh first.')
        return
    end
    local matches = find_droppable()
    if #matches == 0 then
        windower.add_to_chat(207, 'LootTracker: No inventory items matched slip storage.')
        return
    end
    local delay = DROP_DELAY
    for _, entry in ipairs(matches) do
        windower.add_to_chat(207, ('LootTracker: Dropping %s — already in slip storage.'):format(entry.name))
        windower.send_command(('wait %s; lua c loottracker _drop %d %d'):format(delay, entry.index, entry.count))
        delay = delay + DROP_DELAY
    end
    windower.add_to_chat(207, ('LootTracker: Scheduled %d item%s to drop.'):format(
        #matches, #matches == 1 and '' or 's'))
end

--------------------------------------------------------------------------------
-- Sell helpers
--------------------------------------------------------------------------------
local function find_sellable()
    if settings.SellList:empty() then return {} end
    local inventory = windower.ffxi.get_items('inventory')
    local matches   = {}
    for index, item in pairs(inventory) do
        if type(item) == 'table' and item.id ~= 0 then
            local item_data = res.items[item.id]
            if item_data and settings.SellList:contains(item_data.en:lower()) then
                matches[#matches + 1] = {
                    index = index,
                    id    = item.id,
                    count = item.count,
                    name  = item_data.en,
                }
            end
        end
    end
    table.sort(matches, function(a, b) return a.name:lower() < b.name:lower() end)
    return matches
end

-- Send the price query packet for the front of the sell queue.
local function sell_next()
    if #sell_queue == 0 then
        selling = false
        windower.add_to_chat(207, 'LootTracker: Finished selling.')
        return
    end

    local entry = sell_queue[1]
    local pkt = packets.new('outgoing', 0x084, {
        ['Count']           = entry.count,
        ['Item']            = entry.id,
        ['Inventory Index'] = entry.index,
    })
    packets.inject(pkt)
end

local function start_sell()
    if selling then
        windower.add_to_chat(207, 'LootTracker: A sell is already in progress.')
        return
    end
    if settings.SellList:empty() then
        windower.add_to_chat(207, 'LootTracker: Sell list is empty. Use //lt sell add <name> to add items.')
        return
    end

    sell_queue = find_sellable()
    if #sell_queue == 0 then
        windower.add_to_chat(207, 'LootTracker: No matching items found in inventory.')
        return
    end

    windower.add_to_chat(207, ('LootTracker: Selling %d stack%s. Make sure the NPC sell window is open.'):format(
        #sell_queue, #sell_queue == 1 and '' or 's'))
    selling = true
    sell_next()
end

local function preview_sell()
    local matches = find_sellable()
    if #matches == 0 then
        windower.add_to_chat(207, 'LootTracker: No inventory items matched the sell list.')
        return
    end
    windower.add_to_chat(207, ('LootTracker: %d stack%s would be sold (run //lt sell to execute):'):format(
        #matches, #matches == 1 and '' or 's'))
    for _, entry in ipairs(matches) do
        windower.add_to_chat(207, ('  - %s x%d'):format(entry.name, entry.count))
    end
end

--------------------------------------------------------------------------------
-- AH price lookup
--------------------------------------------------------------------------------
local function comma_value(n)
    local left, num, right = string.match(tostring(n), '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right
end

local function format_sale_date(ts)
    if tonumber(os.date('%Y', ts)) == tonumber(os.date('%Y')) then
        return os.date('%b %d', ts)
    else
        return os.date("%b '%y", ts)
    end
end

local function get_npc_price(item_id)
    if not windower.file_exists(NPC_PRICES_PATH) then return nil end
    local ok, prices = pcall(dofile, NPC_PRICES_PATH)
    if ok and type(prices) == 'table' then return prices[item_id] end
    return nil
end

local function save_price_cache()
    local lines = {'return {'}
    for id, info in pairs(price_cache) do
        lines[#lines + 1] = ('    [%d]={latest=%d,last_date=%d,avg7=%s,count7=%d,fetched_at=%d},'):format(
            id, info.latest, info.last_date,
            info.avg7 and tostring(info.avg7) or 'nil',
            info.count7, info.fetched_at)
    end
    lines[#lines + 1] = '}'
    local f = io.open(PRICE_CACHE_PATH, 'w')
    if f then
        f:write(table.concat(lines, '\n'))
        f:close()
    end
end

local function load_price_cache()
    if not windower.file_exists(PRICE_CACHE_PATH) then return end
    local ok, result = pcall(dofile, PRICE_CACHE_PATH)
    if ok and type(result) == 'table' then
        price_cache = result
    end
end

local function cache_age_str(fetched_at)
    local age = os.time() - fetched_at
    if age < 3600 then
        return ('cached %dm ago'):format(math.floor(age / 60))
    else
        return ('cached %dh ago'):format(math.floor(age / 3600))
    end
end

local function get_ah_price(item_id, force_refresh)
    local cached = price_cache[item_id]
    if cached and not force_refresh and (os.time() - cached.fetched_at) < PRICE_CACHE_TTL then
        return cached, true
    end
    local sid = get_server_sid()
    if not sid then return nil end
    local result_table = {}
    local ok = pcall(function()
        https.request{
            url     = 'https://www.ffxiah.com/item/' .. item_id,
            sink    = ltn12.sink.table(result_table),
            headers = { cookie = 'sid=' .. sid },
        }
    end)
    if not ok then return cached, true end  -- return stale data if network fails
    local body = table.concat(result_table)
    local sales_str = body:match('Item%.sales%s*=%s*(.-);')
    if not sales_str or sales_str == 'null' or sales_str == '[]' then return nil end

    local week_ago = os.time() - 7 * 86400
    local latest_price, latest_saleon
    local sum7, count7 = 0, 0

    for entry_str in sales_str:gmatch('{(.-)}') do
        local saleon = tonumber(entry_str:match('"saleon":(%d+)'))
        local price  = tonumber(entry_str:match('"price":(%d+)'))
        if saleon and price then
            if not latest_saleon or saleon > latest_saleon then
                latest_saleon = saleon
                latest_price  = price
            end
            if saleon >= week_ago then
                sum7   = sum7 + price
                count7 = count7 + 1
            end
        end
    end

    if not latest_price then return nil end

    local info = {
        latest     = latest_price,
        last_date  = latest_saleon,
        avg7       = count7 > 0 and math.floor(sum7 / count7) or nil,
        count7     = count7,
        fetched_at = os.time(),
    }
    price_cache[item_id] = info
    save_price_cache()
    return info, false
end

local function update_price_display()
    if not visible or #drop_order == 0 then
        price_display:hide()
        return
    end

    local sorted_keys = {}
    for _, key in ipairs(drop_order) do
        if type(key) == 'number' and price_cache[key] then
            sorted_keys[#sorted_keys + 1] = key
        end
    end
    table.sort(sorted_keys, function(a, b)
        return (loot[a] and loot[a].name or ''):lower() < (loot[b] and loot[b].name or ''):lower()
    end)

    if #sorted_keys == 0 then
        price_display:hide()
        return
    end

    local lines = { ('\\cs(255,200,80)[ AH Prices — %s ]\\cr'):format(server_display_name() or 'Unknown') }
    for _, key in ipairs(sorted_keys) do
        local entry = loot[key]
        local info  = price_cache[key]
        local avg_str = info.avg7
            and (comma_value(info.avg7) .. ' g \xc3\x97' .. info.count7)
            or  '\\cs(128,128,128)---\\cr'
        lines[#lines + 1] = ('  \\cs(200,220,255)%s\\cr  \\cs(180,255,180)%s g\\cr  7d: %s  %s'):format(
            entry.name, comma_value(info.latest), avg_str, format_sale_date(info.last_date))
    end

    price_display:text(table.concat(lines, '\n'))
    price_display:show()
end

local function fetch_prices(force_refresh)
    if settings.Server == '' then
        windower.add_to_chat(207, 'LootTracker: No server set. Use //lt server <name> to set your server (e.g. //lt server ragnarok).')
        return
    end
    local items = {}
    for _, key in ipairs(drop_order) do
        if type(key) == 'number' then
            items[#items + 1] = key
        end
    end
    if #items == 0 then
        windower.add_to_chat(207, 'LootTracker: No priceable items in current session.')
        return
    end
    windower.add_to_chat(207, ('LootTracker: %s AH prices for %d item%s...'):format(
        force_refresh and 'Refreshing' or 'Fetching', #items, #items == 1 and '' or 's'))
    local fetched = 0
    for _, item_id in ipairs(items) do
        if get_ah_price(item_id, force_refresh) then fetched = fetched + 1 end
    end
    windower.add_to_chat(207, ('LootTracker: Got prices for %d/%d items.'):format(fetched, #items))
    update_price_display()
end

--------------------------------------------------------------------------------
-- Reset
--------------------------------------------------------------------------------
local function reset()
    loot        = {}
    drop_order  = {}
    recent      = {}
    total_drops = 0
    update_display()
    update_recent()
    update_price_display()
    windower.add_to_chat(207, 'LootTracker: Session reset.')
end

--------------------------------------------------------------------------------
-- Incoming chunk handler
--------------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data)

    -- Treasure pool drop
    if id == 0x0D2 then
        local pkt = packets.parse('incoming', data)
        if pkt.Item == 0 or pkt.Old then return end

        local item_id   = pkt.Item
        local item_name

        if item_id == 0xFFFF then
            item_name = ('Gil (%d)'):format(pkt.Count)
            item_id   = 'gil'
        else
            item_name = (res.items[item_id] and res.items[item_id].en) or ('Item #' .. item_id)
        end

        if loot[item_id] then
            loot[item_id].count = loot[item_id].count + 1
        else
            loot[item_id] = { name = item_name, count = 1 }
            drop_order[#drop_order + 1] = item_id
        end
        total_drops = total_drops + 1

        recent[#recent + 1] = item_name
        if #recent > RECENT_MAX then table.remove(recent, 1) end

        update_display()
        update_recent()

    -- NPC sell response
    elseif id == 0x03D and selling then
        local pkt = packets.parse('incoming', data)

        if pkt.Type == 0 then
            -- Server returned price — confirm the sale after a short delay
            windower.send_command(('wait %s; lua c loottracker _sell_confirm'):format(SELL_DELAY))

        elseif pkt.Type == 1 then
            -- Sale finalised — log it and start the next item after a delay
            local entry = table.remove(sell_queue, 1)
            windower.add_to_chat(207, ('LootTracker: Sold %s x%d.'):format(entry.name, entry.count))
            windower.send_command(('wait %s; lua c loottracker _sell_next'):format(SELL_DELAY))
        end
    end

end)

--------------------------------------------------------------------------------
-- "Obtained" chat message handler
--------------------------------------------------------------------------------
local item_by_name = nil  -- lazy reverse-lookup cache: lower(en) -> id

local function get_item_id_by_name(name)
    if not item_by_name then
        item_by_name = {}
        for id, entry in pairs(res.items) do
            if entry.en  then item_by_name[entry.en:lower()]  = id end
            if entry.enl then item_by_name[entry.enl:lower()] = id end
        end
    end
    return item_by_name[name:lower()]
end

windower.register_event('incoming text', function(original)
    local text = strip_colors(original)

    -- Skip key item messages ("Obtained key item: ...")
    if text:lower():find('key item', 1, true) then return end

    -- Only match the "Obtained: <item>." colon form (special/event obtainments).
    -- Treasure pool messages ("Player obtains a ...") are already captured via 0x0D2.
    local name, count
    count = 1
    name = text:match('[Oo]btained?:%s+(.-)%.')
    if not name then return end

    name = name:match('^%s*(.-)%s*$')  -- trim

    -- Resolve to item_id when possible so it deduplicates with treasure pool entries
    local item_id  = get_item_id_by_name(name)
    local key      = item_id or ('obt:' .. name:lower())
    local disp     = item_id and res.items[item_id].en or name

    if loot[key] then
        loot[key].count = loot[key].count + count
    else
        loot[key] = { name = disp, count = count }
        drop_order[#drop_order + 1] = key
    end
    total_drops = total_drops + count

    recent[#recent + 1] = count > 1 and (disp .. ' x' .. count) or disp
    if #recent > RECENT_MAX then table.remove(recent, 1) end

    update_display()
    update_recent()
end)

--------------------------------------------------------------------------------
-- Item interaction handler (tracks last used/equipped item for clipboard copy)
--------------------------------------------------------------------------------
windower.register_event('outgoing chunk', function(id, data, modified, injected)
    local item_id

    if id == 0x037 then
        local p = packets.parse('outgoing', data)
        local item = windower.ffxi.get_items(p['Bag'], p['Slot'])
        if item and item.id and item.id > 0 then
            item_id = item.id
        end
    elseif id == 0x050 then
        local p = packets.parse('outgoing', data)
        if p['Item Index'] and p['Item Index'] > 0 then
            local item = windower.ffxi.get_items(p['Bag'], p['Item Index'])
            if item and item.id and item.id > 0 then
                item_id = item.id
            end
        end
    elseif id == 0x084 and not injected then
        -- NPC sell price query (manual only — skip LootTracker's own injected appraisals)
        local p = packets.parse('outgoing', data)
        if p['Item'] and p['Item'] > 0 then
            item_id = p['Item']
        end
    end

    if item_id then
        local entry = res.items[item_id]
        if entry then
            last_confirmed_item = entry.en
        end
    end
end)

--------------------------------------------------------------------------------
-- Inventory arrival handler (auto-drop)
--------------------------------------------------------------------------------
windower.register_event('add item', function(bag, index, id, count)
    if bag ~= inventory_id then return end
    if id == 0 then return end
    if not settings.AutoDrop then return end
    check_and_drop(index, id, count, DROP_DELAY)
end)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
windower.register_event('load', function()
    windower.send_command('bind ^~c lua c loottracker copy')
    load_price_cache()
    if windower.ffxi.get_info().logged_in then
        load_snapshot()
        update_display()
        update_recent()
    end
end)

windower.register_event('unload', function()
    windower.send_command('unbind ^~c')
end)

windower.register_event('login', function()
    load_snapshot()
end)

windower.register_event('zone change', function()
    reset()
end)

windower.register_event('logout', function()
    findall_snap = nil
    selling      = false
    sell_queue   = {}
    display:hide()
    recent_display:hide()
    price_display:hide()
end)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
windower.register_event('addon command', function(command, ...)
    command = (command or 'help'):lower()
    local args = {...}

    -- Loot display
    if command == 'reset' or command == 'r' then
        reset()

    elseif command == 'show' then
        visible = true
        update_display()
        update_recent()
        update_price_display()
        windower.add_to_chat(207, 'LootTracker: Display shown.')

    elseif command == 'hide' then
        visible = false
        display:hide()
        recent_display:hide()
        price_display:hide()
        windower.add_to_chat(207, 'LootTracker: Display hidden.')

    -- Copy full inventory CSV to clipboard
    elseif command == 'copyall' then
        local all_items = windower.ffxi.get_items()
        local bag_names = {
            'inventory', 'safe', 'storage', 'locker',
            'satchel', 'sack', 'case', 'wardrobe',
            'safe2', 'wardrobe2', 'wardrobe3', 'wardrobe4',
            'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
        }
        local lines = {'bag,item_id,item_name,count'}
        for _, bag_name in ipairs(bag_names) do
            local bag = all_items[bag_name]
            if bag then
                for _, item in pairs(bag) do
                    if type(item) == 'table' and item.id and item.id > 0 then
                        local entry = res.items[item.id]
                        local name = entry and entry.en or ('Item #' .. item.id)
                        lines[#lines + 1] = ('%s,%d,"%s",%d'):format(bag_name, item.id, name, item.count)
                    end
                end
            end
        end
        if #lines == 1 then
            windower.add_to_chat(207, 'LootTracker: All bags are empty.')
        else
            windower.copy_to_clipboard(table.concat(lines, '\n'))
            windower.add_to_chat(207, ('LootTracker: Copied %d items to clipboard.'):format(#lines - 1))
        end

    -- Clipboard copy
    elseif command == 'copy' then
        if last_confirmed_item then
            windower.copy_to_clipboard(last_confirmed_item)
            windower.add_to_chat(207, ('LootTracker: Copied "%s" to clipboard.'):format(last_confirmed_item))
        else
            windower.add_to_chat(207, 'LootTracker: No item selected yet — use or equip an item first.')
        end

    -- Auto-drop
    elseif command == 'autodrop' then
        local arg = args[1] and args[1]:lower()
        if arg == 'on' then
            settings.AutoDrop = true
        elseif arg == 'off' then
            settings.AutoDrop = false
        else
            settings.AutoDrop = not settings.AutoDrop
        end
        config.save(settings)
        windower.add_to_chat(207, 'LootTracker: Auto-drop ' .. (settings.AutoDrop and 'enabled.' or 'disabled.'))

    elseif command == 'preview' or command == 'p' then
        preview_drop()

    elseif command == 'drop' then
        scan_and_drop()

    elseif command == 'refresh' then
        load_snapshot()

    elseif command == 'price' then
        if settings.Server == '' then
            windower.add_to_chat(207, 'LootTracker: No server set. Use //lt server <name> to set your server (e.g. //lt server ragnarok).')
        else
        for i = 1, #args do args[i] = windower.convert_auto_trans(args[i]) end
        local force_refresh = args[1] and args[1]:lower() == 'refresh'
        local name_start    = force_refresh and 2 or 1
        local name          = strip_colors(table.concat(args, ' ', name_start))

        if name == '' then
            fetch_prices(force_refresh)
        else
            local item_id = get_item_id_by_name(name)
            if not item_id then
                windower.add_to_chat(207, ('LootTracker: Item "%s" not found.'):format(name))
            else
                local item_name = (res.items[item_id] and res.items[item_id].en) or name
                windower.add_to_chat(207, ('LootTracker: %s price for %s...'):format(
                    force_refresh and 'Refreshing' or 'Fetching', item_name))
                local info, from_cache = get_ah_price(item_id, force_refresh)
                if info then
                    local avg_str    = info.avg7
                        and (comma_value(info.avg7) .. ' g (' .. info.count7 .. ' sale' .. (info.count7 == 1 and '' or 's') .. ')')
                        or  'no sales in last 7 days'
                    local cache_note = from_cache and (' (' .. cache_age_str(info.fetched_at) .. ')') or ''
                    local npc_price  = get_npc_price(item_id)
                    windower.add_to_chat(207, ('LootTracker: %s%s'):format(item_name, cache_note))
                    windower.add_to_chat(207, ('  AH: %s g  |  7d avg: %s  |  Last sold: %s'):format(
                        comma_value(info.latest), avg_str, format_sale_date(info.last_date)))
                    if npc_price then
                        windower.add_to_chat(207, ('  NPC: %s g'):format(comma_value(npc_price)))
                    end
                else
                    windower.add_to_chat(207, ('LootTracker: No AH data found for %s.'):format(item_name))
                end
            end
        end
        end -- server check

    elseif command == 'server' then
        local name = args[1] and args[1]:lower() or ''
        if name == '' then
            if settings.Server == '' then
                windower.add_to_chat(207, 'LootTracker: No server set. Use //lt server <name> (e.g. //lt server ragnarok).')
            else
                windower.add_to_chat(207, ('LootTracker: Current server: %s'):format(server_display_name()))
            end
        elseif not SERVER_IDS[name] then
            windower.add_to_chat(207, ('LootTracker: Unknown server "%s".'):format(args[1]))
            windower.add_to_chat(207, 'LootTracker: Active servers: Asura, Bahamut, Bismarck, Carbuncle, Cerberus, Fenrir, Lakshmi, Leviathan, Odin, Phoenix, Quetzalcoatl, Ragnarok, Shiva, Siren, Sylph, Valefor')
        else
            settings.Server = name
            config.save(settings)
            windower.add_to_chat(207, ('LootTracker: Server set to %s.'):format(server_display_name()))
        end

    elseif command == 'shared' then
        windower.send_ipc_message('findAll update')
        windower.send_command('wait 0.5; lua c loottracker _shared_run')

    elseif command == '_shared_run' then
        run_shared_stacks()

    -- Sell
    elseif command == 'sell' then
        local sub = args[1] and args[1]:lower()

        if sub == nil then
            start_sell()

        elseif sub == 'preview' then
            preview_sell()

        elseif sub == 'stop' then
            if selling then
                selling    = false
                sell_queue = {}
                windower.add_to_chat(207, 'LootTracker: Sell stopped.')
            else
                windower.add_to_chat(207, 'LootTracker: No sell in progress.')
            end

        elseif sub == 'add' then
            local name = table.concat(args, ' ', 2):lower()
            if name == '' then
                windower.add_to_chat(207, 'LootTracker: Usage: //lt sell add <item name>')
            else
                settings.SellList:add(name)
                config.save(settings)
                windower.add_to_chat(207, ('LootTracker: Added "%s" to sell list.'):format(name))
            end

        elseif sub == 'remove' then
            local name = table.concat(args, ' ', 2):lower()
            if name == '' then
                windower.add_to_chat(207, 'LootTracker: Usage: //lt sell remove <item name>')
            elseif settings.SellList:contains(name) then
                settings.SellList:remove(name)
                config.save(settings)
                windower.add_to_chat(207, ('LootTracker: Removed "%s" from sell list.'):format(name))
            else
                windower.add_to_chat(207, ('LootTracker: "%s" is not in the sell list.'):format(name))
            end

        elseif sub == 'list' then
            if settings.SellList:empty() then
                windower.add_to_chat(207, 'LootTracker: Sell list is empty.')
            else
                windower.add_to_chat(207, 'LootTracker: Sell list:')
                for name in settings.SellList:it() do
                    windower.add_to_chat(207, '  - ' .. name)
                end
            end

        elseif sub == 'clear' then
            settings.SellList:clear()
            config.save(settings)
            windower.add_to_chat(207, 'LootTracker: Sell list cleared.')

        else
            windower.add_to_chat(207, 'LootTracker: Unknown sell subcommand. See //lt help.')
        end

    -- Internal deferred commands (via send_command wait)
    elseif command == '_drop' then
        local index = tonumber(args[1])
        local count = tonumber(args[2])
        if index and count then exec_drop(index, count) end

    elseif command == '_sell_confirm' then
        if selling then
            local confirm = packets.new('outgoing', 0x085)
            packets.inject(confirm)
        end

    elseif command == '_sell_next' then
        if selling then sell_next() end

    else
        windower.add_to_chat(207, 'LootTracker v' .. _addon.version)
        windower.add_to_chat(207, '  //lt copy                  - Copy last used/equipped item name to clipboard (also Ctrl+Shift+C)')
        windower.add_to_chat(207, '  //lt copyall               - Copy all bag contents to clipboard as CSV')
        windower.add_to_chat(207, '  //lt reset                 - Clear the session loot log')
        windower.add_to_chat(207, '  //lt show/hide             - Toggle both displays')
        windower.add_to_chat(207, '  //lt autodrop [on|off]     - Toggle auto-drop of slip-stored items')
        windower.add_to_chat(207, '  //lt preview               - Show what //lt drop would discard')
        windower.add_to_chat(207, '  //lt drop                  - Drop all slip-stored items from inventory')
        windower.add_to_chat(207, '  //lt refresh               - Reload FindAll snapshot from disk')
        windower.add_to_chat(207, '  //lt server <name>         - Set your FFXIAH server (e.g. ragnarok, asura)')
        windower.add_to_chat(207, '  //lt price                 - Fetch AH prices for this session\'s loot')
        windower.add_to_chat(207, '  //lt price <item name>     - Fetch AH price for a specific item by name')
        windower.add_to_chat(207, '  //lt price refresh         - Force-refresh session loot prices (bypass 24h cache)')
        windower.add_to_chat(207, '  //lt price refresh <name>  - Force-refresh price for a specific item')
        windower.add_to_chat(207, '  //lt shared               - Show stackable items split across all characters')
        windower.add_to_chat(207, '  //lt sell                  - Sell inventory items on the sell list')
        windower.add_to_chat(207, '  //lt sell preview          - Show what //lt sell would sell')
        windower.add_to_chat(207, '  //lt sell add <name>       - Add item to sell list')
        windower.add_to_chat(207, '  //lt sell remove <name>    - Remove item from sell list')
        windower.add_to_chat(207, '  //lt sell list             - Show current sell list')
        windower.add_to_chat(207, '  //lt sell clear            - Clear the sell list')
        windower.add_to_chat(207, '  //lt sell stop             - Abort an in-progress sell')
        windower.add_to_chat(207, '  //lt help                  - Show this help')
    end
end)
