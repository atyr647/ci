// Decompression speed of the codecs that could hold code or assets inside the file, built with the same compiler as the product (cosmocc, both architectures, one fat file) so that
// the numbers are what the shipped decoder would do on each OS.  usage: packbench <manifest>   manifest line: codec file origsize crc32hex label
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <zlib.h>
#include "zstd.h"
#include "lz4frame.h"
#ifdef HAVE_XZ
#include "xz.h"
#endif

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static unsigned char *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(sz ? sz : 1); if (fread(b, 1, sz, f) != (size_t)sz) { fclose(f); return NULL; } fclose(f); *n = sz; return b;
}
static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }

static int dec(const char *codec, const unsigned char *in, size_t inn, unsigned char *out, size_t outn) {
    if (!strncmp(codec, "zstd", 4)) { size_t r = ZSTD_decompress(out, outn, in, inn); return !ZSTD_isError(r) && r == outn; }
    if (!strncmp(codec, "lz4", 3)) {
        LZ4F_dctx *c; LZ4F_createDecompressionContext(&c, LZ4F_VERSION);
        const unsigned char *s = in; size_t sl = inn; unsigned char *d = out; size_t dl = outn; int ok = 1;
        while (sl) {
            size_t ds = dl, ss = sl; size_t r = LZ4F_decompress(c, d, &ds, s, &ss, NULL);
            if (LZ4F_isError(r)) { ok = 0; break; }
            s += ss; sl -= ss; d += ds; dl -= ds; if (r == 0) break;
        }
        LZ4F_freeDecompressionContext(c); return ok && dl == 0;
    }
    if (!strncmp(codec, "gzip", 4)) {
        z_stream z; memset(&z, 0, sizeof z); if (inflateInit2(&z, 15 + 16) != Z_OK) return 0;
        z.next_in = (Bytef *)in; z.avail_in = inn; z.next_out = out; z.avail_out = outn;
        int r = inflate(&z, Z_FINISH); inflateEnd(&z); return r == Z_STREAM_END && z.total_out == outn;
    }
#ifdef HAVE_XZ
    if (!strncmp(codec, "xz", 2)) {
        struct xz_dec *d = xz_dec_init(XZ_DYNALLOC, 1u << 27); if (!d) return 0;
        struct xz_buf b = { in, 0, inn, out, 0, outn };
        enum xz_ret r = xz_dec_run(d, &b); xz_dec_end(d); return r == XZ_STREAM_END && b.out_pos == outn;
    }
#endif
    return 0;
}

int main(int argc, char **argv) {
#ifdef HAVE_XZ
    xz_crc32_init();
#endif
    FILE *m = fopen(argv[1], "r"); if (!m) { perror("manifest"); return 1; }
    char codec[64], file[512], label[256]; unsigned long long origsize; unsigned crc;
    printf("PACKBENCH-VERSION zstd=%s lz4=%s zlib=%s\n", ZSTD_versionString(), LZ4_versionString(), zlibVersion());
    while (fscanf(m, "%63s %511s %llu %x %255s", codec, file, &origsize, &crc, label) == 5) {
        size_t inn; unsigned char *in = slurp(file, &inn); if (!in) { printf("PACKBENCH %s %s MISSING\n", codec, label); continue; }
        unsigned char *out = malloc(origsize);
        if (!dec(codec, in, inn, out, origsize)) { printf("PACKBENCH %s %s DECODE-FAILED\n", codec, label); continue; }
        unsigned got = crc32(0, out, origsize);
        if (got != crc) { printf("PACKBENCH %s %s CRC-MISMATCH\n", codec, label); continue; }
        double v[64]; int n = 0; double t0 = now(), tot = 0;
        while (n < 64 && (tot < 0.6 || n < 5)) { double a = now(); dec(codec, in, inn, out, origsize); v[n++] = now() - a; tot = now() - t0; if (n >= 40) break; }
        qsort(v, n, sizeof(double), cmpd);
        double best = v[0], med = v[n / 2];
        // first-touch cost: a fresh buffer (page faults included), as a loader that decodes into newly mapped memory would see
        unsigned char *fresh = malloc(origsize); double a = now(); dec(codec, in, inn, fresh, origsize); double cold = now() - a;
        printf("PACKBENCH %s %s comp=%zu orig=%llu best_MBps=%.0f median_MBps=%.0f fresh_MBps=%.0f best_ms=%.2f runs=%d\n", codec, label, inn, origsize,
               origsize / best / 1e6, origsize / med / 1e6, origsize / cold / 1e6, best * 1e3, n);
        fflush(stdout); free(in); free(out); free(fresh);
    }
    return 0;
}
