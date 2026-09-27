# Releasing

Every release is a signed, notarized DMG and zip on GitHub Releases, so Farol opens on any Mac without warnings.

## Publish a release

1. Move the changes under `## [Unreleased]` in `CHANGELOG.md` into a new section like `## [0.1.2] - 2026-10-04`. Its text becomes the release notes.
2. Commit, then tag and push:

```sh
git tag -a v0.1.2 -m "Farol 0.1.2" && git push origin v0.1.2
```

The tag runs `.github/workflows/release.yml`. It builds, tests, signs, notarizes and publishes the release. Tags with a suffix, like `v0.2.0-beta`, become pre-releases.

## Build a signed release locally

`make dist` builds a zip that opens on any Mac without warnings: signed with a Developer ID, notarized by Apple and stapled. It needs a Developer ID Application certificate in your keychain and a notarization key stored once:

```sh
xcrun notarytool store-credentials farol --key AuthKey_XXXX.p8 --key-id <Key ID> --issuer <Issuer ID>
```

The key comes from App Store Connect, under Users and Access, Integrations, App Store Connect API.

## Repository secrets

Pushing a tag like `v0.1.1` runs `.github/workflows/release.yml`: it builds, tests, signs and notarizes, then publishes a DMG and a zip on GitHub Releases with that version's section of `CHANGELOG.md` as the notes. Tags with a suffix, like `v0.2.0-beta`, become pre-releases. The workflow needs these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate exported from Keychain Access as .p12, base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave the .p12 |
| `NOTARY_KEY` | The App Store Connect .p8 key, base64 encoded |
| `NOTARY_KEY_ID` | Its Key ID |
| `NOTARY_ISSUER_ID` | Its Issuer ID |
