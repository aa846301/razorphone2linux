#define _GNU_SOURCE

#include <drm.h>
#include <drm_fourcc.h>
#include <drm_mode.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DRM_MODE_CONNECTED 1

static volatile sig_atomic_t running = 1;

struct display {
	int fd;
	uint32_t connector_id;
	uint32_t crtc_id;
	struct drm_mode_modeinfo mode;
	struct drm_mode_crtc saved_crtc;
	int saved_valid;
};

static void stop_running(int signal_number)
{
	(void)signal_number;
	running = 0;
}

static int drm_ioctl(int fd, unsigned long request, void *argument)
{
	int result;

	do {
		result = ioctl(fd, request, argument);
	} while (result < 0 && errno == EINTR);

	return result;
}

static void free_connector_arrays(uint32_t *encoders,
				  uint32_t *properties, uint64_t *values,
				  struct drm_mode_modeinfo *modes)
{
	free(encoders);
	free(properties);
	free(values);
	free(modes);
}

static int find_connected_display(int fd, struct display *display)
{
	struct drm_mode_card_res resources = {0};
	uint32_t *connectors = NULL;
	uint32_t *crtcs = NULL;
	uint32_t *encoders = NULL;
	int result = -1;
	uint32_t index;

	if (drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) < 0)
		return -1;

	connectors = calloc(resources.count_connectors, sizeof(*connectors));
	crtcs = calloc(resources.count_crtcs, sizeof(*crtcs));
	encoders = calloc(resources.count_encoders, sizeof(*encoders));
	if (!connectors || !crtcs || !encoders)
		goto out;

	resources.connector_id_ptr = (uintptr_t)connectors;
	resources.crtc_id_ptr = (uintptr_t)crtcs;
	resources.encoder_id_ptr = (uintptr_t)encoders;
	if (drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) < 0)
		goto out;

	for (index = 0; index < resources.count_connectors; index++) {
		struct drm_mode_get_connector connector = {0};
		struct drm_mode_modeinfo *modes = NULL;
		uint32_t *connector_encoders = NULL;
		uint32_t *properties = NULL;
		uint64_t *values = NULL;
		uint32_t encoder_id;
		struct drm_mode_get_encoder encoder = {0};

		connector.connector_id = connectors[index];
		if (drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &connector) < 0)
			continue;

		modes = calloc(connector.count_modes, sizeof(*modes));
		connector_encoders = calloc(connector.count_encoders,
					    sizeof(*connector_encoders));
		properties = calloc(connector.count_props, sizeof(*properties));
		values = calloc(connector.count_props, sizeof(*values));
		if ((connector.count_modes && !modes) ||
		    (connector.count_encoders && !connector_encoders) ||
		    (connector.count_props && (!properties || !values))) {
			free_connector_arrays(connector_encoders, properties, values, modes);
			continue;
		}

		connector.modes_ptr = (uintptr_t)modes;
		connector.encoders_ptr = (uintptr_t)connector_encoders;
		connector.props_ptr = (uintptr_t)properties;
		connector.prop_values_ptr = (uintptr_t)values;
		if (drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &connector) < 0 ||
		    connector.connection != DRM_MODE_CONNECTED || !connector.count_modes) {
			free_connector_arrays(connector_encoders, properties, values, modes);
			continue;
		}

		encoder_id = connector.encoder_id;
		if (!encoder_id && connector.count_encoders)
			encoder_id = connector_encoders[0];
		encoder.encoder_id = encoder_id;
		if (!encoder_id || drm_ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &encoder) < 0) {
			free_connector_arrays(connector_encoders, properties, values, modes);
			continue;
		}

		display->connector_id = connector.connector_id;
		display->crtc_id = encoder.crtc_id ? encoder.crtc_id : crtcs[0];
		display->mode = modes[0];
		free_connector_arrays(connector_encoders, properties, values, modes);
		result = 0;
		break;
	}

out:
	free(connectors);
	free(crtcs);
	free(encoders);
	return result;
}

static int open_display(struct display *display)
{
	char path[32];
	int card;

	memset(display, 0, sizeof(*display));
	display->fd = -1;
	for (card = 0; card < 16; card++) {
		snprintf(path, sizeof(path), "/dev/dri/card%d", card);
		display->fd = open(path, O_RDWR | O_CLOEXEC);
		if (display->fd < 0)
			continue;
		if (find_connected_display(display->fd, display) == 0) {
			fprintf(stderr, "razer-kms-present: using %s %ux%u\n", path,
				display->mode.hdisplay, display->mode.vdisplay);
			return 0;
		}
		close(display->fd);
		display->fd = -1;
	}

	errno = ENODEV;
	return -1;
}

int main(int argc, char **argv)
{
	struct display display;
	struct drm_mode_create_dumb create[2] = {{0}};
	struct drm_mode_map_dumb map_request[2] = {{0}};
	struct drm_mode_fb_cmd2 framebuffer[2] = {{0}};
	struct drm_mode_crtc modeset = {0};
	struct stat shared_stat;
	uint8_t *shared = MAP_FAILED;
	uint8_t *pixels[2] = {MAP_FAILED, MAP_FAILED};
	uint64_t last_sequence = UINT64_MAX;
	uint64_t frame_size;
	int shared_fd = -1;
	int active_buffer = 0;
	int buffer_index;
	int result = EXIT_FAILURE;

	if (argc != 2) {
		fprintf(stderr, "usage: %s SHARED-FRAME\n", argv[0]);
		return EXIT_FAILURE;
	}

	signal(SIGINT, stop_running);
	signal(SIGTERM, stop_running);

	if (open_display(&display) < 0) {
		perror("razer-kms-present: no connected DRM display");
		return EXIT_FAILURE;
	}

	if (drm_ioctl(display.fd, DRM_IOCTL_SET_MASTER, NULL) < 0 && errno != EINVAL) {
		perror("razer-kms-present: DRM master");
		goto out_display;
	}

	display.saved_crtc.crtc_id = display.crtc_id;
	if (drm_ioctl(display.fd, DRM_IOCTL_MODE_GETCRTC, &display.saved_crtc) == 0) {
		display.saved_valid = 1;
		if (display.saved_crtc.mode_valid)
			display.mode = display.saved_crtc.mode;
	}

	for (buffer_index = 0; buffer_index < 2; buffer_index++) {
		create[buffer_index].width = display.mode.hdisplay;
		create[buffer_index].height = display.mode.vdisplay;
		create[buffer_index].bpp = 32;
		if (drm_ioctl(display.fd, DRM_IOCTL_MODE_CREATE_DUMB,
			      &create[buffer_index]) < 0) {
			perror("razer-kms-present: CREATE_DUMB");
			goto out_buffers;
		}

		framebuffer[buffer_index].width = create[buffer_index].width;
		framebuffer[buffer_index].height = create[buffer_index].height;
		framebuffer[buffer_index].pixel_format = DRM_FORMAT_XRGB8888;
		framebuffer[buffer_index].handles[0] = create[buffer_index].handle;
		framebuffer[buffer_index].pitches[0] = create[buffer_index].pitch;
		if (drm_ioctl(display.fd, DRM_IOCTL_MODE_ADDFB2,
			      &framebuffer[buffer_index]) < 0) {
			perror("razer-kms-present: ADDFB2");
			goto out_buffers;
		}

		map_request[buffer_index].handle = create[buffer_index].handle;
		if (drm_ioctl(display.fd, DRM_IOCTL_MODE_MAP_DUMB,
			      &map_request[buffer_index]) < 0) {
			perror("razer-kms-present: MAP_DUMB");
			goto out_buffers;
		}
		pixels[buffer_index] = mmap(NULL, create[buffer_index].size,
			PROT_READ | PROT_WRITE, MAP_SHARED, display.fd,
			map_request[buffer_index].offset);
		if (pixels[buffer_index] == MAP_FAILED) {
			perror("razer-kms-present: mmap dumb buffer");
			goto out_buffers;
		}
		memset(pixels[buffer_index], 0, create[buffer_index].size);
	}

	shared_fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (shared_fd < 0 || fstat(shared_fd, &shared_stat) < 0) {
		perror("razer-kms-present: shared frame");
		goto out_buffers;
	}
	frame_size = (uint64_t)create[0].width * create[0].height * 4;
	if ((uint64_t)shared_stat.st_size < sizeof(uint64_t) + frame_size) {
		fprintf(stderr, "razer-kms-present: shared frame is too small\n");
		goto out_buffers;
	}
	shared = mmap(NULL, shared_stat.st_size, PROT_READ, MAP_SHARED, shared_fd, 0);
	if (shared == MAP_FAILED) {
		perror("razer-kms-present: mmap shared frame");
		goto out_buffers;
	}

	/* Wait for Python to finish its first frame before replacing fbcon. */
	for (int attempt = 0; attempt < 100; attempt++) {
		uint64_t sequence;
		uint32_t row;
		struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000};

		memcpy(&sequence, shared, sizeof(sequence));
		if (sequence && !(sequence & 1)) {
			const uint8_t *source = shared + sizeof(uint64_t);
			for (row = 0; row < create[0].height; row++)
				memcpy(pixels[0] + (uint64_t)row * create[0].pitch,
				       source + (uint64_t)row * create[0].width * 4,
				       (size_t)create[0].width * 4);
			__sync_synchronize();
			if (!memcmp(&sequence, shared, sizeof(sequence))) {
				last_sequence = sequence;
				break;
			}
		}
		nanosleep(&delay, NULL);
	}
	msync(pixels[0], create[0].size, MS_SYNC);

	modeset.set_connectors_ptr = (uintptr_t)&display.connector_id;
	modeset.count_connectors = 1;
	modeset.crtc_id = display.crtc_id;
	modeset.fb_id = framebuffer[0].fb_id;
	modeset.mode_valid = 1;
	modeset.mode = display.mode;
	if (drm_ioctl(display.fd, DRM_IOCTL_MODE_SETCRTC, &modeset) < 0) {
		perror("razer-kms-present: SETCRTC");
		goto out_shared;
	}
	fprintf(stderr, "razer-kms-present: modeset active clock=%u\n",
		display.mode.clock);

	while (running) {
		uint64_t sequence;
		uint32_t row;
		int next_buffer = active_buffer ^ 1;
		struct timespec delay = {.tv_sec = 0, .tv_nsec = 50000000};

		memcpy(&sequence, shared, sizeof(sequence));
		if (!(sequence & 1) && sequence != last_sequence) {
			const uint8_t *source = shared + sizeof(uint64_t);
			for (row = 0; row < create[next_buffer].height; row++)
				memcpy(pixels[next_buffer] +
				       (uint64_t)row * create[next_buffer].pitch,
				       source + (uint64_t)row * create[next_buffer].width * 4,
				       (size_t)create[next_buffer].width * 4);
			__sync_synchronize();
			if (!memcmp(&sequence, shared, sizeof(sequence))) {
				struct drm_mode_crtc_page_flip flip = {
					.crtc_id = display.crtc_id,
					.fb_id = framebuffer[next_buffer].fb_id,
				};

				msync(pixels[next_buffer], create[next_buffer].size, MS_SYNC);
				if (drm_ioctl(display.fd, DRM_IOCTL_MODE_PAGE_FLIP, &flip) < 0) {
					if (errno == EBUSY)
						goto wait_for_flip;
					modeset.fb_id = framebuffer[next_buffer].fb_id;
					if (drm_ioctl(display.fd, DRM_IOCTL_MODE_SETCRTC,
						      &modeset) < 0) {
						perror("razer-kms-present: page flip");
						goto wait_for_flip;
					}
				}
				active_buffer = next_buffer;
				last_sequence = sequence;
			}
		}
	wait_for_flip:
		nanosleep(&delay, NULL);
	}

	result = EXIT_SUCCESS;

out_shared:
	if (shared != MAP_FAILED)
		munmap(shared, shared_stat.st_size);
	if (shared_fd >= 0)
		close(shared_fd);
	if (display.saved_valid) {
		display.saved_crtc.set_connectors_ptr = (uintptr_t)&display.connector_id;
		display.saved_crtc.count_connectors = 1;
		drm_ioctl(display.fd, DRM_IOCTL_MODE_SETCRTC, &display.saved_crtc);
	}
out_buffers:
	for (buffer_index = 0; buffer_index < 2; buffer_index++) {
		struct drm_mode_destroy_dumb destroy = {
			.handle = create[buffer_index].handle,
		};
		if (pixels[buffer_index] != MAP_FAILED)
			munmap(pixels[buffer_index], create[buffer_index].size);
		if (framebuffer[buffer_index].fb_id)
			drm_ioctl(display.fd, DRM_IOCTL_MODE_RMFB,
				  &framebuffer[buffer_index].fb_id);
		if (create[buffer_index].handle)
			drm_ioctl(display.fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
	}
	drm_ioctl(display.fd, DRM_IOCTL_DROP_MASTER, NULL);
out_display:
	close(display.fd);
	return result;
}
