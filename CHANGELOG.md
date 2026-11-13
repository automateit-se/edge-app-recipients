# Changelog

## Unreleased

## 0.2.0

- Groups are written as people say them, for example `Personal, Hemtjänst natt`, and become keys
  (`personal`, `hemtjanst_natt`): `recipients_email_hemtjanst_natt`. Other apps (För länge 0.4) take the group
  written the same way. Groups already written as keys are unchanged.

## 0.1.3

- A person with a missing or invalid value, or a list longer than 1024 characters, stopped the app: the edge
  client's log has no `log.w`. Warnings are now written with `log.i` as `warning: ...`, and the tests use a log
  without `w`.

## 0.1.2

- No Landsnummer field in the form: a number like 070-123 45 67 becomes +46701234567, and a number in another
  country is written with its own code (+47 ...). `country_code` can still be set in the JSON.

## 0.1.1

- A list longer than IoT Open stores (1024 characters) keeps the whole addresses that fit and logs a warning,
  instead of a value IoT Open refuses.

## 0.1.0

- First version. People with e-mail, mobile number, groups and channels in the app's settings; one list per group
  and channel (`recipients_email_<group>`, `recipients_sms_<group>`) as metadata on a device of type `recipients`.
- E-mail on by default, SMS only when ticked. Every active person is also in the group `all`.
- Phone numbers are made international (a leading 0 becomes the country code, `+46` by default).
- Names, addresses and numbers are never written to the log.
