/*
 * SCCS — ESP32-2 (ESP32-S3-WROOM-1U)
 *
 * Pi link: Pi UART4 GPIO 8 (TX) / 9 (RX) ↔ this ESP UART1 GPIO 17 (RX) / 18 (TX).
 *
 * PWM (module GPIO): 4–11  (silk 2-4 … 2-11)
 *   2-4 accent, 2-5 rooftop tent
 *   2-6 / 2-7 / 2-8 awning white / red / green
 *   2-9 ensuite
 *   2-10 / 2-11 spare
 * Analog: GPIO 1 (silk 2-1) future A1, GPIO 2 (silk 2-2) future A2
 *         (each 150 Ω pull-up to 3V3)
 *
 * Module: ESP32-S3-WROOM-1U. Upload: see esp32/README.md
 */

#define SCCS_ESP_ID 2
#define SCCS_PWM_PINS {4, 5, 6, 7, 8, 9, 10, 11}
#define SCCS_ANALOG_PINS {1, 2}

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
