// Speed Loopback — ESP32 Parallel 8-bit Interface
// Receives N bytes from FPGA on 8 parallel data wires + 1 clock,
// computes checksum (sum & 0xFF), sends it back on the same data wires.
//
// Wiring (connect with male-male jumper wires):
//   ARDUINO_IO[1]  <-> GPIO5   DATA[0]
//   ARDUINO_IO[2]  <-> GPIO13  DATA[1]
//   ARDUINO_IO[3]  <-> GPIO14  DATA[2]
//   ARDUINO_IO[4]  <-> GPIO27  DATA[3]
//   ARDUINO_IO[5]  <-> GPIO26  DATA[4]
//   ARDUINO_IO[6]  <-> GPIO25  DATA[5]
//   ARDUINO_IO[7]  <-> GPIO33  DATA[6]
//   ARDUINO_IO[8]  <-> GPIO32  DATA[7]
//   ARDUINO_IO[9]  <-> GPIO35  TX_CLK (input-only on ESP32)
//   ARDUINO_IO[10] <-> GPIO16  RX_VALID (output from ESP32 to FPGA)
//   GND            <-> GND

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"
#include "soc/gpio_struct.h"

// ---- Parallel interface pins ----
// DATA bits → GPIO numbers (maps DATA[i] to ARDUINO_IO[i+1])
static const int DATA_PINS[8] = {5, 13, 14, 27, 26, 25, 33, 32};

// CLK: GPIO35 (input-only) — in GPIO.in1.val bit 3
// RX_VALID: GPIO16 (output to FPGA)
#define PIN_CLK        35
#define PIN_RX_VALID   16

// GPIO register bit positions for each DATA pin:
//   DATA[0..5] in GPIO.in  (GPIO0-31)
//   DATA[6..7] in GPIO.in1 (GPIO32-39, bit offset = gpio - 32)
//   CLK        in GPIO.in1 bit 3 (GPIO35)
static const uint8_t DATA_BIT_LOW[6]  = {5, 13, 14, 27, 26, 25};  // DATA[0..5]
static const uint8_t DATA_BIT_HIGH[2] = {1, 0};                     // DATA[6]=GPIO33 bit1, DATA[7]=GPIO32 bit0

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- Read one parallel byte (blocking — waits for CLK rising edge) ----
// Call with interrupts enabled; uses tight polling of GPIO registers.
static inline uint8_t IRAM_ATTR recv_byte() {
    // Wait for CLK to be LOW first (prevents re-triggering on same edge)
    while ((GPIO.in1.val >> 3) & 1);   // GPIO35 = CLK
    // Wait for CLK rising edge
    while (!((GPIO.in1.val >> 3) & 1));

    // Sample both GPIO banks immediately
    uint32_t lo = GPIO.in;
    uint32_t hi = GPIO.in1.val;

    uint8_t b = 0;
    b  = ((lo >> DATA_BIT_LOW[0]) & 1) << 0;
    b |= ((lo >> DATA_BIT_LOW[1]) & 1) << 1;
    b |= ((lo >> DATA_BIT_LOW[2]) & 1) << 2;
    b |= ((lo >> DATA_BIT_LOW[3]) & 1) << 3;
    b |= ((lo >> DATA_BIT_LOW[4]) & 1) << 4;
    b |= ((lo >> DATA_BIT_LOW[5]) & 1) << 5;
    b |= ((hi >> DATA_BIT_HIGH[0]) & 1) << 6;
    b |= ((hi >> DATA_BIT_HIGH[1]) & 1) << 7;
    return b;
}

// ---- Send one byte back to FPGA (checksum response) ----
static void send_checksum(uint8_t checksum) {
    // Switch data pins to OUTPUT and write byte
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], OUTPUT);
        digitalWrite(DATA_PINS[i], (checksum >> i) & 1);
    }

    // Pulse RX_VALID high so FPGA captures the data
    digitalWrite(PIN_RX_VALID, HIGH);
    delay(2);   // FPGA synchroniser needs 2+ cycles at 50 MHz = 40 ns; 2 ms is safe
    digitalWrite(PIN_RX_VALID, LOW);
    delay(1);

    // Return data pins to INPUT for next round
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], INPUT);
    }
}

static void updateOLED(const char* status, uint32_t N, uint8_t checksum) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback FAST");
    display.printf("N = %u\n", N);
    display.println(status);
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback Parallel ---");

    // Configure data pins as INPUT (high-impedance, FPGA drives them)
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], INPUT);
    }
    // CLK is input-only pin, nothing to configure
    // RX_VALID is our output to FPGA
    pinMode(PIN_RX_VALID, OUTPUT);
    digitalWrite(PIN_RX_VALID, LOW);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback FAST");
    display.println("Waiting for FPGA...");
    display.display();

    // Run ESP32 at full 240 MHz for minimum polling latency
    setCpuFrequencyMhz(240);
}

void loop() {
    // ---- Receive 4-byte header (total_count, little-endian) ----
    uint8_t h0 = recv_byte();
    uint8_t h1 = recv_byte();
    uint8_t h2 = recv_byte();
    uint8_t h3 = recv_byte();
    uint32_t N = (uint32_t)h0 | ((uint32_t)h1 << 8) | ((uint32_t)h2 << 16) | ((uint32_t)h3 << 24);

    Serial.printf("Receiving %u bytes (parallel)...\n", N);

    // ---- Tight receive loop — no OLED update inside to avoid I2C stalls ----
    uint32_t sum = 0;
    for (uint32_t i = 0; i < N; i++) {
        sum += recv_byte();
    }

    uint8_t checksum = (uint8_t)(sum & 0xFF);

    // ---- Send checksum back to FPGA ----
    send_checksum(checksum);

    Serial.printf("Done! N=%u Sum=0x%08X Checksum=0x%02X\n", N, sum, checksum);

    // ---- Update OLED (after responding so we don't add latency) ----
    updateOLED("COMPLETE!", N, checksum);

    // Brief pause before next run
    delay(3000);
}
