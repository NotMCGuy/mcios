-- Trade Client v5
-- - Logs in via Trade Server (which proxies Bank)
-- - Deposit chest per client (used for adding stock & receiving purchases)
-- - View listings, create listing, add stock, buy
-- - Settings & Quit need admin password; Logout is free
-- - Ctrl+T blocked

do local raw=os.pullEventRaw os.pullEvent=raw end

local CFG_FILE  = "trade_client.cfg"
local PASS_FILE = "trade_client.pass"

local cfg = {
  tradeChannel = 1444,
  depositChest = nil,   -- client's chest name (must be attached to the Trade Server PC to actually move items)
}

local adminPass=nil
local modem=nil
local user=nil

-- ===== UI =====
local color=term.isColor()
local function setc(bg,fg) if color then term.setBackgroundColor(bg) term.setTextColor(fg) end end
local function header(t)
  term.clear() term.setCursorPos(1,1)
  if color then setc(colors.blue,colors.white) end
  local w=({term.getSize()})[1]
  local txt=" "..t.." "
  term.setCursorPos(math.max(1, math.floor((w-#txt)/2)), 1)
  term.clearLine() write(txt)
  if color then setc(colors.black,colors.white) end
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

-- ===== Config / Pass =====
local function saveCfg() local f=fs.open(CFG_FILE,"w") f.write(textutils.serialize(cfg)) f.close() end
local function loadCfg()
  if fs.exists(CFG_FILE) then local f=fs.open(CFG_FILE,"r") local d=textutils.unserialize(f.readAll()) f.close(); if type(d)=="table" then cfg=d end end
end
local function loadPass()
  if fs.exists(PASS_FILE) then local f=fs.open(PASS_FILE,"r") adminPass=f.readAll() f.close()
  else header("Setup Client Admin Password"); write("Set admin password: "); adminPass=read("*"); local f=fs.open(PASS_FILE,"w") f.write(adminPass) f.close() end
end
local function requirePass(prompt) write(prompt or "Admin password: ") return read("*")==adminPass end

-- ===== Network =====
local function openModem()
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="modem" then modem=peripheral.wrap(n) modem.open(cfg.tradeChannel) return end
  end
  error("No modem found")
end

local function req(msg, timeout)
  modem.transmit(cfg.tradeChannel, cfg.tradeChannel, msg)
  local t=os.startTimer(timeout or 6)
  while true do
    local e,a,ch,_,resp=os.pullEvent()
    if e=="modem_message" and ch==cfg.tradeChannel and type(resp)=="table" then return resp end
    if e=="timer" and a==t then return {ok=false,error="Timeout"} end
  end
end

-- ===== Auth =====
local function login()
  header("Trade / Bank Login")
  write("Username: ") local u=read()
  write("PIN: ") local p=read("*")
  local r=req({type="login", user=u, pin=p})
  if r and r.ok and (r.approved==nil or r.approved) then
    user=u
  else
    msg("Login failed: "..tostring(r and r.error or "unknown"), false)
    pressAny()
  end
end

-- ===== Helpers =====
local function getBalance()
  local r=req({type="getBalance", user=user})
  if r and r.ok then return r.balance or 0 end
  return 0
end

local function listListings()
  local r=req({type="getListings"})
  if r and r.ok then return r.data or {} end
  return {}
end

-- ===== Screens =====
local function screenListings()
  header("Market Listings")
  local L=listListings()
  if #L==0 then print("(none)") else
    table.sort(L,function(a,b) return a.id<b.id end)
    for _,x in ipairs(L) do
      print(("#%d  %s  x%d  @ %s  (%s)"):format(x.id,x.item,x.qty or 0,currency(x.price),x.seller))
    end
  end
  pressAny()
end

local function screenCreateListing()
  header("Create Listing")
  write("Item id: ") local item=read()
  write("Price per unit: ") local price=tonumber(read())
  if not price or price<=0 then msg("Invalid price",false) pressAny() return end
  local r=req({type="createListing", user=user, item=item, price=price})
  if r and r.ok then msg(r.message or ("Created #" .. tostring(r.id)), true)
  else msg("Error: "..tostring(r and r.error or "unknown"), false) end
  pressAny()
end

local function screenAddStock()
  header("Add Stock to Listing")
  if not cfg.depositChest or cfg.depositChest=="" then msg("No deposit chest set in Settings. Visit branch or set chest.", false) pressAny() return end
  write("Listing ID: ") local id=tonumber(read())
  write("Item id (must match listing): ") local item=read()
  write("Amount to deposit: ") local count=tonumber(read())
  if not id or id<=0 or not count or count<=0 then msg("Invalid input",false) pressAny() return end
  local r=req({type="addStock", user=user, listingId=id, item=item, count=count, chestName=cfg.depositChest})
  if r and r.ok then msg(r.message or ("Moved "..tostring(r.moved or 0)), true)
  else msg("Failed: "..tostring(r and r.error or "unknown"), false) end
  pressAny()
end

local function screenBuy()
  header("Buy from Listing")
  if not cfg.depositChest or cfg.depositChest=="" then msg("No deposit chest set in Settings. Visit branch or set chest.", false) pressAny() return end
  local L=listListings()
  if #L==0 then print("(no listings)") pressAny() return end
  table.sort(L,function(a,b) return a.id<b.id end)
  for _,x in ipairs(L) do
    print(("#%d  %s  x%d  @ %s  (%s)"):format(x.id,x.item,x.qty or 0,currency(x.price),x.seller))
  end
  print()
  local bal=getBalance()
  print("Your balance: "..currency(bal))
  write("Listing ID: ") local id=tonumber(read())
  write("Quantity: ") local count=tonumber(read())
  if not id or id<=0 or not count or count<=0 then msg("Invalid selection",false) pressAny() return end
  local r=req({type="buy", user=user, listingId=id, count=count, chestName=cfg.depositChest}, 10)
  if r and r.ok then msg(r.message or ("Purchased "..tostring(r.moved or 0).." items"), true)
  else msg("Failed: "..tostring(r and r.error or "unknown"), false) end
  pressAny()
end

local function screenSettings()
  if not requirePass("Admin password: ") then msg("Access denied",false) pressAny() return end
  while true do
    header("Settings")
    print("1) Set deposit chest (now: "..tostring(cfg.depositChest)..")")
    print("2) Set trade channel (now: "..cfg.tradeChannel..")")
    print("B) Back")
    write("> ") local c=read()
    if c=="1" then write("Peripheral name: ") cfg.depositChest=read(); saveCfg()
    elseif c=="2" then write("Channel: ") local ch=tonumber(read()); if ch then if modem then modem.close(cfg.tradeChannel) end cfg.tradeChannel=ch; modem.open(cfg.tradeChannel); saveCfg() end
    elseif c:lower()=="b" then return end
  end
end

-- ===== Menus =====
local function mainMenu()
  while user do
    header(("Trade — %s | Balance: %s"):format(user, currency(getBalance())))
    print("1) View Listings")
    print("2) Create Listing")
    print("3) Add Stock to Listing")
    print("4) Buy")
    print("S) Settings (admin)")
    print("L) Logout")
    print("Q) Quit (admin)")
    write("> ") local c=read()
    if c=="1" then screenListings()
    elseif c=="2" then screenCreateListing()
    elseif c=="3" then screenAddStock()
    elseif c=="4" then screenBuy()
    elseif c:lower()=="s" then screenSettings()
    elseif c:lower()=="l" then user=nil return true
    elseif c:lower()=="q" then if requirePass("Admin password to quit: ") then return false end
    end
  end
  return true
end

-- ===== Entry =====
loadCfg()
loadPass()
openModem()

while true do
  -- Login Screen
  while not user do
    header("Trade Client (Bank Linked)")
    print("1) Login")
    print("Q) Quit (admin)")
    write("> ") local c=read()
    if c=="1" then login()
    elseif c:lower()=="q" then if requirePass("Admin password to quit: ") then return end end
  end
  local cont = mainMenu()
  if not cont then break end
end
