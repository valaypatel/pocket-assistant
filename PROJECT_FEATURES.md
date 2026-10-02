# Circuit — Project Feature List

## Product direction

Circuit is a voice-first, e-ink note device with a companion mobile app. The mobile app is the primary setup, configuration, synchronization, and management interface.

## Companion mobile app

- [ ] iOS companion app
- [ ] Android-only Short-Circuit companion app (first release)
- [ ] Discover Circuit over Bluetooth Low Energy (BLE)
- [ ] Pair securely with Circuit
- [ ] Send Wi-Fi credentials to Circuit over BLE
- [ ] Show Wi-Fi connection and internet status
- [ ] Configure and update saved Wi-Fi networks
- [ ] Configure device settings
- [ ] Set date, time zone, language, and display preferences
- [ ] Browse, search, edit, and organize Circuit notes
- [ ] View tasks and appointments
- [ ] Manage recordings and audio playback
- [ ] Trigger device synchronization
- [ ] Show battery, storage, and firmware status
- [ ] Firmware update flow
- [ ] Help and troubleshooting screens

### Phone internet relay (Android)

- [ ] Let Circuit send HTTPS requests through Short-Circuit over BLE when no saved Wi-Fi is available
- [ ] Prefer direct saved Wi-Fi; fall back to the phone relay; otherwise work offline
- [ ] Keep relay active through an Android foreground service while Circuit is connected
- [ ] Show clear in-app status when the relay is active
- [ ] Apply HTTPS-only requests, timeouts, response-size limits, and block access to the phone's local network
- [ ] Start with a broad managed relay; later restrict it to approved Circuit and AI API endpoints

### Recommended connection model

1. The app connects to Circuit over BLE during setup.
2. The app sends Wi-Fi credentials securely over BLE.
3. Circuit connects directly to Wi-Fi and the internet.
4. The app uses BLE for local setup and nearby control, while Wi-Fi handles syncing and AI/cloud features.

Circuit should prefer direct Wi-Fi. When Wi-Fi is unavailable, Short-Circuit provides an Android-only, app-level HTTPS relay over BLE. It is not a raw IP tether, but it gives Circuit controlled access to the phone's internet connection.

## Existing project features

- [ ] Voice recording
- [ ] Offline recording with later processing when Wi-Fi returns
- [ ] AI transcription
- [ ] Automatic organization of notes
- [ ] Task recognition and task management
- [ ] Appointment/calendar recognition
- [ ] Searchable memories and notes
- [ ] Ask questions about previous recordings
- [ ] Spoken answers
- [ ] Daily and weekly spoken briefings
- [ ] E-ink home screen with open tasks and upcoming appointments
- [ ] Recording markers/timestamps
- [ ] Local web viewer
- [ ] Audio playback and downloads
- [ ] Support for up to five saved Wi-Fi networks
- [ ] Multiple interface languages
- [ ] Adjustable date and time formats
- [ ] microSD storage
- [ ] LiPo battery operation

## Features to add

- [ ]

## Hardware additions

- [ ]

## Software / AI additions

- [ ]

## Open questions

- [ ] Confirm exact Waveshare board revision and memory size
- [ ] Decide whether to use the original firmware or build a custom firmware fork
- [ ] Decide which features must work without an OpenAI API key
- [x] Android-first development; defer iOS until the project is open sourced or an iOS test device is available
