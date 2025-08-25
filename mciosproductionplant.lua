--[[
=====================================================================
 MCIOS Production Manager (Expanded + Create Tanks + Fast Transfers)
 ComputerCraft Lua
=====================================================================
 Features:
   - Vault + multiple chests
   - Multiple tanks (Create tanks supported via tanks(), pushFluid, pullFluid)
   - Aggregated storage display (sum identical items across all inventories)
   - Three monitors by role: storage / tanks / processes+logs
   - Colored logs (ok/green, warn/yellow, err/red)
   - Routes (simple item -> dest listing)
   - Returners: peripherals auto-swept back to vault
   - Recipes:
       * Count-based OR percent-based (mixable)
       * Multiple outputs per recipe (round-robin)
       * Per-recipe transfer delay (0 = as fast as possible)
   - Test Mode (dry-run)
   - Persistent state save/load
   - Parallel loops: UI, monitors, production, returners
=====================================================================
]]


---------------------------------------------------------------------
-- STATE & PERSISTENCE
---------------------------------------------------------------------

local STATE_FILE = "prod_manager_state_v4.txt"

local state = {
  vault       = nil,            -- string: peripheral name of vault inventory
  chests      = {},             -- array of peripheral names (inventories)
  tanks       = {},             -- array of peripheral names (tanks)
  monitors    = {               -- role->monitor name
    storage = nil,              -- periph name
    tanks   = nil,              -- periph name
    process = nil,              -- periph name
  },
  routes      = {},             -- map itemName -> dest peripheral (not used by recipes directly)
  returners   = {},             -- array of peripheral names (inventories to sweep back to vault)
  recipes     = {},             -- map recipeName -> recipeTable
  production  = false,          -- bool: production on/off
  logs        = {},             -- array of {text, level("ok"/"warn"/"err"), time}
  settings    = {               -- global settings
    tankShowEmpty = true,       -- show tanks even if empty (if info available)
    sortItemsBy   = "count",    -- "count" or "name"
    itemBarWidth  = 24,         -- storage bar width for items
    tankBarWidth  = 36,         -- tanks bar width
    percentBase   = 64,         -- base bucket for percent recipes per cycle
    monitorRefresh= 1.5,        -- seconds between monitor refreshes
    productionTick= 0.5,        -- seconds between production ticks
    returnerTick  = 3.0,        -- seconds between returner sweeps
  }
}

local function saveState()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize(state))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  if not f then return end
  local s = f.readAll()
  f.close()
  local ok, t = pcall(textutils.unserialize, s)
  if ok and type(t) == "table" then
    -- merge defaults
    for k,v in pairs(state) do
      if t[k] == nil then t[k] = v end
    end
    t.monitors = t.monitors or {}
    if type(t.monitors) ~= "table" then t.monitors = {} end
    t.monitors.storage = t.monitors.storage or nil
    t.monitors.tanks   = t.monitors.tanks   or nil
    t.monitors.process = t.monitors.process or nil
    t.returners = t.returners or {}
    t.settings  = t.settings or state.settings
    -- Ensure per-recipe delay exists
    for _,r in pairs(t.recipes or {}) do
      if r.delay == nil then r.delay = 0.05 end
      if r.rrIndex == nil then r.rrIndex = 1 end
    end
    state = t
  end
end

loadState()


---------------------------------------------------------------------
-- LOGGING
---------------------------------------------------------------------

local function addLog(msg, level)
  level = level or "ok" -- "ok","warn","err"
  table.insert(state.logs, { text = msg, level = level, time = textutils.formatTime(os.time(), true) })
  if #state.logs > 80 then table.remove(state.logs, 1) end
end


---------------------------------------------------------------------
-- UTILS
---------------------------------------------------------------------

local function wrap(name)
  if not name then return nil end
  if peripheral.isPresent(name) then
    return peripheral.wrap(name)
  end
  return nil
end

local function isInv(p)
  return p and p.list and p.getItemDetail and p.pushItems
end

local function isTank(p)
  if not p then return false end
  return (p.tanks ~= nil) or (p.getFluidInTank ~= nil) or (p.getFluid ~= nil)
end

local function prompt(label)
  io.write(label or "> ")
  return read()
end

local function toNumber(s)
  local n = tonumber(s)
  return n
end

local function selectFrom(list, title)
  if #list == 0 then return nil end
  print(title or "Select:")
  for i,v in ipairs(list) do print(("%d) %s"):format(i, tostring(v))) end
  io.write("> ")
  local n = tonumber(read())
  if n and list[n] then return list[n], n end
  return nil
end

local function padRight(s, n)
  s = tostring(s or "")
  if #s >= n then return s end
  return s .. string.rep(" ", n - #s)
end

-- Table shallow copy
local function tcopy(t)
  local n = {}
  for k,v in pairs(t) do n[k] = v end
  return n
end


---------------------------------------------------------------------
-- TANK FLUID NORMALIZATION (Create tanks first)
---------------------------------------------------------------------

-- Returns array of {name, amount, capacity}
local function getTankFluids(name)
  local p = wrap(name)
  if not p then return {} end

  -- Prefer Create tanks API (tanks/pushFluid/pullFluid)
  if p.tanks then
    local arr = p.tanks() or {}
    local out = {}
    for _,f in ipairs(arr) do
      if f and f.amount and f.capacity then
        table.insert(out, {
          name = f.name or f.label or "fluid",
          amount = f.amount or 0,
          capacity = f.capacity or 0
        })
      end
    end
    if #out > 0 then return out end
  end

  -- CC general getFluidInTank
  if p.getFluidInTank then
    local arr = p.getFluidInTank() or {}
    local out = {}
    for _,f in ipairs(arr) do
      if f and f.amount and f.capacity then
        table.insert(out, {
          name = f.name or f.label or "fluid",
          amount = f.amount or 0,
          capacity = f.capacity or 0
        })
      end
    end
    if #out > 0 then return out end
  end

  -- Some mods: single tank getFluid
  if p.getFluid then
    local f = p.getFluid()
    if f and f.amount and f.capacity then
      return {{
        name = f.name or f.label or "fluid",
        amount = f.amount or 0,
        capacity = f.capacity or 0
      }}
    end
  end

  return {}
end


---------------------------------------------------------------------
-- STORAGE: VAULT / CHESTS / TANKS / MONITORS
---------------------------------------------------------------------

local function storageSetVault()
  local name = prompt("Vault peripheral name: ")
  local p = wrap(name)
  if p and isInv(p) then
    state.vault = name
    saveState()
    addLog("Vault set: "..name, "ok")
  else
    addLog("Vault invalid: "..tostring(name), "err")
  end
end

local function storageAddChest()
  local name = prompt("Chest peripheral: ")
  local p = wrap(name)
  if p and isInv(p) then
    table.insert(state.chests, name)
    saveState()
    addLog("Chest added: "..name, "ok")
  else
    addLog("Chest invalid: "..tostring(name), "err")
  end
end

local function storageRemoveChest()
  if #state.chests == 0 then print("No chests to remove.") return end
  local sel, idx = selectFrom(state.chests, "Remove which chest?")
  if sel then
    addLog("Chest removed: "..sel, "ok")
    table.remove(state.chests, idx)
    saveState()
  end
end

local function storageAddTank()
  local name = prompt("Tank peripheral: ")
  local p = wrap(name)
  if p and isTank(p) then
    table.insert(state.tanks, name)
    saveState()
    addLog("Tank added: "..name, "ok")
  else
    addLog("Tank invalid: "..tostring(name), "err")
  end
end

local function storageRemoveTank()
  if #state.tanks == 0 then print("No tanks to remove.") return end
  local sel, idx = selectFrom(state.tanks, "Remove which tank?")
  if sel then
    addLog("Tank removed: "..sel, "ok")
    table.remove(state.tanks, idx)
    saveState()
  end
end

local function storageAssignMonitor()
  local name = prompt("Monitor peripheral: ")
  if not wrap(name) then addLog("Monitor not found", "err"); return end
  print("Role (storage/tanks/process):")
  local role = read()
  if role ~= "storage" and role ~= "tanks" and role ~= "process" then
    addLog("Invalid role", "err"); return
  end
  state.monitors[role] = name
  saveState()
  addLog(("Monitor %s -> %s"):format(name, role), "ok")
end

local function storageUnassignMonitor()
  print("Role to unassign (storage/tanks/process):")
  local role = read()
  if state.monitors[role] then
    addLog("Monitor unassigned from "..role, "ok")
    state.monitors[role] = nil
    saveState()
  else
    addLog("Role not assigned: "..tostring(role), "err")
  end
end

local function storageList()
  print("Vault: ", state.vault or "nil")
  print("Chests: ", table.concat(state.chests, ", "))
  print("Tanks: ", table.concat(state.tanks, ", "))
  print("Monitors:")
  for k,v in pairs(state.monitors) do print(("  %s: %s"):format(k, tostring(v))) end
end


---------------------------------------------------------------------
-- ROUTES
---------------------------------------------------------------------

local function routesAdd()
  local item = prompt("Item name (e.g. minecraft:iron_ingot): ")
  local dest = prompt("Destination peripheral: ")
  if not wrap(dest) then addLog("Dest invalid", "err"); return end
  state.routes[item] = dest
  saveState()
  addLog(("Route added: %s -> %s"):format(item, dest), "ok")
end

local function routesRemove()
  local items = {}
  for k,_ in pairs(state.routes) do table.insert(items, k) end
  if #items == 0 then print("No routes.") return end
  local sel = selectFrom(items, "Remove route for which item?")
  if sel then
    state.routes[sel] = nil
    addLog("Route removed for "..sel, "ok")
    saveState()
  end
end

local function routesList()
  if next(state.routes) == nil then print("No routes.") return end
  print("== Routes ==")
  for k,v in pairs(state.routes) do
    print(("  %s -> %s"):format(k, v))
  end
end


---------------------------------------------------------------------
-- RETURNERS (auto-sweep back to vault)
---------------------------------------------------------------------

local function returnerAdd()
  local name = prompt("Returner (inventory) peripheral: ")
  local p = wrap(name)
  if p and isInv(p) then
    table.insert(state.returners, name)
    saveState()
    addLog("Returner added: "..name, "ok")
  else
    addLog("Invalid returner", "err")
  end
end

local function returnerRemove()
  if #state.returners == 0 then print("No returners.") return end
  local sel, idx = selectFrom(state.returners, "Remove which returner?")
  if sel then
    addLog("Returner removed: "..sel, "ok")
    table.remove(state.returners, idx)
    saveState()
  end
end

local function returnerList()
  if #state.returners == 0 then print("No returners.") return end
  print("== Returners ==")
  for i,v in ipairs(state.returners) do print(("%d) %s"):format(i, v)) end
end

local function sweepReturner(name)
  if not state.vault then return end
  local src = wrap(name)
  local dst = wrap(state.vault)
  if not isInv(src) or not isInv(dst) then return end
  local listed = src.list()
  if not listed then return end
  for slot, stack in pairs(listed) do
    if stack and stack.count and stack.count > 0 then
      src.pushItems(state.vault, slot, stack.count)
    end
  end
end


---------------------------------------------------------------------
-- RECIPES
---------------------------------------------------------------------
-- Recipe structure:
-- state.recipes[recipeName] = {
--    mode   = "count" | "percent",
--    items  = { [itemName]=amountOrPercent, ... },
--    outputs= { "periph1","periph2", ... },
--    rrIndex= 1,           -- next output index
--    delay  = 0.05,        -- seconds per push (per-recipe)
-- }

local function recipeAdd()
  local name = prompt("Recipe name: ")
  if not name or name == "" then addLog("Invalid name","err") return end
  if state.recipes[name] then
    print("Recipe exists. Overwrite? (y/n)")
    if read() ~= "y" then return end
  end

  print("Mode (count/percent):")
  local mode = read()
  if mode ~= "count" and mode ~= "percent" then addLog("Invalid mode","err"); return end

  print("Per-recipe transfer delay seconds (0 = max speed):")
  local delay = tonumber(read()) or 0.0
  if delay < 0 then delay = 0 end

  local items = {}
  print("Add items for recipe. Leave item blank to stop.")
  while true do
    io.write("Item: "); local item = read()
    if not item or item == "" then break end
    io.write("Amount (count or percent): "); local amt = tonumber(read())
    if amt and amt >= 0 then
      items[item] = amt
    else
      addLog("Invalid amount, skipping", "warn")
    end
  end

  local outputs = {}
  print("Add output peripherals. Leave blank to stop.")
  while true do
    io.write("Output: "); local out = read()
    if not out or out == "" then break end
    local p = wrap(out)
    if p and isInv(p) then
      table.insert(outputs, out)
    else
      addLog("Invalid output (not an inventory): "..tostring(out), "err")
    end
  end

  state.recipes[name] = {
    mode = mode,
    items = items,
    outputs = outputs,
    rrIndex = 1,
    delay = delay
  }

  saveState()
  addLog("Recipe added: "..name, "ok")
end

local function recipeList()
  if next(state.recipes) == nil then print("No recipes.") return end
  print("== Recipes ==")
  for name, r in pairs(state.recipes) do
    print(("[%s] mode=%s delay=%.3f"):format(name, r.mode, r.delay or 0))
    for item, amt in pairs(r.items) do
      print(("  %s = %s"):format(item, tostring(amt)))
    end
    print(("  outputs: %s"):format(#r.outputs>0 and table.concat(r.outputs, ", ") or "(none)"))
  end
end

local function recipeRemove()
  local keys = {}
  for k,_ in pairs(state.recipes) do table.insert(keys,k) end
  if #keys == 0 then print("No recipes.") return end
  local sel = selectFrom(keys, "Remove which recipe?")
  if sel then
    state.recipes[sel] = nil
    saveState()
    addLog("Recipe removed: "..sel, "ok")
  end
end

local function recipeEdit()
  local keys = {}
  for k,_ in pairs(state.recipes) do table.insert(keys,k) end
  if #keys == 0 then print("No recipes.") return end
  local sel = selectFrom(keys, "Edit which recipe?")
  if not sel then return end
  local r = state.recipes[sel]

  while true do
    print("== Edit Recipe: "..sel.." ==")
    print("1) Change mode (count/percent)")
    print("2) Set transfer delay")
    print("3) Set items (replace)")
    print("4) Add output")
    print("5) Remove output")
    print("6) List outputs")
    print("7) Show recipe")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c == "1" then
      print("New mode (count/percent):")
      local m = read()
      if m=="count" or m=="percent" then
        r.mode = m; addLog("Mode updated","ok")
      else addLog("Invalid mode","err") end
    elseif c == "2" then
      print("Delay seconds (>=0):")
      local d = tonumber(read())
      if d and d >=0 then r.delay = d; addLog("Delay updated","ok") else addLog("Invalid","err") end
    elseif c == "3" then
      local items = {}
      print("Enter items. Blank item to stop.")
      while true do
        io.write("Item: "); local item = read()
        if not item or item == "" then break end
        io.write("Amount/Percent: "); local n = tonumber(read())
        if n then items[item] = n end
      end
      r.items = items; addLog("Items updated","ok")
    elseif c == "4" then
      local out = prompt("Output periph: ")
      if wrap(out) and isInv(wrap(out)) then table.insert(r.outputs, out); addLog("Output added","ok")
      else addLog("Invalid output","err") end
    elseif c == "5" then
      if #r.outputs==0 then print("No outputs.") else
        for i,o in ipairs(r.outputs) do print(("%d) %s"):format(i,o)) end
        io.write("Remove index: "); local i = tonumber(read())
        if i and r.outputs[i] then addLog("Removed output "..r.outputs[i],"ok"); table.remove(r.outputs, i) end
      end
    elseif c == "6" then
      print("Outputs: "..(#r.outputs>0 and table.concat(r.outputs, ", ") or "(none)"))
    elseif c == "7" then
      print(("Mode=%s Delay=%.3f"):format(r.mode, r.delay or 0))
      for item, amt in pairs(r.items) do print(("  %s=%s"):format(item, tostring(amt))) end
      print("Outputs: "..(#r.outputs>0 and table.concat(r.outputs, ", ") or "(none)"))
    elseif c == "0" then break end
  end

  saveState()
end


---------------------------------------------------------------------
-- TRANSFERS (FAST)
---------------------------------------------------------------------

-- Push up to 'amount' of 'itemName' from src inventory to dst inventory.
-- Fast: pushes as many as possible from each matching slot; minimal sleep.
-- Sleeps by 'delay' (seconds) after each push if delay > 0.
local function pushAmount(srcName, dstName, itemName, amount, delay)
  if amount <= 0 then return 0 end
  local src = wrap(srcName)
  local dst = wrap(dstName)
  if not isInv(src) or not isInv(dst) then
    addLog("pushAmount: invalid inv(s): "..tostring(srcName).." / "..tostring(dstName), "err")
    return 0
  end
  local moved = 0
  local listed = src.list() or {}
  for slot, stack in pairs(listed) do
    if stack and stack.name == itemName and moved < amount then
      local toMove = math.min(amount - moved, stack.count)
      local ok = src.pushItems(dstName, slot, toMove)
      moved = moved + (ok or 0)
      if delay and delay > 0 then sleep(delay) end
      if moved >= amount then break end
    end
  end
  if moved > 0 then
    addLog(("Pushed %d %s -> %s"):format(moved, itemName, dstName), "ok")
  end
  return moved
end

local function nextOutput(recipe)
  if not recipe.outputs or #recipe.outputs == 0 then return nil end
  recipe.rrIndex = recipe.rrIndex or 1
  local idx = recipe.rrIndex
  local dest = recipe.outputs[idx]
  idx = idx + 1
  if idx > #recipe.outputs then idx = 1 end
  recipe.rrIndex = idx
  return dest
end


---------------------------------------------------------------------
-- PRODUCTION LOGIC
---------------------------------------------------------------------

local function planPercentItems(items, percentBase)
  -- returns map item->count for this cycle
  local total = 0
  for _,p in pairs(items) do total = total + (tonumber(p) or 0) end
  if total <= 0 then return {} end

  local plan = {}
  local assigned = 0
  local maxItem, maxP = nil, -1
  for item, p in pairs(items) do
    p = tonumber(p) or 0
    local amt = math.floor((p / total) * percentBase + 1e-9)
    if amt > 0 then
      plan[item] = amt
      assigned = assigned + amt
    end
    if p > maxP then maxP = p; maxItem = item end
  end

  local remainder = percentBase - assigned
  if remainder > 0 and maxItem then
    plan[maxItem] = (plan[maxItem] or 0) + remainder
  end

  return plan
end

local function runRecipeOnce(name, testMode)
  local r = state.recipes[name]
  if not r then return end
  if not state.vault then addLog("No vault set (recipe "..name..")","err"); return end
  if not wrap(state.vault) then addLog("Vault missing","err"); return end

  local delay = r.delay or 0
  local outputs = r.outputs or {}
  if #outputs == 0 then addLog("Recipe "..name.." has no outputs","err"); return end

  if r.mode == "count" then
    for item, amt in pairs(r.items) do
      local dest = nextOutput(r)
      if not dest then addLog("No output available","err"); return end
      if not wrap(dest) then addLog("Output missing: "..dest,"err"); return end
      if testMode then
        addLog(("(TEST) %s: %d %s -> %s"):format(name, amt, item, dest), "warn")
      else
        pushAmount(state.vault, dest, item, amt, delay)
      end
    end

  elseif r.mode == "percent" then
    local plan = planPercentItems(r.items, state.settings.percentBase or 64)
    for item, amt in pairs(plan) do
      local dest = nextOutput(r)
      if not dest then addLog("No output available","err"); return end
      if not wrap(dest) then addLog("Output missing: "..dest,"err"); return end
      if testMode then
        addLog(("(TEST) %s: %d %s -> %s"):format(name, amt, item, dest), "warn")
      else
        pushAmount(state.vault, dest, item, amt, delay)
      end
    end
  end
end

local function runAllRecipes(testMode)
  for name,_ in pairs(state.recipes) do
    runRecipeOnce(name, testMode)
  end
end


---------------------------------------------------------------------
-- MONITOR DISPLAY HELPERS
---------------------------------------------------------------------

local function drawBar(m, x, y, width, ratio, col)
  ratio = math.max(0, math.min(1, ratio or 0))
  local fill = math.floor(width * ratio + 0.5)
  m.setCursorPos(x, y)
  m.setBackgroundColor(col)
  m.write(string.rep(" ", fill))
  m.setBackgroundColor(colors.black)
  m.write(string.rep(" ", width - fill))
end

-- Aggregates vault + all chests by item name
local function aggregateItems()
  local totals = {}
  local invs = {}
  if state.vault then table.insert(invs, state.vault) end
  for _,c in ipairs(state.chests) do table.insert(invs, c) end

  for _,invName in ipairs(invs) do
    local inv = wrap(invName)
    if inv and inv.list then
      local listed = inv.list()
      for _, stack in pairs(listed) do
        local nm = stack.name or "unknown"
        totals[nm] = (totals[nm] or 0) + (stack.count or 0)
      end
    end
  end

  -- Convert to array for sorting
  local arr = {}
  for k,v in pairs(totals) do table.insert(arr, {name=k, count=v}) end

  if state.settings.sortItemsBy == "name" then
    table.sort(arr, function(a,b) return a.name < b.name end)
  else
    table.sort(arr, function(a,b)
      if a.count == b.count then return a.name < b.name end
      return a.count > b.count
    end)
  end

  return arr
end


---------------------------------------------------------------------
-- MONITOR RENDERERS (3 roles)
---------------------------------------------------------------------

local function showStorageMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setCursorPos(1,1); m.setTextColor(colors.white); m.write("== Storage (Aggregated) ==")
  local y = 3

  local items = aggregateItems()
  local barW = math.max(10, math.min(state.settings.itemBarWidth or 24, w - 28))

  if #items == 0 then
    m.setCursorPos(1,y); m.setTextColor(colors.gray); m.write("(no items)")
    return
  end

  for _,it in ipairs(items) do
    if y >= h then break end
    local pct = math.min(1, (it.count or 0) / 64)  -- bar scaled vs stack, count shows full total
    m.setCursorPos(1,y); m.setTextColor(colors.white)
    local label = it.name
    if #label > 26 then label = label:sub(1,26) end
    m.write(padRight(label, 26))
    drawBar(m, 28, y, barW, pct, colors.green)
    local right = (" x%d"):format(it.count or 0)
    m.setCursorPos(28 + barW + 1, y); m.setTextColor(colors.white); m.write(right)
    y = y + 1
  end
end

local function showTanksMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setCursorPos(1,1); m.setTextColor(colors.white); m.write("== Tanks (Create supported) ==")
  local y = 3
  local barW = math.max(10, math.min(state.settings.tankBarWidth or 36, w - 4))

  if #state.tanks == 0 then
    m.setCursorPos(1,y); m.setTextColor(colors.gray); m.write("(no tanks)")
    return
  end

  for _,tname in ipairs(state.tanks) do
    local fluids = getTankFluids(tname)
    if #fluids == 0 then
      if state.settings.tankShowEmpty then
        m.setCursorPos(1,y); m.setTextColor(colors.lightBlue)
        local label = "["..tname.."] empty"
        if #label > w then label = label:sub(1,w) end
        m.write(label)
        y = y + 1
      end
    else
      for _,f in ipairs(fluids) do
        if y >= h then return end
        local cap = (f.capacity and f.capacity > 0) and f.capacity or 1
        local amt = f.amount or 0
        local pct = math.min(1, amt / cap)
        m.setCursorPos(1,y); m.setTextColor(colors.lightBlue)
        local label = ("[%s] %s %d/%d"):format(tname, f.name or "fluid", amt, cap)
        if #label > w then label = label:sub(1,w) end
        m.write(label); y = y + 1
        drawBar(m, 2, y, barW, pct, colors.blue)
        y = y + 1
      end
    end
  end
end

local function showProcessMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setCursorPos(1,1); m.setTextColor(colors.white); m.write("== Processes ==")
  m.setCursorPos(1,2); m.write("Production: "..tostring(state.production))
  local y = 4

  -- Show recipes (name, mode, delay, next output)
  local recipeNames = {}
  for k,_ in pairs(state.recipes) do table.insert(recipeNames, k) end
  table.sort(recipeNames)

  if #recipeNames == 0 then
    m.setCursorPos(1,y); m.setTextColor(colors.gray); m.write("(no recipes)")
    y = y + 1
  end

  for _,name in ipairs(recipeNames) do
    local r = state.recipes[name]
    local nextOut = "(none)"
    if r.outputs and #r.outputs > 0 then
      local idx = r.rrIndex or 1
      if idx < 1 or idx > #r.outputs then idx = 1 end
      nextOut = r.outputs[idx] or r.outputs[1]
    end
    m.setCursorPos(1,y); m.setTextColor(colors.cyan)
    local head = ("[%s] mode=%s delay=%.3f next=%s"):format(name, r.mode, r.delay or 0, nextOut)
    if #head > w then head = head:sub(1,w) end
    m.write(head); y = y + 1

    -- items lines
    m.setTextColor(colors.white)
    local line = "  "
    for item, amt in pairs(r.items) do
      local part = ("%s=%s"):format(item, tostring(amt))
      if #line + #part + 2 > w then
        m.setCursorPos(1,y); m.write(line); y = y + 1
        line = "  "
      end
      line = line .. part .. ", "
    end
    if line ~= "  " then
      if #line > w then line = line:sub(1,w) end
      m.setCursorPos(1,y); m.write(line); y = y + 1
    end

    if y > h - 10 then break end
  end

  -- Logs (last 10)
  m.setCursorPos(1, math.min(y+1, h-11)); m.setTextColor(colors.white); m.write("== Logs ==")
  local start = math.max(1, #state.logs - 10)
  local lY = math.min(y+2, h-10)
  for i = start, #state.logs do
    local L = state.logs[i]
    if L then
      if L.level=="ok" then m.setTextColor(colors.green)
      elseif L.level=="warn" then m.setTextColor(colors.yellow)
      elseif L.level=="err" then m.setTextColor(colors.red)
      else m.setTextColor(colors.white) end
      m.setCursorPos(1, lY)
      local line = ("[%s] %s"):format(L.time or "--:--", L.text or "")
      if #line > w then line = line:sub(1,w) end
      m.write(line)
      lY = lY + 1
      if lY > h then break end
    end
  end
end

local function updateMonitorsLoop()
  while true do
    if state.monitors.storage then
      local m = wrap(state.monitors.storage)
      if m then showStorageMonitor(m) end
    end
    if state.monitors.tanks then
      local m = wrap(state.monitors.tanks)
      if m then showTanksMonitor(m) end
    end
    if state.monitors.process then
      local m = wrap(state.monitors.process)
      if m then showProcessMonitor(m) end
    end
    sleep(state.settings.monitorRefresh or 1.5)
  end
end


---------------------------------------------------------------------
-- PRODUCTION / RETURNERS LOOPS
---------------------------------------------------------------------

local function productionLoop()
  while true do
    if state.production then
      runAllRecipes(false)
    end
    sleep(state.settings.productionTick or 0.5)
  end
end

local function returnersLoop()
  while true do
    if state.vault and #state.returners > 0 then
      for _,r in ipairs(state.returners) do
        sweepReturner(r)
      end
    end
    sleep(state.settings.returnerTick or 3.0)
  end
end


---------------------------------------------------------------------
-- SETTINGS MENU
---------------------------------------------------------------------

local function settingsMenu()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Settings ==")
    print("1) Toggle tankShowEmpty (Currently: "..tostring(state.settings.tankShowEmpty)..")")
    print("2) Sort items by (Currently: "..tostring(state.settings.sortItemsBy)..")")
    print("3) Set itemBarWidth (Currently: "..tostring(state.settings.itemBarWidth)..")")
    print("4) Set tankBarWidth (Currently: "..tostring(state.settings.tankBarWidth)..")")
    print("5) Set percentBase (Currently: "..tostring(state.settings.percentBase)..")")
    print("6) Set monitorRefresh (Currently: "..tostring(state.settings.monitorRefresh)..")")
    print("7) Set productionTick (Currently: "..tostring(state.settings.productionTick)..")")
    print("8) Set returnerTick (Currently: "..tostring(state.settings.returnerTick)..")")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c == "1" then
      state.settings.tankShowEmpty = not state.settings.tankShowEmpty
      saveState()
    elseif c == "2" then
      print("Enter 'count' or 'name':")
      local s = read()
      if s=="count" or s=="name" then
        state.settings.sortItemsBy = s; saveState()
      else addLog("Invalid sort","err") end
    elseif c == "3" then
      print("Enter width (10-40):")
      local n = tonumber(read())
      if n and n>=10 and n<=40 then state.settings.itemBarWidth=n; saveState() else addLog("Invalid width","err") end
    elseif c == "4" then
      print("Enter width (10-60):")
      local n = tonumber(read())
      if n and n>=10 and n<=60 then state.settings.tankBarWidth=n; saveState() else addLog("Invalid width","err") end
    elseif c == "5" then
      print("Enter percent base (e.g. 64):")
      local n = tonumber(read())
      if n and n>0 then state.settings.percentBase=n; saveState() else addLog("Invalid base","err") end
    elseif c == "6" then
      print("Enter seconds (e.g. 1.5):")
      local n = tonumber(read())
      if n and n>0 then state.settings.monitorRefresh=n; saveState() else addLog("Invalid value","err") end
    elseif c == "7" then
      print("Enter seconds (e.g. 0.5):")
      local n = tonumber(read())
      if n and n>=0 then state.settings.productionTick=n; saveState() else addLog("Invalid value","err") end
    elseif c == "8" then
      print("Enter seconds (e.g. 3.0):")
      local n = tonumber(read())
      if n and n>=0 then state.settings.returnerTick=n; saveState() else addLog("Invalid value","err") end
    elseif c == "0" then return end
  end
end


---------------------------------------------------------------------
-- MENUS
---------------------------------------------------------------------

local function storageMenu()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Storage Menu ==")
    print("1) Set Vault")
    print("2) Add Chest")
    print("3) Remove Chest")
    print("4) Add Tank")
    print("5) Remove Tank")
    print("6) Assign Monitor (role)")
    print("7) Unassign Monitor (role)")
    print("8) List Storage")
    print("9) Returners...")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c == "1" then storageSetVault()
    elseif c == "2" then storageAddChest()
    elseif c == "3" then storageRemoveChest()
    elseif c == "4" then storageAddTank()
    elseif c == "5" then storageRemoveTank()
    elseif c == "6" then storageAssignMonitor()
    elseif c == "7" then storageUnassignMonitor()
    elseif c == "8" then storageList(); io.read()
    elseif c == "9" then
      while true do
        term.clear(); term.setCursorPos(1,1)
        print("== Returners ==")
        print("1) Add Returner")
        print("2) Remove Returner")
        print("3) List Returners")
        print("0) Back")
        io.write("> ")
        local r = read()
        if r=="1" then returnerAdd()
        elseif r=="2" then returnerRemove()
        elseif r=="3" then returnerList(); io.read()
        elseif r=="0" then break end
      end
    elseif c == "0" then return end
  end
end

local function routesMenu()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Routes Menu ==")
    print("1) Add Route")
    print("2) Remove Route")
    print("3) List Routes")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c=="1" then routesAdd()
    elseif c=="2" then routesRemove()
    elseif c=="3" then routesList(); io.read()
    elseif c=="0" then return end
  end
end

local function recipesMenu()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Recipes Menu ==")
    print("1) Add Recipe")
    print("2) Remove Recipe")
    print("3) List Recipes")
    print("4) Edit Recipe")
    print("5) Test One Recipe (dry-run)")
    print("6) Test All Recipes (dry-run)")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c=="1" then recipeAdd()
    elseif c=="2" then recipeRemove()
    elseif c=="3" then recipeList(); io.read()
    elseif c=="4" then recipeEdit()
    elseif c=="5" then
      local keys = {}
      for k,_ in pairs(state.recipes) do table.insert(keys, k) end
      if #keys==0 then print("No recipes."); sleep(1) else
        local sel = selectFrom(keys, "Which recipe to test?")
        if sel then runRecipeOnce(sel, true) end
      end
    elseif c=="6" then runAllRecipes(true)
    elseif c=="0" then return end
  end
end

local function mainMenu()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Production Manager ==")
    print("1) Storage")
    print("2) Routes")
    print("3) Recipes")
    print("4) Settings")
    print("5) Toggle Production (Currently: "..tostring(state.production)..")")
    print("0) Exit")
    io.write("> ")
    local c = read()
    if c=="1" then storageMenu()
    elseif c=="2" then routesMenu()
    elseif c=="3" then recipesMenu()
    elseif c=="4" then settingsMenu()
    elseif c=="5" then
      state.production = not state.production
      addLog("Production "..tostring(state.production), state.production and "ok" or "warn")
      saveState()
    elseif c=="0" then
      saveState()
      return
    end
  end
end


---------------------------------------------------------------------
-- MAIN
---------------------------------------------------------------------

parallel.waitForAny(
  mainMenu,
  updateMonitorsLoop,
  productionLoop,
  returnersLoop
)
