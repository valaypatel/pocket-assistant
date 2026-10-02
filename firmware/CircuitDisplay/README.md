# Circuit display firmware

This first Circuit firmware makes the Waveshare ESP32-S3-ePaper-1.54 a Bluetooth Low Energy peripheral named `Circuit`.

It exposes one BLE service and two characteristics:

| Purpose | UUID | Properties |
| --- | --- | --- |
| Circuit service | `9f4b3a00-7e46-4df9-9b85-7c4e3e5b1000` | — |
| Display command | `9f4b3a01-7e46-4df9-9b85-7c4e3e5b1000` | Write |
| Status | `9f4b3a02-7e46-4df9-9b85-7c4e3e5b1000` | Read, Notify |

Send UTF-8 JSON to the display-command characteristic:

```json
{"text":"Hello, Circuit!","size":2,"alignment":"center"}
```

`size` accepts 1–4. `alignment` accepts `left`, `center`, or `right`.

## Build and upload

The board needs 8 MB flash and OPI PSRAM enabled. From the workspace root:

```sh
arduino-cli compile --fqbn esp32:esp32:esp32s3:FlashSize=8M,PartitionScheme=default_8MB,PSRAM=opi firmware/CircuitDisplay
arduino-cli upload --fqbn esp32:esp32:esp32s3:FlashSize=8M,PartitionScheme=default_8MB,PSRAM=opi --port /dev/cu.usbmodem101 firmware/CircuitDisplay
```

The display driver and pins come from Waveshare's official board examples, stored in `vendor/waveshare-board`.
