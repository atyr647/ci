/* genclip W H N : raw yuv420p frames on stdout; frame n's gradient phase is
 * n/N so frame N-1 -> frame 0 continues exactly; a 16-bit barcode of n in
 * the top-left (16 blocks of 24x24, Y=16 or 235) identifies each frame. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int c, char **v) {
	int W = atoi(v[1]), H = atoi(v[2]), N = atoi(v[3]);
	unsigned char *f = malloc(W * H * 3 / 2), *u = f + W * H, *vv = u + W * H / 4;
	float *row = malloc(W * sizeof *row);
	for (int n = 0; n < N; n++) {
		double ph = (double)n / N;
		for (int x = 0; x < W; x++) row[x] = sinf(2 * M_PI * ((double)x / W + ph));
		for (int y = 0; y < H; y++) {
			double py = sin(2 * M_PI * ((double)y / H - ph));
			unsigned char *p = f + y * W;
			for (int x = 0; x < W; x++) p[x] = 128 + 50 * row[x] + 40 * py;
		}
		for (int y = 0; y < H / 2; y++)
			for (int x = 0; x < W / 2; x++) {
				u[y * W / 2 + x] = 128 + 60 * row[2 * x];
				vv[y * W / 2 + x] = 128 + 60 * sin(2 * M_PI * (2.0 * y / H + ph));
			}
		for (int b = 0; b < 16; b++) {
			int on = (n >> b) & 1;
			for (int y = 0; y < 24; y++) memset(f + y * W + b * 24, on ? 235 : 16, 24);
			for (int y = 0; y < 12; y++) { memset(u + y * W / 2 + b * 12, 128, 12); memset(vv + y * W / 2 + b * 12, 128, 12); }
		}
		fwrite(f, 1, W * H * 3 / 2, stdout);
	}
	return 0;
}
