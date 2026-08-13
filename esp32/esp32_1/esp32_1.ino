/*
 * SCCS — ESP32-1 (ESP32-S3-WROOM-1U)
 *
 * Pi link: Pi UART3 GPIO 4 (TX) / 5 (RX) ↔ this ESP UART1 GPIO 17 (RX) / 18 (TX).
 *
 * PWM (module GPIO): 4–11  (silk 1-4 … 1-11)
 *   1-4 kitchen panel white, 1-5 red, 1-6 green
 *   1-7 kitchen bench, 1-8 storage, 1-9 rear drawer
 *   1-10 / 1-11 spare
 * Analog: GPIO 1 (silk 1-1) water tank sender (150 Ω to 3V3)
 *
 * Module: ESP32-S3-WROOM-1U. Upload: see esp32/README.md
 */

#define SCCS_ESP_ID 1
#define SCCS_PWM_PINS {4, 5, 6, 7, 8, 9, 10, 11}
#define SCCS_ANALOG_PINS {1}

// Host UART1 to the Pi (both ESPs use the same pins).
#define SCCS_HOST_RX 17
#define SCCS_HOST_TX 18

#include "SccsEspFirmware.h"

void setup() {
  sccsSetup();
}

void loop() {
  sccsLoop();
}
