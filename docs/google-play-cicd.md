# Google Play CI/CD

This repository publishes the Android Flutter app to the Google Play **open testing** track (`beta`) through `.github/workflows/android-play-deploy.yml`.

## Workflow behavior

- `push` with a tag matching `v*` builds a signed Android App Bundle and uploads it to the `beta` Google Play track.
- `workflow_dispatch` manually builds and uploads the signed AAB to the same `beta` track.
- The workflow builds `build/app/outputs/bundle/release/app-release.aab` with `flutter build appbundle --release`.
- The Android `versionCode` is overridden with `github.run_number`, keeping Play uploads unique across CI runs.
- Metadata, images, screenshots, and changelogs are intentionally skipped. The workflow uploads only the binary.
- The deployment track is intentionally fixed to `beta`; `alpha`, `internal`, and `production` are not exposed as manual options.

## Required GitHub Actions secrets

Create these repository secrets under `Settings > Secrets and variables > Actions`:

| Secret | Purpose |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded Android upload keystore. |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password. |
| `ANDROID_KEY_ALIAS` | Upload key alias. |
| `ANDROID_KEY_PASSWORD` | Upload key password. |
| `PLAY_SERVICE_ACCOUNT_JSON` | Raw Google Play service account JSON credentials. |

## Keystore Base64 helper

PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\upload-keystore.jks")) | Set-Clipboard
```

Git Bash / Linux / macOS:

```sh
base64 -w 0 android/upload-keystore.jks
```

## Google Play setup checklist

1. Enable Play App Signing for the app.
2. Use the same upload key represented by `ANDROID_KEYSTORE_BASE64`.
3. Enable the Google Play Android Developer API in Google Cloud.
4. Create a service account JSON key.
5. Link/grant that service account access in Play Console with release permissions for this app.
6. Add the JSON content as `PLAY_SERVICE_ACCOUNT_JSON` in GitHub Actions secrets.
7. Ensure the package name is `com.vitorhugo.sonicrelay.sonic_relay`.
8. Create/configure the Open testing track in Play Console and its tester/feedback settings.

## Safety notes

- Do not commit `android/key.properties`, `.jks`, or `.keystore` files.
- The default CI workflow can still build without signing secrets because `android/app/build.gradle.kts` falls back to the debug signing config when `android/key.properties` is missing.
- The Play deploy workflow fails early if any required secret is missing.
- To publish outside Open testing later, add a separate workflow or PR instead of changing this one silently.
