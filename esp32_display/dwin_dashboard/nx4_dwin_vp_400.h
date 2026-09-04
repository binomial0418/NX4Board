// 由 tools/gen_dgus_config.py 產生，請勿手改。
// DWIN DGUS 的 VP 位址表；與 14.BIN 出自同一份定義。
#pragma once

// ── 資料 VP ──
#define VP_SPEED      0x2000
#define VP_RPM        0x2001
#define VP_TURBO      0x2002
#define VP_COOLANT    0x2003
#define VP_SOC        0x2004
#define VP_FUEL       0x2005
#define VP_LIMIT      0x2006
#define VP_ODO        0x2008
#define VP_TPMS_FL    0x200A
#define VP_TPMS_FR    0x200B
#define VP_TPMS_RL    0x200C
#define VP_TPMS_RR    0x200D
#define VP_CLOCK_HH   0x2010
#define VP_CLOCK_MM   0x2011
#define VP_CLOCK_SS   0x2012
#define VP_DATE_MM    0x2013
#define VP_DATE_DD    0x2014
#define VP_WEEKDAY    0x2015

// ── 變數描述指標（改顏色用；顏色在 SP+3）──
#define SP_SPEED    0x5000
#define SP_SPEED_COLOR 0x5003
#define SP_RPM      0x5010
#define SP_RPM_COLOR 0x5013
#define SP_COOLANT  0x5020
#define SP_COOLANT_COLOR 0x5023
#define SP_LIMIT    0x5030
#define SP_LIMIT_COLOR 0x5033

// ── 顏色（RGB565）──
#define CLR_WHITE 0xFFFF
#define CLR_BLUE  0x2BFE
#define CLR_RED   0xEA28
#define CLR_LABEL 0xE75E

// 開機時把各控制項的描述重寫一次（22_Config.bin 沒載入也能正常顯示）
// 內容 = 描述 0x06 之後的那幾個字。
static const uint16_t SP_INIT_SPEED[13] = {0x2000, 0x01D2, 0x0013, 0xFFFF, 0x00C0, 0x0103, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
static const uint16_t SP_INIT_RPM[13] = {0x2001, 0x0242, 0x00D0, 0x2BFE, 0x0048, 0x0104, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
static const uint16_t SP_INIT_COOLANT[13] = {0x2003, 0x0026, 0x00B2, 0xFFFF, 0x003C, 0x0003, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
static const uint16_t SP_INIT_LIMIT[13] = {0x2006, 0x03CE, 0x0132, 0xFFFF, 0x003C, 0x0003, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
