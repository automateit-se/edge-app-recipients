# Recipients (IoT Open edge app)

An IoT Open edge app that keeps the people who get notifications in one place. People are entered once, with their
e-mail address, mobile number, groups and channels, and the app gives every group a ready list per channel. Other
Edge Apps (for example [toolong](https://github.com/automateit-se/edge-app-toolong)) and IoT Open's notification
outputs use the lists, so a new phone number is changed in one place.

Technical names (metadata keys, JSON) are in English; the settings form is in Swedish.

## Settings

| Setting | Meaning |
|---|---|
| Personer | one row per person: name, e-mail, mobile number, groups, channels, active |
| Grupper | comma separated groups as people say them, for example `Personal, Hemtjänst natt`; they become keys (`personal`, `hemtjanst_natt`). Every active person is also in `all` |
| Aviseras med e-post | on by default. E-mail is cheaper than SMS and is the normal channel |
| Aviseras även med SMS | off by default, for those who must be reached at once |
| Aktiv | off keeps the row but sends nothing, for example during holidays |

## What it writes

The app keeps one device of type `recipients` (name *Mottagare*) with one list per group and channel:

| Metadata key | Example |
|---|---|
| `recipients_email_<group>` | `recipients_email_staff = anna@example.com,bo@example.com` |
| `recipients_sms_<group>` | `recipients_sms_staff = +46701234567` |
| `recipients.groups` | `all,night,staff` |
| `recipients.app_id` | the app instance that owns the device |

Lists are sorted and without duplicates. A list that would be empty is left out. The keys follow IoT Open's
`recipients_*` convention, which IoT Open's own Edge Apps also use.

## Using the lists

An Edge App puts a group's lists in the payload of `lynx.notify`:

```lua
local dev = lynx.getDevices({ type = "recipients" })[1]
lynx.notify(output_id, {
  recipients_email = dev.meta.recipients_email_staff,
  recipients_sms = dev.meta.recipients_sms_staff,
  -- ... the rest of the payload
})
```

and the notification output uses the payload as its recipient: `{{.payload.recipients_email}}` for an e-mail
output, `{{.payload.recipients_sms}}` for an SMS output. One output per channel then serves every group.

## How it works

- At start, and when devices change, the app compares the device's metadata with the settings and only writes when
  something differs (so its own update does not start a loop).
- Keys that are not its own, and a name changed by hand, are kept. Its own keys are put back if edited by hand.
- Each app instance owns its own device (`recipients.app_id`). Removing the app removes the device.
- Names, addresses and numbers are never written to the log; invalid rows are logged by row number only.

The lists are personal data. They are visible to everyone with access to the installation in IoT Open.

## Tests

```bash
lua5.3 tests/test_app.lua
```

The tests run `app.lua` with a faked edge client (`cfg`, `app`, `log`, `json`, `lynx`). All people and addresses in
the tests are made up.

## License

MIT
