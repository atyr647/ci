// mkkitfs -- the FUSE server for Ribbon kit files, and the command line tools around its reader.
// See docs/MKKITFS.md.  Usage: mkkitfs help.
#include "confine.h"
#include "kit.h"
#include "server.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

static const char *kUsage =
  "usage: mkkitfs COMMAND ...\n"
  "  serve --mountpoint DIR [options]  the data path of mkkitfsd (the session server, in Tcl): one FUSE\n"
  "                                  mount; attach/detach orders on stdin, replies on stdout\n"
  "      --cache MiB                 decoded-chunk cache (default 64)\n"
  "      --threads N                 most FUSE worker threads (default 16)\n"
  "      --check-timeout SECONDS     how long the isolated first parse of a kit may take (default 30)\n"
  "      --allow-other               let other users through (needs user_allow_other)\n"
  "      --log FILE                  log here instead of stderr\n"
  "  open [--force] [--signed] [--keys FILE] KIT   open and check a kit: 'open ok' or 'open fail CODE'\n"
  "  expect [--keys FILE] KIT        what kit/kitfmt/tests/golden/*.expect lists, for this kit\n"
  "  index [--force] KIT             the index (what the root hashes)\n"
  "  info [--keys FILE] KIT          identity, seal, signature, manifest\n"
  "  verify [--force] KIT            every chunk, the image, the header, the root\n"
  "  ls KIT                          every entry\n"
  "  cat KIT PATH [OFFSET [LENGTH]]  a file's bytes, each chunk checked first\n"
  "  extract KIT DESTDIR             everything, refusing links that leave DESTDIR\n"
  "  probe KIT                       frame and seal only (no Metakit)\n"
  "exit codes: 0 ok, 1 refused or failed (the code is printed), 2 usage\n";

static int usage() { fputs(kUsage, stderr); return 2; }

static std::vector<std::string> readKeys(const std::string &file) {
  std::vector<std::string> keys;
  std::ifstream in(file);
  if (!in) { fprintf(stderr, "mkkitfs: cannot read %s\n", file.c_str()); exit(2); }
  std::string line;
  while (std::getline(in, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (line.empty() || line[0] == '#' || !line.compare(0, 18, "untrusted comment:")) continue;
    keys.push_back(line);
  }
  return keys;
}

struct Args {
  kit::OpenOptions opt;
  std::vector<std::string> pos;
};

static Args parse(int argc, char **argv, int from) {
  Args a;
  for (int i = from; i < argc; ++i) {
    std::string s = argv[i];
    if (s == "--force") a.opt.force = true;
    else if (s == "--signed") a.opt.requireSigned = true;
    else if (s == "--keys" && i + 1 < argc) { auto k = readKeys(argv[++i]); a.opt.keys.insert(a.opt.keys.end(), k.begin(), k.end()); }
    else if (s == "--") { for (++i; i < argc; ++i) a.pos.push_back(argv[i]); }
    else a.pos.push_back(s);
  }
  return a;
}

static int refuse(const kit::Error &e, const char *what = "open") {
  printf("%s fail %s\n", what, e.code.c_str());
  fprintf(stderr, "mkkitfs: %s: %s\n", e.code.c_str(), e.msg.c_str());
  return 1;
}

static std::string contentHash(const kit::Kit &k, uint32_t node, const char *&err) {
  const kit::Node &n = k.nodes[node];
  std::vector<uint8_t> buf(n.size);
  err = k.readFile(node, 0, n.size, buf.data());
  uint8_t md[32];
  kit::sha256(buf.data(), buf.size(), md);
  return kit::hex(md, 32);
}

static std::vector<uint32_t> sortedNodes(const kit::Kit &k) {
  std::vector<std::pair<std::string, uint32_t>> v;
  for (uint32_t i = 1; i < k.nodes.size(); ++i) v.emplace_back(k.pathOf(i), i);
  std::sort(v.begin(), v.end());
  std::vector<uint32_t> out;
  for (auto &x : v) out.push_back(x.second);
  return out;
}

static int cmdExpect(const Args &a) {
  if (a.pos.size() != 1) return usage();
  std::unique_ptr<kit::Kit> k;
  try { k = kit::Kit::open(a.pos[0], a.opt); } catch (const kit::Error &e) { return refuse(e); }
  printf("open ok\n");
  printf("kind %s\nname %s\nversion %s\nroot %s\nheader %llu\nentries %llu\nchunks %llu\nstored %llu\nbytes %llu\n",
         k->field("kind").c_str(), k->field("name").c_str(), k->field("version").c_str(), k->root.c_str(),
         (unsigned long long)k->frame.header, (unsigned long long)k->nEntries, (unsigned long long)k->nChunks,
         (unsigned long long)k->stored, (unsigned long long)k->bytes);
  std::string rq;
  for (auto &x : k->features) { if (!rq.empty()) rq += ' '; rq += x; }
  printf("format %d.%d\nrequires %s\nsignature %s %s\n", k->major, k->minor, rq.c_str(), k->sig.state.c_str(), k->sig.keyid.c_str());
  if (k->image.present)
    printf("image %s %llu %llu %s %s\n", k->image.fs.c_str(), (unsigned long long)k->image.offset, (unsigned long long)k->image.length,
           k->image.verity.c_str(), k->image.salt.c_str());
  int rc = 0;
  for (uint32_t i : sortedNodes(*k)) {
    const kit::Node &n = k->nodes[i];
    std::string p = kit::tclElement(k->pathOf(i));
    if (n.type == kit::T_DIR) printf("entry %s dir %u\n", p.c_str(), n.mode);
    else if (n.type == kit::T_LINK) printf("entry %s link %u %s\n", p.c_str(), n.mode, kit::tclElement(k->linkOf(n)).c_str());
    else {
      const char *err = "";
      std::string h = contentHash(*k, i, err);
      uint64_t st = 0;
      for (uint32_t c = 0; c < n.nchunks; ++c) st += k->chunks[n.chunk0 + c].zlen;
      unsigned nch = n.codec == kit::C_CLASSIC ? 0 : n.nchunks;
      if (*err) { printf("entry %s read fail %s\n", p.c_str(), err); rc = 1; continue; }
      printf("entry %s file %u %llu %s %u %llu %s\n", p.c_str(), n.mode, (unsigned long long)n.size, kit::codecName(n.codec), nch,
             (unsigned long long)st, h.c_str());
    }
  }
  kit::Kit::Verify v = k->verify();
  printf("verify ok %d image %s\n", v.ok ? 1 : 0, v.image.c_str());
  return rc;
}

static void printVerify(const kit::Kit::Verify &v) {
  if (v.ok) { printf("verify ok 1 image %s\n", v.image.c_str()); return; }
  for (auto &b : v.bad) {
    if (b.path.empty()) printf("verify fail %s\n", b.what.c_str());
    else {
      printf("verify fail %s %s\n", kit::tclElement(b.path).c_str(), b.what.c_str());
      fprintf(stderr, "mkkitfs: %s chunk %s: %s\n", b.path.c_str(), b.what.c_str(), b.detail.c_str());
    }
  }
}

static int cmdInfo(const Args &a) {
  if (a.pos.size() != 1) return usage();
  std::unique_ptr<kit::Kit> k;
  try { k = kit::Kit::open(a.pos[0], a.opt); } catch (const kit::Error &e) { return refuse(e); }
  printf("kind %s\nname %s\nversion %s\nformat %d.%d\nwriter %s\nroot %s\nroot-state %s\nsignature %s\nkeyid %s\ncomment %s\n",
         k->field("kind").c_str(), k->field("name").c_str(), k->field("version").c_str(), k->major, k->minor, k->writer.c_str(),
         k->root.c_str(), k->rootOk ? "ok" : "mismatch", k->sig.state.c_str(), k->sig.keyid.c_str(), k->sig.comment.c_str());
  printf("header %llu\nseal %llu %llu\nstore %llu %llu%s\n", (unsigned long long)k->frame.header, (unsigned long long)k->frame.sealStart,
         (unsigned long long)k->frame.sealSize, (unsigned long long)k->frame.storeStart, (unsigned long long)k->frame.size,
         k->frame.wide ? " wide" : "");
  printf("entries %llu\nchunks %llu\nstored %llu\nbytes %llu\n", (unsigned long long)k->nEntries, (unsigned long long)k->nChunks,
         (unsigned long long)k->stored, (unsigned long long)k->bytes);
  for (auto &f : k->fields) printf("manifest %s %s\n", f.first.c_str(), kit::esc(f.second).c_str());
  for (auto &r : k->needs) printf("need %s %s\n", r[0].c_str(), kit::esc(r[1]).c_str());
  for (auto &r : k->provides) printf("provide %s %s\n", r[0].c_str(), kit::esc(r[1]).c_str());
  for (auto &r : k->perms) printf("perm %s %s\n", r[0].c_str(), kit::esc(r[1]).c_str());
  for (auto &r : k->entries) printf("entry %s %s %s %s\n", kit::esc(r[0]).c_str(), kit::esc(r[1]).c_str(), kit::esc(r[2]).c_str(), r[3].c_str());
  for (auto &r : k->effects) printf("effect %s %s\n", r[0].c_str(), kit::esc(r[1]).c_str());
  if (k->image.present)
    printf("image %s %llu %llu %s %s\n", k->image.fs.c_str(), (unsigned long long)k->image.offset, (unsigned long long)k->image.length,
           k->image.verity.c_str(), k->image.salt.c_str());
  return 0;
}

static int cmdCat(const Args &a) {
  if (a.pos.size() < 2 || a.pos.size() > 4) return usage();
  std::unique_ptr<kit::Kit> k;
  try { k = kit::Kit::open(a.pos[0], a.opt); } catch (const kit::Error &e) { return refuse(e); }
  int64_t i = k->find(a.pos[1]);
  if (i < 0) { printf("read fail NOENT\n"); return 1; }
  const kit::Node &n = k->nodes[i];
  if (n.type != kit::T_FILE) { printf("read fail TYPE\n"); return 1; }
  uint64_t off = a.pos.size() > 2 ? strtoull(a.pos[2].c_str(), nullptr, 10) : 0;
  uint64_t len = a.pos.size() > 3 ? strtoull(a.pos[3].c_str(), nullptr, 10) : n.size;
  if (off > n.size) off = n.size;
  if (len > n.size - off) len = n.size - off;
  std::vector<uint8_t> buf(len);
  const char *e = k->readFile((uint32_t)i, off, len, buf.data());
  if (*e) { printf("read fail %s\n", e); fprintf(stderr, "mkkitfs: %s: %s\n", a.pos[1].c_str(), e); return 1; }
  fwrite(buf.data(), 1, buf.size(), stdout);
  return 0;
}

// a link must stay inside what is extracted (section 5.1, 11.8)
static bool linkStaysInside(const std::string &rel, const std::string &target) {
  if (target.empty() || target[0] == '/') return false;
  long depth = (long)std::count(rel.begin(), rel.end(), '/');
  size_t a = 0;
  while (a <= target.size()) {
    size_t b = target.find('/', a);
    if (b == std::string::npos) b = target.size();
    std::string part = target.substr(a, b - a);
    if (part == "..") { if (--depth < 0) return false; }
    else if (!part.empty() && part != ".") ++depth;
    a = b + 1;
  }
  return true;
}

static int cmdExtract(const Args &a) {
  if (a.pos.size() != 2) return usage();
  std::unique_ptr<kit::Kit> k;
  try { k = kit::Kit::open(a.pos[0], a.opt); } catch (const kit::Error &e) { return refuse(e); }
  std::string dest = a.pos[1];
  struct stat sb;
  if (stat(dest.c_str(), &sb) || !S_ISDIR(sb.st_mode)) { fprintf(stderr, "mkkitfs: %s is not a directory\n", dest.c_str()); return 2; }
  std::vector<uint32_t> order = sortedNodes(*k);
  for (uint32_t i : order) {
    std::string t = dest + "/" + k->pathOf(i);
    if (!lstat(t.c_str(), &sb)) { printf("extract fail EXISTS\n"); fprintf(stderr, "mkkitfs: %s already exists\n", t.c_str()); return 1; }
  }
  for (uint32_t i : order) {
    const kit::Node &n = k->nodes[i];
    if (n.type == kit::T_LINK && !linkStaysInside(k->pathOf(i), k->linkOf(n))) {
      printf("extract fail PATH\n");
      fprintf(stderr, "mkkitfs: %s: the link target '%s' leaves the extracted tree\n", k->pathOf(i).c_str(), k->linkOf(n).c_str());
      return 1;
    }
  }
  std::vector<uint8_t> piece;
  for (uint32_t i : order) {
    const kit::Node &n = k->nodes[i];
    std::string t = dest + "/" + k->pathOf(i);
    if (n.type == kit::T_DIR) { if (mkdir(t.c_str(), 0700)) { perror(t.c_str()); return 1; } continue; }
    if (n.type == kit::T_LINK) { if (symlink(k->linkOf(n).c_str(), t.c_str())) { perror(t.c_str()); return 1; } continue; }
    int fd = open(t.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) { perror(t.c_str()); return 1; }
    for (uint32_t c = 0; c < n.nchunks; ++c) {
      piece.resize(k->chunks[n.chunk0 + c].plain);
      const char *e = k->loadChunk(n.chunk0 + c, piece.data(), n.codec);
      if (*e || write(fd, piece.data(), piece.size()) != (ssize_t)piece.size()) {
        close(fd);
        unlink(t.c_str());
        printf("extract fail %s\n", *e ? e : "IO");
        return 1;
      }
    }
    fchmod(fd, n.mode);
    struct timespec ts[2] = {{n.date, 0}, {n.date, 0}};
    futimens(fd, ts);
    close(fd);
  }
  // directory modes last, deepest first
  for (auto it = order.rbegin(); it != order.rend(); ++it) {
    const kit::Node &n = k->nodes[*it];
    if (n.type == kit::T_DIR) chmod((dest + "/" + k->pathOf(*it)).c_str(), n.mode);
  }
  return 0;
}

// Every command but serve parses an untrusted kit: it does so confined (src/confine.cpp), read-only,
// or for extract able to create files beneath DESTDIR only.  A sanitizer build (make fuzz) can be
// told to skip it, for LeakSanitizer, which needs ptrace; other builds have no way to.
static bool confineMe(confine::Profile p, const std::string &dir = "") {
#ifdef MKKITFS_SANITIZE
  if (getenv("MKKITFS_UNCONFINED")) return true;
#endif
  try {
    confine::apply(p, dir);
    return true;
  } catch (const std::exception &e) {
    fprintf(stderr, "mkkitfs: cannot confine this process: %s\n", e.what());
    return false;
  }
}

int main(int argc, char **argv) {
  if (argc < 2) return usage();
  std::string cmd = argv[1];
  if (cmd == "help" || cmd == "--help" || cmd == "-h") { fputs(kUsage, stdout); return 0; }
  if (cmd == "serve") return srv::serveMain(argc - 1, argv + 1);
  if (cmd == "precheck") {   // internal: the isolated first parse of a kit on fd 3 (serve --isolate yes)
    if (argc != 2) return 2;
    // already inside the server's domain; this adds the reader's (no programs, no threads)
    if (!confineMe(confine::Profile::Reader)) { printf("IO\tcannot confine the checker\n"); return 1; }
    try {
      kit::OpenOptions o;
      kit::Kit::open(dup(3), o);
    } catch (const kit::Error &e) {
      printf("%s\t%s\n", e.code.c_str(), kit::esc(e.msg).c_str());
      return 1;
    }
    printf("ok\n");
    return 0;
  }
  Args a = parse(argc, argv, 2);
  if (cmd == "extract") {
    struct stat sb;
    if (a.pos.size() != 2) return usage();
    if (stat(a.pos[1].c_str(), &sb) || !S_ISDIR(sb.st_mode)) { fprintf(stderr, "mkkitfs: %s is not a directory\n", a.pos[1].c_str()); return 2; }
    if (!confineMe(confine::Profile::Extract, a.pos[1])) return 1;
  } else if (!confineMe(confine::Profile::Reader)) {
    return 1;
  }
  if (cmd == "probe") {
    if (a.pos.size() != 1) return usage();
    int fd = open(a.pos[0].c_str(), O_RDONLY | O_CLOEXEC);
    try {
      if (fd < 0) throw kit::Error("NOTKIT", strerror(errno));
      kit::Frame f = kit::readFrame(fd);
      printf("kit 1\nkind %s\nname %s\nversion %s\nformat %d.%d\nheader %llu\nstore %llu\nsigned %d\nimage %d\n", f.kind.c_str(),
             f.name.c_str(), f.version.c_str(), f.major, f.minor, (unsigned long long)f.header, (unsigned long long)f.storeStart,
             f.signature.empty() ? 0 : 1, f.image ? 1 : 0);
    } catch (const kit::Error &e) {
      printf("kit 0\ncode %s\n", e.code.c_str());
      fprintf(stderr, "mkkitfs: %s: %s\n", e.code.c_str(), e.msg.c_str());
    }
    return 0;
  }
  if (cmd == "open") {
    if (a.pos.size() != 1) return usage();
    try {
      auto k = kit::Kit::open(a.pos[0], a.opt);
      printf("open ok\nsignature %s %s\nroot %s\n", k->sig.state.c_str(), k->sig.keyid.c_str(), k->rootOk ? "ok" : "mismatch");
    } catch (const kit::Error &e) { return refuse(e); }
    return 0;
  }
  if (cmd == "expect") return cmdExpect(a);
  if (cmd == "info") return cmdInfo(a);
  if (cmd == "index") {
    if (a.pos.size() != 1) return usage();
    try {
      auto k = kit::Kit::open(a.pos[0], a.opt);
      fwrite(k->index.data(), 1, k->index.size(), stdout);
    } catch (const kit::Error &e) { return refuse(e); }
    return 0;
  }
  if (cmd == "verify") {
    if (a.pos.size() != 1) return usage();
    try {
      auto k = kit::Kit::open(a.pos[0], a.opt);
      kit::Kit::Verify v = k->verify();
      printVerify(v);
      return v.ok ? 0 : 1;
    } catch (const kit::Error &e) { return refuse(e); }
  }
  if (cmd == "ls") {
    if (a.pos.size() != 1) return usage();
    try {
      auto k = kit::Kit::open(a.pos[0], a.opt);
      for (uint32_t i : sortedNodes(*k)) {
        const kit::Node &n = k->nodes[i];
        static const char *t[] = {"dir", "file", "link"};
        printf("%s\t%o\t%llu\t%s\t%s\n", t[n.type], n.mode, (unsigned long long)n.size, kit::codecName(n.codec), kit::esc(k->pathOf(i)).c_str());
      }
    } catch (const kit::Error &e) { return refuse(e); }
    return 0;
  }
  if (cmd == "cat") return cmdCat(a);
  if (cmd == "extract") return cmdExtract(a);
  return usage();
}
