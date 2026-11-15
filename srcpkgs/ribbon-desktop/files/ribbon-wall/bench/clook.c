/* clook W H S OUT: the Ribbon look's gradient + AA stripes per pixel in C,
 * PNG via zlib level 6: a C baseline for look.tcl (no wordmark). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
static void chunk(FILE *f, const char *t, const unsigned char *d, unsigned n) {
	unsigned char b[4] = {n >> 24, n >> 16, n >> 8, n}; fwrite(b, 1, 4, f); fwrite(t, 1, 4, f); fwrite(d, 1, n, f);
	uLong c = crc32(crc32(0, (const Bytef *)t, 4), d, n); unsigned char cb[4] = {c >> 24, c >> 16, c >> 8, c}; fwrite(cb, 1, 4, f);
}
int main(int argc, char **argv) {
	int W = atoi(argv[1]), H = atoi(argv[2]); double S = atof(argv[3]);
	double k = M_SQRT1_2, L = (W + H) * k, P = 150 * S, Wd = 44 * S, O = 106 * S, h = k;
	size_t rs = 1 + 3 * (size_t)W; unsigned char *raw = malloc(rs * H);
	double t0[3] = {0x2B, 0x28, 0x25}, t1[3] = {0x12, 0x11, 0x10}, sc = 255, sa = 0.03;
	for (int y = 0; y < H; y++) {
		unsigned char *r = raw + rs * y; r[0] = 0;
		double t = (y + 0.5) / H, base[3];
		for (int c = 0; c < 3; c++) base[c] = t0[c] + (t1[c] - t0[c]) * t;
		for (int x = 0; x < W; x++) {
			double pc = (x + 0.5 - W / 2.0) * k - (y + 0.5 - H / 2.0) * k + L / 2;
			double n = floor((pc - O) / P), a = O + n * P, b = a + Wd, cov = fmax(0, fmin(pc + h, b) - fmax(pc - h, a)) / (2 * h);
			double a2 = a + P, b2 = b + P; cov += fmax(0, fmin(pc + h, b2) - fmax(pc - h, a2)) / (2 * h);
			for (int c = 0; c < 3; c++) r[1 + 3 * x + c] = (unsigned char)lround(base[c] + (sc - base[c]) * sa * cov);
		}
	}
	uLongf zn = compressBound(rs * H); unsigned char *z = malloc(zn);
	compress2(z, &zn, raw, rs * H, 6);
	FILE *f = fopen(argv[4], "wb"); fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	unsigned char ih[13] = {W >> 24, W >> 16, W >> 8, W, H >> 24, H >> 16, H >> 8, H, 8, 2, 0, 0, 0};
	chunk(f, "IHDR", ih, 13); chunk(f, "IDAT", z, zn); chunk(f, "IEND", NULL, 0); fclose(f);
	return 0;
}
