--[[ MCIOS Banking Server v11
     - Authoritative vault + accounts
     - Elastic pricing (base / (1 + elasticity * stock/maxStock), minPrice clamp)
     - Vault stock is purely what's physically inside the vault chest
     - Client RPC: login, createAccount, getAccount, getPrices, getVaultStock,
       depositFromClientChest, withdrawToClientChest, transfer
     - Admin menu: approve accounts, credit/debit, manage items (base price),
       price settings (maxStock/minPrice/elasticity), configure vault chest,
       view balances, view vault stock, view logs, quit (password)
     - Opens channel on all modems (wired + wireless); termination blocked
]]

-- Block termination globally
do
  local raw = os.pullEventRaw
  os.pullEvent = raw
end

-------------------------
-- Files / Channel
-------------------------
local DATA_FILE  = "bank_server.dat"
local PASS_FILE  = "bank_admin.pass"
local LOG_FILE   = "bank_server.log"
local CHANNEL    = 1337

-------------------------
-- State
-------------------------
local bank = {
  accounts = {},          -- [user] = { pin=string, approved=bool, balance=number }
  items    = {},          -- [itemName] = { basePrice=number }
  config   = {
    vaultChest = nil,     -- peripheral name for vault chest
    price = {
      maxStock = 1000,
      minPrice = 1,
      elasticity = 1.2,   -- higher => price drops more as stock rises
      currencySymbol = "$",
    }
  },
  version  = 1,
}

local adminPass = nil

-------------------------
-- Utils
-------------------------
local function currency(n)
  local cs = bank.config.price.currencySymbol or "$"
  return cs .. tostring(math.floor((n or 0) + 0.5))
end

local function header(t)
  term.clear()
  term.setCursorPos(1,1)
  print(("="):rep(50))
  print("  "..t)
  print(("="):rep(50))
  print()
end

local function pressAny()
  print()
  print("Press any key to continue...")
  os.pullEvent("key")
end

local function logLine(msg)
  local f = fs.open(LOG_FILE, "a")
  f.writeLine(("[%s] %s"):format(textutils.formatTime(os.time(), true), msg))
  f.close()
end

local function save()
  local f = fs.open(DATA_FILE, "w")
  f.write(textutils.serialize(bank))
  f.close()
end

local function load()
  if fs.exists(DATA_FILE) then
    local f = fs.open(DATA_FILE, "r")
    local txt = f.readAll() f.close()
    local ok, t = pcall(textutils.unserialize, txt)
    if ok and type(t) == "table" then bank = t end
  end
  -- migration / defaults
  bank.config = bank.config or {}
  bank.config.vaultChest = bank.config.vaultChest or nil
  bank.config.price = bank.config.price or {}
  local p = bank.config.price
  p.maxStock = p.maxStock or 1000
  p.minPrice = p.minPrice or 1
  p.elasticity = p.elasticity or 1.2
  p.currencySymbol = p.currencySymbol or "$"
end

local function loadPass()
  if fs.exists(PASS_FILE) then
    local f = fs.open(PASS_FILE, "r")
    adminPass = f.readAll()
    f.close()
  else
    header("First-time Setup")
    write("Set admin password: ")
    adminPass = read("*")
    local f = fs.open(PASS_FILE, "w")
    f.write(adminPass) f.close()
  end
end

local function requirePass(prompt)
  write(prompt or "Admin password: ")
  return read("*") == adminPass
end

-------------------------
-- Modems (open all)
-------------------------
local MODEMS = {}
local function openAllModems()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m and m.open then
        m.open(CHANNEL)
        table.insert(MODEMS, m)
      end
    end
  end
  if #MODEMS == 0 then error("No modem found! Attach wired or wireless modem.") end
end

local function replyOn(sideName, res)
  -- Prefer replying via the same modem side if available; else broadcast on all
  local m = peripheral.wrap(sideName)
  if m and m.transmit then
    m.transmit(CHANNEL, CHANNEL, res)
  else
    for _, mm in ipairs(MODEMS) do
      mm.transmit(CHANNEL, CHANNEL, res)
    end
  end
end

-------------------------
-- Vault helpers
-------------------------
local function getVault()
  return bank.config.vaultChest and peripheral.wrap(bank.config.vaultChest) or nil
end

local function scanVaultCounts()
  local vault = getVault()
  local stock = {}
  if not vault or not vault.list then return stock end
  for slot, s in pairs(vault.list()) do
    local name = s.name or (s.id or s.label) -- some adapters vary; prefer name
    if name then
      stock[name] = (stock[name] or 0) + (s.count or 0)
    end
  end
  return stock
end

local function computePrice(itemName, stockCount)
  local it = bank.items[itemName]
  if not it or not it.basePrice or it.basePrice <= 0 then return nil end
  local cfg = bank.config.price
  local maxStock = cfg.maxStock > 0 and cfg.maxStock or 1000
  local s = math.max(0, (stockCount or 0)) / maxStock
  local p = it.basePrice / (1 + (cfg.elasticity or 1.2) * s)
  p = math.floor(math.max(cfg.minPrice or 1, p))
  return p
end

-------------------------
-- Networking handlers
-------------------------
local function rpc_createAccount(msg)
  if bank.accounts[msg.user] then
    return { ok=false, error="Account exists" }
  end
  bank.accounts[msg.user] = { pin = msg.pin, approved = false, balance = 0 }
  save()
  logLine("Account created: "..msg.user)
  return { ok=true, message="Account created. Awaiting approval." }
end

local function rpc_login(msg)
  local acc = bank.accounts[msg.user]
  if not acc then return { ok=false, error="No account" } end
  if acc.pin ~= msg.pin then return { ok=false, error="Invalid PIN" } end
  if not acc.approved then return { ok=false, error="Not approved" } end
  return { ok=true }
end

local function rpc_getAccount(msg)
  local acc = bank.accounts[msg.user]
  if not acc then return { ok=false, error="No account" } end
  return { ok=true, balance=acc.balance, approved=acc.approved }
end

local function rpc_getPrices(_msg)
  local stock = scanVaultCounts()
  local out = {}
  for name, it in pairs(bank.items) do
    local price = computePrice(name, stock[name] or 0)
    if price then
      out[name] = { price = price, stock = stock[name] or 0, base = it.basePrice }
    end
  end
  return { ok=true, prices=out }
end

local function rpc_getVaultStock(_msg)
  local stock = scanVaultCounts()
  local out = {}
  for name, count in pairs(stock) do
    local price = computePrice(name, count)
    if price then
      out[name] = { count = count, price = price }
    end
  end
  return { ok=true, stock=out }
end

local function rpc_transfer(msg)
  local from, to, amount = msg.from, msg.to, tonumber(msg.amount)
  if not from or not to or not amount or amount <= 0 then
    return { ok=false, error="Invalid transfer" }
  end
  local a,b = bank.accounts[from], bank.accounts[to]
  if not a or not b then return { ok=false, error="Unknown account" } end
  if not a.approved or not b.approved then return { ok=false, error="Not approved" } end
  if (a.balance or 0) < amount then return { ok=false, error="Insufficient funds" } end
  a.balance = (a.balance or 0) - amount
  b.balance = (b.balance or 0) + amount
  save()
  logLine(("Transfer %s -> %s : %s"):format(from, to, currency(amount)))
  return { ok=true, message="Transfer complete" }
end

local function rpc_depositFromClientChest(msg)
  local user, chestName = msg.user, msg.chestName
  local acc = bank.accounts[user]
  if not acc or not acc.approved then return { ok=false, error="No account/Not approved" } end

  local src = peripheral.wrap(chestName)
  local vaultName = bank.config.vaultChest
  local vault = getVault()
  if not src or not src.list or not src.pushItems then return { ok=false, error="Client chest missing" } end
  if not vault or not vault.list or not vault.pullItems then return { ok=false, error="Vault missing" } end
  if not vaultName then return { ok=false, error="Vault not configured" } end

  local totalPaid, movedCount = 0, 0
  local stockBefore = scanVaultCounts() -- to compute unit prices

  -- Move priced items only
  for slot, s in pairs(src.list()) do
    local name = s.name
    local it = bank.items[name]
    if it and (s.count or 0) > 0 then
      local currentStock = stockBefore[name] or 0
      local unitPrice = computePrice(name, currentStock) or (bank.config.price.minPrice or 1)
      local pushed = src.pushItems(vaultName, slot, s.count)
      if pushed and pushed > 0 then
        movedCount = movedCount + pushed
        totalPaid = totalPaid + pushed * unitPrice
        stockBefore[name] = currentStock + pushed -- update for further slots of same item
      end
    end
  end

  if movedCount == 0 then
    return { ok=false, error="No priced items or nothing moved" }
  end

  acc.balance = (acc.balance or 0) + totalPaid
  save()
  logLine(("%s deposit: +%s (%d items)"):format(user, currency(totalPaid), movedCount))
  return { ok=true, message=("Deposited %d items worth %s"):format(movedCount, currency(totalPaid)) }
end

local function rpc_withdrawToClientChest(msg)
  local user, chestName, item, count = msg.user, msg.chestName, msg.item, tonumber(msg.count)
  if not user or not chestName or not item or not count or count <= 0 then
    return { ok=false, error="Invalid request" }
  end
  local acc = bank.accounts[user]
  if not acc or not acc.approved then return { ok=false, error="No account/Not approved" } end

  local vault = getVault()
  local dst = peripheral.wrap(chestName)
  if not vault or not vault.list or not vault.pushItems then return { ok=false, error="Vault missing" } end
  if not dst or not dst.list then return { ok=false, error="Client chest missing" } end

  local stock = scanVaultCounts()
  local available = stock[item] or 0
  if available < count then return { ok=false, error="Not enough stock" } end

  local unitPrice = computePrice(item, available)
  if not unitPrice then return { ok=false, error="Item not priced" } end
  local cost = unitPrice * count
  if (acc.balance or 0) < cost then return { ok=false, error="Insufficient funds" } end

  -- Move by slots (FIX: use slot numbers, not item names)
  local remaining = count
  for slot, s in pairs(vault.list()) do
    if remaining <= 0 then break end
    if s.name == item then
      local toMove = math.min(remaining, s.count or 0)
      if toMove > 0 then
        local moved = vault.pushItems(chestName, slot, toMove)
        remaining = remaining - (moved or 0)
      end
    end
  end

  if remaining > 0 then
    return { ok=false, error="Withdraw failed (partial move)" }
  end

  acc.balance = (acc.balance or 0) - cost
  save()
  logLine(("%s withdrew %dx %s for %s"):format(user, count, item, currency(cost)))
  return { ok=true, message=("Withdrew %d x %s for %s"):format(count, item, currency(cost)) }
end

local function handleRequest(sideName, msg)
  if type(msg) ~= "table" then return { ok=false, error="Bad message" } end
  if msg.type == "createAccount"         then return rpc_createAccount(msg)
  elseif msg.type == "login"             then return rpc_login(msg)
  elseif msg.type == "getAccount"        then return rpc_getAccount(msg)
  elseif msg.type == "getPrices"         then return rpc_getPrices(msg)
  elseif msg.type == "getVaultStock"     then return rpc_getVaultStock(msg)
  elseif msg.type == "depositFromClientChest" then return rpc_depositFromClientChest(msg)
  elseif msg.type == "withdrawToClientChest"  then return rpc_withdrawToClientChest(msg)
  elseif msg.type == "transfer"          then return rpc_transfer(msg)
  else return { ok=false, error="Unknown request" }
  end
end

-------------------------
-- Admin Menu
-------------------------
local function adminApprove()
  header("Approve Accounts")
  local listed = false
  for u,a in pairs(bank.accounts) do
    if not a.approved then print(" - "..u) listed = true end
  end
  if not listed then print("(no pending)") end
  print()
  write("Username to approve (blank to skip): ")
  local u = read()
  if u ~= "" and bank.accounts[u] then
    bank.accounts[u].approved = true
    save()
    logLine("Approved account: "..u)
    print("Approved.")
  end
  pressAny()
end

local function adminCreditDebit()
  header("Credit / Debit")
  write("User: ") local u = read()
  local a = bank.accounts[u]
  if not a then print("No such user.") pressAny() return end
  write("Amount (+credit / -debit): ") local d = tonumber(read())
  if not d then print("Invalid.") pressAny() return end
  a.balance = math.max(0, (a.balance or 0) + d)
  save()
  print("New balance: "..currency(a.balance))
  logLine(("Admin adj %s by %s"):format(u, currency(d)))
  pressAny()
end

local function adminManageItems()
  while true do
    header("Manage Items (base price)")
    local i=0
    for name,it in pairs(bank.items) do
      i=i+1
      print(("%d) %s  base:%s"):format(i, name, currency(it.basePrice)))
    end
    if i==0 then print("(none)") end
    print()
    print("[A] Add/Update   [R] Remove   [B] Back")
    write("> ")
    local c = read()
    if c:lower()=="a" then
      write("Item ID (e.g., minecraft:iron_ingot): ") local id = read()
      if id=="" then print("ID required") sleep(0.8) goto cont end
      write("Base price: ") local bp = tonumber(read())
      if not bp or bp<=0 then print("Invalid base price") sleep(0.8) goto cont end
      bank.items[id] = { basePrice = bp }
      save()
      print("Saved.")
      sleep(0.7)
    elseif c:lower()=="r" then
      write("Item ID to remove: ") local id = read()
      if bank.items[id] then bank.items[id]=nil save() print("Removed.") else print("Not found.") end
      sleep(0.7)
    elseif c:lower()=="b" then return end
    ::cont::
  end
end

local function adminPriceSettings()
  local cfg = bank.config.price
  while true do
    header("Price Settings")
    print("1) maxStock         : "..tostring(cfg.maxStock))
    print("2) minPrice         : "..tostring(cfg.minPrice))
    print("3) elasticity       : "..tostring(cfg.elasticity))
    print("4) currency symbol  : "..tostring(cfg.currencySymbol))
    print("B) Back")
    write("> ")
    local c = read()
    if c=="1" then write("New maxStock: ") local v=tonumber(read()) if v and v>0 then cfg.maxStock=v end
    elseif c=="2" then write("New minPrice: ") local v=tonumber(read()) if v and v>=0 then cfg.minPrice=v end
    elseif c=="3" then write("New elasticity: ") local v=tonumber(read()) if v and v>0 then cfg.elasticity=v end
    elseif c=="4" then write("New currency symbol: ") local v=read() if v~="" then cfg.currencySymbol=v end
    elseif c:lower()=="b" then save() return
    end
    save()
  end
end

local function adminViewBalances()
  header("Accounts")
  local n=0
  for u,a in pairs(bank.accounts) do
    n=n+1
    print(("%d) %s  [%s]  Balance: %s"):format(n,u, a.approved and "✓" or "✗", currency(a.balance)))
  end
  if n==0 then print("(no accounts)") end
  pressAny()
end

local function adminViewVaultStock()
  header("Vault Stock")
  local stock = scanVaultCounts()
  if not next(stock) then print("(vault empty or not set)") end
  for name,count in pairs(stock) do
    local price = computePrice(name, count)
    if price then
      print(("%s  x%d  @ %s"):format(name, count, currency(price)))
    else
      print(("%s  x%d  (unpriced)"):format(name, count))
    end
  end
  pressAny()
end

local function adminConfigureVault()
  header("Configure Vault Chest")
  print("Current: "..tostring(bank.config.vaultChest))
  write("New peripheral name (blank to keep): ")
  local v = read()
  if v ~= "" then
    bank.config.vaultChest = v
    save()
    print("Saved.")
  end
  pressAny()
end

local function adminViewLogs()
  header("Logs")
  if fs.exists(LOG_FILE) then
    local f = fs.open(LOG_FILE,"r")
    local line = f.readLine()
    local cnt = 0
    while line do
      print(line)
      cnt = cnt + 1
      line = f.readLine()
      if cnt % 20 == 0 then pressAny() header("Logs") end
    end
    f.close()
  else
    print("(no logs yet)")
  end
  pressAny()
end

local function adminMenu()
  while true do
    header("MCIOS Bank Admin")
    print("[1] Approve Accounts")
    print("[2] Credit/Debit Account")
    print("[3] Manage Items (base price)")
    print("[4] Price Settings")
    print("[5] View Accounts")
    print("[6] View Vault Stock")
    print("[7] Configure Vault Chest")
    print("[8] View Logs")
    print("[Q] Quit (admin)")
    print()
    write("> ")
    local c = read()
    if c=="1" then adminApprove()
    elseif c=="2" then adminCreditDebit()
    elseif c=="3" then adminManageItems()
    elseif c=="4" then adminPriceSettings()
    elseif c=="5" then adminViewBalances()
    elseif c=="6" then adminViewVaultStock()
    elseif c=="7" then adminConfigureVault()
    elseif c=="8" then adminViewLogs()
    elseif c and c:lower()=="q" then
      if requirePass("Admin password to quit: ") then
        term.clear() term.setCursorPos(1,1) print("Goodbye!") sleep(0.3)
        os.reboot()
      else
        print("Wrong password.") sleep(1.2)
      end
    end
  end
end

-------------------------
-- Network Loop
-------------------------
local function networkLoop()
  while true do
    local e, side, ch, _, msg = os.pullEvent("modem_message")
    if ch == CHANNEL and type(msg) == "table" then
      local res = handleRequest(side, msg)
      replyOn(side, res)
    end
  end
end

-------------------------
-- Entry
-------------------------
load()
loadPass()
openAllModems()

parallel.waitForAny(networkLoop, adminMenu)
