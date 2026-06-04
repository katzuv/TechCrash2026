// Speed Loopback — ESP32 Parallel 8-bit Interface
// Receives N bytes from FPGA on 8 parallel data wires + 1 clock,
// computes checksum (sum & 0xFF), sends it back on the same data wires.
//
// Wiring (male-male jumper wires, Arduino header → ESP32):
//   ARDUINO_IO[1]  → GPIO2   DATA[0]  ┐
//   ARDUINO_IO[2]  → GPIO4   DATA[1]  │
//   ARDUINO_IO[3]  → GPIO5   DATA[2]  │  all on the GPIO5 side
//   ARDUINO_IO[4]  → GPIO17  DATA[3]  │
//   ARDUINO_IO[5]  → GPIO18  DATA[4]  │
//   ARDUINO_IO[6]  → GPIO19  DATA[5]  │
//   ARDUINO_IO[7]  → GPIO23  DATA[6]  │
//   ARDUINO_IO[8]  → GPIO0   DATA[7]  ┘  (boot pin — OK as input at runtime)
//   ARDUINO_IO[9]  → GPIO15  TX_CLK      (GPIO5 side)
//   ARDUINO_IO[10] → GPIO16  RX_VALID    (GPIO5 side, output to FPGA)
//   GND            → GND

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"
#include "soc/gpio_struct.h"

// ---- Parallel interface pin assignments ----
// DATA[i] → GPIO:  0→2, 1→4, 2→5, 3→17, 4→18, 5→19, 6→23, 7→0
// CLK → GPIO15.  All 10 wires are on the GPIO5 side of the board.
// GPIO0 (DATA[7]) is a boot-strapping pin — always configure as INPUT first.
static const int DATA_PINS[8] = {2, 4, 5, 17, 18, 19, 23, 0};

#define PIN_CLK       15    // TX_CLK from FPGA  (GPIO5 side, bit 15 of GPIO.in)
#define PIN_RX_VALID  16    // RX_VALID to FPGA  (GPIO5 side)

// All signals now live in GPIO.in (GPIO0-31) — single register covers CLK + DATA.

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- Receive one byte: wait for CLK rising edge then sample DATA[7:0] ----
static inline uint8_t IRAM_ATTR recv_byte() {
    while ((GPIO.in >> 15) & 1);      // wait for CLK LOW  (GPIO15)
    while (!((GPIO.in >> 15) & 1));   // wait for CLK HIGH

    uint32_t lo = GPIO.in;   // single read captures CLK + all 8 data bits

    uint8_t b  = ((lo >>  2) & 1) << 0;  // DATA[0] = GPIO2
    b |= ((lo >>  4) & 1) << 1;          // DATA[1] = GPIO4
    b |= ((lo >>  5) & 1) << 2;          // DATA[2] = GPIO5
    b |= ((lo >> 17) & 1) << 3;          // DATA[3] = GPIO17
    b |= ((lo >> 18) & 1) << 4;          // DATA[4] = GPIO18
    b |= ((lo >> 19) & 1) << 5;          // DATA[5] = GPIO19
    b |= ((lo >> 23) & 1) << 6;          // DATA[6] = GPIO23
    b |= ((lo >>  0) & 1) << 7;          // DATA[7] = GPIO0
    return b;
}

// ---- Send checksum back to FPGA ----
static void send_checksum(uint8_t checksum) {
    // Switch data pins to OUTPUT and write the checksum byte
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], OUTPUT);
        digitalWrite(DATA_PINS[i], (checksum >> i) & 1);
    }
    // Pulse RX_VALID; FPGA synchroniser only needs 2 cycles (40 ns) but 2 ms is safe
    digitalWrite(PIN_RX_VALID, HIGH);
    delay(2);
    digitalWrite(PIN_RX_VALID, LOW);
    delay(1);
    // Restore data pins to INPUT for the next run
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], INPUT);
    }
}

static void updateOLED(uint32_t N, uint8_t checksum) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("8-bit Parallel");
    display.printf("N = %u\n", N);
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback Parallel ---");

    // Data pins start as INPUT (FPGA drives them during transfer)
    for (int i = 0; i < 8; i++) {
        pinMode(DATA_PINS[i], INPUT);
    }
    pinMode(PIN_CLK, INPUT);
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
    display.println("Speed Loopback");
    display.println("8-bit Parallel");
    display.println("Waiting for FPGA...");
    display.display();

    setCpuFrequencyMhz(240);  // max clock for tightest polling loop
}

void loop() {
    // ---- Receive 4-byte header (total_count little-endian) ----
    Serial.println("Waiting for FPGA (press KEY[0])...");
    uint32_t N = (uint32_t)recv_byte()
               | ((uint32_t)recv_byte() << 8)
               | ((uint32_t)recv_byte() << 16)
               | ((uint32_t)recv_byte() << 24);

    Serial.printf("Receiving %u bytes...\n", N);

    // Print first 8 bytes to verify data arriving correctly
    uint32_t sum = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint8_t b = recv_byte();
        sum += b;
        if (i < 8) Serial.printf("  byte[%u] = 0x%02X\n", i, b);
        if (i > 0 && i % 1000 == 0) Serial.printf("  ...%u bytes done\n", i);
    }

    uint8_t checksum = (uint8_t)(sum & 0xFF);

    // ---- Respond to FPGA before touching OLED ----
    send_checksum(checksum);

    Serial.printf("Done! N=%u Sum=0x%08X Checksum=0x%02X\n", N, sum, checksum);

    updateOLED(N, checksum);
    delay(3000);
}
