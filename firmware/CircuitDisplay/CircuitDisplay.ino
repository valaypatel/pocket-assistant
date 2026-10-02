#include <Arduino.h>
#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <Adafruit_GFX.h>

// Waveshare's official display driver is kept in vendor/ so its panel setup and
// pin assignments remain traceable to the board manufacturer.
#include "../../vendor/waveshare-board/02_Example/Arduino/09_LVGL_V8_Test/src/display/epaper_driver_bsp.cpp"

namespace {
constexpr uint8_t kEpdPowerPin = 6;
constexpr uint16_t kDisplayWidth = 200;
constexpr uint16_t kDisplayHeight = 200;

constexpr char kDeviceName[] = "Circuit";
constexpr char kServiceUuid[] = "9f4b3a00-7e46-4df9-9b85-7c4e3e5b1000";
constexpr char kDisplayCommandUuid[] = "9f4b3a01-7e46-4df9-9b85-7c4e3e5b1000";
constexpr char kStatusUuid[] = "9f4b3a02-7e46-4df9-9b85-7c4e3e5b1000";

epaper_driver_display* displayDriver = nullptr;
BLECharacteristic* statusCharacteristic = nullptr;
String pendingCommand;
bool hasPendingCommand = false;

class EInkCanvas final : public Adafruit_GFX {
 public:
  explicit EInkCanvas(epaper_driver_display& driver)
      : Adafruit_GFX(kDisplayWidth, kDisplayHeight), driver_(driver) {}

  void drawPixel(int16_t x, int16_t y, uint16_t color) override {
    if (x < 0 || y < 0 || x >= kDisplayWidth || y >= kDisplayHeight) {
      return;
    }
    driver_.EPD_DrawColorPixel(x, y, color == DRIVER_COLOR_BLACK ? DRIVER_COLOR_BLACK : DRIVER_COLOR_WHITE);
  }

 private:
  epaper_driver_display& driver_;
};

void notifyStatus(const char* status) {
  Serial.printf("[Circuit] %s\n", status);
  if (statusCharacteristic != nullptr) {
    statusCharacteristic->setValue(status);
    statusCharacteristic->notify();
  }
}

void showText(const String& text, uint8_t size, const String& alignment) {
  size = constrain(size, 1, 4);
  displayDriver->EPD_Clear();
  EInkCanvas canvas(*displayDriver);
  canvas.setTextColor(DRIVER_COLOR_BLACK);
  canvas.setTextSize(size);
  canvas.setTextWrap(true);

  const int16_t lineHeight = 8 * size;
  int16_t cursorY = 12;
  int16_t start = 0;
  while (start <= text.length() && cursorY <= kDisplayHeight - lineHeight) {
    int16_t newline = text.indexOf('\n', start);
    if (newline < 0) newline = text.length();
    String line = text.substring(start, newline);
    int16_t x1, y1;
    uint16_t width, height;
    canvas.getTextBounds(line, 0, cursorY, &x1, &y1, &width, &height);
    int16_t cursorX = 8;
    if (alignment == "center") cursorX = (kDisplayWidth - width) / 2;
    if (alignment == "right") cursorX = kDisplayWidth - width - 8;
    canvas.setCursor(max<int16_t>(0, cursorX), cursorY);
    canvas.print(line);
    cursorY += lineHeight + 4;
    start = newline + 1;
  }

  displayDriver->EPD_DisplayPart();
  notifyStatus("displayed");
}

void processCommand(const String& command) {
  JsonDocument document;
  const DeserializationError error = deserializeJson(document, command);
  if (error) {
    notifyStatus("error:invalid-json");
    return;
  }

  const char* text = document["text"] | "";
  const uint8_t size = document["size"] | 2;
  const char* alignment = document["alignment"] | "left";
  showText(String(text), size, String(alignment));
}

class DisplayCommandCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    // Do not update e-ink inside the BLE callback: e-ink refresh blocks for a
    // noticeable time and BLE requires write callbacks to return promptly.
    pendingCommand = characteristic->getValue();
    hasPendingCommand = true;
    notifyStatus("received");
  }
};

class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { notifyStatus("connected"); }

  void onDisconnect(BLEServer* server) override {
    notifyStatus("disconnected");
    server->getAdvertising()->start();
  }
};

void startDisplay() {
  pinMode(kEpdPowerPin, OUTPUT);
  digitalWrite(kEpdPowerPin, LOW);  // Waveshare's e-ink power rail is active low.
  delay(50);

  custom_lcd_spi_t config = {};
  config.cs = 11;
  config.dc = 10;
  config.rst = 9;
  config.busy = 8;
  config.mosi = 13;
  config.scl = 12;
  config.spi_host = SPI2_HOST;
  config.buffer_len = 5000;

  displayDriver = new epaper_driver_display(kDisplayWidth, kDisplayHeight, config);
  displayDriver->EPD_Init();
  displayDriver->EPD_Clear();
  displayDriver->EPD_Display();
  displayDriver->EPD_DisplayPartBaseImage();
  displayDriver->EPD_Init_Partial();
  showText("Circuit\nReady for Short-Circuit", 2, "center");
}

void startBle() {
  BLEDevice::init(kDeviceName);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(kServiceUuid);
  BLECharacteristic* displayCommand = service->createCharacteristic(
      kDisplayCommandUuid, BLECharacteristic::PROPERTY_WRITE);
  displayCommand->setCallbacks(new DisplayCommandCallbacks());

  statusCharacteristic = service->createCharacteristic(
      kStatusUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  statusCharacteristic->addDescriptor(new BLE2902());
  statusCharacteristic->setValue("ready");
  service->start();

  BLEAdvertising* advertising = server->getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->start();
  notifyStatus("advertising");
}
}  // namespace

void setup() {
  Serial.begin(115200);
  delay(300);
  startDisplay();
  startBle();
}

void loop() {
  if (hasPendingCommand) {
    const String command = pendingCommand;
    hasPendingCommand = false;
    processCommand(command);
  }
  delay(10);
}
