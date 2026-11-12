# Changelog

## Unreleased

## 0.1.0

- First version. People with e-mail, mobile number, groups and channels in the app's settings; one list per group
  and channel (`recipients_email_<group>`, `recipients_sms_<group>`) as metadata on a device of type `recipients`.
- E-mail on by default, SMS only when ticked. Every active person is also in the group `all`.
- Phone numbers are made international (a leading 0 becomes the country code, `+46` by default).
- Names, addresses and numbers are never written to the log.
