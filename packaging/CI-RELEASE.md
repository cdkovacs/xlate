# CI release (GitHub Actions)

`.github/workflows/release.yml` computes the next version, builds the signed and
notarized `.pkg` on a `macos-26` runner, and publishes it as a GitHub Release.

## Trigger and versioning

- Runs on manual **Run workflow** (`workflow_dispatch`). The `push` trigger is
  commented out; uncomment it to release on every push to `main`.
- Version comes from [`paulhatch/semantic-version`](https://github.com/PaulHatch/semantic-version)
  using Conventional Commits: `feat:` bumps minor, `!:` or `BREAKING CHANGE:` bumps
  major, anything else bumps patch. With no `v*` tag yet, the first release is `0.0.1`.
- The release is tagged `v<version>` with two assets: `Xlate-<version>.pkg` and a
  stable-named `Xlate.pkg`, so
  `https://github.com/cdkovacs/xlate/releases/latest/download/Xlate.pkg` always
  points at the newest installer.

## Required secrets

Set these under Settings, Secrets and variables, Actions, or with the `gh`
commands below. They're the same set the dbox-email-filer release uses, so the same
`.p12` and `.p8` files work if both apps ship under one Apple team. Secret values
can't be copied between repos, so they have to be set again here.

| Secret | What it is |
|--------|------------|
| `DEVID_APP_P12_BASE64` | base64 of the Developer ID Application identity `.p12` |
| `DEVID_INSTALLER_P12_BASE64` | base64 of the Developer ID Installer identity `.p12` |
| `P12_PASSWORD` | the export password on both `.p12` files |
| `KEYCHAIN_PASSWORD` | any string; protects the throwaway keychain on the runner |
| `ASC_API_KEY_P8_BASE64` | base64 of the App Store Connect API key `AuthKey_XXXX.p8` |
| `ASC_KEY_ID` | the API key's Key ID |
| `ASC_ISSUER_ID` | the API key's Issuer ID (UUID) |

The certificate common names aren't secrets. The workflow reads them from the
keychain after import.

```sh
openssl base64 -A -in devid_app.p12       | gh secret set DEVID_APP_P12_BASE64 -R cdkovacs/xlate
openssl base64 -A -in devid_installer.p12 | gh secret set DEVID_INSTALLER_P12_BASE64 -R cdkovacs/xlate
openssl base64 -A -in AuthKey_XXXX.p8     | gh secret set ASC_API_KEY_P8_BASE64 -R cdkovacs/xlate
gh secret set P12_PASSWORD      -R cdkovacs/xlate --body 'your-p12-export-password'
gh secret set KEYCHAIN_PASSWORD -R cdkovacs/xlate --body 'any-random-string'
gh secret set ASC_KEY_ID        -R cdkovacs/xlate --body 'XXXXXXXXXX'
gh secret set ASC_ISSUER_ID     -R cdkovacs/xlate --body 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

## Local builds

```sh
SIGN=0 packaging/build_pkg.sh            # unsigned, ad-hoc signed app
```

A `SIGN=0` build leaves `build/Xlate.app` ad-hoc signed, which drops its audio
capture permission. Run `scripts/bundle.sh` afterwards to re-sign the dev copy.

## Notes

- The installer is Apple Silicon only (`hostArchitectures="arm64"`) and needs
  macOS 26, matching `LSMinimumSystemVersion` in `Resources/Info.plist`.
- `packaging/component.plist` marks the bundle non-relocatable. Without it,
  Installer finds any other `dev.ckovacs.xlate` bundle on disk (such as a dev
  `build/Xlate.app`) and upgrades that copy instead of writing to `/Applications`.
- If notarization fails, the log prints the submission id;
  `xcrun notarytool log <id> --keychain-profile xlate-notary` shows Apple's reason.
