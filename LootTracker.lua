_addon.name    = 'LootTracker'
_addon.author  = ''
_addon.version = '1.3'
_addon.commands = {'loottracker', 'lt'}

res     = require('resources')
config  = require('config')
texts   = require('texts')
packets = require('packets')
require('sets')

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

defaults.AutoDrop = false
defaults.SellList = S{}   -- item names (lowercase) to auto-sell

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
local RECENT_MAX   = 10
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
-- Reset
--------------------------------------------------------------------------------
local function reset()
    loot        = {}
    drop_order  = {}
    recent      = {}
    total_drops = 0
    update_display()
    update_recent()
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
            if entry.en then item_by_name[entry.en:lower()] = id end
        end
    end
    return item_by_name[name:lower()]
end

windower.register_event('incoming text', function(original)
    local text = strip_colors(original)

    -- Skip key item messages ("Obtained key item: ...")
    if text:lower():find('key item', 1, true) then return end

    -- Extract name (and optional count) from the three known patterns
    local name, count
    count = 1
    name = text:match('[Oo]btain[a-z]*:%s+(.-)%.')
    if not name then
        name = text:match('[Oo]btain[a-z]*%s+[Aa]n?%s+(.-)%.')
    end
    if not name then
        local qty, n = text:match('[Oo]btain[a-z]*%s+(%d+)%s+(.-)%.')
        if qty then count, name = tonumber(qty), n end
    end
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
        windower.add_to_chat(207, 'LootTracker: Display shown.')

    elseif command == 'hide' then
        visible = false
        display:hide()
        recent_display:hide()
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
