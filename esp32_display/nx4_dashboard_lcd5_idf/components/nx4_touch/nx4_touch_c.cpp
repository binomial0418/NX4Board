// gt911_touch（C++ 類別）的 C 介面包裝，說明見 nx4_touch_c.h。

#include "nx4_touch_c.h"
#include "gt911_touch.h"
#include "pins_config.h"

static gt911_touch s_touch(TP_I2C_SDA, TP_I2C_SCL, TP_RST, TP_INT);

void nx4_touch_begin(void) { s_touch.begin(); }
bool nx4_touch_read(uint16_t *x, uint16_t *y) { return s_touch.getTouch(x, y); }
