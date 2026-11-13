-- Recipients: keeps the installation's notification recipients in one place.
--
-- People are entered in the app's settings: name, e-mail, phone, groups (for example "staff, night") and which
-- channels they want. The app works out one comma separated list per group and channel and writes them as metadata
-- on a device of its own (type "recipients"):
--
--   recipients_email_<group> = a@example.com,b@example.com
--   recipients_sms_<group>   = +46701234567
--
-- The keys follow IoT Open's recipients_* convention, so other Edge Apps (for example toolong) put them in the
-- payload of lynx.notify and a notification output uses {{.payload.recipients_email}} as its recipient. E-mail is
-- on by default, SMS only for those who tick it, so e-mail is the normal channel.
--
-- Every active person is also in the group "all". Names, addresses and numbers are never written to the log.

local VERSION = "0.2.0"
local DEVICE_TYPE = "recipients"
local KEY_APP = "recipients.app_id"
local PREFIX = "recipients_"
local MAX_VALUE = 1024 -- longest metadata value IoT Open stores (characters)
local GROUP_ALL = "all"

--- Characters in a UTF-8 text (bytes that do not continue a character), without depending on the utf8 library.
local function chars(s) return select(2, tostring(s):gsub("[^\128-\191]", "")) end

local M = {}

-- ---- settings ------------------------------------------------------------------------------------------------

local function is_null(v) return v == nil or (json ~= nil and v == json.null) end

local function bool(v, d)
  if is_null(v) or v == "" then return d end
  return v == true or v == "true" or v == 1 or v == "1"
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- The edge client's log has i, e and d (no w): warnings are written with log.i.
local function warn(f, ...) log.i("warning: " .. f, ...) end

--- A lower case e-mail address, or nil when it does not look like one.
function M.email(s)
  s = trim(s):lower()
  if s == "" or #s > 254 then return nil end
  if not s:match("^[%w%._%%%+%-]+@[%w%.%-]+%.[%a][%a]+$") or s:find("..", 1, true) then return nil end
  return s
end

--- A phone number in international form (+46701234567), or nil. A leading 0 becomes the country code (+46 unless
--- the setting country_code is given in the JSON); a number in another country is written with its own code.
function M.phone(s, country)
  s = trim(s)
  if s == "" then return nil end
  local digits = s:gsub("[%s%-%(%)%.]", "")
  if digits:match("^00%d+$") then digits = "+" .. digits:sub(3) end
  if digits:match("^0%d+$") then digits = (country or "+46") .. digits:sub(2) end
  if not digits:match("^%+%d+$") or #digits < 8 or #digits > 16 then return nil end
  return digits
end

--- Group names from "Staff, night" -> {"staff", "night"}: lower case letters, digits, _ and -.
--- A key from a name a person writes: "Hemtjänst natt" -> "hemtjanst_natt". Keys are kept as they are.
function M.slug(v)
  local t = trim(v)
  for from, to in pairs({ ["å"] = "a", ["Å"] = "a", ["ä"] = "a", ["Ä"] = "a", ["ö"] = "o", ["Ö"] = "o", ["é"] = "e", ["É"] = "e", ["ü"] = "u", ["Ü"] = "u" }) do
    t = t:gsub(from, to)
  end
  t = t:lower():gsub("[^a-z0-9_%-]+", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  return t
end

--- Group keys from what a person writes: "Personal, Hemtjänst natt" -> { "personal", "hemtjanst_natt" }.
function M.groups(s)
  local out, seen = {}, {}
  for part in tostring(s or ""):gmatch("[^,;]+") do
    local g = M.slug(part)
    if g ~= "" and not seen[g] then
      seen[g] = true
      out[#out + 1] = g
    end
  end
  return out
end

--- People from the app's configuration: { {name, email, phone, groups, use_email, use_sms} }, plus problems
--- ({ {index, what} }) for entries that were left out or partly used.
function M.people(c)
  c = c or {}
  local list = type(c.people) == "table" and c.people or {}
  local country = trim(c.country_code ~= nil and not is_null(c.country_code) and c.country_code or "+46")
  if not country:match("^%+%d+$") then country = "+46" end
  local out, problems = {}, {}
  for i, p in ipairs(list) do
    if type(p) == "table" and bool(p.person_active, true) then
      local person = {
        name = trim(p.person_name),
        email = M.email(p.person_email),
        phone = M.phone(p.person_phone, country),
        groups = M.groups(p.person_groups),
        use_email = bool(p.person_use_email, true),
        use_sms = bool(p.person_use_sms, false),
      }
      if trim(p.person_email) ~= "" and not person.email then problems[#problems + 1] = { i, "email" } end
      if trim(p.person_phone) ~= "" and not person.phone then problems[#problems + 1] = { i, "phone" } end
      if person.use_sms and not person.phone then problems[#problems + 1] = { i, "sms without phone" } end
      if person.use_email and not person.email and not person.use_sms then problems[#problems + 1] = { i, "no address" } end
      out[#out + 1] = person
    end
  end
  return out, problems
end

-- ---- lists -----------------------------------------------------------------------------------------------------

--- Metadata for the recipients device: recipients_email_<group> and recipients_sms_<group> for every group that
--- has someone on that channel, and recipients.groups with the group names. Lists are sorted and without
--- duplicates, so the same people always give the same metadata.
function M.lists(people)
  local by = {} -- by[channel][group] = set
  local groups = { [GROUP_ALL] = true }
  local function add(channel, group, value)
    by[channel] = by[channel] or {}
    by[channel][group] = by[channel][group] or {}
    by[channel][group][value] = true
  end
  for _, p in ipairs(people) do
    local gs = { GROUP_ALL }
    for _, g in ipairs(p.groups) do gs[#gs + 1] = g groups[g] = true end
    for _, g in ipairs(gs) do
      if p.use_email and p.email then add("email", g, p.email) end
      if p.use_sms and p.phone then add("sms", g, p.phone) end
    end
  end
  local meta, too_long = {}, {}
  for channel, gs in pairs(by) do
    for g, set in pairs(gs) do
      local values = {}
      for v in pairs(set) do values[#values + 1] = v end
      table.sort(values)
      local key = PREFIX .. channel .. "_" .. g
      local text = table.concat(values, ",")
      if chars(text) > MAX_VALUE then
        -- IoT Open refuses longer values: keep whole entries that fit, and say so in the log
        too_long[#too_long + 1] = key
        local kept = {}
        local len = 0
        for _, v in ipairs(values) do
          local add = chars(v) + (#kept > 0 and 1 or 0)
          if len + add > MAX_VALUE then break end
          kept[#kept + 1] = v
          len = len + add
        end
        text = table.concat(kept, ",")
      end
      meta[key] = text
    end
  end
  local names = {}
  for g in pairs(groups) do names[#names + 1] = g end
  table.sort(names)
  meta["recipients.groups"] = table.concat(names, ",")
  table.sort(too_long)
  return meta, too_long
end

-- ---- the device --------------------------------------------------------------------------------------------------

--- The metadata the device should have: its own keys from `lists`, the app's id, and whatever else is already
--- there that is not one of ours (a name changed by hand, for example).
function M.wanted_meta(current, lists, app_id, app_name)
  local meta = {}
  for k, v in pairs(current or {}) do
    if type(k) == "string" and k:sub(1, #PREFIX) ~= PREFIX and k ~= "recipients.groups" then meta[k] = v end
  end
  for k, v in pairs(lists) do meta[k] = v end
  meta[KEY_APP] = tostring(app_id)
  if not meta.name or meta.name == "" then meta.name = app_name or "Mottagare" end
  return meta
end

local function same(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function own_device()
  local devices = lynx.getDevices({ [KEY_APP] = tostring(app.id) }) or {}
  for _, d in ipairs(devices) do
    if type(d) == "table" and d.meta and d.meta[KEY_APP] == tostring(app.id) then return d end
  end
  return nil
end

--- Brings the device in line with the settings. Returns "created", "updated" or "unchanged".
function M.sync()
  local people, problems = M.people(cfg)
  for _, pr in ipairs(problems) do warn("person %d: %s is missing or not valid", pr[1], pr[2]) end
  local lists, too_long = M.lists(people)
  for _, key in ipairs(too_long) do warn("%s would be longer than %d characters: the last addresses are left out, use smaller groups", key, MAX_VALUE) end
  local dev = own_device()
  if dev == nil then
    lynx.createDevice({
      type = DEVICE_TYPE,
      installation_id = app.installation_id,
      meta = M.wanted_meta({}, lists, app.id, app.name),
    })
    log.i("recipients %s: device created, %d people", VERSION, #people)
    return "created"
  end
  local meta = M.wanted_meta(dev.meta, lists, app.id, app.name)
  if same(meta, dev.meta or {}) and dev.type == DEVICE_TYPE then return "unchanged" end
  lynx.apiCall("PUT", "/api/v2/devicex/" .. tostring(dev.installation_id or app.installation_id) .. "/" .. tostring(dev.id), {
    id = dev.id,
    installation_id = dev.installation_id or app.installation_id,
    type = DEVICE_TYPE,
    meta = meta,
    protected_meta = dev.protected_meta or {},
  })
  log.i("recipients %s: device %s updated, %d people", VERSION, tostring(dev.id), #people)
  return "updated"
end

-- ---- edge client callbacks ---------------------------------------------------------------------------------------

function onStart()
  local ok, err = pcall(M.sync)
  if not ok then log.e("could not update the recipients device: %s", tostring(err)) end
end

-- the device was changed or removed by someone else: put our keys back (no change = no call, so no loop)
function onDevicesUpdated()
  local ok, err = pcall(M.sync)
  if not ok then log.e("could not update the recipients device: %s", tostring(err)) end
end

function onDestroy()
  local ok, err = pcall(function()
    local dev = own_device()
    if dev then lynx.deleteDevice(dev.id) end
  end)
  if not ok then log.e("could not remove the recipients device: %s", tostring(err)) end
end

function onExit() end

-- iotopen-rt treats anything the app's code returns as an error, so the functions are only handed out to the tests
if RECIPIENTS_TEST then return M end
