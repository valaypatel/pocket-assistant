# CI/CD

Three GitHub Actions workflows in `.github/workflows/`. Each runs only when files
in its own area change, so an app change does not rebuild the firmware.

| Workflow | Runs on | What it does |
|---|---|---|
| `app.yml` | `apps/short_circuit/**` | Format check, `flutter analyze`, `flutter test`, then builds the release APK. A tag `app-vX.Y.Z` publishes a GitHub release. |
| `firmware.yml` | `firmware/**` | Builds the ESP32-S3 firmware in the ESP-IDF 5.5.3 container and uploads the flash image. A tag `firmware-vX.Y.Z` publishes a release. |
| `lambda.yml` | `services/music-lambda/**` | Python tests, builds the Lambda package, `terraform fmt` and `validate`. On `main` it deploys the code to AWS and smoke-tests it. |

Pull requests run the checks only. Nothing is deployed or released from a PR.
Every action is pinned to a commit SHA, and Dependabot proposes updates weekly.

## Nothing to set up

These work as soon as the workflows are merged:

- App checks and the debug-signed APK artifact.
- The firmware build and its artifact (`circuit-firmware`, containing
  `circuit-firmware.bin`, the whole flash image to write at address 0).
- Lambda tests, packaging and Terraform validation.

## One-time setup

### Deploying the Lambda from GitHub

The deploy step is skipped until the AWS role exists. No AWS keys are stored in
GitHub: the job swaps its GitHub identity for short-lived credentials.

```bash
cd services/music-lambda/terraform
AWS_PROFILE=tf-admin terraform apply        # adds the deploy role and its policy only
gh variable set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw deploy_role_arn)"
```

Optional repository variables: `AWS_REGION` (default `ap-south-1`) and
`LAMBDA_FUNCTION_NAME` (default `circuit-music`).

The role can only update that one function's code and invoke it, and only a
workflow running on `main` of `valaypatel/pocket-assistant` can assume it. The
account's existing GitHub provider is reused.

**Code and infrastructure are now split.** The workflow ships the code, and
Terraform ignores it (`ignore_changes` on the function). Use `terraform apply`
for infrastructure and settings, such as the Spotify variables. To deploy code by
hand, run `python3 build.py` and `aws lambda update-function-code`.

A private repository on the free GitHub plan has no branch protection or
environment approvals, so a merge to `main` that touches `services/music-lambda`
deploys straight away. Review before merging.

### Signing the app for releases

An APK built on a CI runner is signed with a throwaway debug key, and Android
refuses to update an installed app with an APK signed by a different key. So a
**release** (tag `app-v*`) fails unless these four secrets exist:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore, base64 encoded |
| `ANDROID_KEYSTORE_PASSWORD` | its store password |
| `ANDROID_KEY_ALIAS` | the key alias |
| `ANDROID_KEY_PASSWORD` | the key password |

To keep updating the copy already on your phone, it has to be signed with the
same key. That one was built with this machine's debug keystore:

```bash
base64 -i ~/.android/debug.keystore | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD --body android
gh secret set ANDROID_KEY_ALIAS --body androiddebugkey
gh secret set ANDROID_KEY_PASSWORD --body android
```

Or make a new key (`keytool -genkeypair ...`) and reinstall the app once; that
loses its saved settings and Circuit pairing. A debug keystore's password is
well known, so use a proper key before sharing the app with anyone.

Locally, `android/key.properties` (git-ignored) does the same job. Without it the
release build uses the debug key, as before.

## Releasing

```bash
git tag app-v1.0.1 && git push origin app-v1.0.1             # Short-Circuit APK
git tag firmware-v0.2.0 && git push origin firmware-v0.2.0   # Circuit flash image
```

Flash a firmware release with
`esptool.py --chip esp32s3 write_flash 0x0 circuit-firmware-<version>.bin`.

## How the firmware build works

The board support code (Waveshare's example, LVGL, the codec driver) is not in
this repository. The workflow fetches it at a pinned commit and resolves the
components from `firmware/CircuitBleDisplay/ci/waveshare.dependencies.lock`, a
copy of the lock file from the working build, so the versions and hashes match
the board (LVGL 9.6.0). Without the lock, `lvgl/lvgl: ^9.3.0` would pick up the
newest 9.x.

To move to a newer Waveshare commit or component set, change `WAVESHARE_COMMIT`
in `firmware.yml`, build locally, and copy the new `dependencies.lock` over the
file in `ci/`.
