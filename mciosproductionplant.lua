--[[
Production Manager (Three-Monitor Edition)

Features:
 - Storage manager (vault, chests, tanks)
 - Monitors with roles: storage, tanks, process
 - Routes (simple item -> dest listing)
 - Auto-Returners: peripherals that push their contents back to the vault automatically
 - Recipes (count-based + percent-based, mixable)
 - Multiple outputs per recipe (round-robin)
 - Fast transfers per slot (batch pushItems)
 - Test Mode (dry-run)
 - Color logs on process monitor: ok=green, warn=yellow, err=red
 - Persistent state
]]

-------------------------------
-- State
-------------------------------
local STATE_FILE = "prod_manager_state"

local state = {
  vault = nil,           -- string peripheral name
  chests = {},           -- { "chest_1", ... }
  tanks = {},            -- { "tank_1", ... }
  monitors = {           -- role -> peripheral
    storage = nil,
    tanks = nil,
    process = nil,
  },
  routes = {},           -- itemName -> dest peripheral
  returners = {},        -- { "machine_1", ... } auto-return to vault
  recipes = {},          -- name -> {mode="count"/"percent", items={name=amount}, outputs={"dest1","dest2"}, rrIndex=1}
  production = false,
  logs = {},             -- { {text="...", level="ok/warn/err"} ... } keep last ~40
}

-------------------------------
-- Persistence
-------------------------------
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
    -- ensure new keys exist
    for k,v in pairs(state) do
      if t[k] == nil then t[k] = v end
    end
    -- ensure monitors has roles
    t.monitors = t.monitors or {}
    if type(t.monitors) ~= "table" then t.monitors = {} end
    t.monitors.storage = t.monitors.storage or nil
    t.monitors.tanks   = t.monitors.tanks   or nil
    t.monitors.process = t.monitors.process or nil
    -- ensure returners
    t.returners = t.returners or {}
    state = t
  end
end
loadState()

-------------------------------
-- Logging
-------------------------------
local function addLog(msg, level)
  level = level or "ok" -- ok / warn / err
  table.insert(state.logs, { text = msg, level = level, t = os.clock() })
  if #state.logs > 40 then
    table.remove(state.logs, 1)
  end
end

-------------------------------
-- Utils
-------------------------------
local function prompt(label)
  io.write(label or "")
  return read()
end

local function wrap(name)
  if not name then return nil end
  if peripheral.isPresent(name) then
    return peripheral.wrap(name)
  end
  return nil
end

local function isInventory(p)
  return p and p.list and p.getItemDetail and p.pushItems
end

local function isTankPeriph(p)
  return p and (p.getFluidInTank or p.getFluid or p.tanks)
end

-- Try different tank APIs and normalize into { {name, amount, capacity}, ... }
local function getTankFluids(name)
  local p = wrap(name)
  if not p then return {} end
  if p.getFluidInTank then
    local arr = p.getFluidInTank() or {}
    local out = {}
    for _,f in ipairs(arr) do
      if f and f.amount and f.capacity then
        table.insert(out, { name = f.name or f.label or "fluid", amount = f.amount, capacity = f.capacity })
      end
    end
    return out
  end
  if p.getFluid then
    local f = p.getFluid()
    if f and f.amount and f.capacity then
      return { { name = f.name or f.label or "fluid", amount = f.amount, capacity = f.capacity } }
    end
  end
  if p.tanks then
    local arr = p.tanks() or {}
    local out = {}
    for _,f in ipairs(arr) do
      if f and f.amount and f.capacity then
        table.insert(out, { name = f.name or f.label or "fluid", amount = f.amount, capacity = f.capacity })
      end
    end
    return out
  end
  return {}
end

local function selectFromList(list, title)
  if #list == 0 then return nil end
  print(title or "Select:")
  for i,v in ipairs(list) do print(("%d) %s"):format(i, tostring(v))) end
  io.write("> ")
  local n = tonumber(read())
  if n and list[n] then return list[n], n end
  return nil
end

-------------------------------
-- Storage management
-------------------------------
local function storageSetVault()
  local name = prompt("Vault peripheral name: ")
  if wrap(name) and isInventory(wrap(name)) then
    state.vault = name
    saveState()
    addLog("Vault set: "..name, "ok")
  else
    addLog("Vault invalid or not an inventory: "..tostring(name), "err")
  end
end

local function storageAddChest()
  local name = prompt("Chest peripheral: ")
  if wrap(name) and isInventory(wrap(name)) then
    table.insert(state.chests, name)
    saveState()
    addLog("Chest added: "..name, "ok")
  else
    addLog("Chest invalid: "..tostring(name), "err")
  end
end

local function storageRemoveChest()
  if #state.chests == 0 then print("No chests.") return end
  local sel, idx = selectFromList(state.chests, "Remove which chest?")
  if sel then
    addLog("Chest removed: "..sel, "ok")
    table.remove(state.chests, idx)
    saveState()
  end
end

local function storageAddTank()
  local name = prompt("Tank peripheral: ")
  if wrap(name) and isTankPeriph(wrap(name)) then
    table.insert(state.tanks, name)
    saveState()
    addLog("Tank added: "..name, "ok")
  else
    addLog("Tank invalid: "..tostring(name), "err")
  end
end

local function storageRemoveTank()
  if #state.tanks == 0 then print("No tanks.") return end
  local sel, idx = selectFromList(state.tanks, "Remove which tank?")
  if sel then
    addLog("Tank removed: "..sel, "ok")
    table.remove(state.tanks, idx)
    saveState()
  end
end

local function storageAssignMonitor()
  local name = prompt("Monitor peripheral: ")
  if not wrap(name) then addLog("Monitor not found", "err") return end
  print("Role? (storage/tanks/process)")
  local role = read()
  if role ~= "storage" and role ~= "tanks" and role ~= "process" then
    addLog("Invalid role", "err"); return
  end
  state.monitors[role] = name
  saveState()
  addLog(("Monitor %s -> %s"):format(name, role), "ok")
end

local function storageRemoveMonitor()
  local roles = {}
  for k,v in pairs(state.monitors) do if v then table.insert(roles, k.." ("..v..")") end end
  if #roles == 0 then print("No assigned monitors.") return end
  print("Remove which monitor role?")
  print("Options: storage, tanks, process")
  local role = read()
  if state.monitors[role] then
    addLog("Monitor unassigned from role: "..role, "ok")
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
  for role, name in pairs(state.monitors) do
    print("  "..role..": "..tostring(name))
  end
end

-------------------------------
-- Routes (simple list)
-------------------------------
local function routesAdd()
  local item = prompt("Item name (minecraft:foo): ")
  local dest = prompt("Destination peripheral: ")
  if not wrap(dest) then addLog("Dest invalid", "err"); return end
  state.routes[item] = dest
  saveState()
  addLog(("Route: %s -> %s"):format(item, dest), "ok")
end

local function routesRemove()
  local items = {}
  for k,_ in pairs(state.routes) do table.insert(items, k) end
  if #items == 0 then print("No routes.") return end
  local sel = selectFromList(items, "Remove which item route?")
  if sel then
    state.routes[sel] = nil
    saveState()
    addLog("Route removed: "..sel, "ok")
  end
end

local function routesList()
  if next(state.routes) == nil then print("No routes.") return end
  print("== Routes ==")
  for k,v in pairs(state.routes) do
    print(("  %s -> %s"):format(k, v))
  end
end

-------------------------------
-- Auto-Returners
-------------------------------
local function returnerAdd()
  local name = prompt("Returner peripheral (will push to vault): ")
  if not wrap(name) or not isInventory(wrap(name)) then addLog("Invalid returner", "err"); return end
  table.insert(state.returners, name)
  saveState()
  addLog("Returner added: "..name, "ok")
end

local function returnerRemove()
  if #state.returners == 0 then print("No returners.") return end
  local sel, idx = selectFromList(state.returners, "Remove which returner?")
  if sel then
    addLog("Returner removed: "..sel, "ok")
    table.remove(state.returners, idx)
    saveState()
  end
end

local function returnerList()
  if #state.returners == 0 then print("No returners.") return end
  print("== Returners ==")
  for i,v in ipairs(state.returners) do print(("  %d) %s"):format(i,v)) end
end

-- Moves *all* items from a returner into the vault, quickly.
local function sweepReturner(name)
  if not state.vault then return end
  local src = wrap(name)
  local vault = wrap(state.vault)
  if not isInventory(src) or not isInventory(vault) then return end
  local listed = src.list()
  if not listed then return end
  for slot, stack in pairs(listed) do
    if stack and stack.count and stack.count > 0 then
      local moved = src.pushItems(state.vault, slot, stack.count)
      if moved and moved > 0 then
        -- minimal logging to avoid spam
      end
    end
  end
end

-------------------------------
-- Recipes
-------------------------------
-- structure: state.recipes[name] = {
--   mode="count"/"percent",
--   items = { [itemName]=qtyOrPercent, ... },
--   outputs = { "chest1","chest2", ... },
--   rrIndex = 1,
-- }

local function recipeAdd()
  local name = prompt("Recipe name: ")
  if not name or name == "" then addLog("Invalid name","err") return end
  io.write("Mode (count/percent): ")
  local mode = read()
  if mode ~= "count" and mode ~= "percent" then addLog("Invalid mode","err") return end
  local items = {}
  print("Enter items (blank to finish):")
  while true do
    io.write("Item: "); local item = read()
    if not item or item == "" then break end
    io.write("Amount/Percent: "); local n = tonumber(read())
    if not n then addLog("Invalid number","err") else items[item] = n end
  end
  local outputs = {}
  print("Outputs (comma-separated peripheral names):")
  local outLine = read() or ""
  for s in string.gmatch(outLine, "[^,]+") do
    local o = (s:gsub("^%s+",""):gsub("%s+$",""))
    if o ~= "" then table.insert(outputs, o) end
  end
  state.recipes[name] = { mode = mode, items = items, outputs = outputs, rrIndex = 1 }
  saveState()
  addLog("Recipe added: "..name, "ok")
end

local function recipeList()
  if next(state.recipes) == nil then print("No recipes.") return end
  print("== Recipes ==")
  for name, r in pairs(state.recipes) do
    print((" [%s] mode=%s"):format(name, r.mode))
    for item,amt in pairs(r.items) do
      print(("   %s = %s"):format(item, tostring(amt)))
    end
    print(("   outputs: %s"):format(#r.outputs>0 and table.concat(r.outputs,", ") or "(none)"))
  end
end

local function recipeRemove()
  local keys = {}
  for k,_ in pairs(state.recipes) do table.insert(keys,k) end
  if #keys == 0 then print("No recipes.") return end
  local sel = selectFromList(keys, "Remove which recipe?")
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
  local sel = selectFromList(keys, "Edit which recipe?")
  if not sel then return end
  local r = state.recipes[sel]
  while true do
    print("== Edit Recipe: "..sel.." ==")
    print("1) Change items/ratios")
    print("2) Add output")
    print("3) Remove output")
    print("4) List outputs")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c == "1" then
      local items = {}
      print("Enter items (blank to finish):")
      while true do
        io.write("Item: "); local item = read()
        if not item or item == "" then break end
        io.write("Amount/Percent: "); local n = tonumber(read())
        if n then items[item] = n end
      end
      r.items = items
      addLog("Recipe items updated: "..sel, "ok")
      saveState()
    elseif c == "2" then
      local out = prompt("Output peripheral: ")
      if wrap(out) then
        table.insert(r.outputs, out)
        saveState()
        addLog(("Added output to %s: %s"):format(sel, out), "ok")
      else
        addLog("Invalid peripheral", "err")
      end
    elseif c == "3" then
      if #r.outputs == 0 then print("No outputs.") else
        for i,o in ipairs(r.outputs) do print(("%d) %s"):format(i,o)) end
        io.write("Remove index: ")
        local idx = tonumber(read())
        if idx and r.outputs[idx] then
          addLog(("Removed output from %s: %s"):format(sel, r.outputs[idx]), "ok")
          table.remove(r.outputs, idx)
          saveState()
        end
      end
    elseif c == "4" then
      print("Outputs: "..(#r.outputs>0 and table.concat(r.outputs,", ") or "(none)"))
    elseif c == "0" then break end
  end
end

-------------------------------
-- Transfers (fast)
-------------------------------
local function pushAmount(srcName, dstName, itemName, amount)
  if amount <= 0 then return 0 end
  local src = wrap(srcName)
  local dst = wrap(dstName)
  if not isInventory(src) or not isInventory(dst) then
    addLog("pushAmount: invalid inv(s)", "err")
    return 0
  end
  local moved = 0
  local listed = src.list() or {}
  for slot, stack in pairs(listed) do
    if stack and stack.name == itemName and moved < amount then
      local toMove = math.min(amount - moved, stack.count)
      local ok = src.pushItems(dstName, slot, toMove)
      moved = moved + (ok or 0)
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

-------------------------------
-- Production logic
-------------------------------
local PERCENT_BASE = 64 -- how many total items per cycle for a percent recipe

local function runRecipeOnce(name, testMode)
  local r = state.recipes[name]; if not r then return end
  if not state.vault then addLog("No vault set (recipe "..name..")", "err"); return end
  if not wrap(state.vault) then addLog("Vault peripheral missing", "err"); return end
  local dest = nextOutput(r)
  if not dest then addLog("Recipe "..name.." has no outputs", "err"); return end
  if not wrap(dest) then addLog("Output missing: "..dest, "err"); return end

  if r.mode == "count" then
    for item, amt in pairs(r.items) do
      if testMode then
        addLog(("(TEST) %s: %d %s -> %s"):format(name, amt, item, dest), "warn")
      else
        pushAmount(state.vault, dest, item, amt)
      end
    end
  elseif r.mode == "percent" then
    local total = 0
    for _,p in pairs(r.items) do total = total + (tonumber(p) or 0) end
    if total <= 0 then addLog("Recipe "..name..": total percent <= 0", "err"); return end
    -- compute amounts (round down, ensure at least 1 if percent>0 and there is stock)
    local plan = {}
    local assigned = 0
    for item, p in pairs(r.items) do
      local amt = math.floor((p / total) * PERCENT_BASE + 0.0001)
      if amt > 0 then plan[item] = amt; assigned = assigned + amt end
    end
    -- if rounding lost some, add remainder to highest-percent item
    local remainder = PERCENT_BASE - assigned
    if remainder > 0 then
      -- pick the item with largest p
      local bestItem, bestP = nil, -1
      for item, p in pairs(r.items) do
        p = tonumber(p) or 0
        if p > bestP then bestP = p; bestItem = item end
      end
      if bestItem then plan[bestItem] = (plan[bestItem] or 0) + remainder end
    end

    for item, amt in pairs(plan) do
      if amt > 0 then
        if testMode then
          addLog(("(TEST) %s: %d %s -> %s"):format(name, amt, item, dest), "warn")
        else
          pushAmount(state.vault, dest, item, amt)
        end
      end
    end
  end
end

local function runAllRecipes(testMode)
  for name,_ in pairs(state.recipes) do
    runRecipeOnce(name, testMode)
  end
end

-------------------------------
-- UI: Monitors (3 roles)
-------------------------------
local function drawBar(m, x, y, width, ratio, col)
  ratio = math.max(0, math.min(1, ratio or 0))
  local fill = math.floor(width * ratio + 0.5)
  m.setCursorPos(x, y)
  m.setBackgroundColor(col)
  m.write(string.rep(" ", fill))
  m.setBackgroundColor(colors.black)
  m.write(string.rep(" ", width - fill))
end

local function showStorageMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setTextColor(colors.white); m.setCursorPos(1,1); m.write("== Storage ==")
  local y = 3
  local invs = {}
  if state.vault then table.insert(invs, state.vault) end
  for _,c in ipairs(state.chests) do table.insert(invs, c) end

  for _,invName in ipairs(invs) do
    local inv = wrap(invName)
    if inv and inv.list then
      m.setTextColor(colors.cyan); m.setCursorPos(1,y); m.write("["..invName.."]"); y=y+1
      for slot, stack in pairs(inv.list()) do
        local pct = math.min((stack.count or 0) / 64, 1)
        m.setTextColor(colors.white); m.setCursorPos(2,y)
        m.write((stack.name or "item").." x"..tostring(stack.count or 0))
        drawBar(m, math.max(30, math.floor(w*0.5)), y, math.max(10, math.floor(w*0.45)), pct, colors.green)
        y = y + 1
        if y > h-2 then return end
      end
    end
    if y > h-2 then return end
  end
end

local function showTanksMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setTextColor(colors.white); m.setCursorPos(1,1); m.write("== Tanks ==")
  local y = 3
  for _,tname in ipairs(state.tanks) do
    local tanks = getTankFluids(tname)
    if #tanks == 0 then
      m.setTextColor(colors.lightBlue); m.setCursorPos(1,y); m.write("["..tname.."] empty")
      y = y + 1
    else
      for _,f in ipairs(tanks) do
        local pct = (f.capacity and f.capacity>0) and (f.amount / f.capacity) or 0
        m.setTextColor(colors.lightBlue); m.setCursorPos(1,y)
        m.write(("["..tname.."] %s %d/%d"):format(f.name, f.amount, f.capacity))
        y = y + 1
        drawBar(m, 2, y, math.max(10, w-3), pct, colors.blue)
        y = y + 1
        if y > h-2 then return end
      end
    end
    if y > h-2 then return end
  end
end

local function showProcessMonitor(m)
  m.setBackgroundColor(colors.black); m.clear()
  local w,h = m.getSize()
  m.setTextColor(colors.white); m.setCursorPos(1,1); m.write("== Processes ==")
  m.setCursorPos(1,2); m.write("Production: "..tostring(state.production))
  local y = 4

  -- Show recipes summary
  for name, r in pairs(state.recipes) do
    m.setTextColor(colors.cyan); m.setCursorPos(1,y)
    local nextDest = (r.outputs and #r.outputs>0) and (r.outputs[r.rrIndex or 1] or r.outputs[1]) or "(none)"
    m.write(("["..name.."] mode=%s -> next: %s"):format(r.mode, nextDest))
    y = y + 1
    m.setTextColor(colors.white)
    local line = "  "
    for item, amt in pairs(r.items) do
      local part = ("%s=%s"):format(item, tostring(amt))
      if #line + #part + 2 > w then
        m.setCursorPos(1,y); m.write(line); y=y+1; line="  "
      end
      line = line..part..", "
    end
    if line ~= "  " then m.setCursorPos(1,y); m.write(line); y=y+1 end
    if y > h-8 then break end
  end

  -- Logs (last 8)
  m.setTextColor(colors.white); m.setCursorPos(1, math.max(y+1, h-9)); m.write("== Logs ==")
  local start = math.max(1, #state.logs - 7)
  local lY = math.max(y+2, h-8)
  for i = start, #state.logs do
    local L = state.logs[i]
    if L then
      if L.level=="ok" then m.setTextColor(colors.green)
      elseif L.level=="warn" then m.setTextColor(colors.yellow)
      elseif L.level=="err" then m.setTextColor(colors.red)
      else m.setTextColor(colors.white) end
      m.setCursorPos(1, lY)
      local text = L.text
      if #text > w then text = text:sub(1, w) end
      m.write(text)
      lY = lY + 1
      if lY > h then break end
    end
  end
end

local function updateMonitors()
  while true do
    local m
    if state.monitors.storage then
      m = wrap(state.monitors.storage); if m then showStorageMonitor(m) end
    end
    if state.monitors.tanks then
      m = wrap(state.monitors.tanks); if m then showTanksMonitor(m) end
    end
    if state.monitors.process then
      m = wrap(state.monitors.process); if m then showProcessMonitor(m) end
    end
    sleep(1.5)
  end
end

-------------------------------
-- Menus
-------------------------------
local function menuStorage()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Storage Menu ==")
    print("1) Set Vault")
    print("2) Add Chest")
    print("3) Remove Chest")
    print("4) Add Tank")
    print("5) Remove Tank")
    print("6) Assign Monitor (role)")
    print("7) Remove Monitor (role)")
    print("8) List Storage")
    print("9) Manage Returners")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c=="1" then storageSetVault()
    elseif c=="2" then storageAddChest()
    elseif c=="3" then storageRemoveChest()
    elseif c=="4" then storageAddTank()
    elseif c=="5" then storageRemoveTank()
    elseif c=="6" then storageAssignMonitor()
    elseif c=="7" then storageRemoveMonitor()
    elseif c=="8" then storageList(); io.read()
    elseif c=="9" then
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
    elseif c=="0" then return end
  end
end

local function menuRoutes()
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

local function menuRecipes()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Recipes Menu ==")
    print("1) Add Recipe")
    print("2) Remove Recipe")
    print("3) List Recipes")
    print("4) Edit Recipe")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c=="1" then recipeAdd()
    elseif c=="2" then recipeRemove()
    elseif c=="3" then recipeList(); io.read()
    elseif c=="4" then recipeEdit()
    elseif c=="0" then return end
  end
end

local function menuTest()
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("== Test Mode ==")
    print("1) Run single recipe (TEST)")
    print("2) Run all recipes (TEST)")
    print("0) Back")
    io.write("> ")
    local c = read()
    if c=="1" then
      local keys = {}
      for k,_ in pairs(state.recipes) do table.insert(keys,k) end
      if #keys==0 then print("No recipes."); sleep(1) else
        local sel = selectFromList(keys, "Select recipe:")
        if sel then runRecipeOnce(sel, true) end
      end
    elseif c=="2" then runAllRecipes(true)
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
    print("4) Test Mode")
    print("5) Toggle Production (Currently: "..tostring(state.production)..")")
    print("0) Exit")
    io.write("> ")
    local c = read()
    if c=="1" then menuStorage()
    elseif c=="2" then menuRoutes()
    elseif c=="3" then menuRecipes()
    elseif c=="4" then menuTest()
    elseif c=="5" then
      state.production = not state.production
      addLog("Production "..tostring(state.production), "ok")
      saveState()
    elseif c=="0" then
      saveState()
      return
    end
  end
end

-------------------------------
-- Loops
-------------------------------
local function productionLoop()
  while true do
    if state.production then
      -- Run each recipe once per tick
      for name,_ in pairs(state.recipes) do
        runRecipeOnce(name, false)
      end
    end
    sleep(1.0)
  end
end

local function returnersLoop()
  while true do
    if state.vault and #state.returners > 0 then
      for _,r in ipairs(state.returners) do
        sweepReturner(r)
      end
    end
    sleep(3.0)
  end
end

-------------------------------
-- Main
-------------------------------
parallel.waitForAny(
  mainMenu,
  updateMonitors,
  productionLoop,
  returnersLoop
)

