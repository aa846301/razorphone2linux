#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int send_ff_event(int fd, unsigned int code, int value)
{
	struct input_event event = {
		.type = EV_FF,
		.code = code,
		.value = value,
	};

	return write(fd, &event, sizeof(event)) == sizeof(event) ? 0 : -1;
}

int main(int argc, char **argv)
{
	struct ff_effect effect = {
		.type = FF_RUMBLE,
		.id = -1,
		.replay = { .length = 2000 },
		.u.rumble = { .strong_magnitude = 0xffff },
	};
	struct timespec duration = { .tv_sec = 2 };
	int fd, result = 1;

	if (argc != 2) {
		fprintf(stderr, "usage: %s /dev/input/eventN\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", argv[1], strerror(errno));
		return 1;
	}
	if (ioctl(fd, EVIOCSFF, &effect) < 0) {
		fprintf(stderr, "upload FF_RUMBLE: %s\n", strerror(errno));
		goto out;
	}
	if (send_ff_event(fd, FF_GAIN, 0xffff) < 0 ||
	    send_ff_event(fd, effect.id, 1) < 0) {
		fprintf(stderr, "start FF_RUMBLE: %s\n", strerror(errno));
		goto erase;
	}
	while (nanosleep(&duration, &duration) < 0 && errno == EINTR)
		;
	if (send_ff_event(fd, effect.id, 0) < 0) {
		fprintf(stderr, "stop FF_RUMBLE: %s\n", strerror(errno));
		goto erase;
	}
	puts("maximum FF_RUMBLE command completed");
	result = 0;

erase:
	ioctl(fd, EVIOCRMFF, effect.id);
out:
	close(fd);
	return result;
}
