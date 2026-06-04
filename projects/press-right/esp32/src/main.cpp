// Press Right — ESP32 Firmware
// Receives 2-byte (little-endian) stopped counter value from FPGA.
// If within 1000 +/- 10, plays victory buzzer.
// OLED shows the value and WIN/MISS result.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

// ---- Buzzer helpers ----
void playVictory() {
    // Three rising tones
    int freqs[] = {784, 988, 1319};
    for (int i = 0; i < 3; i++) {
        ledcWriteTone(0, freqs[i]);
        delay(150);
    }
    ledcWriteTone(0, 0);
}

void playMiss() {
    ledcWriteTone(0, 300);
    delay(400);
    ledcWriteTone(0, 0);
}

void updateOLED(uint16_t value, bool won, int32_t diff) {
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);

    display.setTextSize(2);
    display.setCursor(0, 0);
    display.println("PressRight");

    display.setTextSize(3);
    display.setCursor(20, 20);
    display.printf("%4u", value);

    display.setTextSize(2);
    display.setCursor(0, 48);
    if (won) {
        display.println("  WIN!");
    } else {
        display.printf("MISS %+d", (int)diff);
    }

    display.display();
}

void showWaiting() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Press Right");
    display.println("Target: 1000");
    display.println("");
    display.println("Waiting for FPGA...");
    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Press Right ---");

    // Buzzer
    ledcSetup(0, 2000, 8);
    ledcAttachPin(PIN_BUZZER, 0);
    ledcWriteTone(0, 0);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    showWaiting();
}

void loop() {
    // Wait for 2 bytes (little-endian 16-bit value)
    if (FpgaSerial.available() < 2) {
        return;
    }

    uint8_t lo = FpgaSerial.read();
    uint8_t hi = FpgaSerial.read();
    uint16_t value = (uint16_t)lo | ((uint16_t)hi << 8);

    int32_t diff = (int32_t)value - 1000;
    bool won = (diff >= -10 && diff <= 10);

    Serial.printf("Received: %u  diff: %d  %s\n", value, diff, won ? "WIN" : "MISS");

    updateOLED(value, won, diff);

    if (won) {
        playVictory();
    } else {
        playMiss();
    }

    // Drain any stale bytes
    while (FpgaSerial.available()) FpgaSerial.read();

    showWaiting();
}
