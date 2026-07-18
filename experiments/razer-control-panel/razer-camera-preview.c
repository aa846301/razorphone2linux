#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
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

#define BUFFER_COUNT 4
#define HEADER_HEIGHT 210
#define PREVIEW_BLOCK 4
#define CAPTURE_DIRECTORY "/var/lib/razer-control-panel/captures"
#define CAPTURE_STATUS "/run/razer-camera-capture.last"

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t capture_requested;

struct buffer {
	void *data;
	size_t length;
};

static void stop_running(int signal_number)
{
	(void)signal_number;
	running = 0;
}

static void request_capture(int signal_number)
{
	(void)signal_number;
	capture_requested = 1;
}

static int xioctl(int fd, unsigned long request, void *argument)
{
	int result;

	do {
		result = ioctl(fd, request, argument);
	} while (result < 0 && errno == EINTR);
	return result;
}

static unsigned int raw10_pixel(const uint8_t *row, unsigned int x)
{
	const uint8_t *group = row + (x / 4) * 5;
	unsigned int lane = x & 3;

	return ((unsigned int)group[lane] << 2) |
	       ((group[4] >> (lane * 2)) & 3);
}

static unsigned int sample(const uint8_t *raw, unsigned int stride,
			   unsigned int width, unsigned int height,
			   int x, int y)
{
	if (x < 0)
		x = 0;
	else if ((unsigned int)x >= width)
		x = width - 1;
	if (y < 0)
		y = 0;
	else if ((unsigned int)y >= height)
		y = height - 1;
	return raw10_pixel(raw + (size_t)y * stride, x);
}

static uint8_t to_u8(unsigned int value)
{
	/* A small preview gain compensates for the lack of a userspace 3A loop. */
	value = (value * 3) >> 3;
	return value > 255 ? 255 : value;
}

enum bayer_color {
	BAYER_RED,
	BAYER_GREEN,
	BAYER_BLUE,
};

enum bayer_pattern {
	BAYER_RGGB,
	BAYER_GRBG,
	BAYER_BGGR,
	BAYER_GBRG,
};

static enum bayer_color bayer_color_at(enum bayer_pattern pattern, int x, int y)
{
	static const enum bayer_color colors[][4] = {
		[BAYER_RGGB] = { BAYER_RED, BAYER_GREEN, BAYER_GREEN, BAYER_BLUE },
		[BAYER_GRBG] = { BAYER_GREEN, BAYER_RED, BAYER_BLUE, BAYER_GREEN },
		[BAYER_BGGR] = { BAYER_BLUE, BAYER_GREEN, BAYER_GREEN, BAYER_RED },
		[BAYER_GBRG] = { BAYER_GREEN, BAYER_BLUE, BAYER_RED, BAYER_GREEN },
	};

	return colors[pattern][((y & 1) << 1) | (x & 1)];
}

static uint32_t debayer(const uint8_t *raw, unsigned int stride,
			unsigned int width, unsigned int height,
			int x, int y, enum bayer_pattern pattern)
{
	unsigned int p = sample(raw, stride, width, height, x, y);
	unsigned int r, g, b;
	enum bayer_color color = bayer_color_at(pattern, x, y);

	if (color == BAYER_RED) {
		r = p;
		g = (sample(raw, stride, width, height, x - 1, y) +
		     sample(raw, stride, width, height, x + 1, y) +
		     sample(raw, stride, width, height, x, y - 1) +
		     sample(raw, stride, width, height, x, y + 1)) / 4;
		b = (sample(raw, stride, width, height, x - 1, y - 1) +
		     sample(raw, stride, width, height, x + 1, y - 1) +
		     sample(raw, stride, width, height, x - 1, y + 1) +
		     sample(raw, stride, width, height, x + 1, y + 1)) / 4;
	} else if (color == BAYER_BLUE) {
		b = p;
		g = (sample(raw, stride, width, height, x - 1, y) +
		     sample(raw, stride, width, height, x + 1, y) +
		     sample(raw, stride, width, height, x, y - 1) +
		     sample(raw, stride, width, height, x, y + 1)) / 4;
		r = (sample(raw, stride, width, height, x - 1, y - 1) +
		     sample(raw, stride, width, height, x + 1, y - 1) +
		     sample(raw, stride, width, height, x - 1, y + 1) +
		     sample(raw, stride, width, height, x + 1, y + 1)) / 4;
	} else {
		g = p;
		if (bayer_color_at(pattern, x - 1, y) == BAYER_RED) {
			r = (sample(raw, stride, width, height, x - 1, y) +
			     sample(raw, stride, width, height, x + 1, y)) / 2;
			b = (sample(raw, stride, width, height, x, y - 1) +
			     sample(raw, stride, width, height, x, y + 1)) / 2;
		} else {
			r = (sample(raw, stride, width, height, x, y - 1) +
			     sample(raw, stride, width, height, x, y + 1)) / 2;
			b = (sample(raw, stride, width, height, x - 1, y) +
			     sample(raw, stride, width, height, x + 1, y)) / 2;
		}
	}

	return (uint32_t)to_u8(r) << 16 | (uint32_t)to_u8(g) << 8 | to_u8(b);
}

static void put_le16(uint8_t *destination, uint16_t value)
{
	destination[0] = value;
	destination[1] = value >> 8;
}

static void put_le32(uint8_t *destination, uint32_t value)
{
	destination[0] = value;
	destination[1] = value >> 8;
	destination[2] = value >> 16;
	destination[3] = value >> 24;
}

static int write_raw(const char *path, const uint8_t *raw, size_t length)
{
	FILE *file = fopen(path, "wb");
	int result;

	if (!file)
		return -1;
	result = fwrite(raw, 1, length, file) == length ? 0 : -1;
	if (fclose(file) != 0)
		result = -1;
	return result;
}

static int write_bmp(const char *path, const uint8_t *raw, unsigned int stride,
		     unsigned int width, unsigned int height,
		     enum bayer_pattern pattern)
{
	unsigned int row_stride = (width * 3 + 3) & ~3U;
	uint32_t image_size = row_stride * height;
	uint8_t header[54] = { 'B', 'M' };
	uint8_t *row = calloc(1, row_stride);
	FILE *file;
	unsigned int x, y;
	int result = 0;

	if (!row)
		return -1;
	file = fopen(path, "wb");
	if (!file) {
		free(row);
		return -1;
	}
	put_le32(header + 2, sizeof(header) + image_size);
	put_le32(header + 10, sizeof(header));
	put_le32(header + 14, 40);
	put_le32(header + 18, width);
	/* A negative DIB height stores the image top-down. */
	put_le32(header + 22, (uint32_t)(int32_t)-height);
	put_le16(header + 26, 1);
	put_le16(header + 28, 24);
	put_le32(header + 34, image_size);
	if (fwrite(header, 1, sizeof(header), file) != sizeof(header))
		result = -1;
	for (y = 0; !result && y < height; y++) {
		memset(row, 0, row_stride);
		for (x = 0; x < width; x++) {
			uint32_t color = debayer(raw, stride, width, height, x, y, pattern);

			row[x * 3] = color;
			row[x * 3 + 1] = color >> 8;
			row[x * 3 + 2] = color >> 16;
		}
		if (fwrite(row, 1, row_stride, file) != row_stride)
			result = -1;
	}
	free(row);
	if (fclose(file) != 0)
		result = -1;
	return result;
}

static void write_capture_error(void)
{
	int saved_errno = errno;
	FILE *status = fopen(CAPTURE_STATUS ".tmp", "w");

	if (!status)
		return;
	fprintf(status, "error=%s\n", strerror(saved_errno));
	if (fclose(status) == 0)
		rename(CAPTURE_STATUS ".tmp", CAPTURE_STATUS);
}

static int save_capture(const char *camera, const char *bayer, const char *fourcc,
			const uint8_t *raw, size_t raw_length, unsigned int stride,
			unsigned int width, unsigned int height,
			enum bayer_pattern pattern)
{
	struct timespec now;
	struct tm local;
	char timestamp[32], base[256], raw_path[320], bmp_path[320], meta_path[320];
	FILE *meta, *status;

	if ((mkdir("/var/lib/razer-control-panel", 0755) < 0 && errno != EEXIST) ||
	    (mkdir(CAPTURE_DIRECTORY, 0755) < 0 && errno != EEXIST)) {
		write_capture_error();
		return -1;
	}
	clock_gettime(CLOCK_REALTIME, &now);
	localtime_r(&now.tv_sec, &local);
	strftime(timestamp, sizeof(timestamp), "%Y%m%d-%H%M%S", &local);
	snprintf(base, sizeof(base), "%s/%s-%s-%03ld", CAPTURE_DIRECTORY,
		 camera, timestamp, now.tv_nsec / 1000000);
	snprintf(raw_path, sizeof(raw_path), "%s.raw10", base);
	snprintf(bmp_path, sizeof(bmp_path), "%s.bmp", base);
	snprintf(meta_path, sizeof(meta_path), "%s.txt", base);

	if (write_raw(raw_path, raw, raw_length) < 0 ||
	    write_bmp(bmp_path, raw, stride, width, height, pattern) < 0) {
		write_capture_error();
		return -1;
	}
	meta = fopen(meta_path, "w");
	if (!meta) {
		write_capture_error();
		return -1;
	}
	fprintf(meta, "camera=%s\nwidth=%u\nheight=%u\nbytesperline=%u\n"
		"fourcc=%s\nbayer=%s\nraw_bytes=%zu\n",
		camera, width, height, stride, fourcc, bayer, raw_length);
	if (fclose(meta) != 0) {
		write_capture_error();
		return -1;
	}
	status = fopen(CAPTURE_STATUS ".tmp", "w");
	if (!status) {
		write_capture_error();
		return -1;
	}
	fprintf(status, "ok\nbmp=%s\nraw=%s\nmeta=%s\n", bmp_path, raw_path, meta_path);
	if (fclose(status) != 0 || rename(CAPTURE_STATUS ".tmp", CAPTURE_STATUS) < 0) {
		write_capture_error();
		return -1;
	}
	fprintf(stdout, "capture saved: %s (raw: %s)\n", bmp_path, raw_path);
	fflush(stdout);
	return 0;
}

static void render(uint8_t *shared, unsigned int screen_width,
		   unsigned int screen_height, const uint8_t *raw,
		   unsigned int raw_stride, unsigned int raw_width,
		   unsigned int raw_height, enum bayer_pattern pattern, int mirror)
{
	uint32_t *pixels = (uint32_t *)(shared + sizeof(uint64_t));
	unsigned int available_height = screen_height - HEADER_HEIGHT;
	unsigned int draw_width = raw_height * available_height / raw_width;
	unsigned int x0, dx, dy;

	if (draw_width > screen_width)
		draw_width = screen_width;
	x0 = (screen_width - draw_width) / 2;
	__atomic_add_fetch((uint64_t *)shared, 1, __ATOMIC_ACQ_REL);
	memset(pixels + (size_t)HEADER_HEIGHT * screen_width, 0,
	       (size_t)available_height * screen_width * sizeof(*pixels));

	/*
	 * Full-resolution software demosaicing takes more than a frame interval on
	 * the SDM845 little cores and keeps the shared-frame sequence permanently
	 * odd. Demosaic one sample per small preview block, then replicate it.
	 */
	for (dy = 0; dy < available_height; dy += PREVIEW_BLOCK) {
		int sx = dy * raw_width / available_height;
		unsigned int block_height = available_height - dy;

		if (block_height > PREVIEW_BLOCK)
			block_height = PREVIEW_BLOCK;
		for (dx = 0; dx < draw_width; dx += PREVIEW_BLOCK) {
			int sy = dx * raw_height / draw_width;
			unsigned int block_width = draw_width - dx;
			uint32_t color;
			unsigned int bx, by;

			if (!mirror)
				sy = raw_height - 1 - sy;
			if (block_width > PREVIEW_BLOCK)
				block_width = PREVIEW_BLOCK;
			color = debayer(raw, raw_stride, raw_width, raw_height,
					sx, sy, pattern);
			for (by = 0; by < block_height; by++) {
				uint32_t *row = pixels +
					(size_t)(HEADER_HEIGHT + dy + by) * screen_width + x0 + dx;

				for (bx = 0; bx < block_width; bx++)
					row[bx] = color;
			}
		}
	}
	__atomic_add_fetch((uint64_t *)shared, 1, __ATOMIC_RELEASE);
}

int main(int argc, char **argv)
{
	struct v4l2_format format = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	struct v4l2_requestbuffers request = { .count = BUFFER_COUNT,
		.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP };
	struct buffer buffers[BUFFER_COUNT] = {{0}};
	struct stat shared_stat;
	uint8_t *shared = MAP_FAILED;
	unsigned int screen_width, screen_height, index;
	uint32_t requested_fourcc;
	int video_fd = -1, shared_fd = -1, mirror, result = EXIT_FAILURE;
	enum bayer_pattern pattern;
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

	if (argc != 9) {
		fprintf(stderr, "usage: %s VIDEO SHARED WIDTH HEIGHT FORMAT MIRROR FOURCC CAMERA\n", argv[0]);
		return EXIT_FAILURE;
	}
	screen_width = strtoul(argv[3], NULL, 10);
	screen_height = strtoul(argv[4], NULL, 10);
	if (!screen_width || screen_height <= HEADER_HEIGHT)
		return EXIT_FAILURE;
	if (!strcmp(argv[5], "RGGB"))
		pattern = BAYER_RGGB;
	else if (!strcmp(argv[5], "GRBG"))
		pattern = BAYER_GRBG;
	else if (!strcmp(argv[5], "BGGR"))
		pattern = BAYER_BGGR;
	else if (!strcmp(argv[5], "GBRG"))
		pattern = BAYER_GBRG;
	else {
		fprintf(stderr, "unsupported Bayer pattern: %s\n", argv[5]);
		return EXIT_FAILURE;
	}
	mirror = atoi(argv[6]);
	format.fmt.pix_mp.width = 1920;
	format.fmt.pix_mp.height = 1080;
	requested_fourcc = v4l2_fourcc(argv[7][0], argv[7][1], argv[7][2], argv[7][3]);
	format.fmt.pix_mp.pixelformat = requested_fourcc;
	format.fmt.pix_mp.field = V4L2_FIELD_NONE;

	signal(SIGINT, stop_running);
	signal(SIGTERM, stop_running);
	signal(SIGUSR1, request_capture);
	video_fd = open(argv[1], O_RDWR | O_CLOEXEC | O_NONBLOCK);
	if (video_fd < 0 || xioctl(video_fd, VIDIOC_S_FMT, &format) < 0 ||
	    format.fmt.pix_mp.width != 1920 || format.fmt.pix_mp.height != 1080 ||
	    format.fmt.pix_mp.pixelformat != requested_fourcc ||
	    format.fmt.pix_mp.num_planes != 1) {
		perror("razer-camera-preview: video format");
		goto out;
	}
	if (xioctl(video_fd, VIDIOC_REQBUFS, &request) < 0 || request.count < 2 ||
	    request.count > BUFFER_COUNT) {
		perror("razer-camera-preview: request buffers");
		goto out;
	}
	for (index = 0; index < request.count; index++) {
		struct v4l2_plane planes[VIDEO_MAX_PLANES] = {{0}};
		struct v4l2_buffer buffer = { .type = type, .memory = V4L2_MEMORY_MMAP,
			.index = index, .length = VIDEO_MAX_PLANES, .m.planes = planes };
		if (xioctl(video_fd, VIDIOC_QUERYBUF, &buffer) < 0)
			goto out;
		buffers[index].length = planes[0].length;
		buffers[index].data = mmap(NULL, planes[0].length, PROT_READ,
			MAP_SHARED, video_fd, planes[0].m.mem_offset);
		if (buffers[index].data == MAP_FAILED || xioctl(video_fd, VIDIOC_QBUF, &buffer) < 0)
			goto out;
	}
	shared_fd = open(argv[2], O_RDWR | O_CLOEXEC);
	if (shared_fd < 0 || fstat(shared_fd, &shared_stat) < 0 ||
	    (uint64_t)shared_stat.st_size < sizeof(uint64_t) +
		(uint64_t)screen_width * screen_height * sizeof(uint32_t))
		goto out;
	shared = mmap(NULL, shared_stat.st_size, PROT_READ | PROT_WRITE,
		MAP_SHARED, shared_fd, 0);
	if (shared == MAP_FAILED || xioctl(video_fd, VIDIOC_STREAMON, &type) < 0) {
		perror("razer-camera-preview: stream on");
		goto out;
	}

	while (running) {
		struct pollfd poll_fd = { .fd = video_fd, .events = POLLIN };
		struct v4l2_plane planes[VIDEO_MAX_PLANES] = {{0}};
		struct v4l2_buffer buffer = { .type = type, .memory = V4L2_MEMORY_MMAP,
			.length = VIDEO_MAX_PLANES, .m.planes = planes };
		if (poll(&poll_fd, 1, 1000) <= 0)
			continue;
		if (xioctl(video_fd, VIDIOC_DQBUF, &buffer) < 0) {
			if (errno == EAGAIN)
				continue;
			break;
		}
		if (buffer.index >= request.count)
			break;
		render(shared, screen_width, screen_height, buffers[buffer.index].data,
		       format.fmt.pix_mp.plane_fmt[0].bytesperline, format.fmt.pix_mp.width,
		       format.fmt.pix_mp.height, pattern, mirror);
		if (capture_requested) {
			size_t bytes_used = planes[0].bytesused;

			capture_requested = 0;
			if (!bytes_used || bytes_used > buffers[buffer.index].length)
				bytes_used = buffers[buffer.index].length;
			save_capture(argv[8], argv[5], argv[7], buffers[buffer.index].data,
				     bytes_used, format.fmt.pix_mp.plane_fmt[0].bytesperline,
				     format.fmt.pix_mp.width, format.fmt.pix_mp.height, pattern);
		}
		if (xioctl(video_fd, VIDIOC_QBUF, &buffer) < 0)
			break;
	}
	xioctl(video_fd, VIDIOC_STREAMOFF, &type);
	result = EXIT_SUCCESS;

out:
	if (shared != MAP_FAILED)
		munmap(shared, shared_stat.st_size);
	for (index = 0; index < BUFFER_COUNT; index++)
		if (buffers[index].data && buffers[index].data != MAP_FAILED)
			munmap(buffers[index].data, buffers[index].length);
	if (shared_fd >= 0)
		close(shared_fd);
	if (video_fd >= 0)
		close(video_fd);
	return result;
}
