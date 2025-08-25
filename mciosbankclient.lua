--[[ MCIOS Banking Client v12
   Features:
   - Colourful polished menus
   - Admin login required at startup
   - User login / create accounts
   - Deposit from local chest
   - Withdraw items back into same chest
   - Transfers, Balance, Prices
   - Logout freely, Quit & Settings require admin password
   - Ctrl+T disabled
]]

-- Block termination
do local raw=os.pullEventRaw; os.pullEvent=raw end

-------------------------
-- Files / Config
-------------------------
local CONFIG_FILE="bank_client.cfg"
local PASS_FILE="bank_admin.pass"
local CHANNEL=1337

local config={ chestName=nil }
local adminPass=nil
local modem=nil
local currentUser=nil

-------------------------
-- Utils (colours & UI)
-------------------------
local useColour=term.isColor()

local function clr(bg,fg) term.setBackgroundColor(bg) term.setTextColor(fg) end

local function header(title)
  term.clear()
  term.setCursorPos(1,1)
  if useColour then clr(colors.blue,colors.white) end
  local w,h=term.getSize()
  term.clearLine()
  local text=" "..title.." "
  local x=math.floor((w-#text)/2)
  term.setCursorPos(x,1)
  write(text)
  if useColour then clr(colors.black,colors.white) end
  term.setCursorPos(1,3)
end

local function msg(txt, ok)
  if useColour then
    if ok==true then clr(colors.black,colors.green)
    elseif ok==false then clr(colors.black,colors.red)
    else clr(colors.black,colors.white) end
  end
  print(txt)
  if useColour then clr(colors.black,colors.white) end
end

local function pressAny()
  print()
  print("Press any key...")
  os.pullEvent("key")
end

local function currency(n) return "$"..tostring(math.floor((n or 0)+0.5)) end

-------------------------
-- Save/load
-------------------------
local function saveConfig()
  local f=fs.open(CONFIG_FILE,"w") f.write(textutils.serialize(config)) f.close()
end
local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local f=fs.open(CONFIG_FILE,"r") local t=f.readAll() f.close()
    local ok,d=pcall(textutils.unserialize,t)
    if ok and type(d)=="table" then config=d end
  end
end

local function loadPass()
  if fs.exists(PASS_FILE) then
    local f=fs.open(PASS_FILE,"r") adminPass=f.readAll() f.close()
  else
    header("Setup Admin Password")
    write("Set admin password: ")
    adminPass=read("*")
    local f=fs.open(PASS_FILE,"w") f.write(adminPass) f.close()
  end
end

local function requirePass(prompt)
  write(prompt or "Password: ")
  return read("*")==adminPass
end

-------------------------
-- Networking
-------------------------
local function openModem()
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="modem" then
      modem=peripheral.wrap(n)
      modem.open(CHANNEL)
      return
    end
  end
  error("No modem attached!")
end

local function request(tbl)
  modem.transmit(CHANNEL,CHANNEL,tbl)
  local timer=os.startTimer(3)
  while true do
    local e,s,c,_,m=os.pullEvent()
    if e=="modem_message" and c==CHANNEL then return m
    elseif e=="timer" and s==timer then return{ok=false,error="Timeout"} end
  end
end

-------------------------
-- Account / Screens
-------------------------
local function loginMenu()
  while not currentUser do
    header("Bank Client - Login")
    print("1) Login")
    print("2) Create Account")
    print("S) Settings (admin)")
    print("Q) Quit (admin)")
    print()
    write("> ") local c=read()
    if c=="1" then
      write("Username: ") local u=read()
      write("PIN: ") local p=read("*")
      local r=request{type="login",user=u,pin=p}
      if r.ok then msg("Login success!",true) sleep(1) currentUser=u
      else msg("Fail: "..tostring(r.error),false) sleep(1.5) end
    elseif c=="2" then
      write("Username: ") local u=read()
      write("PIN: ") local p=read("*")
      local r=request{type="createAccount",user=u,pin=p}
      msg(r.ok and r.message or r.error,r.ok) pressAny()
    elseif c:lower()=="s" then
      if requirePass("Admin password: ") then
        write("Deposit chest name: ")
        local v=read()
        if v~="" then config.chestName=v saveConfig() msg("Saved.",true) sleep(1) end
      else msg("Wrong password!",false) sleep(1.2) end
    elseif c:lower()=="q" then
      if requirePass("Admin password: ") then os.reboot()
      else msg("Wrong password!",false) sleep(1.2) end
    end
  end
end

-------------------------
-- Actions
-------------------------
local function doDeposit()
  header("Deposit")
  if not config.chestName then msg("Chest not set.",false) pressAny() return end
  local r=request{type="depositFromClientChest",user=currentUser,chestName=config.chestName}
  msg(r.ok and r.message or r.error,r.ok)
  pressAny()
end

local function doWithdraw()
  header("Withdraw")
  if not config.chestName then msg("Chest not set.",false) pressAny() return end
  local s=request{type="getVaultStock"}
  if not s.ok then msg("Error: "..tostring(s.error),false) pressAny() return end
  local items={} local i=0
  for name,d in pairs(s.stock or{}) do i=i+1 items[i]=name
    print(("%d) %s  x%d @ %s"):format(i,name,d.count,currency(d.price)))
  end
  if i==0 then msg("No stock.",false) pressAny() return end
  print() write("Select #: ") local idx=tonumber(read())
  local name=items[idx] if not name then return end
  write("Amount: ") local amt=tonumber(read()) or 0
  if amt<=0 then return end
  local r=request{type="withdrawToClientChest",user=currentUser,chestName=config.chestName,item=name,count=amt}
  msg(r.ok and r.message or r.error,r.ok)
  pressAny()
end

local function doTransfer()
  header("Transfer")
  write("Recipient: ") local to=read()
  write("Amount: ") local amt=tonumber(read())
  if not amt or amt<=0 then return end
  local r=request{type="transfer",from=currentUser,to=to,amount=amt}
  msg(r.ok and r.message or r.error,r.ok)
  pressAny()
end

local function doBalance()
  header("Balance")
  local r=request{type="getAccount",user=currentUser}
  if r.ok then print("Balance: "..currency(r.balance)) print("Approved: "..tostring(r.approved))
  else msg("Error: "..tostring(r.error),false) end
  pressAny()
end

local function doPrices()
  header("Prices")
  local r=request{type="getPrices"}
  if r.ok then
    for n,d in pairs(r.prices) do
      print(("%s @ %s (stock %d, base %d)"):format(n,currency(d.price),d.stock,d.base))
    end
  else msg("Error: "..tostring(r.error),false) end
  pressAny()
end

-------------------------
-- Main Menu
-------------------------
local function userMenu()
  while currentUser do
    header("Welcome "..currentUser)
    print("1) Deposit")
    print("2) Withdraw")
    print("3) Transfer")
    print("4) Balance")
    print("5) Prices")
    print("L) Logout")
    print()
    write("> ") local c=read()
    if c=="1" then doDeposit()
    elseif c=="2" then doWithdraw()
    elseif c=="3" then doTransfer()
    elseif c=="4" then doBalance()
    elseif c=="5" then doPrices()
    elseif c:lower()=="l" then currentUser=nil end
  end
end

-------------------------
-- Entry
-------------------------
loadConfig()
loadPass()
openModem()

while true do
  loginMenu()
  if currentUser then userMenu() end
end
