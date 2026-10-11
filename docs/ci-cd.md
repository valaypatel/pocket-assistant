# CI/CD

Three GitHub Actions workflows in `.github/workflows/`. Each runs only when files
in its own area change, so an app change does not rebuild the firmware.

| Workflow | Runs on | What it does |
|---|---|---|
| `app.yml` | `apps/short_circuit/**` | Format check, `flutter analyze`, `flutter test`, then builds the release APK. A push to `development` sends that APK to the testers. A tag `app-vX.Y.Z` publishes a GitHub release. |
| `firmware.yml` | `firmware/**` | Builds the ESP32-S3 firmware in the ESP-IDF 5.5.3 container and uploads the bootloader, partition table and app as separate files. A tag `firmware-vX.Y.Z` publishes a release. |
| `lambda.yml` | `services/music-lambda/**` | Python tests, builds the Lambda package, `terraform fmt` and `validate`. On `main` it deploys the code to AWS and smoke-tests it. |

`app.yml` and `firmware.yml` also run when `docs/security/test-vectors.json` or `docs/security/reference/**`
change, because both sides check themselves against those. Editing the rest of `docs/security`
(the README) runs nothing, so a text edit does not cost a build.

Pull requests run the checks only. Nothing is deployed or released from a PR.

**Branches.** `development` is where work lands: pull requests target it, and every push to it
sends a signed build to the testers (below), so each change is tried on a phone first. `main` is
production: it only receives `development` once that build has been tried, and a release is a tag
on `main`. A push to `main` builds the APK but does not send it.
Every action is pinned to a commit SHA, and Dependabot proposes updates weekly.

## Nothing to set up

These work as soon as the workflows are merged:

- App checks and the APK artifact (signed with the release key once the signing secrets below are set, otherwise with a throwaway debug key).
- The firmware build and its artifact (`circuit-firmware`: `bootloader.bin`,
  `partition-table.bin` and `circuit-app.bin`, to be flashed at their own addresses).
- Lambda tests, packaging and Terraform validation.

## One-time setup

### Deploying the Lambda from GitHub

The deploy step is skipped until the AWS role exists (done for this repository). No AWS
keys are stored in GitHub: the job swaps its GitHub identity for short-lived credentials.

```bash
cd services/music-lambda/terraform
AWS_PROFILE=tf-admin terraform apply        # adds the deploy role and its policy only
gh variable set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw deploy_role_arn)"
```

This repository uses GitHub's "immutable subject" setting, so its identity token names the
repo with numeric ids. Pass the prefix to Terraform (for example in `terraform.tfvars`) or
AWS will refuse the deploy with "Not authorized to perform sts:AssumeRoleWithWebIdentity":

```bash
gh api repos/valaypatel/pocket-assistant/actions/oidc/customization/sub --jq .sub_claim_prefix
# then: github_subject_prefix = "<that value>"
```

Optional repository variables: `AWS_REGION` (default `ap-south-1`) and
`LAMBDA_FUNCTION_NAME` (default `circuit-music`).

The role can only update that one function's code and invoke it, and only a
workflow running on `main` of `valaypatel/pocket-assistant` can assume it. The
account's existing GitHub provider is reused.

**Rolling back.** Every successful run keeps its package as the `music-lambda-zip`
artifact for 14 days. To put an earlier one back:

```bash
gh run download <run id> -n music-lambda-zip -D old
aws lambda update-function-code --function-name circuit-music --region ap-south-1 \
  --zip-file fileb://old/music-lambda.zip
```

A merge that touches anything under `services/music-lambda` redeploys, even a docs-only
change (the code is the same, so it is harmless). The smoke test only checks that the
function starts and refuses a request with no key; it does not run a recognition.

**Dependencies are pinned.** `services/music-lambda/requirements.lock` lists the exact
version of everything the function runs, and `build.py` installs exactly those, so a
deploy never picks up a newer library by surprise. To change one, edit
`requirements.txt` and regenerate the lock (the command is at the top of the file).

**Code and infrastructure are now split.** The workflow ships the code, and
Terraform ignores it (`ignore_changes` on the function). Use `terraform apply`
for infrastructure and settings, such as the Spotify variables. To deploy code by
hand, run `python3 build.py` and `aws lambda update-function-code`.

A private repository on the free GitHub plan has no branch protection or
environment approvals, so a merge to `main` that touches `services/music-lambda`
deploys straight away. Review before merging.

### Signing the app

Releases are signed with a release key kept outside the repository, in
`~/.circuit-signing/` on the Mac that made it:

| File | What it is |
|---|---|
| `short-circuit-release.keystore` | the release key (4096-bit RSA, SHA-256, valid to 2056) |
| `credentials.env` | its passwords and alias |
| `rotation.lineage` | proof that this key replaces the earlier one (see below) |

**Back these three files up** (a password manager's file storage is fine). If they
are lost, no update can ever be signed to replace the installed app, and the only
way forward is to uninstall it, which erases its data. They are also stored as
GitHub secrets, but secrets cannot be read back out.

**Firebase (events and crash reports).** `google-services.json` from the Firebase console is
not committed. Locally it lives at `apps/short_circuit/android/app/google-services.json`
(git-ignored); CI writes it from the `GOOGLE_SERVICES_JSON_BASE64` secret
(`base64 -i google-services.json | gh secret set GOOGLE_SERVICES_JSON_BASE64`). Without it
the build works and the app sends nothing. What is and is not sent is described at the top
of `apps/short_circuit/lib/telemetry.dart`.

**Release notes.** Each tester build's notes say which build it is, then the "How to test on the
phone" section of the pull request(s) that produced it. The pull request template
(`.github/pull_request_template.md`) has that section: write numbered steps a tester can follow,
and they arrive in the notes (HTML comments are dropped). A build with no such section says so.
The notes are made by `.github/scripts/release-notes.sh`, which never fails the build.

**Firebase App Distribution.** A push to `development`, a release tag (`app-v*`) or a manual run
of the App workflow sends the signed APK to the testers in Firebase. It is skipped until the repository
variable `FIREBASE_APP_ID` exists. One-time setup:

1. Firebase console > Release & Monitor > App Distribution > Get started, and make a tester
   group named `testers` (or set the variable `FIREBASE_TESTER_GROUP`).
2. Google Cloud console > IAM > Service accounts > create one, give it the role
   **Firebase App Distribution Admin**, and make a JSON key for it.
3. `gh secret set FIREBASE_SERVICE_ACCOUNT_JSON < key.json`, then delete the key file.
4. `gh variable set FIREBASE_APP_ID --body "<mobilesdk_app_id from google-services.json>"`.

The key can upload builds and nothing else. A build signed with the throwaway debug key is
refused, because it could not update an installed app.

GitHub secrets used by `app.yml`: `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` and
`ANDROID_LINEAGE_BASE64`. Without the first four, pull request builds use a
throwaway debug key, and a tagged release (`app-v*`) fails on purpose.

**Why there is a rotation proof.** The app on the phone was first installed signed
with the old debug key. Android only accepts an update signed with the same key,
unless the update carries a signed proof that a new key replaces the old one
(Android 9 and later). `tool/sign_with_lineage.sh` attaches that proof, so the app
updates in place and keeps its notes, settings and pairing. For that reason the app
needs Android 9 or later (`minSdk = 28`) and is signed with the v3 scheme only,
which is the one that carries the proof. The old key is not needed again.

Every build is numbered by the time it was made (10-second steps since 2026-01-01 UTC), by CI
and by hand alike, so the build made last always has the higher number. Android refuses to
install a lower number over a higher one, and the only way round that is to uninstall, which
wipes the app's settings, keys and notes. So never pick a number yourself: a build made by hand
for a phone uses `flutter build apk --release --build-number="$(tool/build_number.sh)"`. (Builds
before 7 October 2026 were `1000 + the run number`; the time-based numbers are far above them.)
If the rotation secret
(`ANDROID_LINEAGE_BASE64`) is ever missing, the build warns, and the APK will not
update an app that was installed signed with the previous key.

Locally, put the same values in `apps/short_circuit/android/key.properties`
(git-ignored), including `lineageFile=<path to rotation.lineage>`. Then:

```bash
cd apps/short_circuit
flutter build apk --release
tool/sign_with_lineage.sh build/app/outputs/flutter-apk/app-release.apk
```

Check the result with the Android SDK's `apksigner verify --print-certs`, and read
the proof back with `apksigner lineage --in app-release.apk --print-certs`.

To change keys again later, make a new keystore and a new lineage with
`apksigner rotate --old-signer ... --new-signer ...` from the current key, then
replace the secrets.

## Releasing

```bash
git tag app-v1.0.1 && git push origin app-v1.0.1             # Short-Circuit APK
git tag firmware-v0.2.0 && git push origin firmware-v0.2.0   # Circuit firmware files
```

Flash a firmware release with its three files, each at its own address:

```bash
esptool.py --chip esp32s3 write_flash \
  0x0 bootloader.bin 0x8000 partition-table.bin 0x10000 circuit-app-<version>.bin
```

This writes only those regions. The board's saved Wi-Fi, pairing and notes key live
in flash at `0x9000`, between the partition table and the app, and are left alone.
**Do not flash a single merged image at `0x0`, and do not run `erase_flash`:** a
merged image is blank between its parts, so either one wipes that region. Notes
sealed with the wiped key could then only be opened by a phone that already holds it.

## Flashing a build from GitHub

`firmware/CircuitBleDisplay/tools/flash-release.sh` downloads a firmware build and flashes the
board that is plugged in over USB. It needs `gh` (signed in, the repository is private) and
`esptool` (`pip install esptool`).

```bash
tools/flash-release.sh                  # the newest release (tag firmware-v*)
tools/flash-release.sh firmware-v0.2.0  # a specific release
tools/flash-release.sh --run 123456     # the build of a GitHub Actions run, before it is released
tools/flash-release.sh --dir ./dist     # files you already have
tools/flash-release.sh --dry-run        # download and check everything, flash nothing
```

It checks the files against `SHA256SUMS`, refuses anything that looks like a merged image,
finds the board's serial port (or use `--port`), asks before flashing (`--yes` skips the
question) and writes only the bootloader, partition table and app. Your saved Wi-Fi, pairing and
notes key are never touched. Close any serial monitor first; it holds the port.

A release needs a tag: `git tag firmware-v0.2.0 && git push origin firmware-v0.2.0`. Until one
exists, use `--run` with an id from `gh run list --workflow firmware.yml`.

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
