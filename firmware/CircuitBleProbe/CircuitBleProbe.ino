#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

namespace {
constexpr char kDeviceName[] = "Circuit";
constexpr char kServiceUuid[] = "9f4b3a00-7e46-4df9-9b85-7c4e3e5b1000";

class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { Serial.println("[PROBE] connected"); }
  void onDisconnect(BLEServer* server) override {
    Serial.println("[PROBE] disconnected; advertising again");
    server->getAdvertising()->start();
  }
};
}  // namespace

void setup() {
  Serial.begin(115200);
  delay(3000);  // give the host time to open the USB serial port
  Serial.printf("[PROBE] boot, reset reason %d, free heap %u, psram %u\n",
                static_cast<int>(esp_reset_reason()), ESP.getFreeHeap(), ESP.getPsramSize());
  Serial.println("[PROBE] starting BLE");

  BLEDevice::init(kDeviceName);
  Serial.printf("[PROBE] BLE address %s\n", BLEDevice::getAddress().toString().c_str());
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService* service = server->createService(kServiceUuid);
  service->start();
  server->getAdvertising()->addServiceUUID(kServiceUuid);
  server->getAdvertising()->start();

  Serial.println("[PROBE] advertising as Circuit");
}

void loop() {
  Serial.println("[PROBE] alive");
  delay(1000);
}
