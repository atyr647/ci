// Linux: creates a virtual gamepad through /dev/uinput (the kernel's own simulation interface) and plays a fixed script on it; pad_test --expect=uinput checks what arrives.
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
static int fd;
static void ev(int type, int code, int value) { struct input_event e; memset(&e, 0, sizeof e); e.type = type; e.code = code; e.value = value; if (write(fd, &e, sizeof e) != sizeof e) perror("write"); }
static void syn(void) { ev(EV_SYN, SYN_REPORT, 0); struct timespec t = {0, 40000000}; nanosleep(&t, 0); }
static void absrange(int code, int mn, int mx) { struct uinput_abs_setup s; memset(&s, 0, sizeof s); s.code = code; s.absinfo.minimum = mn; s.absinfo.maximum = mx; ioctl(fd, UI_ABS_SETUP, &s); ioctl(fd, UI_SET_ABSBIT, code); }
int main(int argc, char **argv) {
    int wait_s = argc > 1 ? atoi(argv[1]) : 3;
    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK); if (fd < 0) { perror("/dev/uinput"); return 2; }
    ioctl(fd, UI_SET_EVBIT, EV_KEY); ioctl(fd, UI_SET_EVBIT, EV_ABS); ioctl(fd, UI_SET_EVBIT, EV_SYN);
    int keys[] = {BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR}; for (unsigned i = 0; i < sizeof keys / sizeof *keys; i++) ioctl(fd, UI_SET_KEYBIT, keys[i]);
    absrange(ABS_X, -32768, 32767); absrange(ABS_Y, -32768, 32767); absrange(ABS_RX, -32768, 32767); absrange(ABS_RY, -32768, 32767); absrange(ABS_Z, 0, 255); absrange(ABS_RZ, 0, 255); absrange(ABS_HAT0X, -1, 1); absrange(ABS_HAT0Y, -1, 1);
    struct uinput_setup us; memset(&us, 0, sizeof us); us.id.bustype = BUS_USB; us.id.vendor = 0x045e; us.id.product = 0x028e; us.id.version = 1; strcpy(us.name, "Celori Test Pad");
    if (ioctl(fd, UI_DEV_SETUP, &us) || ioctl(fd, UI_DEV_CREATE)) { perror("create"); return 3; }
    printf("uinput_feeder: virtual gamepad created, waiting %d s for the reader\n", wait_s); fflush(stdout); sleep(wait_s);
    ev(EV_KEY, BTN_SOUTH, 1); syn(); ev(EV_KEY, BTN_SOUTH, 0); syn();
    ev(EV_ABS, ABS_X, 16384); syn(); ev(EV_ABS, ABS_X, -32768); syn(); ev(EV_ABS, ABS_Y, -32768); syn();
    ev(EV_ABS, ABS_RZ, 255); syn(); ev(EV_ABS, ABS_HAT0X, 1); syn(); ev(EV_ABS, ABS_HAT0X, 0); syn();
    ev(EV_KEY, BTN_START, 1); syn(); ev(EV_KEY, BTN_START, 0); syn(); ev(EV_ABS, ABS_X, 0); syn();
    sleep(1); ioctl(fd, UI_DEV_DESTROY); close(fd); puts("uinput_feeder: script sent"); return 0;
}
