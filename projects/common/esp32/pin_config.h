// ============================================================
// CrashTech VLSI-2026 — ESP32 Kit GPIO Pin Configuration
// ============================================================
// Central pin definition for ALL projects.
// Board: ESP32-DevKit (30/38-pin)
//
// Bottom row only + 3.3V and GPIO34 from upper row.
// RXD/TXD (GPIO1/3) reserved for USB serial debug.
// CLK/SDO/SDI (GPIO6/7/8) are flash pins — do NOT use.
//
// FPGA side: Arduino header on DE10-Lite
//            ARDUINO_IO[0] = UART RX from ESP32
//            ARDUINO_IO[1] = UART TX to ESP32
//            GND pin on Arduino header = connect ESP32 GND here
// ============================================================

#pragma once

// ---- UART to FPGA (bidirectional) ----
#define PIN_FPGA_TX         16      // ESP32 UART2 TX  -> FPGA ARDUINO_IO[0]
#define PIN_FPGA_RX         17      // ESP32 UART2 RX  <- FPGA ARDUINO_IO[1]
#define FPGA_BAUD           9600    // 9600 8N1

// ---- OLED Display (I2C, SSD1306 128x64) ----
#define PIN_OLED_SDA        21      // I2C SDA (default Wire)
#define PIN_OLED_SCL        22      // I2C SCL (default Wire)
#define OLED_WIDTH          128
#define OLED_HEIGHT         64
#define OLED_I2C_ADDR       0x3C    // Typical SSD1306 address

// ---- Servo Motor ----
#define PIN_SERVO           18      // PWM output (LEDC)

// ---- Buzzer ----
#define PIN_BUZZER          23      // PWM output (LEDC)

// ---- LEDs ----
#define PIN_LED_1           19      // LED 1
#define PIN_LED_2            2      // LED 2 (also onboard LED on most DevKits)
#define PIN_LED_3           15      // LED 3

// ---- Switches (active LOW — wire between pin and GND, use INPUT_PULLUP) ----
#define PIN_SW_1             4      // Switch 1
#define PIN_SW_2             0      // Switch 2 (boot pin: do NOT hold LOW during power-on)

// ---- Analog Input (upper row) ----
#define PIN_ANALOG_IN       34      // ADC1_CH6, input-only, works with WiFi active
