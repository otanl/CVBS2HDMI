// SMPTE-style colour bars out of an M5Stack ATOM (ESP32-PICO-D4) as NTSC
// composite, for calibrating the TangADC decoder.
//
// Why this exists: a decoder cannot be validated against a picture whose
// correct answer is unknown.  These bars have exact, published YUV values, so
// the FPGA's demodulated output can be checked numerically instead of by eye.
//
// Panel_CVBS drives the signal from the ESP32 DAC; the M5Stack RCA unit is on
// G26 (DAC channel 2).  It comes from M5GFX rather than LovyanGFX directly --
// same code, but LovyanGFX is not published to the ESP component registry
// while M5GFX is, so this builds with plain `idf.py` and no vendored source.

#include <M5GFX.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_log.h"

// NTSC has a 7.5 IRE setup pedestal, NTSC-J has none (black == blanking).
// NTSC-J keeps the arithmetic honest when checking levels, and is what
// Japanese equipment expects.  Set to 0 for plain NTSC.
#define USE_NTSC_J 1

// Overridable from the build so the level can be swept against a real
// measurement of the sync fraction rather than guessed:
//   idf.py build -DM5_OUTPUT_LEVEL=192
// Render a mostly-black frame instead of the bars.  Not a picture anyone
// wants -- it is a test for whether the capture side's black level depends on
// how bright the picture is, which it will if the input is AC coupled with no
// DC restoration.  A bright picture then pushes sync and blanking towards the
// bottom of the ADC range and clips them, and that is a property of the
// coupling, not of the generator.
//   idf.py build -DM5_DARK=1
#ifndef M5_DARK
#define M5_DARK 0
#endif

#ifndef M5_OUTPUT_LEVEL
#define M5_OUTPUT_LEVEL 128
#endif

// 720x480 is the panel maximum but needs 345 kB; an ATOM has no PSRAM.
// 360x240 is an exact half in both axes, so pixels stay square.
static constexpr int MEM_W = 360;
static constexpr int MEM_H = 240;

class LGFX : public m5gfx::LGFX_Device {
public:
    m5gfx::Panel_CVBS _panel;

    LGFX(void) {
        {
            auto cfg = _panel.config();
            cfg.memory_width  = MEM_W;
            cfg.memory_height = MEM_H;
            cfg.panel_width   = MEM_W;
            cfg.panel_height  = MEM_H;
            cfg.offset_x      = 0;
            cfg.offset_y      = 0;
            _panel.config(cfg);
        }
        {
            auto cfg = _panel.config_detail();
#if USE_NTSC_J
            cfg.signal_type = cfg.signal_type_t::NTSC_J;
#else
            cfg.signal_type = cfg.signal_type_t::NTSC;
#endif
            cfg.pin_dac      = 26;     // M5Stack RCA unit
            cfg.use_psram    = 0;      // ATOM has none
            // Raised above the library default of 128, deliberately.
            //
            // Panel_CVBS emits sync at DAC code 0 and everything else relative
            // to it: blanking at 286 mV, white at 960 mV, so 29.8% of the
            // signal is sync, exactly as NTSC asks.  The ESP32's DAC does not
            // deliver that.  Measured through the TangADC front end, a DAC
            // code near the bottom is worth 0.65 ADC codes while one in the
            // middle is worth 1.75 -- the bottom of the DAC's range is
            // compressed about 2.7:1 -- so the sync pulse arrives at 17 ADC
            // codes where it should be 38, and the sync fraction is 13%
            // instead of 29%.  The pulse is flat, so this is the DAC's
            // transfer curve and not a coupling capacitor drooping.
            //
            // output_level scales blanking, black and white away from a sync
            // that stays pinned at code 0, which lifts them clear of the
            // compressed region and restores some of the ratio.  It costs
            // total amplitude: the signal is no longer 1 Vpp, which matters if
            // this generator is ever fed to something expecting a standard
            // level.  See M5_OUTPUT_LEVEL below for the measured sweep.
            cfg.output_level = M5_OUTPUT_LEVEL;
            // Left at the library default.  Three separate attempts to
            // "correct" the M5 side from capture-side numbers were all wrong,
            // every one of them founded on min/max over a whole second -- an
            // extreme-value statistic that a single clamp transient pins to
            // the rails.  Judge amplitude from the waveform, never from those.
            cfg.chroma_level = 128;
            _panel.config_detail(cfg);
        }
        setPanel(&_panel);
    }
};

static LGFX gfx;

// 75% colour bars: every primary is either 0 or 191.  Order is the standard
// descending-luminance one, so a correctly decoded picture has a monotonic
// luma staircase left to right.
struct Bar { uint8_t r, g, b; const char *name; };
static const Bar BARS[8] = {
    {191, 191, 191, "white75"},
    {191, 191,   0, "yellow" },
    {  0, 191, 191, "cyan"   },
    {  0, 191,   0, "green"  },
    {191,   0, 191, "magenta"},
    {191,   0,   0, "red"    },
    {  0,   0, 191, "blue"   },
    {  0,   0,   0, "black"  },
};

static const char *TAG = "colorbars";

extern "C" void app_main(void)
{
    // rgb332 rather than rgb565: the frame buffer lives in SRAM (an ATOM has
    // no PSRAM) and 360x240 costs 86 kB at one byte per pixel against 173 kB
    // at two.  The larger one does not reliably fit alongside the rest of the
    // system, and a failed init produces a dead or garbage signal rather than
    // an obvious error.  256 colours is ample for colour bars.
    ESP_LOGI(TAG, "free heap before init: %u", (unsigned)esp_get_free_heap_size());
    ESP_LOGI(TAG, "largest free block   : %u",
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));

    gfx.setColorDepth(m5gfx::color_depth_t::rgb332_1Byte);
    bool ok = gfx.init();

    ESP_LOGI(TAG, "init %s, panel %dx%d, free heap now %u",
             ok ? "OK" : "FAILED", gfx.width(), gfx.height(),
             (unsigned)esp_get_free_heap_size());
    if (!ok) {
        ESP_LOGE(TAG, "Panel_CVBS init failed - no signal will be generated");
    }

    const int w = gfx.width();
    const int h = gfx.height();

#if M5_DARK
    gfx.fillScreen(gfx.color888(0, 0, 0));
    gfx.fillRect(0, 0, w / 16, h / 8, gfx.color888(191, 191, 191));
    ESP_LOGI(TAG, "dark test pattern");
#else
    // Top three quarters: the colour bars themselves.
    const int bars_h = (h * 3) / 4;
    for (int i = 0; i < 8; ++i) {
        int x0 = (w * i) / 8;
        int x1 = (w * (i + 1)) / 8;
        gfx.fillRect(x0, 0, x1 - x0, bars_h,
                     gfx.color888(BARS[i].r, BARS[i].g, BARS[i].b));
    }

    // Bottom quarter: a grey staircase, for checking luma gain and linearity
    // independently of any chroma decoding.
    const int ramp_y = bars_h;
    const int ramp_h = h - bars_h;
    for (int i = 0; i < 16; ++i) {
        int x0 = (w * i) / 16;
        int x1 = (w * (i + 1)) / 16;
        int v  = i * 255 / 15;
        gfx.fillRect(x0, ramp_y, x1 - x0, ramp_h, gfx.color888(v, v, v));
    }

    ESP_LOGI(TAG, "colour bars drawn: 8 bars over %d rows, ramp over %d rows",
             bars_h, ramp_h);
#endif  // M5_DARK

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        ESP_LOGI(TAG, "alive, free heap %u", (unsigned)esp_get_free_heap_size());
    }
}
