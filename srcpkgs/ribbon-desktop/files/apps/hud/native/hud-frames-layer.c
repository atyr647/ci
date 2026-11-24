/* hud-frames-layer.c - libribbon-hud-frames.so: VK_LAYER_RIBBON_hud_frames, the Game HUD's frame source for Vulkan
 * games that do not run under gamescope (U23, hud-frames.tcl's "layer" producer).
 *
 * An implicit Vulkan layer (manifest: ribbon-hud-frames.json in the loader's implicit_layer.d). It passes every call
 * through and times vkQueuePresentKHR: the time between two presents of the newest swapchain is one frame time. The
 * frame times go to the HUD daemon's pipe, $RIBBON_HUD_FRAMES, else $XDG_RUNTIME_DIR/ribbon-hud-frames, as text lines
 *     pid=PID MS MS ...\n
 * (milliseconds, three decimals), one line every 50 ms or so. Each line is one write() under PIPE_BUF, so the lines of
 * several games never mix. The path must be a FIFO (the daemon makes it and keeps it open); a regular file is written
 * only when RIBBON_HUD_FRAMES names it. Nothing is written while no daemon reads (the open fails with ENXIO; it is
 * tried again once a second), and a full pipe drops the line: a game never waits on the HUD. SIGPIPE is blocked
 * around the write, so a daemon that goes away cannot kill the game.
 *
 * Off with RIBBON_HUD_FRAMES_DISABLE=1 (the manifest's disable_environment). gamescope itself is skipped: it presents
 * the composited picture, and its own frame statistics come through its --stats-path pipe. A privileged program (setuid,
 * setcap: secure execution) is skipped too: its environment is its caller's, so the paths in it are not to be written. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#define EXPORT __attribute__((visibility("default")))
#define LAYER_NAME "VK_LAYER_RIBBON_hud_frames"

/* ---------------- dispatch tables, keyed by the loader's dispatch pointer ---------------- */

typedef void *dkey;
static dkey key_of(const void *handle) { return *(dkey *)handle; }

struct inst {
	dkey key;
	VkInstance instance;
	PFN_vkGetInstanceProcAddr gipa;
	PFN_vkDestroyInstance destroy;
	struct inst *next;
};

struct dev {
	dkey key;
	VkDevice device;
	PFN_vkGetDeviceProcAddr gdpa;
	PFN_vkDestroyDevice destroy;
	PFN_vkCreateSwapchainKHR create_swapchain;
	PFN_vkDestroySwapchainKHR destroy_swapchain;
	PFN_vkQueuePresentKHR present;
	struct dev *next;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct inst *insts;
static struct dev *devs;

static struct inst *inst_of(dkey k)
{
	for (struct inst *i = insts; i; i = i->next) if (i->key == k) return i;
	return NULL;
}
static struct dev *dev_of(dkey k)
{
	for (struct dev *d = devs; d; d = d->next) if (d->key == k) return d;
	return NULL;
}

/* ---------------- the frame times ---------------- */

static int enabled = -1;           /* -1: not decided yet */
static VkSwapchainKHR timed;       /* the swapchain whose presents are timed: the newest */
static int64_t last_ns;            /* its last present, CLOCK_MONOTONIC ns (0: none yet) */
static char line[3072];            /* the frame times since the last write, each " MS" */
static size_t line_len;
static int64_t line_since;         /* when the first frame time of the pending line came */
static int out_fd = -1;
static int64_t out_retry;          /* do not try to open again before this */
static char out_path[4096];
static int out_explicit;           /* RIBBON_HUD_FRAMES named the path */

static int64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void decide(void)
{
	if (enabled >= 0) return;
	enabled = 0;
	const char *off = getenv("RIBBON_HUD_FRAMES_DISABLE");
	if (off && *off && strcmp(off, "0")) return;
	/* gamescope composites other programs' pictures: its presents are not a game's frames */
	if (!strcmp(program_invocation_short_name, "gamescope")) return;
	/* secure_getenv: NULL in a setuid or setcap program, whose caller would otherwise name the file it appends to */
	const char *p = secure_getenv("RIBBON_HUD_FRAMES");
	if (p && *p) {
		out_explicit = 1;
		snprintf(out_path, sizeof out_path, "%s", p);
	} else {
		const char *rt = secure_getenv("XDG_RUNTIME_DIR");
		if (!rt || !*rt) return;
		snprintf(out_path, sizeof out_path, "%s/ribbon-hud-frames", rt);
	}
	line_len = 0;
	enabled = 1;
}

static void out_close(int64_t now)
{
	if (out_fd >= 0) close(out_fd);
	out_fd = -1;
	out_retry = now + 1000000000;
}

static int out_open(int64_t now)
{
	if (out_fd >= 0) return 1;
	if (now < out_retry) return 0;
	out_retry = now + 1000000000;
	struct stat st;
	if (stat(out_path, &st) < 0) return 0;
	if (!S_ISFIFO(st.st_mode) && !(out_explicit && S_ISREG(st.st_mode))) return 0;
	/* a FIFO with no reader: ENXIO, and the next try is in a second */
	out_fd = open(out_path, O_WRONLY | O_NONBLOCK | O_CLOEXEC | (S_ISREG(st.st_mode) ? O_APPEND : 0));
	return out_fd >= 0;
}

/* one write of the pending line, with SIGPIPE blocked: a reader that left gives EPIPE, not a signal */
static void flush_line(int64_t now)
{
	if (!line_len) return;
	/* the process id is taken now: a forked child's lines are its own */
	char out[sizeof line + 32];
	size_t len = (size_t)snprintf(out, sizeof out, "pid=%ld%.*s\n", (long)getpid(), (int)line_len, line);
	if (out_open(now)) {
		sigset_t pipe_set, old;
		sigemptyset(&pipe_set);
		sigaddset(&pipe_set, SIGPIPE);
		pthread_sigmask(SIG_BLOCK, &pipe_set, &old);
		sigset_t before;
		sigpending(&before);
		ssize_t n = write(out_fd, out, len);
		int err = errno;
		if (n < 0 && err == EPIPE && !sigismember(&before, SIGPIPE)) {
			/* take the SIGPIPE this write raised, so it is not delivered when the mask is restored */
			struct timespec zero = { 0, 0 };
			sigtimedwait(&pipe_set, NULL, &zero);
		}
		pthread_sigmask(SIG_SETMASK, &old, NULL);
		if (n < 0 && err != EAGAIN && err != EINTR) out_close(now);
	}
	/* a full pipe (EAGAIN) or no reader: the line is dropped */
	line_len = 0;
}

static void frame(VkSwapchainKHR sc)
{
	if (sc != timed) return;
	int64_t t = now_ns();
	if (last_ns) {
		double ms = (t - last_ns) / 1e6;
		/* a pause (a minimised or stopped game) is not a frame */
		if (ms > 0 && ms < 1000) {
			if (!line_len) line_since = t;
			if (line_len + 16 < sizeof line)
				line_len += (size_t)snprintf(line + line_len, sizeof line - line_len, " %.3f", ms);
		}
	}
	last_ns = t;
	if (line_len && (t - line_since >= 50000000 || line_len + 32 >= sizeof line)) flush_line(t);
}

/* ---------------- the intercepted calls ---------------- */

static VKAPI_ATTR VkResult VKAPI_CALL l_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out)
{
	VkLayerInstanceCreateInfo *chain = (VkLayerInstanceCreateInfo *)ci->pNext;
	while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
		chain = (VkLayerInstanceCreateInfo *)chain->pNext;
	if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
	PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
	PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
	if (!create) return VK_ERROR_INITIALIZATION_FAILED;
	chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
	VkResult r = create(ci, a, out);
	if (r != VK_SUCCESS) return r;
	struct inst *i = calloc(1, sizeof *i);
	if (!i) return VK_SUCCESS;
	i->key = key_of(*out);
	i->instance = *out;
	i->gipa = gipa;
	i->destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
	pthread_mutex_lock(&lock);
	decide();
	i->next = insts;
	insts = i;
	pthread_mutex_unlock(&lock);
	return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL l_DestroyInstance(VkInstance instance, const VkAllocationCallbacks *a)
{
	if (!instance) return;
	pthread_mutex_lock(&lock);
	struct inst **pp = &insts, *i = NULL;
	for (; *pp; pp = &(*pp)->next) if ((*pp)->key == key_of(instance)) { i = *pp; *pp = i->next; break; }
	pthread_mutex_unlock(&lock);
	if (i) {
		if (i->destroy) i->destroy(instance, a);
		free(i);
	}
}

static VKAPI_ATTR VkResult VKAPI_CALL l_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out)
{
	VkLayerDeviceCreateInfo *chain = (VkLayerDeviceCreateInfo *)ci->pNext;
	while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
		chain = (VkLayerDeviceCreateInfo *)chain->pNext;
	if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
	PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
	PFN_vkGetDeviceProcAddr gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
	pthread_mutex_lock(&lock);
	struct inst *i = inst_of(key_of(pd));
	VkInstance instance = i ? i->instance : VK_NULL_HANDLE;
	pthread_mutex_unlock(&lock);
	PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance, "vkCreateDevice");
	if (!create) return VK_ERROR_INITIALIZATION_FAILED;
	chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
	VkResult r = create(pd, ci, a, out);
	if (r != VK_SUCCESS) return r;
	struct dev *d = calloc(1, sizeof *d);
	if (!d) return VK_SUCCESS;
	d->key = key_of(*out);
	d->device = *out;
	d->gdpa = gdpa;
	d->destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
	/* NULL when the application did not enable VK_KHR_swapchain: then this layer hands out none either */
	d->create_swapchain = (PFN_vkCreateSwapchainKHR)gdpa(*out, "vkCreateSwapchainKHR");
	d->destroy_swapchain = (PFN_vkDestroySwapchainKHR)gdpa(*out, "vkDestroySwapchainKHR");
	d->present = (PFN_vkQueuePresentKHR)gdpa(*out, "vkQueuePresentKHR");
	pthread_mutex_lock(&lock);
	d->next = devs;
	devs = d;
	pthread_mutex_unlock(&lock);
	return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL l_DestroyDevice(VkDevice device, const VkAllocationCallbacks *a)
{
	if (!device) return;
	pthread_mutex_lock(&lock);
	struct dev **pp = &devs, *d = NULL;
	for (; *pp; pp = &(*pp)->next) if ((*pp)->key == key_of(device)) { d = *pp; *pp = d->next; break; }
	pthread_mutex_unlock(&lock);
	if (d) {
		if (d->destroy) d->destroy(device, a);
		free(d);
	}
}

static VKAPI_ATTR VkResult VKAPI_CALL l_CreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSwapchainKHR *out)
{
	pthread_mutex_lock(&lock);
	struct dev *d = dev_of(key_of(device));
	PFN_vkCreateSwapchainKHR next = d ? d->create_swapchain : NULL;
	pthread_mutex_unlock(&lock);
	if (!next) return VK_ERROR_INITIALIZATION_FAILED;
	VkResult r = next(device, ci, a, out);
	if (r == VK_SUCCESS) {
		pthread_mutex_lock(&lock);
		/* the newest swapchain is the game's picture (a resize makes a new one, from the old one: the timing goes on) */
		if (!(ci->oldSwapchain && ci->oldSwapchain == timed)) last_ns = 0;
		timed = *out;
		pthread_mutex_unlock(&lock);
	}
	return r;
}

static VKAPI_ATTR void VKAPI_CALL l_DestroySwapchainKHR(VkDevice device, VkSwapchainKHR sc, const VkAllocationCallbacks *a)
{
	pthread_mutex_lock(&lock);
	struct dev *d = dev_of(key_of(device));
	PFN_vkDestroySwapchainKHR next = d ? d->destroy_swapchain : NULL;
	if (sc == timed) {
		/* the game's last frame times go out before its picture does */
		if (enabled == 1) flush_line(now_ns());
		timed = VK_NULL_HANDLE;
		last_ns = 0;
	}
	pthread_mutex_unlock(&lock);
	if (next) next(device, sc, a);
}

static VKAPI_ATTR VkResult VKAPI_CALL l_QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pi)
{
	pthread_mutex_lock(&lock);
	struct dev *d = dev_of(key_of(queue));
	PFN_vkQueuePresentKHR next = d ? d->present : NULL;
	if (enabled == 1 && pi)
		for (uint32_t k = 0; k < pi->swapchainCount; k++) frame(pi->pSwapchains[k]);
	pthread_mutex_unlock(&lock);
	if (!next) return VK_ERROR_DEVICE_LOST;
	return next(queue, pi);
}

/* ---------------- the entry points ---------------- */

static PFN_vkVoidFunction device_func(const char *name, struct dev *d)
{
	if (!strcmp(name, "vkGetDeviceProcAddr")) return NULL;   /* handled by the caller */
	if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)l_DestroyDevice;
	/* the swapchain calls only when the next layer or driver has them for this device */
	if (!strcmp(name, "vkCreateSwapchainKHR")) return d && !d->create_swapchain ? NULL : (PFN_vkVoidFunction)l_CreateSwapchainKHR;
	if (!strcmp(name, "vkDestroySwapchainKHR")) return d && !d->destroy_swapchain ? NULL : (PFN_vkVoidFunction)l_DestroySwapchainKHR;
	if (!strcmp(name, "vkQueuePresentKHR")) return d && !d->present ? NULL : (PFN_vkVoidFunction)l_QueuePresentKHR;
	return NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL l_GetDeviceProcAddr(VkDevice device, const char *name);

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL l_GetInstanceProcAddr(VkInstance instance, const char *name)
{
	if (!name) return NULL;
	if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)l_GetInstanceProcAddr;
	if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)l_CreateInstance;
	if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)l_DestroyInstance;
	if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)l_CreateDevice;
	if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)l_GetDeviceProcAddr;
	if (!instance) return NULL;
	PFN_vkVoidFunction f = device_func(name, NULL);
	if (f) return f;
	pthread_mutex_lock(&lock);
	struct inst *i = inst_of(key_of(instance));
	PFN_vkGetInstanceProcAddr next = i ? i->gipa : NULL;
	pthread_mutex_unlock(&lock);
	return next ? next(instance, name) : NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL l_GetDeviceProcAddr(VkDevice device, const char *name)
{
	if (!name || !device) return NULL;
	if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)l_GetDeviceProcAddr;
	pthread_mutex_lock(&lock);
	struct dev *d = dev_of(key_of(device));
	PFN_vkGetDeviceProcAddr next = d ? d->gdpa : NULL;
	PFN_vkVoidFunction f = device_func(name, d);
	int ours = !strcmp(name, "vkDestroyDevice") || !strcmp(name, "vkCreateSwapchainKHR") || !strcmp(name, "vkDestroySwapchainKHR") ||
		!strcmp(name, "vkQueuePresentKHR");
	pthread_mutex_unlock(&lock);
	if (ours) return f;
	return next ? next(device, name) : NULL;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v)
{
	if (!v || v->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
	if (v->loaderLayerInterfaceVersion >= 2) {
		v->pfnGetInstanceProcAddr = l_GetInstanceProcAddr;
		v->pfnGetDeviceProcAddr = l_GetDeviceProcAddr;
		v->pfnGetPhysicalDeviceProcAddr = NULL;
	}
	if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
	return VK_SUCCESS;
}
