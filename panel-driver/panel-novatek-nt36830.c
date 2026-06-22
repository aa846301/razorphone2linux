// SPDX-License-Identifier: GPL-2.0-only
/*
 * NovaTeK NT36830 AMOLED Dual-DSI Panel Driver with DSC
 *
 * Copyright (c) 2024 Linux Community
 *
 * Panel driver for the NovaTeK NT36830 in the Razer Phone 2.
 * 5.72" 1440x2560 120Hz AMOLED, Dual DSI, VESA DSC 1.1.
 *
 * Init sequence translated byte-for-byte from the official Razer/FIH
 * downstream DTS (dsi-panel-nt36830-wqhd-dualmipi-cmd.dtsi) found in
 * PixelExperience-Devices/kernel_razer_sdm845 (fih/rc2/).
 *
 * Conversion methodology follows the OnePlus 6 (panel-samsung-sofef00.c)
 * pattern: each downstream qcom,mdss-dsi-on-command byte sequence is
 * translated to mipi_dsi_dcs_write_seq_multi() calls.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_probe_helper.h>

#include <video/mipi_display.h>

/* Number of regulators needed by this panel */
#define NT36830_NUM_SUPPLIES 3

/*
 * Macro to send a DCS command to both DSI interfaces for dual-DSI panels.
 * Based on panel-novatek-nt36523.c mipi_dsi_dual_dcs_write_seq_multi.
 */
#define nt36830_dual_dcs_write_seq(dsi_ctx, dsi0, dsi1, cmd, seq...)           \
	mipi_dsi_dual_dcs_write_seq_multi(&(dsi_ctx), dsi0, dsi1, cmd, seq)

struct nt36830_panel {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi0;
	struct mipi_dsi_device *dsi1;
	struct regulator_bulk_data supplies[NT36830_NUM_SUPPLIES];
	struct gpio_desc *reset_gpio;
	struct drm_dsc_config dsc;
	enum drm_panel_orientation orientation;
};

static const struct regulator_bulk_data nt36830_supplies[NT36830_NUM_SUPPLIES] = {
	{.supply = "vddio"},
	{.supply = "vci"},
	{.supply = "poc"},
};

static inline struct nt36830_panel *to_nt36830(struct drm_panel *panel)
{
	return container_of(panel, struct nt36830_panel, panel);
}

/*
 * Reset sequence from official DTS: <1 10>, <0 10>, <1 10>
 * Physical: HIGH 10ms -> LOW 10ms (reset pulse) -> HIGH 10ms
 * With GPIO_ACTIVE_LOW: gpiod value 0=physical HIGH, 1=physical LOW
 */
static void nt36830_reset(struct nt36830_panel *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
}

/*
 * Panel initialization sequence.
 *
 * Translated byte-for-byte from the official Razer/FIH downstream DTS
 * qcom,mdss-dsi-on-command in dsi-panel-nt36830-wqhd-dualmipi-cmd.dtsi.
 * Source: PixelExperience-Devices/kernel_razer_sdm845 (fih/rc2/)
 *
 * DTS wire format:
 *   15 = DCS short write 1 param
 *   39 = DCS long write
 *   05 = DCS short write 0 param (sleep_out, display_on)
 *   wait byte: delay in ms (hex)
 *
 * Note: razer,mdss-dsi-disable-sending-pps is set in the official DTS.
 * The NT36830 DDIC configures its internal DSC decoder via registers
 * C0/C1/C2 on page 10. We do NOT send standard MIPI PPS (0x0A) or
 * compression_mode (0x07) commands. The dsi->dsc config is used by
 * the MSM DSI host to program its DSC encoder.
 */
static int nt36830_on(struct nt36830_panel *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi0 };

	/* --- Pre-init: DDIC diagnostic/calibration reset --- */

	/* Page D0 */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0xd0);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x75, 0x40);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xf1, 0x40);
	mipi_dsi_msleep(&dsi_ctx, 10);

	/* Page 10 - calibration params */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x2c,
				   0x01, 0x02, 0x04, 0x08, 0x10);
	mipi_dsi_msleep(&dsi_ctx, 10);

	/* Page D0 - cleanup */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0xd0);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x75, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xf1, 0x00);
	mipi_dsi_msleep(&dsi_ctx, 10);

	/* --- Page 10: DSC and base configuration --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xba, 0x03);  /* DSC enable */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbc, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xc0, 0x83);  /* DSC control */

	/* DSC PPS parameters (DDIC internal decoder config via C1) */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xc1,
				   0xab, 0x28, 0x00, 0x08, 0x02, 0x00,
				   0x02, 0x68, 0x00, 0xd5, 0x00, 0x0a,
				   0x0d, 0xb7, 0x09, 0x89);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xc2, 0x10, 0xf0);

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xd5, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xd6, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xde, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xe1, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xe5, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbb, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xf6, 0x70);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xf7, 0x80);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbe,
				   0x00, 0x10, 0x00, 0x10);

	/* TE (Tearing Effect) on VBLANK */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x35, 0x00);

	/* --- Page 20: Panel configuration --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x20);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x5d, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x5e, 0x14);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x5f, 0xeb);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x87, 0x02);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x96, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x97, 0x6d);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x98, 0x6d);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xae, 0x00);

	/* --- Page 21: Color calibration --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x21);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xe0, 0x24);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xe1,
				   0x42, 0x0a, 0x86, 0x53, 0x1b, 0x97,
				   0x0a, 0x86, 0x42, 0x1b, 0x97, 0x53);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xe2,
				   0x86, 0x42, 0x0a, 0x97, 0x53, 0x1b,
				   0x0a, 0x86, 0x42, 0x1b, 0x97, 0x53);

	/* --- Page 20: Gamma LUT (Red channel) --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x20);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb0,
				   0x00, 0x01, 0x00, 0x21, 0x00, 0x43,
				   0x00, 0x5b, 0x00, 0x72, 0x00, 0x83,
				   0x00, 0x96, 0x00, 0xa5);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb1,
				   0x00, 0xb2, 0x00, 0xe1, 0x01, 0x09,
				   0x01, 0x4b, 0x01, 0x80, 0x01, 0xd3,
				   0x02, 0x16, 0x02, 0x19);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb2,
				   0x02, 0x58, 0x02, 0x9b, 0x02, 0xc4,
				   0x02, 0xfb, 0x03, 0x1f, 0x03, 0x4b,
				   0x03, 0x5b, 0x03, 0x69);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb3,
				   0x03, 0x7c, 0x03, 0x93, 0x03, 0xb7,
				   0x03, 0xcf, 0x03, 0xe1, 0x03, 0xe6,
				   0x00, 0x00);

	/* Gamma LUT (Green channel) */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb4,
				   0x00, 0xc0, 0x00, 0xca, 0x00, 0xd5,
				   0x00, 0xe0, 0x00, 0xea, 0x00, 0xf4,
				   0x00, 0xfd, 0x01, 0x06);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb5,
				   0x01, 0x0f, 0x01, 0x2f, 0x01, 0x4b,
				   0x01, 0x7b, 0x01, 0xa6, 0x01, 0xec,
				   0x02, 0x28, 0x02, 0x2a);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb6,
				   0x02, 0x65, 0x02, 0xa6, 0x02, 0xce,
				   0x03, 0x04, 0x03, 0x27, 0x03, 0x51,
				   0x03, 0x62, 0x03, 0x71);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb7,
				   0x03, 0x86, 0x03, 0x9e, 0x03, 0xb6,
				   0x03, 0xcd, 0x03, 0xdf, 0x03, 0xe6,
				   0x00, 0xbf);

	/* Gamma LUT (Blue channel) */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb8,
				   0x01, 0x12, 0x01, 0x18, 0x01, 0x20,
				   0x01, 0x27, 0x01, 0x2e, 0x01, 0x35,
				   0x01, 0x3b, 0x01, 0x42);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb9,
				   0x01, 0x48, 0x01, 0x61, 0x01, 0x77,
				   0x01, 0x9e, 0x01, 0xc2, 0x02, 0x00,
				   0x02, 0x37, 0x02, 0x39);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xba,
				   0x02, 0x71, 0x02, 0xb0, 0x02, 0xd9,
				   0x03, 0x11, 0x03, 0x37, 0x03, 0x5c,
				   0x03, 0x6e, 0x03, 0x81);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbb,
				   0x03, 0x9d, 0x03, 0xb6, 0x03, 0xca,
				   0x03, 0xda, 0x03, 0xe4, 0x03, 0xe6,
				   0x01, 0x11);

	/* --- Page 21: Gamma LUT (mirror for page 21) --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x21);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);

	/* Red */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb0,
				   0x00, 0x01, 0x00, 0x21, 0x00, 0x43,
				   0x00, 0x5b, 0x00, 0x72, 0x00, 0x83,
				   0x00, 0x96, 0x00, 0xa5);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb1,
				   0x00, 0xb2, 0x00, 0xe1, 0x01, 0x09,
				   0x01, 0x4b, 0x01, 0x80, 0x01, 0xd3,
				   0x02, 0x16, 0x02, 0x19);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb2,
				   0x02, 0x58, 0x02, 0x9b, 0x02, 0xc4,
				   0x02, 0xfb, 0x03, 0x1f, 0x03, 0x4b,
				   0x03, 0x5b, 0x03, 0x69);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb3,
				   0x03, 0x7c, 0x03, 0x93, 0x03, 0xb7,
				   0x03, 0xcf, 0x03, 0xe1, 0x03, 0xe6,
				   0x00, 0x00);
	/* Green */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb4,
				   0x00, 0xc0, 0x00, 0xca, 0x00, 0xd5,
				   0x00, 0xe0, 0x00, 0xea, 0x00, 0xf4,
				   0x00, 0xfd, 0x01, 0x06);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb5,
				   0x01, 0x0f, 0x01, 0x2f, 0x01, 0x4b,
				   0x01, 0x7b, 0x01, 0xa6, 0x01, 0xec,
				   0x02, 0x28, 0x02, 0x2a);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb6,
				   0x02, 0x65, 0x02, 0xa6, 0x02, 0xce,
				   0x03, 0x04, 0x03, 0x27, 0x03, 0x51,
				   0x03, 0x62, 0x03, 0x71);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb7,
				   0x03, 0x86, 0x03, 0x9e, 0x03, 0xb6,
				   0x03, 0xcd, 0x03, 0xdf, 0x03, 0xe6,
				   0x00, 0xbf);
	/* Blue */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb8,
				   0x01, 0x12, 0x01, 0x18, 0x01, 0x20,
				   0x01, 0x27, 0x01, 0x2e, 0x01, 0x35,
				   0x01, 0x3b, 0x01, 0x42);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb9,
				   0x01, 0x48, 0x01, 0x61, 0x01, 0x77,
				   0x01, 0x9e, 0x01, 0xc2, 0x02, 0x00,
				   0x02, 0x37, 0x02, 0x39);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xba,
				   0x02, 0x71, 0x02, 0xb0, 0x02, 0xd9,
				   0x03, 0x11, 0x03, 0x37, 0x03, 0x5c,
				   0x03, 0x6e, 0x03, 0x81);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbb,
				   0x03, 0x9d, 0x03, 0xb6, 0x03, 0xca,
				   0x03, 0xda, 0x03, 0xe4, 0x03, 0xe6,
				   0x01, 0x11);

	/* --- Page 24: GIP (Gate IC in Panel) timing --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x24);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x14, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x15, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x16, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x17, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb4, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb6, 0x30);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x18, 0x02);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x1b, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x1c, 0x0e);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x1d, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x1e, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x1f, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x22, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x23, 0x0e);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x24, 0x0f);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x25, 0xa8);

	/* --- Page 26 --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x26);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x60, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x62, 0x00);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x40, 0x00);

	/* --- Page 28 --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x28);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x91, 0x02);

	/* --- Page E0: DSC setting --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0xe0);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x48, 0x81);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x8e, 0x09);

	/* --- Page F0: VESA DSC setting --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0xf0);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x33, 0x20);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x34, 0x35);

	/* --- Page 23 --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x23);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x06, 0x22);

	/* --- Page 10: Final configuration --- */

	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);

	/* Brightness: 0x0FFF = 4095 (max) */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x51, 0x0f, 0xff);
	/* CABC mode 3 */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x55, 0x03);
	/* Backlight control */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0x53, 0x2c);
	/* VFP control */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xb1, 0x04);

	/* Sleep Out (0x11), wait 120ms */
	dsi_ctx.dsi = ctx->dsi0;
	mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	if (ctx->dsi1) {
		dsi_ctx.dsi = ctx->dsi1;
		mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	}
	mipi_dsi_msleep(&dsi_ctx, 120);

	/* Display On (0x29) */
	dsi_ctx.dsi = ctx->dsi0;
	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	if (ctx->dsi1) {
		dsi_ctx.dsi = ctx->dsi1;
		mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	}

	return dsi_ctx.accum_err;
}

/*
 * Panel off sequence from official DTS qcom,mdss-dsi-off-command.
 * Delays: display_off wait 34ms (0x22), sleep_in wait 180ms (0xB4).
 */
static int nt36830_off(struct nt36830_panel *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi0 };

	/* Page 10 */
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xff, 0x10);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xfb, 0x01);
	nt36830_dual_dcs_write_seq(dsi_ctx, ctx->dsi0, ctx->dsi1, 0xbc, 0x00);

	/* Display Off (0x28), wait 34ms */
	dsi_ctx.dsi = ctx->dsi0;
	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	if (ctx->dsi1) {
		dsi_ctx.dsi = ctx->dsi1;
		mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	}
	mipi_dsi_msleep(&dsi_ctx, 34);

	/* Sleep In (0x10), wait 180ms */
	dsi_ctx.dsi = ctx->dsi0;
	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	if (ctx->dsi1) {
		dsi_ctx.dsi = ctx->dsi1;
		mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	}
	mipi_dsi_msleep(&dsi_ctx, 180);

	return dsi_ctx.accum_err;
}

static int nt36830_prepare(struct drm_panel *panel)
{
	struct nt36830_panel *ctx = to_nt36830(panel);
	int ret;

	ret = regulator_bulk_enable(NT36830_NUM_SUPPLIES, ctx->supplies);
	if (ret < 0) {
		dev_err(&ctx->dsi0->dev, "Failed to enable regulators: %d\n", ret);
		return ret;
	}

	nt36830_reset(ctx);

	ret = nt36830_on(ctx);
	if (ret < 0) {
		dev_err(&ctx->dsi0->dev, "Failed to initialize panel: %d\n", ret);
		gpiod_set_value_cansleep(ctx->reset_gpio, 1);
		regulator_bulk_disable(NT36830_NUM_SUPPLIES, ctx->supplies);
		return ret;
	}

	return 0;
}

static int nt36830_unprepare(struct drm_panel *panel)
{
	struct nt36830_panel *ctx = to_nt36830(panel);

	nt36830_off(ctx);

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	regulator_bulk_disable(NT36830_NUM_SUPPLIES, ctx->supplies);

	return 0;
}

/*
 * Display modes: 1440x2560 @ 60/120Hz
 *
 * From official DTS timing@0:
 *   Per DSI: 720x2560, hfp=20, hbp=12, hpw=8, vfp=16, vbp=14, vpw=2
 *
 * For mainline dual-DSI: horizontal porches are doubled.
 *   hdisplay=1440, hfp=40, hpw=16, hbp=24 -> htotal=1520
 *   vdisplay=2560, vfp=16, vpw=2, vbp=14  -> vtotal=2592
 *   clock = 1520 * 2592 * 60 / 1000 = 236390 kHz
 *
 * Keep the bring-up mode conservative at 60Hz first; the repo notes that
 * 120Hz requires additional DSI clock work beyond the current mainline path.
 *
 * Physical size: 71mm x 126mm (from DTS).
 */
static const struct drm_display_mode nt36830_modes[] = {
	{
		.clock = 236390,
		.hdisplay = 1440,
		.hsync_start = 1440 + 40,
		.hsync_end = 1440 + 40 + 16,
		.htotal = 1440 + 40 + 16 + 24,
		.vdisplay = 2560,
		.vsync_start = 2560 + 16,
		.vsync_end = 2560 + 16 + 2,
		.vtotal = 2560 + 16 + 2 + 14,
		.width_mm = 71,
		.height_mm = 126,
	},
	{
		.clock = 472781,
		.hdisplay = 1440,
		.hsync_start = 1440 + 40,
		.hsync_end = 1440 + 40 + 16,
		.htotal = 1440 + 40 + 16 + 24,
		.vdisplay = 2560,
		.vsync_start = 2560 + 16,
		.vsync_end = 2560 + 16 + 2,
		.vtotal = 2560 + 16 + 2 + 14,
		.width_mm = 71,
		.height_mm = 126,
	},
};

static int nt36830_get_modes(struct drm_panel *panel,
			     struct drm_connector *connector)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(nt36830_modes); i++) {
		struct drm_display_mode *mode;

		mode = drm_mode_duplicate(connector->dev, &nt36830_modes[i]);
		if (!mode)
			return -ENOMEM;

		mode->type = DRM_MODE_TYPE_DRIVER;
		if (i == 0)
			mode->type |= DRM_MODE_TYPE_PREFERRED;

		drm_mode_set_name(mode);
		drm_mode_probed_add(connector, mode);
	}

	connector->display_info.width_mm = nt36830_modes[0].width_mm;
	connector->display_info.height_mm = nt36830_modes[0].height_mm;
	connector->display_info.bpc = 10;

	return ARRAY_SIZE(nt36830_modes);
}

static enum drm_panel_orientation
nt36830_get_orientation(struct drm_panel *panel)
{
	struct nt36830_panel *ctx = to_nt36830(panel);

	return ctx->orientation;
}

static const struct drm_panel_funcs nt36830_panel_funcs = {
	.prepare = nt36830_prepare,
	.unprepare = nt36830_unprepare,
	.get_modes = nt36830_get_modes,
	.get_orientation = nt36830_get_orientation,
};

/*
 * Backlight via MIPI DCS (12-bit brightness, 0-4095).
 * From DTS: bl-min-level=1, bl-max-level=4095.
 */
static int nt36830_bl_update_status(struct backlight_device *bl)
{
	struct nt36830_panel *ctx = bl_get_data(bl);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi0 };
	u16 brightness = backlight_get_brightness(bl);
	u8 payload[] = {
		MIPI_DCS_SET_DISPLAY_BRIGHTNESS,
		brightness >> 8,
		brightness & 0xff,
	};

	mipi_dsi_dual_dcs_write_buffer_multi(&dsi_ctx, ctx->dsi0, ctx->dsi1,
					     payload, sizeof(payload));

	return dsi_ctx.accum_err;
}

static const struct backlight_ops nt36830_bl_ops = {
	.update_status = nt36830_bl_update_status,
};

static struct backlight_device *
nt36830_create_backlight(struct nt36830_panel *ctx)
{
	struct device *dev = &ctx->dsi0->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = 2048,
		.max_brightness = 4095,
		.scale = BACKLIGHT_SCALE_NON_LINEAR,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, ctx,
					      &nt36830_bl_ops, &props);
}

/*
 * DSC configuration: VESA DSC 1.1
 *
 * From official DTS:
 *   qcom,mdss-dsc-slice-height = <8>
 *   qcom,mdss-dsc-slice-width = <720>
 *   qcom,mdss-dsc-slice-per-pkt = <1>
 *   qcom,mdss-dsc-bit-per-component = <10>
 *   qcom,mdss-dsc-bit-per-pixel = <8>
 *   qcom,mdss-dsc-block-prediction-enable
 *   qcom,mdss-dsc-encoders = <1>  (per DSI interface)
 *
 * Note: razer,mdss-dsi-disable-sending-pps is set in the official DTS.
 * The NT36830 DDIC configures its DSC decoder internally via registers
 * C0/C1/C2 on page 10. We do NOT send the standard MIPI PPS command.
 * The dsi->dsc config is used by the MSM DSI host to program its DSC
 * encoder.
 */
static void nt36830_init_dsc(struct nt36830_panel *ctx)
{
	struct drm_dsc_config *dsc = &ctx->dsc;

	memset(dsc, 0, sizeof(*dsc));

	dsc->dsc_version_major = 1;
	dsc->dsc_version_minor = 1;

	dsc->slice_height = 8;
	dsc->slice_width = 720;
	dsc->slice_count = 1;          /* one 720-pixel slice per DSI interface */
	dsc->pic_width = 720;
	dsc->pic_height = 2560;

	dsc->bits_per_component = 10;
	dsc->bits_per_pixel = 8 << 4;  /* 8.0 bpp in 4.4 fixed-point */

	dsc->block_pred_enable = true;
	dsc->line_buf_depth = 11;      /* 10bpc needs line_buf_depth=11 */
	dsc->simple_422 = false;
	dsc->convert_rgb = true;

	dsc->rc_tgt_offset_high = 3;
	dsc->rc_tgt_offset_low = 3;
	dsc->rc_edge_factor = 6;
	dsc->rc_quant_incr_limit0 = 15;  /* For 10bpc */
	dsc->rc_quant_incr_limit1 = 15;  /* For 10bpc */

	dsc->mux_word_size = 48;         /* For bpc > 8 */
	dsc->initial_xmit_delay = 512;
	dsc->rc_model_size = 8192;

	dsc->flatness_min_qp = 7;        /* For 10bpc */
	dsc->flatness_max_qp = 16;       /* For 10bpc */
	dsc->first_line_bpg_offset = 12;

	drm_dsc_compute_rc_parameters(dsc);
}

static int nt36830_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct nt36830_panel *ctx;
	struct mipi_dsi_device *dsi1;
	struct device_node *dsi1_node;
	int ret, i;

	ctx = devm_drm_panel_alloc(dev, struct nt36830_panel, panel,
				   &nt36830_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	/* Get the secondary DSI node for dual-DSI */
	dsi1_node = of_graph_get_remote_node(dsi->dev.of_node, 1, -1);
	if (dsi1_node) {
		struct mipi_dsi_host *host =
			of_find_mipi_dsi_host_by_node(dsi1_node);
		const struct mipi_dsi_device_info info = {
			.type = "nt36830-sec",
			.channel = 0,
			.node = NULL,
		};

		of_node_put(dsi1_node);

		if (!host)
			return dev_err_probe(dev, -EPROBE_DEFER,
					     "Cannot find secondary DSI host\n");

		dsi1 = devm_mipi_dsi_device_register_full(dev, host, &info);
		if (IS_ERR(dsi1))
			return dev_err_probe(dev, PTR_ERR(dsi1),
					     "Cannot register secondary DSI device\n");

		ctx->dsi1 = dsi1;
	}

	/* Get regulators */
	for (i = 0; i < NT36830_NUM_SUPPLIES; i++)
		ctx->supplies[i].supply = nt36830_supplies[i].supply;

	ret = devm_regulator_bulk_get(dev, NT36830_NUM_SUPPLIES, ctx->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to get regulators\n");

	/* Get reset GPIO */
	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "Failed to get reset gpio\n");

	/* Configure primary DSI */
	ctx->dsi0 = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	ret = of_drm_get_panel_orientation(dev->of_node, &ctx->orientation);
	if (ret < 0)
		return dev_err_probe(dev, ret, "Failed to get panel orientation\n");

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_LPM |
			  MIPI_DSI_CLOCK_NON_CONTINUOUS;

	/* Configure secondary DSI */
	if (ctx->dsi1) {
		ctx->dsi1->lanes = 4;
		ctx->dsi1->format = MIPI_DSI_FMT_RGB888;
		ctx->dsi1->mode_flags = dsi->mode_flags;
	}

	/* Initialize DSC parameters */
	nt36830_init_dsc(ctx);
	dsi->dsc = &ctx->dsc;
	if (ctx->dsi1)
		ctx->dsi1->dsc = &ctx->dsc;

	/* Set prepare_prev_first for proper power sequencing */
	ctx->panel.prepare_prev_first = true;

	/* Create backlight device */
	ctx->panel.backlight = nt36830_create_backlight(ctx);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "Failed to create backlight\n");

	drm_panel_add(&ctx->panel);

	/* Attach primary DSI */
	ret = devm_mipi_dsi_attach(dev, dsi);
	if (ret < 0) {
		dev_err(dev, "Failed to attach to DSI0: %d\n", ret);
		drm_panel_remove(&ctx->panel);
		return ret;
	}

	/* Attach secondary DSI */
	if (ctx->dsi1) {
		ret = devm_mipi_dsi_attach(dev, ctx->dsi1);
		if (ret < 0) {
			dev_err(dev, "Failed to attach to DSI1: %d\n", ret);
			drm_panel_remove(&ctx->panel);
			return ret;
		}
	}

	dev_info(dev, "NT36830 panel probed (dual-DSI=%s, DSC 10bpc/8bpp)\n",
		 ctx->dsi1 ? "yes" : "no");

	return 0;
}

static void nt36830_remove(struct mipi_dsi_device *dsi)
{
	struct nt36830_panel *ctx = mipi_dsi_get_drvdata(dsi);

	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id nt36830_of_match[] = {
	{ .compatible = "razer,aura-nt36830" },
	{ .compatible = "novatek,nt36830" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, nt36830_of_match);

static struct mipi_dsi_driver nt36830_driver = {
	.probe = nt36830_probe,
	.remove = nt36830_remove,
	.driver = {
		.name = "panel-novatek-nt36830",
		.of_match_table = nt36830_of_match,
	},
};
module_mipi_dsi_driver(nt36830_driver);

MODULE_AUTHOR("Linux Community");
MODULE_DESCRIPTION("DRM Driver for NovaTeK NT36830 Dual-DSI AMOLED Panel with DSC");
MODULE_LICENSE("GPL");
