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
#include <unistd.h>

#define BUFFER_COUNT 4
#define HEADER_HEIGHT 210

static volatile sig_atomic_t running = 1;

struct buffer {
	void *data;
	size_t length;
};

static void stop_running(int signal_number)
{
	(void)signal_number;
	running = 0;
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

static uint32_t debayer(const uint8_t *raw, unsigned int stride,
			unsigned int width, unsigned int height,
			int x, int y, int grbg)
{
	unsigned int p = sample(raw, stride, width, height, x, y);
	unsigned int r, g, b;
	int even_x = !(x & 1), even_y = !(y & 1);
	int red = grbg ? (even_y && !even_x) : (even_y && even_x);
	int blue = grbg ? (!even_y && even_x) : (!even_y && !even_x);

	if (red) {
		r = p;
		g = (sample(raw, stride, width, height, x - 1, y) +
		     sample(raw, stride, width, height, x + 1, y) +
		     sample(raw, stride, width, height, x, y - 1) +
		     sample(raw, stride, width, height, x, y + 1)) / 4;
		b = (sample(raw, stride, width, height, x - 1, y - 1) +
		     sample(raw, stride, width, height, x + 1, y - 1) +
		     sample(raw, stride, width, height, x - 1, y + 1) +
		     sample(raw, stride, width, height, x + 1, y + 1)) / 4;
	} else if (blue) {
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
		if ((grbg && even_y) || (!grbg && !even_y)) {
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

static void render(uint8_t *shared, unsigned int screen_width,
		   unsigned int screen_height, const uint8_t *raw,
		   unsigned int raw_stride, unsigned int raw_width,
		   unsigned int raw_height, int grbg, int mirror)
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

	for (dy = 0; dy < available_height; dy++) {
		int sx = dy * raw_width / available_height;
		for (dx = 0; dx < draw_width; dx++) {
			int sy = dx * raw_height / draw_width;
			if (!mirror)
				sy = raw_height - 1 - sy;
			pixels[(size_t)(HEADER_HEIGHT + dy) * screen_width + x0 + dx] =
				debayer(raw, raw_stride, raw_width, raw_height,
					sx, sy, grbg);
		}
	}
	__atomic_add_fetch((uint64_t *)shared, 1, __ATOMIC_RELEASE);
}

int main(int argc, char **argv)
{
	struct v4l2_format format = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_requestbuffers request = { .count = BUFFER_COUNT,
		.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
	struct buffer buffers[BUFFER_COUNT] = {{0}};
	struct stat shared_stat;
	uint8_t *shared = MAP_FAILED;
	unsigned int screen_width, screen_height, index;
	uint32_t requested_fourcc;
	int video_fd = -1, shared_fd = -1, grbg, mirror, result = EXIT_FAILURE;
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

	if (argc != 8) {
		fprintf(stderr, "usage: %s VIDEO SHARED WIDTH HEIGHT FORMAT MIRROR FOURCC\n", argv[0]);
		return EXIT_FAILURE;
	}
	screen_width = strtoul(argv[3], NULL, 10);
	screen_height = strtoul(argv[4], NULL, 10);
	if (!screen_width || screen_height <= HEADER_HEIGHT)
		return EXIT_FAILURE;
	grbg = !strcmp(argv[5], "GRBG");
	mirror = atoi(argv[6]);
	format.fmt.pix.width = 1920;
	format.fmt.pix.height = 1080;
	requested_fourcc = v4l2_fourcc(argv[7][0], argv[7][1], argv[7][2], argv[7][3]);
	format.fmt.pix.pixelformat = requested_fourcc;
	format.fmt.pix.field = V4L2_FIELD_NONE;

	signal(SIGINT, stop_running);
	signal(SIGTERM, stop_running);
	video_fd = open(argv[1], O_RDWR | O_CLOEXEC | O_NONBLOCK);
	if (video_fd < 0 || xioctl(video_fd, VIDIOC_S_FMT, &format) < 0 ||
	    format.fmt.pix.width != 1920 || format.fmt.pix.height != 1080 ||
	    format.fmt.pix.pixelformat != requested_fourcc) {
		perror("razer-camera-preview: video format");
		goto out;
	}
	if (xioctl(video_fd, VIDIOC_REQBUFS, &request) < 0 || request.count < 2) {
		perror("razer-camera-preview: request buffers");
		goto out;
	}
	for (index = 0; index < request.count; index++) {
		struct v4l2_buffer buffer = { .type = type, .memory = V4L2_MEMORY_MMAP,
			.index = index };
		if (xioctl(video_fd, VIDIOC_QUERYBUF, &buffer) < 0)
			goto out;
		buffers[index].length = buffer.length;
		buffers[index].data = mmap(NULL, buffer.length, PROT_READ,
			MAP_SHARED, video_fd, buffer.m.offset);
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
		struct v4l2_buffer buffer = { .type = type, .memory = V4L2_MEMORY_MMAP };
		if (poll(&poll_fd, 1, 1000) <= 0)
			continue;
		if (xioctl(video_fd, VIDIOC_DQBUF, &buffer) < 0) {
			if (errno == EAGAIN)
				continue;
			break;
		}
		render(shared, screen_width, screen_height, buffers[buffer.index].data,
		       format.fmt.pix.bytesperline, format.fmt.pix.width,
		       format.fmt.pix.height, grbg, mirror);
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
