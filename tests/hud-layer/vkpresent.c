/* vkpresent.c - a stand-in Vulkan game for tests/hud-layer/run.sh: presents FRAMES frames, one every MS milliseconds,
 * on a VK_EXT_headless_surface swapchain (no window system needed), so the Ribbon frame layer has presents to time.
 *   vkpresent FRAMES MS [RECREATE]   RECREATE: make a new swapchain (the old one retired) after that many frames
 * Exit 0 when every frame was presented, 77 when no Vulkan driver here offers headless presentation (the test skips),
 * 1 on another failure. Prints "presented N" at the end. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CHECK(x, what) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s: %d\n", what, r_); exit(1); } } while (0)

static void sleep_ms(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	while (nanosleep(&ts, &ts) < 0) {}
}

int main(int argc, char **argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 60;
	long ms = argc > 2 ? atol(argv[2]) : 10;
	int recreate = argc > 3 ? atoi(argv[3]) : 0;
	const char *iext[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME };
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vkpresent", .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
		.enabledExtensionCount = 2, .ppEnabledExtensionNames = iext };
	VkInstance inst;
	VkResult r = vkCreateInstance(&ici, NULL, &inst);
	if (r == VK_ERROR_EXTENSION_NOT_PRESENT || r == VK_ERROR_INCOMPATIBLE_DRIVER || r == VK_ERROR_INITIALIZATION_FAILED) {
		fprintf(stderr, "no headless Vulkan here (%d)\n", r);
		return 77;
	}
	CHECK(r, "vkCreateInstance");

	PFN_vkCreateHeadlessSurfaceEXT mk = (PFN_vkCreateHeadlessSurfaceEXT)vkGetInstanceProcAddr(inst, "vkCreateHeadlessSurfaceEXT");
	if (!mk) { fprintf(stderr, "no vkCreateHeadlessSurfaceEXT\n"); return 77; }
	VkHeadlessSurfaceCreateInfoEXT hci = { .sType = VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT };
	VkSurfaceKHR surf;
	CHECK(mk(inst, &hci, NULL, &surf), "vkCreateHeadlessSurfaceEXT");

	uint32_t npd = 0;
	vkEnumeratePhysicalDevices(inst, &npd, NULL);
	if (!npd) { fprintf(stderr, "no Vulkan device\n"); return 77; }
	VkPhysicalDevice *pds = calloc(npd, sizeof *pds);
	vkEnumeratePhysicalDevices(inst, &npd, pds);
	VkPhysicalDevice pd = VK_NULL_HANDLE;
	uint32_t qf = 0;
	for (uint32_t i = 0; i < npd && !pd; i++) {
		uint32_t nq = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(pds[i], &nq, NULL);
		VkQueueFamilyProperties *qp = calloc(nq, sizeof *qp);
		vkGetPhysicalDeviceQueueFamilyProperties(pds[i], &nq, qp);
		for (uint32_t q = 0; q < nq; q++) {
			VkBool32 ok = VK_FALSE;
			vkGetPhysicalDeviceSurfaceSupportKHR(pds[i], q, surf, &ok);
			if (ok && (qp[q].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { pd = pds[i]; qf = q; break; }
		}
		free(qp);
	}
	free(pds);
	if (!pd) { fprintf(stderr, "no device presents to a headless surface\n"); return 77; }

	float prio = 1;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qf, .queueCount = 1, .pQueuePriorities = &prio };
	const char *dext[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
	VkDevice dev;
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev), "vkCreateDevice");
	VkQueue queue;
	vkGetDeviceQueue(dev, qf, 0, &queue);
	/* the swapchain calls through vkGetDeviceProcAddr, as games do */
	PFN_vkCreateSwapchainKHR create_sc = (PFN_vkCreateSwapchainKHR)vkGetDeviceProcAddr(dev, "vkCreateSwapchainKHR");
	PFN_vkDestroySwapchainKHR destroy_sc = (PFN_vkDestroySwapchainKHR)vkGetDeviceProcAddr(dev, "vkDestroySwapchainKHR");
	PFN_vkGetSwapchainImagesKHR images = (PFN_vkGetSwapchainImagesKHR)vkGetDeviceProcAddr(dev, "vkGetSwapchainImagesKHR");
	PFN_vkAcquireNextImageKHR acquire = (PFN_vkAcquireNextImageKHR)vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR");
	PFN_vkQueuePresentKHR present = (PFN_vkQueuePresentKHR)vkGetDeviceProcAddr(dev, "vkQueuePresentKHR");
	if (!create_sc || !destroy_sc || !images || !acquire || !present) { fprintf(stderr, "no swapchain calls\n"); return 1; }

	VkSurfaceCapabilitiesKHR caps;
	CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &caps), "surface caps");
	uint32_t nf = 0;
	vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, NULL);
	VkSurfaceFormatKHR *fmts = calloc(nf ? nf : 1, sizeof *fmts);
	vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, fmts);
	VkSwapchainCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surf,
		.minImageCount = caps.minImageCount < 2 ? 2 : caps.minImageCount, .imageFormat = fmts[0].format,
		.imageColorSpace = fmts[0].colorSpace, .imageExtent = { 64, 64 }, .imageArrayLayers = 1,
		.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
		.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
		.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE };
	if (caps.maxImageCount && sci.minImageCount > caps.maxImageCount) sci.minImageCount = caps.maxImageCount;
	free(fmts);
	VkSwapchainKHR sc;
	CHECK(create_sc(dev, &sci, NULL, &sc), "vkCreateSwapchainKHR");

	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qf };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool), "command pool");
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(dev, &cai, &cb), "command buffer");
	VkSemaphoreCreateInfo semi = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
	VkSemaphore got, done;
	vkCreateSemaphore(dev, &semi, NULL, &got);
	vkCreateSemaphore(dev, &semi, NULL, &done);
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	vkCreateFence(dev, &fci, NULL, &fence);

	int presented = 0;
	for (int f = 0; f < frames; f++) {
		if (recreate && f == recreate) {
			VkSwapchainKHR old = sc;
			sci.oldSwapchain = old;
			CHECK(create_sc(dev, &sci, NULL, &sc), "recreate swapchain");
			vkQueueWaitIdle(queue);
			destroy_sc(dev, old, NULL);
		}
		uint32_t n = 0;
		images(dev, sc, &n, NULL);
		VkImage *imgs = calloc(n, sizeof *imgs);
		images(dev, sc, &n, imgs);
		uint32_t idx;
		CHECK(acquire(dev, sc, UINT64_MAX, got, VK_NULL_HANDLE, &idx), "acquire");
		VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
		vkResetCommandBuffer(cb, 0);
		vkBeginCommandBuffer(cb, &bi);
		VkImageMemoryBarrier b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0, .dstAccessMask = 0,
			.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
			.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = imgs[idx],
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &b);
		vkEndCommandBuffer(cb);
		VkPipelineStageFlags ws = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
		VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &got, .pWaitDstStageMask = &ws,
			.commandBufferCount = 1, .pCommandBuffers = &cb, .signalSemaphoreCount = 1, .pSignalSemaphores = &done };
		CHECK(vkQueueSubmit(queue, 1, &si, fence), "submit");
		VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &done,
			.swapchainCount = 1, .pSwapchains = &sc, .pImageIndices = &idx };
		CHECK(present(queue, &pi), "present");
		vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX);
		vkResetFences(dev, 1, &fence);
		free(imgs);
		presented++;
		sleep_ms(ms);
	}
	vkQueueWaitIdle(queue);
	destroy_sc(dev, sc, NULL);
	vkDestroyFence(dev, fence, NULL);
	vkDestroySemaphore(dev, got, NULL);
	vkDestroySemaphore(dev, done, NULL);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroySurfaceKHR(inst, surf, NULL);
	vkDestroyInstance(inst, NULL);
	printf("presented %d\n", presented);
	return presented == frames ? 0 : 1;
}
