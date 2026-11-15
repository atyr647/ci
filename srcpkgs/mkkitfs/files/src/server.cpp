// server.cpp -- mkkitfs serve: one FUSE mount per user session, every kit of the session under it,
// mounted and unmounted through a control socket (the protocol is in docs/MKKITFS.md).
//
//   <mountpoint>/<name>-<version>-<n>/...      a mounted kit's tree (n: this server's mount number)
//
// Requests are served by libfuse's multithreaded loop (low-level API, inode numbers): the kit's
// tables are immutable once it is open, so lookups, getattr and readdir take no lock beyond a
// shared one on the table of mounted kits.  File data goes through a bounded LRU of decoded,
// hash-checked chunks; a read takes the chunks it needs (decoding a missing one once, whoever asks
// first) and replies straight from the cache with fuse_reply_iov, without copying or allocating.
#define FUSE_USE_VERSION 312
#include "server.h"

#include "confine.h"
#include "kit.h"

#include <fuse_lowlevel.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <poll.h>
#include <set>
#include <shared_mutex>
#include <spawn.h>
#include <string>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

extern char **environ;

namespace srv {

static const char *kVersion = "1.0.0";
static const int kProto = 1;
static std::string confined;   // what confine::apply put in place ("seccomp landlock-6")
static const double kForever = 365.0 * 86400;   // the tree of a mounted kit never changes

// ---- configuration and logging (the policy -- keys, references, linger, idle exit, the control
// socket -- is mkkitfsd's, in Tcl; this process is the data path and takes its orders on stdin) ---------------------------------------------------------------------------
struct Config {
  std::string mountpoint, logFile;
  size_t cacheBytes = 64u << 20;
  int threads = 16;
  bool allowOther = false;
  int checkTimeout = 30;
};
static Config cfg;
static std::mutex logMu;
static FILE *logOut = stderr;

static void logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf(const char *fmt, ...) {
  char when[32];
  time_t t = time(nullptr);
  struct tm tm;
  localtime_r(&t, &tm);
  strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", &tm);
  std::lock_guard<std::mutex> g(logMu);
  fprintf(logOut, "%s mkkitfs: ", when);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(logOut, fmt, ap);
  va_end(ap);
  fputc('\n', logOut);
  fflush(logOut);
}

// ---- mounted kits ---------------------------------------------------------------------------------------------
struct Entry;

struct Mounted {
  std::unique_ptr<kit::Kit> k;
  uint32_t seq = 0;
  std::string id;                       // the kit's directory name: <name>-<version>-<seq>
  std::string path;                     // where it was first attached from (realpath)
  dev_t dev = 0;
  ino_t ino = 0;
  off_t size = 0;
  struct timespec mtime {}, ctime {};
  bool attached = true;                 // visible in the mount point
  bool freed = false;
  std::atomic<long> pins{0};            // requests using it right now
  std::atomic<uint64_t> nlookup{0};     // the kernel's references to its inodes
  std::vector<Entry *> slots;           // one per stored piece; under Cache::mu
  std::atomic<uint64_t> badReads{0};
  std::mutex badMu;
  std::set<uint32_t> badLogged;
};

struct Registry {
  std::shared_mutex mu;
  std::unordered_map<uint32_t, Mounted *> bySeq;   // every live kit, attached or not
  std::map<std::string, Mounted *> byId;           // attached kits, by directory name
  uint32_t nextSeq = 1;
};
static Registry reg;
static struct fuse_session *se;
static time_t startTime;
static uid_t myUid;
static gid_t myGid;
static bool noOpen = false;  // the kernel can skip OPEN for files (FUSE_CAP_NO_OPEN_SUPPORT)

static std::atomic<uint64_t> stLookups{0}, stGetattr{0}, stReads{0}, stReadBytes{0}, stReaddir{0}, stBad{0}, stOther{0};

static void maybeFree(Mounted *m);

// a kit in use by one request; nothing frees it until the pin is dropped
struct Pin {
  Mounted *m = nullptr;
  uint32_t node = 0;
  Pin() = default;
  Pin(const Pin &) = delete;
  ~Pin() {
    if (m && m->pins.fetch_sub(1) == 1) maybeFree(m);
  }
};

static inline uint64_t inoOf(const Mounted *m, uint32_t node) { return (uint64_t)m->seq << 32 | (uint64_t)(node + 1); }

static bool pin(fuse_ino_t ino, Pin &p) {
  uint32_t seq = (uint32_t)(ino >> 32), node = (uint32_t)(ino & 0xffffffffu);
  if (!seq || !node) return false;
  std::shared_lock<std::shared_mutex> g(reg.mu);
  auto it = reg.bySeq.find(seq);
  if (it == reg.bySeq.end() || node - 1 >= it->second->k->nodes.size()) return false;
  p.m = it->second;
  p.node = node - 1;
  p.m->pins.fetch_add(1);
  return true;
}

// ---- the decoded-chunk cache ---------------------------------------------------------------------------------------
// Buffers come in power-of-two size classes (4 KiB .. 16 MiB) and are recycled, so once the cache
// has warmed up a miss reuses an evicted buffer instead of allocating.
struct Entry {
  Mounted *m = nullptr;
  uint32_t ci = 0;
  uint8_t *buf = nullptr;
  uint8_t cls = 0;
  int pins = 0;
  enum { LOADING, READY, FAILED } state = LOADING;
  const char *err = "";
  Entry *prev = nullptr, *next = nullptr;
};

class Cache {
 public:
  explicit Cache(size_t budget) : budget_(budget) { lru_.prev = lru_.next = &lru_; }

  static int classOf(uint32_t n) {
    int c = 0;
    while (((size_t)4096 << c) < n) ++c;
    return c;
  }
  static size_t sizeOf(int cls) { return (size_t)4096 << cls; }

  // the decoded piece `ci` of m, pinned (release with put), or nullptr and err
  Entry *get(Mounted *m, uint32_t ci, uint8_t codec, const char *&err) {
    std::unique_lock<std::mutex> g(mu_);
    Entry *e = m->slots[ci];
    if (e) {
      ++e->pins;
      if (e->state == Entry::READY) {
        ++hits;
        touch(e);
        return e;
      }
      ++waits;
      cv_.wait(g, [&] { return e->state != Entry::LOADING; });
      if (e->state == Entry::READY) return e;
      err = e->err;
      if (--e->pins == 0) recycle(e);
      return nullptr;
    }
    ++misses;
    const kit::Chunk &c = m->k->chunks[ci];
    e = take(classOf(c.plain));
    e->m = m;
    e->ci = ci;
    e->state = Entry::LOADING;
    e->pins = 1;
    m->slots[ci] = e;
    g.unlock();
    const char *r = m->k->loadChunk(ci, e->buf, codec);
    g.lock();
    if (!*r) {
      e->state = Entry::READY;
      link(e);
      cv_.notify_all();
      return e;
    }
    e->state = Entry::FAILED;
    e->err = r;
    m->slots[ci] = nullptr;   // a later read tries again (and fails again, if the kit is damaged)
    cv_.notify_all();
    err = r;
    if (--e->pins == 0) recycle(e);
    return nullptr;
  }

  void put(Entry *e) {
    std::lock_guard<std::mutex> g(mu_);
    if (--e->pins == 0 && e->state != Entry::READY) recycle(e);
  }

  // a kit goes away: nothing of it is pinned (no request uses it)
  void drop(Mounted *m) {
    std::lock_guard<std::mutex> g(mu_);
    for (Entry *&e : m->slots) {
      if (!e) continue;
      if (e->state == Entry::READY) unlink(e);
      e->state = Entry::FAILED;
      if (e->pins == 0) recycle(e);
      e = nullptr;
    }
  }

  void stats(std::string &out) {
    std::lock_guard<std::mutex> g(mu_);
    out += "\tcache-budget\t" + std::to_string(budget_) + "\tcache-bytes\t" + std::to_string(used_) + "\tcache-entries\t" +
           std::to_string(count_) + "\thits\t" + std::to_string(hits) + "\tmisses\t" + std::to_string(misses) + "\twaits\t" +
           std::to_string(waits) + "\tevictions\t" + std::to_string(evictions) + "\tallocations\t" + std::to_string(allocs);
  }

 private:
  void link(Entry *e) {   // at the front (most recent)
    e->next = lru_.next;
    e->prev = &lru_;
    lru_.next->prev = e;
    lru_.next = e;
    ++count_;
  }
  void unlink(Entry *e) {
    e->prev->next = e->next;
    e->next->prev = e->prev;
    e->prev = e->next = nullptr;
    --count_;
  }
  void touch(Entry *e) {
    if (lru_.next == e) return;
    unlink(e);
    link(e);
  }
  // an entry that is no longer anywhere: its buffer and itself back to the free lists
  void recycle(Entry *e) {
    freeBufs_[e->cls].push_back(e->buf);
    e->buf = nullptr;
    e->m = nullptr;
    freeEntries_.push_back(e);
  }
  void release(uint8_t *buf, int cls) {
    free(buf);
    used_ -= sizeOf(cls);
  }
  Entry *take(int cls) {
    size_t need = sizeOf(cls);
    uint8_t *buf = nullptr;
    if (!freeBufs_[cls].empty()) { buf = freeBufs_[cls].back(); freeBufs_[cls].pop_back(); }
    // over budget: give back free buffers of other sizes, then evict from the cold end
    for (int c = 0; c < kClasses && used_ + (buf ? 0 : need) > budget_; ++c)
      while (!freeBufs_[c].empty() && used_ + (buf ? 0 : need) > budget_) { release(freeBufs_[c].back(), c); freeBufs_[c].pop_back(); }
    Entry *v = lru_.prev;
    while (v != &lru_ && used_ + (buf ? 0 : need) > budget_) {
      Entry *prev = v->prev;
      if (v->pins == 0) {
        unlink(v);
        v->m->slots[v->ci] = nullptr;
        ++evictions;
        if (!buf && v->cls == cls) buf = v->buf;
        else release(v->buf, v->cls);
        v->buf = nullptr;
        v->m = nullptr;
        freeEntries_.push_back(v);
      }
      v = prev;
    }
    if (!buf) {
      buf = (uint8_t *)malloc(need);
      if (!buf) abort();
      used_ += need;
      ++allocs;
    }
    Entry *e;
    if (!freeEntries_.empty()) { e = freeEntries_.back(); freeEntries_.pop_back(); }
    else e = new Entry;
    *e = Entry();
    e->buf = buf;
    e->cls = (uint8_t)cls;
    return e;
  }

  static const int kClasses = 13;   // 4 KiB .. 16 MiB
  std::mutex mu_;
  std::condition_variable cv_;
  size_t budget_, used_ = 0, count_ = 0;
  Entry lru_;
  std::vector<Entry *> freeEntries_;
  std::vector<uint8_t *> freeBufs_[kClasses];
  uint64_t hits = 0, misses = 0, waits = 0, evictions = 0, allocs = 0;
};
static Cache *cache;

// ---- kits coming and going -------------------------------------------------------------------------------------------
static void maybeFree(Mounted *m) {
  {
    std::unique_lock<std::shared_mutex> g(reg.mu);
    if (m->freed || m->attached || m->pins.load() != 0 || m->nlookup.load() != 0) return;
    m->freed = true;
    reg.bySeq.erase(m->seq);
  }
  cache->drop(m);
  logf("freed %s", m->id.c_str());
  delete m;
}

// detach: the kit leaves the mount point; it is freed once the kernel forgets its inodes
static void detach(Mounted *m) {
  {
    std::unique_lock<std::shared_mutex> g(reg.mu);
    if (!m->attached) return;
    m->attached = false;
    reg.byId.erase(m->id);
  }
  logf("detached %s", m->id.c_str());
  if (se) fuse_lowlevel_notify_inval_entry(se, FUSE_ROOT_ID, m->id.c_str(), m->id.size());
  m->pins.fetch_add(1);
  if (m->pins.fetch_sub(1) == 1) maybeFree(m);
}

// ---- FUSE operations -------------------------------------------------------------------------------------------------------
static void fillStat(const Mounted *m, uint32_t node, struct stat &st) {
  const kit::Node &n = m->k->nodes[node];
  memset(&st, 0, sizeof st);
  st.st_ino = inoOf(m, node);
  st.st_uid = myUid;
  st.st_gid = myGid;
  st.st_blksize = 4096;
  switch (n.type) {
    case kit::T_DIR:
      st.st_mode = S_IFDIR | n.mode;
      st.st_nlink = 2 + n.ndirs;
      st.st_size = 4096;
      st.st_mtime = st.st_ctime = st.st_atime = m->k->newest;
      break;
    case kit::T_FILE:
      st.st_mode = S_IFREG | n.mode;
      st.st_nlink = 1;
      st.st_size = (off_t)n.size;
      st.st_blocks = (blkcnt_t)((n.size + 511) / 512);
      if (n.csize) st.st_blksize = n.csize;
      st.st_mtime = st.st_ctime = st.st_atime = n.date;
      break;
    default:
      st.st_mode = S_IFLNK | n.mode;
      st.st_nlink = 1;
      st.st_size = n.linkLen;
      st.st_mtime = st.st_ctime = st.st_atime = n.date;
  }
}

static void fillTop(struct stat &st) {
  memset(&st, 0, sizeof st);
  st.st_ino = FUSE_ROOT_ID;
  st.st_mode = S_IFDIR | 0555;
  st.st_nlink = 2;
  st.st_uid = myUid;
  st.st_gid = myGid;
  st.st_size = 4096;
  st.st_blksize = 4096;
  st.st_mtime = st.st_ctime = st.st_atime = startTime;
}

static void entryFor(const Mounted *m, uint32_t node, struct fuse_entry_param &e) {
  memset(&e, 0, sizeof e);
  e.ino = inoOf(m, node);
  e.attr_timeout = e.entry_timeout = kForever;
  fillStat(m, node, e.attr);
}

static void opInit(void *, struct fuse_conn_info *conn) {
  if (conn->capable & FUSE_CAP_CACHE_SYMLINKS) conn->want |= FUSE_CAP_CACHE_SYMLINKS;
  if (conn->capable & FUSE_CAP_PARALLEL_DIROPS) conn->want |= FUSE_CAP_PARALLEL_DIROPS;
  conn->want &= ~FUSE_CAP_AUTO_INVAL_DATA;
  noOpen = (conn->capable & FUSE_CAP_NO_OPEN_SUPPORT) != 0;
}

static void opLookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
  stLookups++;
  struct fuse_entry_param e;
  if (parent == FUSE_ROOT_ID) {
    std::shared_lock<std::shared_mutex> g(reg.mu);
    auto it = reg.byId.find(name);
    if (it == reg.byId.end()) { g.unlock(); fuse_reply_err(req, ENOENT); return; }
    entryFor(it->second, 0, e);
    it->second->nlookup.fetch_add(1);
    g.unlock();
    if (fuse_reply_entry(req, &e)) { /* the kernel will not forget it: undo */ }
    return;
  }
  Pin p;
  if (!pin(parent, p)) { fuse_reply_err(req, ESTALE); return; }
  int64_t c = p.m->k->child(p.node, name, strlen(name));
  if (c < 0) {
    memset(&e, 0, sizeof e);
    e.entry_timeout = kForever;   // a negative entry: the kit never gains this name
    fuse_reply_entry(req, &e);
    return;
  }
  entryFor(p.m, (uint32_t)c, e);
  p.m->nlookup.fetch_add(1);
  fuse_reply_entry(req, &e);
}

static void forgetOne(fuse_ino_t ino, uint64_t n) {
  if (ino == FUSE_ROOT_ID) return;
  Pin p;
  if (!pin(ino, p)) return;
  p.m->nlookup.fetch_sub(n);
}

static void opForget(fuse_req_t req, fuse_ino_t ino, uint64_t n) {
  forgetOne(ino, n);
  fuse_reply_none(req);
}

static void opForgetMulti(fuse_req_t req, size_t count, struct fuse_forget_data *f) {
  for (size_t i = 0; i < count; ++i) forgetOne(f[i].ino, f[i].nlookup);
  fuse_reply_none(req);
}

static void opGetattr(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *) {
  stGetattr++;
  struct stat st;
  if (ino == FUSE_ROOT_ID) {
    fillTop(st);
    std::shared_lock<std::shared_mutex> g(reg.mu);
    st.st_nlink = 2 + reg.byId.size();
    g.unlock();
    fuse_reply_attr(req, &st, 1.0);
    return;
  }
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  fillStat(p.m, p.node, st);
  fuse_reply_attr(req, &st, kForever);
}

static void opReadlink(fuse_req_t req, fuse_ino_t ino) {
  stOther++;
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  const kit::Node &n = p.m->k->nodes[p.node];
  if (n.type != kit::T_LINK) { fuse_reply_err(req, EINVAL); return; }
  fuse_reply_readlink(req, p.m->k->pool.data() + n.link);   // NUL-terminated in the pool
}

static void opOpen(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
  stOther++;
  if ((fi->flags & O_ACCMODE) != O_RDONLY) { fuse_reply_err(req, EROFS); return; }
  if (noOpen) { fuse_reply_err(req, ENOSYS); return; }   // the kernel stops sending OPEN and keeps its cache
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  fi->keep_cache = 1;
  fi->noflush = 1;
  fuse_reply_open(req, fi);
}

static void logBad(Mounted *m, uint32_t node, uint32_t ci, const char *err) {
  stBad++;
  m->badReads++;
  {
    std::lock_guard<std::mutex> g(m->badMu);
    if (!m->badLogged.insert(ci).second) return;
  }
  const kit::Node &n = m->k->nodes[node];
  logf("bad chunk: kit %s (%s) %s chunk %u: %s; the read fails with EIO", m->id.c_str(), m->path.c_str(),
       m->k->pathOf(node).c_str(), ci - n.chunk0, err);
}

static void opRead(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *) {
  stReads++;
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  const kit::Kit &k = *p.m->k;
  const kit::Node &n = k.nodes[p.node];
  if (n.type != kit::T_FILE) { fuse_reply_err(req, n.type == kit::T_DIR ? EISDIR : EINVAL); return; }
  if (off < 0 || (uint64_t)off >= n.size || size == 0) { fuse_reply_buf(req, nullptr, 0); return; }
  uint64_t len = std::min<uint64_t>(size, n.size - (uint64_t)off);
  uint64_t csize = n.codec == kit::C_CLASSIC ? n.size : n.csize;
  uint32_t first = (uint32_t)((uint64_t)off / csize), last = (uint32_t)(((uint64_t)off + len - 1) / csize);
  static const unsigned kMax = 260;   // a 1 MiB read in 4 KiB chunks touches 257
  if (last - first + 1 > kMax) {      // never shorten a read (the kernel would take it as the end of the file)
    fuse_reply_err(req, EIO);
    return;
  }
  Entry *ents[kMax];
  struct iovec iov[kMax];
  unsigned got = 0;
  const char *err = "";
  for (uint32_t c = first; c <= last; ++c) {
    Entry *e = cache->get(p.m, n.chunk0 + c, n.codec, err);
    if (!e) { logBad(p.m, p.node, n.chunk0 + c, err); break; }
    uint64_t base = (uint64_t)c * csize;
    uint64_t from = c == first ? (uint64_t)off - base : 0;
    uint64_t to = std::min<uint64_t>(k.chunks[n.chunk0 + c].plain, (uint64_t)off + len - base);
    ents[got] = e;
    iov[got].iov_base = e->buf + from;
    iov[got].iov_len = to - from;
    ++got;
  }
  if (got == last - first + 1) {
    stReadBytes += len;
    fuse_reply_iov(req, iov, (int)got);
  } else {
    fuse_reply_err(req, EIO);
  }
  for (unsigned i = 0; i < got; ++i) cache->put(ents[i]);
}

static void opOpendir(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
  stOther++;
  if (ino == FUSE_ROOT_ID) {   // the kits come and go: no caching of the listing
    fi->keep_cache = 0;
    fi->cache_readdir = 0;
    fuse_reply_open(req, fi);
    return;
  }
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  if (p.m->k->nodes[p.node].type != kit::T_DIR) { fuse_reply_err(req, ENOTDIR); return; }
  fi->keep_cache = 1;
  fi->cache_readdir = 1;
  fuse_reply_open(req, fi);
}

static thread_local std::vector<char> dirBuf;

static void readdirCommon(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, bool plus) {
  stReaddir++;
  if (dirBuf.size() < size) dirBuf.resize(std::max<size_t>(size, 65536));
  char *buf = dirBuf.data();
  size_t pos = 0;
  struct fuse_entry_param e;
  struct stat st;
  auto add = [&](const char *name, off_t next) -> bool {
    size_t room = size - pos, n;
    if (plus) n = fuse_add_direntry_plus(req, buf + pos, room, name, &e, next);
    else n = fuse_add_direntry(req, buf + pos, room, name, &e.attr, next);
    if (n > room) return false;
    pos += n;
    return true;
  };
  auto dot = [&](fuse_ino_t i, const struct stat &a) {
    memset(&e, 0, sizeof e);   // ino 0: no entry for the kernel to link ("." and ".." never count as lookups)
    e.attr = a;
    e.attr.st_ino = i;
  };
  if (ino == FUSE_ROOT_ID) {
    fillTop(st);
    std::shared_lock<std::shared_mutex> g(reg.mu);
    off_t i = off;
    if (i == 0) { dot(FUSE_ROOT_ID, st); if (!add(".", 1)) goto done; i = 1; }
    if (i == 1) { dot(FUSE_ROOT_ID, st); if (!add("..", 2)) goto done; i = 2; }
    {
      auto it = reg.byId.begin();
      std::advance(it, std::min<size_t>(reg.byId.size(), (size_t)(i - 2)));
      for (; it != reg.byId.end(); ++it, ++i) {
        entryFor(it->second, 0, e);
        if (!add(it->first.c_str(), i + 1)) break;
        if (plus) it->second->nlookup.fetch_add(1);
      }
    }
  done:
    g.unlock();
    fuse_reply_buf(req, buf, pos);
    return;
  }
  Pin p;
  if (!pin(ino, p)) { fuse_reply_err(req, ESTALE); return; }
  const kit::Kit &k = *p.m->k;
  const kit::Node &d = k.nodes[p.node];
  if (d.type != kit::T_DIR) { fuse_reply_err(req, ENOTDIR); return; }
  off_t i = off;
  for (; i < (off_t)d.count + 2; ++i) {
    if (i < 2) {
      if (i == 0 || p.node != 0) fillStat(p.m, i == 0 ? p.node : d.parent, st);
      else fillTop(st);
      dot(st.st_ino, st);
      if (!add(i == 0 ? "." : "..", i + 1)) break;
      continue;
    }
    uint32_t c = k.kids[d.first + (uint32_t)(i - 2)];
    entryFor(p.m, c, e);
    if (!add(k.nameOf(k.nodes[c]), i + 1)) break;
    if (plus) p.m->nlookup.fetch_add(1);
  }
  fuse_reply_buf(req, buf, pos);
}

static void opReaddir(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *) {
  readdirCommon(req, ino, size, off, false);
}
static void opReaddirplus(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *) {
  readdirCommon(req, ino, size, off, true);
}

static void opStatfs(fuse_req_t req, fuse_ino_t) {
  stOther++;
  struct statvfs s;
  memset(&s, 0, sizeof s);
  uint64_t bytes = 0, files = 0;
  {
    std::shared_lock<std::shared_mutex> g(reg.mu);
    for (auto &kv : reg.byId) { bytes += kv.second->k->bytes; files += kv.second->k->nodes.size(); }
  }
  s.f_bsize = s.f_frsize = 4096;
  s.f_blocks = bytes / 4096 + 1;
  s.f_files = files + 1;
  s.f_namemax = 255;
  s.f_flag = ST_RDONLY | ST_NOSUID | ST_NODEV;
  fuse_reply_statfs(req, &s);
}

// the format has no extended attributes: ENOSYS once, and the kernel stops asking (no round trip
// for security.capability on every exec)
static void opGetxattr(fuse_req_t req, fuse_ino_t, const char *, size_t) { stOther++; fuse_reply_err(req, ENOSYS); }
static void opListxattr(fuse_req_t req, fuse_ino_t, size_t) { stOther++; fuse_reply_err(req, ENOSYS); }

static struct fuse_lowlevel_ops ops;

// ---- orders from mkkitfsd ------------------------------------------------------------------------------------------------------------
// One request per line on stdin, one reply per request on stdout; fields separated by TAB and
// escaped as in the kit index (\\ \t \n \r).  A reply is any number of data lines, then one line
// starting with "ok" or "err".  docs/MKKITFS.md has the requests; the session's own control socket,
// references, linger and idle exit are mkkitfsd's (Tcl), which is the only one talking to this.
static std::string unesc(const std::string &s) {
  std::string o;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 1 < s.size()) {
      char c = s[++i];
      o += c == 't' ? '\t' : c == 'n' ? '\n' : c == 'r' ? '\r' : c;
    } else {
      o += s[i];
    }
  }
  return o;
}

static std::string line(std::initializer_list<std::string> xs) {
  std::string s;
  bool first = true;
  for (const std::string &x : xs) { if (!first) s += '\t'; s += kit::esc(x); first = false; }
  return s;
}

static std::atomic<bool> stopping{false};

static std::string describe(const Mounted *m, const kit::SigInfo &sig) {
  const kit::Kit &k = *m->k;
  return line({"id", m->id, "dir", cfg.mountpoint + "/" + m->id, "name", k.field("name"), "version", k.field("version"), "kind",
               k.field("kind"), "signature", sig.state, "keyid", sig.keyid, "comment", sig.comment, "root", k.root, "entries",
               std::to_string(k.nEntries), "bytes", std::to_string(k.bytes), "path", m->path});
}

// the first parse of a kit, in a child process: Metakit can crash on damaged data, and a crash
// here would take every mounted kit of the session with it (KIT-FORMAT.md section 11.9)
static bool precheck(int fd, std::string &code, std::string &msg) {
  int out[2];
  if (pipe2(out, O_CLOEXEC)) { code = "IO"; msg = strerror(errno); return false; }
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fd, 3);
  posix_spawn_file_actions_adddup2(&fa, out[1], 1);
  posix_spawnattr_t at;
  posix_spawnattr_init(&at);
  sigset_t none, def;
  sigemptyset(&none);
  sigemptyset(&def);
  sigaddset(&def, SIGTERM); sigaddset(&def, SIGINT); sigaddset(&def, SIGHUP); sigaddset(&def, SIGPIPE);
  posix_spawnattr_setsigmask(&at, &none);
  posix_spawnattr_setsigdefault(&at, &def);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
  char a0[] = "mkkitfs", a1[] = "precheck";
  char *argv[] = {a0, a1, nullptr};
  pid_t pid;
  int rc = posix_spawn(&pid, "/proc/self/exe", &fa, &at, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&at);
  close(out[1]);
  if (rc) { close(out[0]); code = "IO"; msg = std::string("cannot start the checker: ") + strerror(rc); return false; }
  std::string got;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(cfg.checkTimeout);
  bool timedOut = false;
  for (;;) {
    int left = (int)std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
    if (left <= 0) { timedOut = true; break; }
    struct pollfd p = {out[0], POLLIN, 0};
    int r = poll(&p, 1, left);
    if (r < 0 && errno == EINTR) continue;
    if (r == 0) { timedOut = true; break; }
    char b[4096];
    ssize_t k = read(out[0], b, sizeof b);
    if (k < 0 && errno == EINTR) continue;
    if (k <= 0) break;
    got.append(b, (size_t)k);
    if (got.size() > 65536) break;
  }
  close(out[0]);
  if (timedOut) kill(pid, SIGKILL);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (timedOut) { code = "IO"; msg = "checking the kit took longer than " + std::to_string(cfg.checkTimeout) + " s"; return false; }
  if (WIFSIGNALED(status)) { code = "STRUCTURE"; msg = "the kit crashed the checker (signal " + std::to_string(WTERMSIG(status)) + ")"; return false; }
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && got == "ok\n") return true;
  size_t tab = got.find('\t'), nl = got.find('\n');
  if (tab != std::string::npos) {
    code = got.substr(0, tab);
    msg = unesc(got.substr(tab + 1, nl == std::string::npos ? std::string::npos : nl - tab - 1));
  } else {
    code = "STRUCTURE";
    msg = "the checker failed (exit " + std::to_string(WIFEXITED(status) ? WEXITSTATUS(status) : -1) + ")";
  }
  return false;
}

// attach PATH [signed 0|1] [isolate 0|1] [key PUBKEY]... [statement SHA256]
//   statement: the SHA-256 of the seal's statement as mkkitfsd checked it (its trust policy, e.g.
//   kittrust, decided on that statement): refused if the file's seal says anything else now
static std::string doAttach(const std::vector<std::string> &w) {
  if (w.size() < 2 || w.size() % 2) return line({"err", "CONFIG", "usage: attach PATH [signed 0|1] [isolate 0|1] [key PUBKEY]... [statement SHA256]"});
  bool requireSigned = false, isolate = true;
  std::vector<std::string> keys;
  std::string wantStmt;
  for (size_t i = 2; i + 1 < w.size(); i += 2) {
    if (w[i] == "signed") requireSigned = w[i + 1] == "1";
    else if (w[i] == "isolate") isolate = w[i + 1] != "0";
    else if (w[i] == "key") keys.push_back(w[i + 1]);
    else if (w[i] == "statement") wantStmt = w[i + 1];
    else return line({"err", "CONFIG", "unknown attach option '" + w[i] + "' (signed, isolate, key, statement)"});
  }
  char rp[PATH_MAX];
  if (!realpath(w[1].c_str(), rp)) return line({"err", "NOTKIT", w[1] + ": " + strerror(errno)});
  std::string path = rp;
  int fd = open(rp, O_RDONLY | O_CLOEXEC | O_NOCTTY);
  if (fd < 0) return line({"err", "NOTKIT", path + ": " + strerror(errno)});
  struct stat sb;
  if (fstat(fd, &sb) || !S_ISREG(sb.st_mode)) { close(fd); return line({"err", "NOTKIT", path + " is not a regular file"}); }
  kit::SigInfo sig;
  std::string checkedStmt;
  try {
    kit::Frame f = kit::readFrame(fd);   // the seal first, without Metakit
    checkedStmt = f.statement;
    if (f.major != 1) throw kit::Error("VERSION", "kit format " + std::to_string(f.major) + "." + std::to_string(f.minor) + ": this server reads format 1.x only");
    if (!wantStmt.empty()) {
      uint8_t md[32];
      kit::sha256(f.statement.data(), f.statement.size(), md);
      if (kit::hex(md, 32) != wantStmt) throw kit::Error("SIGNATURE", "the kit's seal changed after it was checked");
    }
    sig = kit::checkSignature(f.statement, f.signature, keys);
    if (requireSigned && sig.state != "valid") throw kit::Error("SIGNATURE", "the kit's signature is " + sig.state + ": " + sig.detail);
  } catch (const kit::Error &e) {
    close(fd);
    logf("refused %s: %s: %s", path.c_str(), e.code.c_str(), e.msg.c_str());
    return line({"err", e.code, e.msg});
  }
  // the same file, unchanged since it was attached (kits are replaced by rename, never rewritten
  // in place while installed): no need to parse it again
  Mounted *m = nullptr;
  bool cached = false;
  {
    std::shared_lock<std::shared_mutex> g(reg.mu);
    for (auto &kv : reg.byId) {
      Mounted *x = kv.second;
      if (x->dev == sb.st_dev && x->ino == sb.st_ino && x->size == sb.st_size && x->mtime.tv_sec == sb.st_mtim.tv_sec &&
          x->mtime.tv_nsec == sb.st_mtim.tv_nsec && x->ctime.tv_sec == sb.st_ctim.tv_sec && x->ctime.tv_nsec == sb.st_ctim.tv_nsec) {
        m = x;
        cached = true;
        break;
      }
    }
  }
  if (m) {
    close(fd);
    return "ok\t" + describe(m, sig) + "\t" + line({"cached", "1"});
  }
  std::string code, msg;
  if (isolate && !precheck(fd, code, msg)) {
    close(fd);
    logf("refused %s: %s: %s", path.c_str(), code.c_str(), msg.c_str());
    return line({"err", code, msg});
  }
  std::unique_ptr<kit::Kit> k;
  try {
    kit::OpenOptions o;
    o.keys = keys;
    k = kit::Kit::open(fd, o);
    // the kit is the one whose seal was checked (it could have been re-sealed in place since)
    if (k->frame.statement != checkedStmt) throw kit::Error("SIGNATURE", "the kit's seal changed while it was opened");
  } catch (const kit::Error &e) {
    if (k) k.reset();   // it owns fd now
    else close(fd);
    logf("refused %s: %s: %s", path.c_str(), e.code.c_str(), e.msg.c_str());
    return line({"err", e.code, e.msg});
  }
  // Every file gets its own mount, even with the same root as one already attached: two files
  // with one root have the same tree, but one may be damaged where the other is not (the root
  // binds the chunk hashes, not the bytes), and the good one must not be served the bad one's EIO.
  std::unique_lock<std::shared_mutex> g(reg.mu);
  m = new Mounted;
  m->seq = reg.nextSeq++;
  m->id = k->field("name") + "-" + k->field("version") + "-" + std::to_string(m->seq);
  m->path = path;
  m->slots.assign(k->chunks.size(), nullptr);
  m->dev = sb.st_dev;
  m->ino = sb.st_ino;
  m->size = sb.st_size;
  m->mtime = sb.st_mtim;
  m->ctime = sb.st_ctim;
  m->k = std::move(k);
  reg.bySeq[m->seq] = m;
  reg.byId[m->id] = m;
  g.unlock();
  // a negative dentry from before would hide the new directory
  if (se) fuse_lowlevel_notify_inval_entry(se, FUSE_ROOT_ID, m->id.c_str(), m->id.size());
  logf("attached %s (%s, %llu entries, root %s) from %s", m->id.c_str(), sig.state.c_str(), (unsigned long long)m->k->nEntries,
       m->k->root.c_str(), path.c_str());
  return "ok\t" + describe(m, sig) + "\t" + line({"cached", cached ? "1" : "0"});
}

static std::string doDetach(const std::vector<std::string> &w) {
  if (w.size() != 2) return line({"err", "CONFIG", "usage: detach ID"});
  Mounted *m = nullptr;
  {
    std::shared_lock<std::shared_mutex> g(reg.mu);
    auto it = reg.byId.find(w[1]);
    if (it != reg.byId.end()) m = it->second;
  }
  if (!m) return line({"err", "NOENT", w[1] + " is not attached"});
  detach(m);
  return line({"ok", "id", w[1]});
}

static std::string doKits() {
  std::string out;
  std::shared_lock<std::shared_mutex> g(reg.mu);
  for (auto &kv : reg.byId) {
    const Mounted *m = kv.second;
    out += "kit\t" + describe(m, m->k->sig) + "\t" + line({"bad-reads", std::to_string(m->badReads.load())}) + "\n";
  }
  return out + line({"ok", "count", std::to_string(reg.byId.size()), "live", std::to_string(reg.bySeq.size())});
}

static std::string doStatus() {
  std::string s = line({"ok", "version", kVersion, "proto", std::to_string(kProto), "mountpoint", cfg.mountpoint, "pid",
                        std::to_string(getpid()), "confined", confined});
  {
    std::shared_lock<std::shared_mutex> g(reg.mu);
    s += "\t" + line({"kits", std::to_string(reg.byId.size()), "live", std::to_string(reg.bySeq.size())});
  }
  s += "\t" + line({"lookups", std::to_string(stLookups.load()), "getattrs", std::to_string(stGetattr.load()), "reads",
                    std::to_string(stReads.load()), "read-bytes", std::to_string(stReadBytes.load()), "readdirs",
                    std::to_string(stReaddir.load()), "other", std::to_string(stOther.load()), "bad-reads", std::to_string(stBad.load())});
  cache->stats(s);
  return s;
}

static void shutdownServer() {
  if (stopping.exchange(true)) return;
  logf("stopping");
  kill(getpid(), SIGTERM);   // libfuse's handler ends the session loop in the main thread
}

static void orders() {
  char *lp = nullptr;
  size_t cap = 0;
  ssize_t n;
  while (!stopping && (n = getline(&lp, &cap, stdin)) >= 0) {
    std::string req(lp, (size_t)n);
    while (!req.empty() && (req.back() == '\n' || req.back() == '\r')) req.pop_back();
    if (req.empty()) continue;
    std::vector<std::string> w;
    size_t a = 0;
    for (;;) {
      size_t b = req.find('\t', a);
      w.push_back(unesc(req.substr(a, b == std::string::npos ? std::string::npos : b - a)));
      if (b == std::string::npos) break;
      a = b + 1;
    }
    std::string reply;
    bool quit = false;
    if (w[0] == "attach") reply = doAttach(w);
    else if (w[0] == "detach") reply = doDetach(w);
    else if (w[0] == "kits") reply = doKits();
    else if (w[0] == "status") reply = doStatus();
    else if (w[0] == "quit") { reply = line({"ok"}); quit = true; }
    else reply = line({"err", "CONFIG", "unknown request '" + w[0] + "' (attach detach kits status quit)"});
    fputs(reply.c_str(), stdout);
    fputc('\n', stdout);
    fflush(stdout);
    if (quit) break;
  }
  free(lp);
  shutdownServer();   // quit, or stdin closed: whoever started us is gone
}

// ---- startup ---------------------------------------------------------------------------------------------------------------
int serveMain(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto val = [&]() -> std::string {
      if (i + 1 >= argc) { fprintf(stderr, "mkkitfs: %s needs a value\n", a.c_str()); exit(2); }
      return argv[++i];
    };
    if (a == "--mountpoint") cfg.mountpoint = val();
    else if (a == "--cache") cfg.cacheBytes = (size_t)std::max(1L, atol(val().c_str())) << 20;
    else if (a == "--threads") cfg.threads = std::max(1, atoi(val().c_str()));
    else if (a == "--check-timeout") cfg.checkTimeout = std::max(1, atoi(val().c_str()));
    else if (a == "--allow-other") cfg.allowOther = true;
    else if (a == "--log") cfg.logFile = val();
    else { fprintf(stderr, "mkkitfs: unknown serve option %s (mkkitfs help)\n", a.c_str()); return 2; }
  }
  if (cfg.mountpoint.empty()) { fprintf(stderr, "mkkitfs: serve needs --mountpoint (mkkitfsd gives it)\n"); return 2; }
  // nothing inherited beyond stdin/out/err (a readiness pipe of mkkitfsd's, say) stays open here
  for (int fd = 3; fd < 1024; ++fd) close(fd);
  if (!cfg.logFile.empty()) {
    FILE *f = fopen(cfg.logFile.c_str(), "a");
    if (!f) { printf("err\tIO\tcannot open the log\n"); return 1; }
    logOut = f;
  }
  signal(SIGPIPE, SIG_IGN);
  myUid = geteuid();
  myGid = getegid();
  startTime = time(nullptr);
  cache = new Cache(cfg.cacheBytes);

  // a dead server leaves "Transport endpoint is not connected" behind
  struct stat sb;
  if (stat(cfg.mountpoint.c_str(), &sb) && errno == ENOTCONN) {
    if (myUid == 0) umount2(cfg.mountpoint.c_str(), MNT_DETACH);
    else {
      pid_t p;
      char a0[] = "fusermount3", a1[] = "-u", a2[] = "-z";
      char *av[] = {a0, a1, a2, (char *)cfg.mountpoint.c_str(), nullptr};
      if (!posix_spawnp(&p, "fusermount3", nullptr, nullptr, av, environ)) waitpid(p, nullptr, 0);
    }
  }
  if (stat(cfg.mountpoint.c_str(), &sb) || !S_ISDIR(sb.st_mode)) {
    printf("%s\n", line({"err", "IO", cfg.mountpoint + " is not a directory"}).c_str());
    return 1;
  }

  ops.init = opInit;
  ops.lookup = opLookup;
  ops.forget = opForget;
  ops.forget_multi = opForgetMulti;
  ops.getattr = opGetattr;
  ops.readlink = opReadlink;
  ops.open = opOpen;
  ops.read = opRead;
  ops.opendir = opOpendir;
  ops.readdir = opReaddir;
  ops.readdirplus = opReaddirplus;
  ops.statfs = opStatfs;
  ops.getxattr = opGetxattr;
  ops.listxattr = opListxattr;

  std::string mo = "ro,default_permissions,fsname=mkkitfs,subtype=kit";
  if (cfg.allowOther) mo += ",allow_other";
  char a0[] = "mkkitfs", a1[] = "-o";
  char *fargv[] = {a0, a1, (char *)mo.c_str(), nullptr};
  struct fuse_args args = FUSE_ARGS_INIT(3, fargv);
  se = fuse_session_new(&args, &ops, sizeof ops, nullptr);
  if (!se) { printf("err\tIO\tcannot start a FUSE session\n"); return 1; }
  // the unmount guard first, so that whatever happens from the mount on (a crash included), the
  // mount goes with this process: once confined, this process can't unmount anything itself
  if (!confine::unmountGuard(cfg.mountpoint)) {
    printf("%s\n", line({"err", "IO", std::string("cannot start the unmount guard: ") + strerror(errno)}).c_str());
    fuse_session_destroy(se);
    return 1;
  }
  if (fuse_set_signal_handlers(se) || fuse_session_mount(se, cfg.mountpoint.c_str())) {
    printf("%s\n", line({"err", "IO", "cannot mount " + cfg.mountpoint + " (is /dev/fuse usable?)"}).c_str());
    fuse_session_destroy(se);
    return 1;
  }
  // from here on kits are parsed: read-only file access, no network, no other program than this
  // one's checker, a seccomp allowlist (confine.cpp)
  try {
    confined = confine::apply(confine::Profile::Server).describe();
  } catch (const std::exception &e) {
    printf("%s\n", line({"err", "CONFINE", std::string("cannot confine the server: ") + e.what()}).c_str());
    _exit(1);   // the guard unmounts
  }
  // our own threads leave SIGTERM & co. to the main thread, which runs the session loop
  sigset_t block, prev;
  sigemptyset(&block);
  sigaddset(&block, SIGTERM); sigaddset(&block, SIGINT); sigaddset(&block, SIGHUP);
  pthread_sigmask(SIG_BLOCK, &block, &prev);
  logf("serving %s on %s (cache %zu MiB, %d threads, %s)", kVersion, cfg.mountpoint.c_str(), cfg.cacheBytes >> 20, cfg.threads,
       confined.c_str());
  printf("%s\n", line({"ready", "version", kVersion, "proto", std::to_string(kProto), "mountpoint", cfg.mountpoint, "pid",
                       std::to_string(getpid()), "confined", confined}).c_str());
  fflush(stdout);
  std::thread reader(orders);
  reader.detach();   // it may be blocked in getline when the session ends
  pthread_sigmask(SIG_SETMASK, &prev, nullptr);

  struct fuse_loop_config *lc = fuse_loop_cfg_create();
  fuse_loop_cfg_set_clone_fd(lc, 1);
  fuse_loop_cfg_set_max_threads(lc, (unsigned)cfg.threads);
  fuse_loop_cfg_set_idle_threads(lc, (unsigned)std::max(1, cfg.threads / 2));
  int rc = fuse_session_loop_mt(se, lc);
  fuse_loop_cfg_destroy(lc);
  stopping = true;
  // no fuse_session_unmount: the guard unmounts once this process has gone
  fuse_remove_signal_handlers(se);
  fuse_session_destroy(se);
  se = nullptr;
  logf("stopped");
  fflush(stdout);
  _exit(rc < 0 ? 1 : 0);   // the order reader may still hold stdin
}

}  // namespace srv
