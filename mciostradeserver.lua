-- Trade Server v5 (Bank-integrated, Vault-based, Monitor display)
-- - Uses Bank accounts (100% source of truth)
-- - Listings: {id, seller, item, price, qty}
-- - Sellers add stock from their chest -> Trade Vault (server-side peripheral)
-- - Buyers receive items from Vault -> their chest
-- - Bank transfers (buyer -> seller) via bank "transfer" API
-- - Admin menu (password), monitor auto-refresh, logs printable
-- - Ctrl+T blocked, Quit requires admin password

-- ========== Safety ==========
do local raw=os.pullEventRaw os.pullEvent=raw end

-- ========== Files / State ==========
local CFG_FILE  = "trade_server.cfg"
local DB_FILE   = "trade_server.db"
local LOG_FILE  = "trade_server.log"
local PASS_FILE = "trade_server.pass"

local cfg = {
  tradeChannel = 1444,
  bankChannel  = 1337,
  vaultName    = nil,   -- inventory peripheral name for the trade vault
  monitorName  = nil,   -- optional monitor
}

local S = {
  listings = {},        -- array of {id,seller,item,price,qty}
  nextId   = 1,
}

local logs = {}
local adminPass = nil
local modem = nil
local running = true

-- ========== UI Helpers ==========
local color = term.isColor()
local function setc(bg,fg) if color then term.setBackgroundColor(bg) term.setTextColor(fg) end end
local function header(t)
  term.clear() term.setCursorPos(1,1)
  if color then setc(colors.blue, colors.white) end
  local w = ({term.getSize()})[1]
  local txt = " "..t.." "
  term.setCursorPos(math.max(1, math.floor((w-#txt)/2)), 1)
  term.clearLine() write(txt)
  if color then setc(colors.black, colors.white) end
  term.setCursorPos(1,3)
end
local function msg(s,ok)
  if color then
    if ok==true then setc(colors.black,colors.green)
    elseif ok==false then setc(colors.black,colors.red)
    else setc(colors.black,colors.white) end
  end
  print(s)
  if color then setc(colors.black,colors.white) end
end
local function pressAny() print() print("Press any key...") os.pullEvent("key") end
local function currency(n) return "$"..tostring(math.floor((n or 0)+0.5)) end
local function nowStr() return textutils.formatTime(os.time(), true) end

-- ========== Persistence ==========
local function saveAll()
  local f=fs.open(DB_FILE,"w")
  f.write(textutils.serialize(S))
  f.close()
end
local function loadAll()
  if fs.exists(DB_FILE) then
    local f=fs.open(DB_FILE,"r")
    local d=textutils.unserialize(f.readAll())
    f.close()
    if type(d)=="table" then
      S.listings = d.listings or {}
      S.nextId   = d.nextId   or 1
    end
  end
end

local function loadCfg()
  if fs.exists(CFG_FILE) then
    local f=fs.open(CFG_FILE,"r")
    local d=textutils.unserialize(f.readAll())
    f.close()
    if type(d)=="table" then for k,v in pairs(d) do cfg[k]=v end end
  end
end
local function saveCfg()
  local f=fs.open(CFG_FILE,"w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function addLog(line)
  local L = ("["..nowStr().."] "..line)
  table.insert(logs, L)
  if #logs>800 then table.remove(logs,1) end
  local f=fs.open(LOG_FILE,"w") f.write(textutils.serialize(logs)) f.close()
end
local function loadLogs()
  if fs.exists(LOG_FILE) then
    local f=fs.open(LOG_FILE,"r")
    local d=textutils.unserialize(f.readAll())
    f.close()
    if type(d)=="table" then logs=d end
  end
end

local function loadPass()
  if fs.exists(PASS_FILE) then
    local f=fs.open(PASS_FILE,"r") adminPass=f.readAll() f.close()
  else
    header("Setup Trade Admin Password")
    write("Set admin password: ")
    adminPass=read("*")
    local f=fs.open(PASS_FILE,"w") f.write(adminPass) f.close()
  end
end
local function requirePass(prompt)
  write(prompt or "Admin password: ")
  return read("*")==adminPass
end

-- ========== Peripherals ==========
local function getInv(name)
  if not name or name=="" then return nil end
  if not peripheral.isPresent(name) then return nil end
  local p=peripheral.wrap(name)
  if p and p.list and p.pushItems then return p end
  return nil
end

local function getVault() return getInv(cfg.vaultName) end

local function getMonitor()
  if cfg.monitorName and peripheral.isPresent(cfg.monitorName) and peripheral.getType(cfg.monitorName)=="monitor" then
    return peripheral.wrap(cfg.monitorName)
  end
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="monitor" then
      cfg.monitorName=n; saveCfg()
      return peripheral.wrap(n)
    end
  end
end

local function openModem()
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="modem" then
      modem=peripheral.wrap(n)
      modem.open(cfg.tradeChannel)
      modem.open(cfg.bankChannel)
      return
    end
  end
  error("No modem found")
end

-- ========== Monitor ==========
local function drawMonitor()
  local m=getMonitor()
  if not m then return end
  m.setTextScale(0.5)
  m.setBackgroundColor(colors.black)
  m.setTextColor(colors.white)
  m.clear()
  m.setCursorPos(1,1)
  m.setBackgroundColor(colors.blue) m.setTextColor(colors.white)
  local w=({m.getSize()})[1]
  local title=" Trade Market "
  m.setCursorPos(math.max(1, math.floor((w-#title)/2)), 1)
  m.write(title)
  m.setBackgroundColor(colors.black) m.setTextColor(colors.white)
  m.setCursorPos(1,3)

  -- build visible list
  local L={}
  for _,x in ipairs(S.listings) do if (x.qty or 0)>0 then table.insert(L,x) end end
  table.sort(L, function(a,b)
    if a.item==b.item then return a.price<b.price else return a.item<b.item end
  end)

  if #L==0 then m.write("(no listings)") return end
  local y=3
  for _,x in ipairs(L) do
    m.setCursorPos(1,y)
    m.write(("#%d  %s  x%d  @ %s  (%s)"):format(x.id,x.item,x.qty,currency(x.price),x.seller))
    y=y+1
    local _,h=m.getSize() if y>h then break end
  end
end

local function monitorLoop()
  while running do drawMonitor() sleep(3) end
end

-- ========== Bank Proxy ==========
local function bankReq(tbl, timeout)
  modem.transmit(cfg.bankChannel, cfg.bankChannel, tbl)
  local t=os.startTimer(timeout or 6)
  while true do
    local e,a,ch,_,resp = os.pullEvent()
    if e=="modem_message" and ch==cfg.bankChannel and type(resp)=="table" then
      return resp
    elseif e=="timer" and a==t then
      return {ok=false, error="Bank timeout"}
    end
  end
end

-- ========== Item Moves ==========
local function moveFromChestToVault(srcName, item, need)
  local src = getInv(srcName); local v=getVault()
  if not src then return 0, "Deposit chest not found (visit branch)" end
  if not v then return 0, "Vault not configured" end
  local moved=0
  for slot,stk in pairs(src.list()) do
    if stk.name==item and moved<need then
      local toMove = math.min((need-moved), stk.count or 64)
      local amt = src.pushItems(cfg.vaultName, slot, toMove)
      moved = moved + (amt or 0)
      if moved>=need then break end
    end
  end
  return moved
end

local function moveFromVaultToChest(item, need, destName)
  local v=getVault(); local dst=getInv(destName)
  if not v then return 0, "Vault not configured" end
  if not dst then return 0, "Buyer chest not found (visit branch)" end
  local moved=0
  for slot,stk in pairs(v.list()) do
    if stk.name==item and moved<need then
      local toMove = math.min((need-moved), stk.count or 64)
      local amt = v.pushItems(destName, slot, toMove)
      moved = moved + (amt or 0)
      if moved>=need then break end
    end
  end
  return moved
end

-- ========== Trade Logic ==========
local function findListing(id)
  for i,x in ipairs(S.listings) do if x.id==id then return x,i end end
end

local function createListing(user, item, price)
  if not item or item=="" then return false, "Item id required" end
  local p = tonumber(price or 0)
  if not p or p<=0 then return false, "Price > 0 required" end
  local L={ id=S.nextId, seller=user, item=item, price=math.floor(p), qty=0 }
  S.nextId = S.nextId + 1
  table.insert(S.listings, L)
  saveAll()
  addLog(("Listing #%d created by %s: %s @ %s"):format(L.id, user, item, currency(L.price)))
  drawMonitor()
  return true, ("Created listing #%d"):format(L.id), L.id
end

local function addStock(user, listingId, item, count, chestName)
  local id=tonumber(listingId or 0); local qty=tonumber(count or 0)
  if id<=0 or qty<=0 then return false, "Bad stock params" end
  local L = findListing(id)
  if not L then return false, "Listing not found" end
  if L.seller~=user then return false, "Not your listing" end
  if L.item~=item then return false, "Item mismatch" end
  local moved, err = moveFromChestToVault(chestName, L.item, qty)
  if (moved or 0)<=0 then return false, err or "No items moved" end
  L.qty = (L.qty or 0) + moved
  saveAll()
  addLog(("Stock +%d to listing #%d by %s (%s)"):format(moved, L.id, L.seller, L.item))
  drawMonitor()
  return true, ("Deposited %d (new qty %d)"):format(moved, L.qty), moved
end

local function buy(user, listingId, count, buyerChest)
  local id=tonumber(listingId or 0); local need=tonumber(count or 0)
  if id<=0 or need<=0 then return false, "Bad purchase params" end
  local L = findListing(id)
  if not L or (L.qty or 0)<=0 then return false, "Not available" end

  -- ensure vault has the item
  local v=getVault(); if not v then return false, "Vault not configured" end
  local have=0
  for _,stk in pairs(v.list()) do if stk.name==L.item then have=have+(stk.count or 0) end end
  if have<=0 then return false, "Out of stock" end
  local take = math.min(need, L.qty, have)

  -- Try moving items first (ensures chest exists & has space)
  local moved, err = moveFromVaultToChest(L.item, take, buyerChest)
  if (moved or 0)<=0 then return false, err or "Delivery failed (visit branch?)" end

  local total = moved * L.price

  -- Do bank transfer buyer -> seller
  local tr = bankReq({type="transfer", from=user, to=L.seller, amount=total})
  if not (tr and tr.ok) then
    -- revert delivery best-effort
    local dst = getInv(buyerChest)
    if dst then
      for slot,stk in pairs(dst.list()) do
        if stk.name==L.item and moved>0 then
          local amt = dst.pushItems(cfg.vaultName, slot, moved)
          moved = moved - (amt or 0)
          if moved<=0 then break end
        end
      end
    end
    return false, "Bank transfer failed: "..tostring(tr and tr.error or "unknown")
  end

  -- success
  L.qty = L.qty - (moved or 0)
  saveAll()
  addLog(("Purchase: %s bought %d of %s from %s for %s (listing #%d)")
    :format(user, moved, L.item, L.seller, currency(total), L.id))
  drawMonitor()
  return true, ("Purchased %d for %s"):format(moved, currency(total)), moved, total
end

-- ========== Trade Protocol (wireless) ==========
local function handleClient(msg)
  local reply={ok=false}
  if msg.type=="login" then
    local r = bankReq({type="login", user=msg.user, pin=msg.pin})
    if r and r.ok then reply.ok=true; reply.approved=(r.approved==nil and true or r.approved)
    else reply.ok=false; reply.error=r and r.error or "Login failed" end

  elseif msg.type=="getBalance" then
    local r=bankReq({type="getAccount", user=msg.user})
    if r and r.ok then reply.ok=true; reply.balance=r.balance else reply.ok=false; reply.error=r and r.error or "Bank error" end

  elseif msg.type=="getListings" then
    reply.ok=true; reply.data=S.listings

  elseif msg.type=="createListing" then
    local ok,err,id=createListing(msg.user, msg.item, msg.price)
    reply.ok=ok; if ok then reply.id=id; reply.message=err else reply.error=err end

  elseif msg.type=="addStock" then
    local ok,err,moved=addStock(msg.user, msg.listingId, msg.item, msg.count, msg.chestName)
    reply.ok=ok; if ok then reply.moved=moved; reply.message=err else reply.error=err end

  elseif msg.type=="buy" then
    local ok,err,moved,total=buy(msg.user, msg.listingId, msg.count, msg.chestName)
    reply.ok=ok; if ok then reply.moved=moved; reply.total=total; reply.message=err else reply.error=err end

  else
    reply.ok=false; reply.error="Unknown request"
  end
  modem.transmit(cfg.tradeChannel, cfg.tradeChannel, reply)
end

-- ========== Admin UI ==========
local function uiListings()
  header("Trade Listings")
  if #S.listings==0 then print("(none)") else
    table.sort(S.listings, function(a,b) return a.id<b.id end)
    for _,L in ipairs(S.listings) do
      print(("#%d  %s  x%d  @ %s  (%s)"):format(L.id, L.item, L.qty, currency(L.price), L.seller))
    end
  end
  pressAny()
end

local function uiSetVault()
  header("Configure Vault")
  write("Vault inventory peripheral name (current: "..tostring(cfg.vaultName).."): ")
  local n=read()
  if n~="" then cfg.vaultName=n; saveCfg() end
  local ok = getVault() ~= nil
  msg("Vault "..(ok and "OK" or "NOT FOUND"), ok)
  pressAny()
end

local function uiSetMonitor()
  header("Configure Monitor")
  print("Leave blank to auto-detect first monitor.")
  write("Monitor name (current: "..tostring(cfg.monitorName).."): ")
  local n=read()
  if n=="" then cfg.monitorName=nil else cfg.monitorName=n end
  saveCfg()
  msg("Saved",true) pressAny()
end

local function uiChannels()
  header("Channels")
  print("Trade: "..cfg.tradeChannel.."   Bank: "..cfg.bankChannel)
  write("New Trade ch (blank skip): ") local t=read()
  if t~="" then cfg.tradeChannel=tonumber(t) or cfg.tradeChannel end
  write("New Bank ch  (blank skip): ") local b=read()
  if b~="" then cfg.bankChannel=tonumber(b) or cfg.bankChannel end
  saveCfg()
  if modem then modem.closeAll() modem.open(cfg.tradeChannel) modem.open(cfg.bankChannel) end
  msg("Channels updated",true) pressAny()
end

local function uiLogs()
  header("Logs (latest)")
  local start = math.max(1, #logs-24)
  for i=start,#logs do print(logs[i]) end
  print()
  print("[P] Print  [C] Clear  [Any] Back")
  local e,k=os.pullEvent("key") local name=keys.getName(k)
  if name=="p" then
    local pr
    for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="printer" then pr=peripheral.wrap(n) break end end
    if not pr then msg("No printer found",false) pressAny() return end
    pr.newPage() pr.setCursorPos(1,1)
    for _,line in ipairs(logs) do pr.write(line) local _,y=pr.getCursorPos() pr.setCursorPos(1,y+1) end
    pr.endPage() msg("Printed",true) pressAny()
  elseif name=="c" then
    logs={} addLog("Logs cleared")
    msg("Cleared",true) pressAny()
  end
end

local function adminMenu()
  while running do
    header("Trade Server Admin")
    print("1) View Listings")
    print("2) Configure Vault")
    print("3) Configure Monitor")
    print("4) Channels")
    print("5) View/Print/Clear Logs")
    print("Q) Quit (password)")
    write("> ") local c=read()
    if c=="1" then uiListings()
    elseif c=="2" then uiSetVault()
    elseif c=="3" then uiSetMonitor()
    elseif c=="4" then uiChannels()
    elseif c=="5" then uiLogs()
    elseif c:lower()=="q" then
      if requirePass("Admin password to quit: ") then running=false end
    end
  end
end

-- ========== Entry ==========
loadCfg()
loadAll()
loadLogs()
loadPass()
openModem()

parallel.waitForAny(
  function()
    while running do
      local e,_,ch,_,msgTbl = os.pullEvent("modem_message")
      if ch==cfg.tradeChannel and type(msgTbl)=="table" then
        handleClient(msgTbl)
      end
    end
  end,
  adminMenu,
  monitorLoop
)
