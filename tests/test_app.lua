-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client's globals (cfg, app, log, json, lynx) are faked. All people and addresses are made up.

local failures, count = 0, 0

local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end

local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

--- Loads app.lua in a fake edge client. opts: cfg, devices (list of device tables).
local function load_app(opts)
  local fake = { devices = opts.devices or {}, calls = {}, logs = {}, next_id = 100 }
  local lynx = {
    getDevices = function(filter)
      local out = {}
      for _, d in ipairs(fake.devices) do
        local hit = true
        for k, v in pairs(filter or {}) do if (d.meta or {})[k] ~= v then hit = false end end
        if hit then out[#out + 1] = d end
      end
      return out
    end,
    createDevice = function(d)
      fake.calls[#fake.calls + 1] = { "create", d }
      fake.next_id = fake.next_id + 1
      fake.devices[#fake.devices + 1] = { id = fake.next_id, installation_id = d.installation_id, type = d.type, meta = d.meta }
    end,
    apiCall = function(method, path, body)
      fake.calls[#fake.calls + 1] = { method, path, body }
      for i, d in ipairs(fake.devices) do if d.id == body.id then fake.devices[i] = body end end
      return body
    end,
    deleteDevice = function(id)
      fake.calls[#fake.calls + 1] = { "delete", id }
      for i, d in ipairs(fake.devices) do if d.id == id then table.remove(fake.devices, i) break end end
    end,
  }
  local function logger(level)
    return function(f, ...) fake.logs[#fake.logs + 1] = level .. " " .. string.format(f, ...) end
  end
  local env = setmetatable({
    RECIPIENTS_TEST = true,
    cfg = opts.cfg or {},
    app = { id = 7, installation_id = 1001, name = "Mottagare" },
    json = { null = setmetatable({}, { __tostring = function() return "null" end }) },
    lynx = lynx,
    log = { i = logger("I"), e = logger("E") },
  }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  local M = chunk()
  return M, env, fake
end

local PEOPLE = {
  { person_name = "Anna", person_email = "Anna@Example.com", person_groups = "staff, Night" },
  { person_name = "Bo", person_email = "bo@example.com", person_phone = "070-123 45 67", person_groups = "staff", person_use_sms = true },
  { person_name = "Cia", person_email = "cia@example.com", person_groups = "relatives", person_active = false },
  { person_name = "Dan", person_phone = "+46 70 765 43 21", person_groups = "night", person_use_email = false, person_use_sms = true },
}

-- ---- parsing ---------------------------------------------------------------------------------------------------

check("e-mail addresses are checked and lower cased", function()
  local M = load_app({})
  eq(M.email(" Anna@Example.COM "), "anna@example.com", "valid")
  eq(M.email("anna@example"), nil, "no domain")
  eq(M.email("anna@@example.com"), nil, "two @")
  eq(M.email("an..na@example.com"), nil, "double dot")
  eq(M.email(""), nil, "empty")
end)

check("phone numbers become international", function()
  local M = load_app({})
  eq(M.phone("070-123 45 67"), "+46701234567", "leading 0")
  eq(M.phone("0046701234567"), "+46701234567", "00")
  eq(M.phone("+47 912 34 567"), "+4791234567", "other country")
  eq(M.phone("070-123 45 67", "+358"), "+358701234567", "other country code")
  eq(M.phone("12"), nil, "too short")
  eq(M.phone("070 abc"), nil, "letters")
end)

check("groups are cleaned and deduplicated", function()
  local M = load_app({})
  local g = M.groups(" Staff, night ;staff, Night Shift,, bad!name, Hemtjänst natt, Åre-gruppen")
  eq(table.concat(g, "|"), "staff|night|night_shift|bad_name|hemtjanst_natt|are-gruppen", "groups")
end)

-- ---- lists -----------------------------------------------------------------------------------------------------

check("one sorted list per group and channel, inactive people left out", function()
  local M = load_app({})
  local meta = M.lists((M.people({ people = PEOPLE })))
  eq(meta.recipients_email_staff, "anna@example.com,bo@example.com", "email staff")
  eq(meta.recipients_email_night, "anna@example.com", "email night (Dan has no e-mail)")
  eq(meta.recipients_sms_staff, "+46701234567", "sms staff")
  eq(meta.recipients_sms_night, "+46707654321", "sms night")
  eq(meta.recipients_email_all, "anna@example.com,bo@example.com", "email all")
  eq(meta.recipients_sms_all, "+46701234567,+46707654321", "sms all")
  eq(meta.recipients_email_relatives, nil, "inactive person gives no list")
  eq(meta["recipients.groups"], "all,night,staff", "group names")
end)

check("SMS only for those who ask for it", function()
  local M = load_app({})
  local meta = M.lists((M.people({ people = { { person_name = "Eva", person_email = "eva@example.com", person_phone = "0701111111", person_groups = "staff" } } })))
  eq(meta.recipients_sms_staff, nil, "no sms without the toggle")
  eq(meta.recipients_email_staff, "eva@example.com", "email by default")
end)

check("without a country code setting a leading 0 becomes +46", function()
  local M = load_app({})
  local people = M.people({ people = { { person_name = "Eva", person_phone = "070-111 11 11", person_use_sms = true, person_groups = "staff" } } })
  eq(people[1].phone, "+46701111111", "default +46")
  local meta = M.lists(people)
  eq(meta.recipients_sms_staff, "+46701111111", "in the list")
end)

check("a list longer than IoT Open stores keeps whole addresses that fit", function()
  local M = load_app({})
  local people = {}
  for i = 1, 60 do people[#people + 1] = { person_name = "P" .. i, person_email = string.format("person%02d@example.com", i), person_groups = "staff" } end
  local meta, too_long = M.lists((M.people({ people = people })))
  assert(#meta.recipients_email_staff <= 1024, #meta.recipients_email_staff)
  assert(meta.recipients_email_staff:match("@example%.com$"), "ends with a whole address")
  eq(too_long[1], "recipients_email_all", "reported")
end)

check("problems are reported without the values", function()
  local M = load_app({})
  local _, problems = M.people({ people = {
    { person_name = "X", person_email = "not-an-address", person_groups = "staff" },
    { person_name = "Y", person_groups = "staff", person_use_sms = true },
  } })
  eq(#problems, 3, "problems")
  eq(problems[1][2], "email", "bad e-mail")
  eq(problems[2][2], "no address", "no address")
  eq(problems[3][2], "sms without phone", "sms without phone")
end)

check("the same people always give the same metadata", function()
  local M = load_app({})
  local reversed = {}
  for i = #PEOPLE, 1, -1 do reversed[#reversed + 1] = PEOPLE[i] end
  local a = M.lists((M.people({ people = PEOPLE })))
  local b = M.lists((M.people({ people = reversed })))
  for k, v in pairs(a) do eq(b[k], v, k) end
end)

check("json null and string toggles from the form", function()
  local M, env = load_app({})
  local people = M.people({ people = { { person_name = "Z", person_email = "z@example.com", person_active = env.json.null, person_use_sms = "false" } } })
  eq(#people, 1, "null active = active")
  eq(people[1].use_sms, false, "string false")
end)

-- ---- the device ------------------------------------------------------------------------------------------------

check("first start creates the device", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.onStart()
  eq(#fake.devices, 1, "devices")
  local d = fake.devices[1]
  eq(d.type, "recipients", "type")
  eq(d.installation_id, 1001, "installation")
  eq(d.meta["recipients.app_id"], "7", "app id")
  eq(d.meta.name, "Mottagare", "name")
  eq(d.meta.recipients_email_staff, "anna@example.com,bo@example.com", "list")
end)

check("an unchanged configuration makes no call", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.onStart()
  local n = #fake.calls
  env.onStart()
  env.onDevicesUpdated()
  eq(#fake.calls, n, "calls")
end)

check("a changed configuration updates the device and removes old lists", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.onStart()
  env.cfg.people = { PEOPLE[1] }
  env.onStart()
  local d = fake.devices[1]
  eq(fake.calls[#fake.calls][1], "PUT", "update")
  eq(fake.calls[#fake.calls][2], "/api/v2/devicex/1001/101", "path")
  eq(d.meta.recipients_email_staff, "anna@example.com", "list")
  eq(d.meta.recipients_sms_staff, nil, "old list removed")
  eq(d.meta["recipients.groups"], "all,night,staff", "groups")
end)

check("keys added by hand and a new name are kept", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.onStart()
  fake.devices[1].meta.name = "Mottagare hus A"
  fake.devices[1].meta.note = "kept"
  fake.devices[1].meta.recipients_email_staff = "hand@example.com" -- ours: put back
  env.onDevicesUpdated()
  local d = fake.devices[1]
  eq(d.meta.name, "Mottagare hus A", "name")
  eq(d.meta.note, "kept", "other key")
  eq(d.meta.recipients_email_staff, "anna@example.com,bo@example.com", "our key restored")
end)

check("another app's recipients device is left alone", function()
  local other = { id = 50, installation_id = 1001, type = "recipients", meta = { ["recipients.app_id"] = "8", recipients_email_staff = "x@example.com" } }
  local _, env, fake = load_app({ cfg = { people = PEOPLE }, devices = { other } })
  env.onStart()
  eq(#fake.devices, 2, "devices")
  eq(fake.devices[1].meta.recipients_email_staff, "x@example.com", "other device untouched")
end)

check("removing the app removes its device", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.onStart()
  env.onDestroy()
  eq(#fake.devices, 0, "devices")
end)

check("no names, addresses or numbers in the log", function()
  local _, env, fake = load_app({ cfg = { people = {
    { person_name = "Anna", person_email = "bad-address", person_phone = "070-123 45 67", person_use_sms = true, person_groups = "staff" },
  } } })
  env.onStart()
  for _, line in ipairs(fake.logs) do
    assert(not line:find("Anna") and not line:find("bad-address") and not line:find("070") and not line:find("+467", 1, true), line)
  end
end)

check("an error from IoT Open is logged, not raised", function()
  local _, env, fake = load_app({ cfg = { people = PEOPLE } })
  env.lynx.getDevices = function() error("timeout") end
  env.onStart()
  assert(fake.logs[#fake.logs]:find("^E could not update"), fake.logs[#fake.logs])
end)

check("the code returns nothing in the edge client", function()
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
