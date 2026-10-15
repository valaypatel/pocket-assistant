# Pocket Assistant

A pocket voice-note device with an e-paper screen, plus an Android companion app.
Speak a thought into the device. It is saved on the board, synced to your phone,
transcribed, sorted, and turned into tasks you can chat about.

The long-term goal is an assistant that acts on your behalf, for example
"tell my wife I'm running late" while you drive. See
[PROJECT_FEATURES.md](PROJECT_FEATURES.md) for the roadmap.

> Working names: the board is called **Circuit** and the Android app is
> **Short-Circuit**. Both are placeholders and the code uses them throughout.

## What works today

- **Board:** records audio, shows state and notes on a 200x200 1-bit e-paper
  screen, and stores each note as its own WAV file.
- **Pairing:** secure BLE bonding between phone and board.
- **Sync:** the phone sends Wi-Fi credentials over BLE. Notes then sync over
  HTTPS on the board's Wi-Fi, using a pinned self-signed certificate and a token
  exchanged over the bonded BLE link.
- **Phone relay:** when the board has no Wi-Fi, an Android foreground service can
  relay its HTTPS requests over BLE.
- **App:** notes list and search, audio playback, tasks, per-note detail, and
  delete (which also deletes the note on the board).
- **AI:** Gemini transcribes the audio. A separate OpenAI-compatible service
  (you configure the base URL, key and model in the app) titles and summarises
  notes, extracts tasks and reminders, and powers per-note chat. Failed AI
  calls are retried in the background and can be re-run from the note page.

## Repository layout

```
apps/short_circuit/              Flutter app plus a Kotlin foreground relay service
firmware/CircuitBleDisplay/      ESP32-S3 firmware (ESP-IDF + LVGL), the current board firmware
prototypes/                      HTML mock-ups of the e-paper states and the app
PROJECT_FEATURES.md              Feature list and roadmap
```

## Hardware

- Waveshare ESP32-S3 e-paper 1.54" board
  ([waveshareteam/ESP32-S3-ePaper-1.54](https://github.com/waveshareteam/ESP32-S3-ePaper-1.54))
- An Android phone (the app is Android-only for now)

## Building the firmware

The firmware reuses Waveshare's board-specific components, which are not stored
in this repository. Clone them into `vendor/` first:

```bash
mkdir -p vendor
git clone https://github.com/waveshareteam/ESP32-S3-ePaper-1.54.git vendor/waveshare-board
```

Install ESP-IDF 5.5.3, then build and flash:

```bash
cd firmware/CircuitBleDisplay
idf.py set-target esp32s3
idf.py build
idf.py -p <serial-port> flash monitor
```

`CMakeLists.txt` expects the Waveshare example at
`vendor/waveshare-board/02_Example/ESP-IDF/V2/11_FactoryProgram/`. The patched
display driver (it uses an internal DMA buffer to stay stable during Wi-Fi sync)
is in `firmware/CircuitBleDisplay/components/board_display`.

## Building the app

You need the Flutter SDK (Dart `^3.13.5`) and the Android SDK.

```bash
cd apps/short_circuit
flutter pub get
flutter test
flutter build apk --release
```

Install on a phone with `adb install -r build/app/outputs/flutter-apk/app-release.apk`.

### First run

1. Open the app and pair with the board over Bluetooth.
2. Add your Wi-Fi network on the Circuit page.
3. Under settings, add a Gemini API key (transcription) and, optionally, the
   base URL, key and model for an OpenAI-compatible service (notes review and
   chat). Keys are kept in Android secure storage and never in the repository.

## Security

New notes are encrypted on the board as they are recorded and stay encrypted in
transit and on the phone. Nothing deletes a note or a key. See
[docs/security/README.md](docs/security/README.md) for how it works and what it
does and does not protect against.

## License

Circuit is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): you can
read, run, change and share it for noncommercial purposes, and every copy must keep the licence
and the "Required Notice" line in [NOTICE](NOTICE), which names the copyright holder. Commercial
use needs a separate licence from the copyright holder. The ESP-IDF patch and other third-party
parts keep their own licences; [NOTICE](NOTICE) lists them.

## CI/CD

GitHub Actions builds and tests each part when its files change, and can release
the APK and the firmware files from a tag. The Lambda code deploys from `main`
once its AWS role is set up. See [docs/ci-cd.md](docs/ci-cd.md).

## Project status

Early and personal. Things change often, and the board firmware and app are
developed together, so keep them at the same commit.
