// kit.cpp -- the kit reader (see kit.h).  The order of the checks follows kitfmt.tcl, so that a
// damaged kit is refused with the same code by both readers.
#define OPENSSL_SUPPRESS_DEPRECATED 1   // SHA256_Init & co.: the only SHA-256 API that never allocates
#include "kit.h"

#include "mk4.h"

#include <libdeflate.h>
#include <openssl/evp.h>
#include <openssl/sha.h>

#include <algorithm>
#include <cctype>
#include <functional>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>

namespace kit {

// ---- limits (section 10) -------------------------------------------------------------------
static const uint64_t kEntries = 1000000, kDepth = 64, kName = 255, kPath = 4096, kLink = 4095;
static const uint64_t kRows = 10000, kValue = 65536, kClassic = 16777216;
static const uint64_t kChunkMin = 4096, kChunkMax = 1048576, kFileMax = 1ull << 40;
static const uint64_t kSegMin = 65536, kSegMax = 16777216, kPad = 65536, kSealMax = 65536;

[[noreturn]] static void fail(const char *code, const std::string &msg) { throw Error(code, msg); }

const char *codecName(uint8_t c) {
  switch (c) {
    case C_RAW: return "raw";
    case C_DEFLATE: return "deflate";
    case C_CLASSIC: return "classic";
    case C_ZSTD: return "zstd";
  }
  return "";
}

// ---- small helpers -------------------------------------------------------------------------------
void sha256(const void *p, size_t n, uint8_t out[32]) {
  SHA256_CTX c;
  SHA256_Init(&c);
  SHA256_Update(&c, p, n);
  SHA256_Final(out, &c);
}

std::string hex(const uint8_t *p, size_t n) {
  static const char *d = "0123456789abcdef";
  std::string s(n * 2, '0');
  for (size_t i = 0; i < n; ++i) { s[2 * i] = d[p[i] >> 4]; s[2 * i + 1] = d[p[i] & 15]; }
  return s;
}

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

bool unhex64(const std::string &s, Hash &out) {
  if (s.size() != 64) return false;
  for (int i = 0; i < 32; ++i) {
    int a = hexval(s[2 * i]), b = hexval(s[2 * i + 1]);
    if (a < 0 || b < 0) return false;
    out[i] = (uint8_t)(a << 4 | b);
  }
  return true;
}

std::string esc(const std::string &s) {
  std::string o;
  o.reserve(s.size());
  for (char c : s) {
    switch (c) {
      case '\\': o += "\\\\"; break;
      case '\t': o += "\\t"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      default: o += c;
    }
  }
  return o;
}

std::string tclElement(const std::string &s) {
  if (s.empty()) return "{}";
  bool special = s[0] == '#';
  int depth = 0;
  bool balanced = true;
  for (char c : s) {
    switch (c) {
      case ' ': case '\t': case '\n': case '\r': case '\v': case '\f': case ';': case '"': case '$':
      case '[': case ']': case '\\':
        special = true; break;
      case '{': special = true; ++depth; break;
      case '}': special = true; if (--depth < 0) balanced = false; break;
    }
  }
  if (!special) return s;
  if (balanced && depth == 0 && s.back() != '\\') return "{" + s + "}";
  std::string o;
  for (char c : s) {
    if (strchr(" \t\n\r\v\f;\"$[]\\{}", c)) o += '\\';
    o += c;
  }
  return o;
}

static bool validUtf8(const std::string &s) {
  const unsigned char *p = (const unsigned char *)s.data(), *e = p + s.size();
  while (p < e) {
    unsigned c = *p++;
    if (c < 0x80) continue;
    int n;
    unsigned min;
    if ((c & 0xe0) == 0xc0) { n = 1; c &= 0x1f; min = 0x80; }
    else if ((c & 0xf0) == 0xe0) { n = 2; c &= 0x0f; min = 0x800; }
    else if ((c & 0xf8) == 0xf0) { n = 3; c &= 0x07; min = 0x10000; }
    else return false;
    if (e - p < n) return false;
    for (int i = 0; i < n; ++i) {
      if ((p[i] & 0xc0) != 0x80) return false;
      c = c << 6 | (p[i] & 0x3f);
    }
    p += n;
    if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return false;
  }
  return true;
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

static void preadAll(int fd, void *buf, size_t n, uint64_t off) {
  size_t done = 0;
  while (done < n) {
    ssize_t k = pread(fd, (char *)buf + done, n - done, (off_t)(off + done));
    if (k < 0 && errno == EINTR) continue;
    if (k <= 0) fail("TRUNCATED", "the file is shorter than its frame says (truncated while open?)");
    done += k;
  }
}

static uint64_t bound(uint64_t n) { return n + (n >> 12) + (n >> 14) + (n >> 25) + 13; }

// ---- the frame (section 1.1) and the seal (section 7.1) -------------------------------------------
static bool isUint(const std::string &s) {   // 0|[1-9][0-9]*
  if (s.empty() || s.size() > 19) return false;
  if (s[0] == '0') return s.size() == 1;
  for (char c : s) if (c < '0' || c > '9') return false;
  return true;
}

static bool isHex(const std::string &s) {
  if (s.empty()) return false;
  for (char c : s) if (hexval(c) < 0) return false;
  return true;
}

static std::vector<std::string> splitOn(const std::string &s, char sep) {
  std::vector<std::string> out;
  size_t a = 0;
  for (;;) {
    size_t b = s.find(sep, a);
    out.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
    if (b == std::string::npos) break;
    a = b + 1;
  }
  return out;
}

// `^key (\S+)$` for printable ASCII
static bool oneWord(const std::string &line, const char *key, std::string &v) {
  size_t k = strlen(key);
  if (line.compare(0, k, key) || line.size() < k + 2 || line[k] != ' ') return false;
  v = line.substr(k + 1);
  return v.find(' ') == std::string::npos;
}

static void parseStatement(const std::string &stmt, Frame &f) {
  for (unsigned char c : stmt)
    if (c != '\n' && (c < 0x20 || c > 0x7e)) fail("STATEMENT", "the statement is not printable ASCII");
  if (stmt.empty() || stmt.back() != '\n') fail("STATEMENT", "the statement does not end with a newline");
  std::vector<std::string> lines = splitOn(stmt.substr(0, stmt.size() - 1), '\n');
  static const char *want[] = {"ribbon-kit-seal", "format", "kind", "name", "version", "root", "header"};
  size_t i = 0;
  for (const std::string &line : lines) {
    std::string key = line.substr(0, line.find(' '));
    if (i < 7) {
      if (key != want[i]) fail("STATEMENT", "statement line " + std::to_string(i + 1) + " should be '" + want[i] + "', not '" + key + "'");
    } else if (!(i == 7 && key == "image")) {
      fail("STATEMENT", "unexpected statement line '" + line + "'");
    }
    std::string v;
    if (key == "ribbon-kit-seal") {
      if (line != "ribbon-kit-seal 1") fail("STATEMENT", "unknown statement version: " + line);
    } else if (key == "format") {
      size_t dot = line.find('.');
      std::string ma = dot == std::string::npos ? "" : line.substr(7, dot - 7), mi = dot == std::string::npos ? "" : line.substr(dot + 1);
      auto digits = [](const std::string &x) { if (x.empty() || x.size() > 9) return false; for (char c : x) if (c < '0' || c > '9') return false; return true; };
      if (line.compare(0, 7, "format ") || !digits(ma) || !digits(mi)) fail("STATEMENT", "bad format line: " + line);
      f.major = std::stoi(ma);
      f.minor = std::stoi(mi);
    } else if (key == "kind") {
      if (line != "kind app" && line != "kind system") fail("STATEMENT", "bad kind line: " + line);
      f.kind = line.substr(5);
    } else if (key == "name") {
      if (!oneWord(line, "name", f.name)) fail("STATEMENT", "bad name line");
    } else if (key == "version") {
      if (!oneWord(line, "version", f.version)) fail("STATEMENT", "bad version line");
    } else if (key == "root") {
      Hash h;
      if (!oneWord(line, "root", v) || !unhex64(v, h)) fail("STATEMENT", "bad root line");
      f.root = v;
    } else if (key == "header") {
      std::vector<std::string> w = splitOn(line, ' ');
      Hash h;
      if (w.size() != 3 || !isUint(w[1]) || !unhex64(w[2], h)) fail("STATEMENT", "bad header line");
      f.header = std::stoull(w[1]);
      f.headerHash = w[2];
    } else if (key == "image") {
      std::vector<std::string> w = splitOn(line, ' ');
      Hash h;
      bool ok = w.size() == 6 && (w[1] == "erofs" || w[1] == "squashfs") && isUint(w[2]) && isUint(w[3]) && w[3] != "0" &&
                (w[4] == "-" || unhex64(w[4], h)) && (w[5] == "-" || isHex(w[5]));
      if (!ok || w[5].size() > 256 || (w[5] != "-" && w[5].size() % 2)) fail("STATEMENT", "bad image line: " + line);
      f.image = true;
      f.imgFs = w[1];
      f.imgOffset = std::stoull(w[2]);
      f.imgLength = std::stoull(w[3]);
      f.imgVerity = w[4];
      f.imgSalt = w[5];
    }
    ++i;
  }
  if (i < 7) fail("STATEMENT", "the statement is incomplete");
}

Frame readFrame(int fd) {
  Frame f;
  struct stat sb;
  if (fstat(fd, &sb) || !S_ISREG(sb.st_mode)) fail("NOTKIT", "not a regular file");
  uint64_t size = (uint64_t)sb.st_size;
  if (size < 48) fail("TRUNCATED", "too short (" + std::to_string(size) + " bytes) to hold a Metakit store");
  uint8_t t[24];
  preadAll(fd, t, 24, size - 24);
  int64_t start;
  if (t[8] == 0x80 && !t[9] && !t[10] && !t[11] && t[16] == 0x80) {
    start = (int64_t)size - 16 - (int64_t)be32(t + 12);
    f.wide = false;
  } else if (t[0] == 0x82 && !t[1] && !t[2] && !t[3] && t[8] == 0x83 && t[16] == 0x81) {
    uint64_t skip = (uint64_t)t[9] << 48 | (uint64_t)t[10] << 40 | (uint64_t)t[11] << 32 | be32(t + 4);
    start = (int64_t)size - 24 - (int64_t)skip;
    f.wide = true;
  } else {
    fail("TRUNCATED", "does not end with Metakit's tails: not a Metakit file, or truncated");
  }
  if (start < 0 || start > (int64_t)size - 24) fail("TRUNCATED", "the tails point outside the file (truncated?)");
  uint8_t h[4];
  preadAll(fd, h, 4, start);
  if (!((h[0] == 0x4a && h[1] == 0x4c) || (h[0] == 0x4c && h[1] == 0x4a)) || h[2] != 0x1a)
    fail("TRUNCATED", "no Metakit header where its tails say the store starts (offset " + std::to_string(start) + ")");
  f.size = size;
  f.storeStart = start;
  if (start < 32) fail("SEAL", "a Metakit file with no kit seal in front of its store");
  uint8_t tr[32];
  preadAll(fd, tr, 32, start - 32);
  if (memcmp(tr, "KITSEAL\x1a", 8)) fail("SEAL", "a Metakit file with no kit seal in front of its store");
  uint32_t ver = be32(tr + 8), bsize = be32(tr + 12), slen = be32(tr + 16), glen = be32(tr + 20), crc = be32(tr + 24), res = be32(tr + 28);
  if (ver != 1) fail("SEAL", "seal version " + std::to_string(ver) + " is not supported (this reader knows version 1)");
  if (bsize < 512 || bsize > kSealMax || bsize % 512 || bsize > (uint64_t)start || (uint64_t)slen + glen + 32 > bsize || res != 0)
    fail("SEAL", "the seal's sizes are inconsistent");
  f.sealStart = start - bsize;
  f.sealSize = bsize;
  std::vector<uint8_t> block(bsize);
  preadAll(fd, block.data(), bsize, f.sealStart);
  f.statement.assign((const char *)block.data(), slen);
  f.signature.assign((const char *)block.data() + slen, glen);
  for (size_t i = slen + glen; i < bsize - 32; ++i)
    if (block[i]) fail("SEAL", "the seal's padding is not all zero bytes");
  if (libdeflate_crc32(0, block.data(), (size_t)slen + glen) != crc) fail("SEAL", "the seal's checksum does not match (damaged seal)");
  parseStatement(f.statement, f);
  if (f.header != f.sealStart)
    fail("STATEMENT", "the statement says the header is " + std::to_string(f.header) + " bytes, but the seal starts at " + std::to_string(f.sealStart));
  return f;
}

// ---- signatures (section 7.3): minisign, verified with libcrypto's Ed25519 and BLAKE2b-512 ------------
static bool b64decode(const std::string &in, std::string &out) {
  std::string s = in;
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ' || s.back() == '\t')) s.pop_back();
  size_t a = 0;
  while (a < s.size() && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r')) ++a;
  s = s.substr(a);
  while (!s.empty() && s.back() == '=') s.pop_back();
  out.clear();
  uint32_t acc = 0;
  int bits = 0;
  for (char c : s) {
    int v;
    if (c >= 'A' && c <= 'Z') v = c - 'A';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
    else if (c >= '0' && c <= '9') v = c - '0' + 52;
    else if (c == '+') v = 62;
    else if (c == '/') v = 63;
    else return false;
    acc = (acc << 6 | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) { bits -= 8; out += (char)((acc >> bits) & 0xff); }
  }
  return true;
}

static std::string keyId(const std::string &b8) {
  std::string out;
  static const char *d = "0123456789ABCDEF";
  for (int i = 7; i >= 0; --i) { unsigned char c = b8[i]; out += d[c >> 4]; out += d[c & 15]; }
  return out;
}

static bool ed25519(const unsigned char pk[32], const unsigned char *sig, const unsigned char *msg, size_t n, bool &usable) {
  usable = false;
  EVP_PKEY *k = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nullptr, pk, 32);
  if (!k) return false;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  bool ok = false;
  if (c && EVP_DigestVerifyInit(c, nullptr, nullptr, nullptr, k) == 1) {
    usable = true;
    ok = EVP_DigestVerify(c, sig, 64, msg, n) == 1;
  }
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(k);
  return ok;
}

SigInfo checkSignature(const std::string &stmt, const std::string &sig, const std::vector<std::string> &keys) {
  SigInfo s;
  if (sig.empty()) { s.state = "unsigned"; s.detail = "the kit is not signed"; return s; }
  std::string t = sig;
  while (!t.empty() && t.back() == '\n') t.pop_back();
  std::vector<std::string> L = splitOn(t, '\n');
  std::string raw;
  if (L.size() != 4 || L[0].compare(0, 19, "untrusted comment: ") || L[2].compare(0, 17, "trusted comment: ")) {
    s.state = "invalid"; s.detail = "malformed signature: not a minisign signature"; return s;
  }
  if (!b64decode(L[1], raw) || raw.size() != 74 || (raw.compare(0, 2, "Ed") && raw.compare(0, 2, "ED"))) {
    s.state = "invalid"; s.detail = "malformed signature: not an Ed25519 minisign signature"; return s;
  }
  s.keyid = keyId(raw.substr(2, 8));
  s.comment = L[2].substr(17);
  if (keys.empty()) { s.state = "unchecked"; s.detail = "no trusted keys are configured"; return s; }
  std::string pk;
  for (const std::string &k : keys) {
    std::string r;
    if (b64decode(k, r) && r.size() == 42 && !r.compare(0, 2, "Ed") && keyId(r.substr(2, 8)) == s.keyid) { pk = r; break; }
  }
  if (pk.empty()) { s.state = "untrusted"; s.detail = "signed by key " + s.keyid + ", which is not a trusted key"; return s; }
  std::string global;
  if (!b64decode(L[3], global) || global.size() != 64) { s.state = "invalid"; s.detail = "malformed signature: bad global signature"; return s; }
  std::string msg = stmt;
  if (raw[1] == 'D') {   // prehashed: Ed25519 over BLAKE2b-512 of the message
    unsigned char md[64];
    unsigned int ml = 0;
    EVP_MD_CTX *c = EVP_MD_CTX_new();
    bool ok = c && EVP_DigestInit_ex(c, EVP_blake2b512(), nullptr) == 1 && EVP_DigestUpdate(c, stmt.data(), stmt.size()) == 1 &&
              EVP_DigestFinal_ex(c, md, &ml) == 1 && ml == 64;
    EVP_MD_CTX_free(c);
    if (!ok) { s.state = "unchecked"; s.detail = "the signature could not be checked: no BLAKE2b-512 in libcrypto"; return s; }
    msg.assign((const char *)md, 64);
  }
  bool usable;
  const unsigned char *pkb = (const unsigned char *)pk.data() + 10;
  bool ok1 = ed25519(pkb, (const unsigned char *)raw.data() + 10, (const unsigned char *)msg.data(), msg.size(), usable);
  if (!usable) { s.state = "unchecked"; s.detail = "the signature could not be checked: no Ed25519 in libcrypto"; return s; }
  std::string gm = raw.substr(10, 64) + s.comment;
  bool ok2 = ok1 && ed25519(pkb, (const unsigned char *)global.data(), (const unsigned char *)gm.data(), gm.size(), usable);
  if (ok1 && ok2) { s.state = "valid"; s.detail = "good signature by trusted key " + s.keyid; }
  else { s.state = "invalid"; s.detail = "BAD signature (key " + s.keyid + ")"; }
  return s;
}

// ---- Metakit, read-only on our own mapping ---------------------------------------------------------------
// A strategy over a mapping this code made: Metakit then reads every column straight from it, and the
// position of each memo in the file is the distance of its first byte from the mapping's start.
namespace {
class MapStrategy : public c4_Strategy {
 public:
  MapStrategy(const uint8_t *base, uint64_t size) : _base(base), _size(size) {
    _mapStart = base;
    _dataSize = size;
  }
  ~MapStrategy() override { _mapStart = 0; }
  bool IsValid() const override { return true; }
  int DataRead(t4_fpos pos, void *buf, int len) override {
    t4_fpos at = _baseOffset + pos;
    if (pos < 0 || at < 0 || (uint64_t)at > _size || len < 0) { ++_failure; return -1; }
    uint64_t n = std::min<uint64_t>((uint64_t)len, _size - (uint64_t)at);
    memcpy(buf, _base + at, n);
    return (int)n;
  }
  void DataWrite(t4_fpos, const void *, int) override { ++_failure; }
  void DataCommit(t4_fpos) override {}
  void ResetFileMapping() override {}
  t4_fpos FileSize() override { return (t4_fpos)_size; }
  t4_i32 FreshGeneration() override { return 1; }

 private:
  const uint8_t *_base;
  uint64_t _size;
};

// a parsed Metakit layout: name, type letter ('V' for a subview), subfields
struct Field {
  std::string name;
  char type = 'S';
  std::vector<Field> sub;
};

void parseFields(const char *&p, std::vector<Field> &out) {
  while (*p && *p != ']') {
    Field f;
    while (*p && *p != ':' && *p != '[' && *p != ',' && *p != ']') f.name += *p++;
    if (*p == ':') { ++p; f.type = *p ? *p++ : 'S'; while (*p && *p != ',' && *p != ']') ++p; }
    else if (*p == '[') { ++p; f.type = 'V'; parseFields(p, f.sub); if (*p == ']') ++p; }
    out.push_back(std::move(f));
    if (*p == ',') ++p;
  }
}

const Field *findField(const std::vector<Field> &fs, const std::string &name) {
  for (const Field &f : fs) if (f.name == name) return &f;
  return nullptr;
}

// every property of `need` (a layout string) must be in `have` with that type
void needLayout(const std::vector<Field> &have, const char *need, const std::string &where) {
  std::vector<Field> want;
  const char *p = need;
  parseFields(p, want);
  std::function<void(const std::vector<Field> &, const std::vector<Field> &, const std::string &)> rec =
    [&](const std::vector<Field> &h, const std::vector<Field> &w, const std::string &at) {
      for (const Field &f : w) {
        const Field *g = findField(h, f.name);
        if (f.type == 'V') {
          if (!g || g->type != 'V') fail("STRUCTURE", at + " has no subview '" + f.name + "'");
          rec(g->sub, f.sub, at + "." + f.name);
        } else if (!g || g->type != f.type) {
          fail("STRUCTURE", at + " has no property " + f.name + ":" + std::string(1, f.type));
        }
      }
    };
  rec(have, want, where);
}

int itemSize(const c4_RowRef &r, const c4_Property &p) {
  c4_Cursor c = &r;
  return c._seq->ItemSize(c._index, p.GetId());
}

// an S value, refused if it is not a clean C string
std::string getS(const c4_RowRef &r, const c4_StringProp &p, const std::string &where) {
  c4_Bytes b;
  p(r).GetData(b);
  int n = b.Size();
  if (n == 0) return std::string();
  const char *s = (const char *)b.Contents();
  if (s[n - 1] != 0 || memchr(s, 0, n - 1)) fail("STRUCTURE", where + ": NUL in a value");
  return std::string(s, n - 1);
}

bool isHex64(const std::string &s) { Hash h; return unhex64(s, h); }

// [a-z][a-z0-9-]*
bool keyLike(const std::string &s) {
  if (s.empty() || s[0] < 'a' || s[0] > 'z') return false;
  for (char c : s) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  return true;
}

// reverse-DNS: labels [a-z0-9]([a-z0-9-]*[a-z0-9])? joined by '.', two or more
bool dnsName(const std::string &s) {
  std::vector<std::string> L = splitOn(s, '.');
  if (L.size() < 2) return false;
  for (const std::string &l : L) {
    if (l.empty()) return false;
    for (char c : l) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    if (l.front() == '-' || l.back() == '-') return false;
  }
  return true;
}

// [0-9A-Za-z][0-9A-Za-z.+~_-]*
bool versionLike(const std::string &s) {
  if (s.empty() || !isalnum((unsigned char)s[0])) return false;
  for (char c : s) if (!(isalnum((unsigned char)c) || strchr(".+~_-", c))) return false;
  return true;
}

void validName(const std::string &n, const std::string &where) {
  if (n.empty() || n == "." || n == ".." || n.find('/') != std::string::npos) fail("PATH", where + ": invalid name '" + n + "'");
  for (unsigned char c : n) if (c < 0x20 || c == 0x7f || c == '\\') fail("PATH", where + ": invalid name '" + n + "'");
  if (n.size() > kName) fail("LIMIT", where + ": name longer than 255 bytes");
}
}  // namespace

// ---- opening ------------------------------------------------------------------------------------------------
std::unique_ptr<Kit> Kit::open(const std::string &path, const OpenOptions &opt) {
  int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOCTTY);
  if (fd < 0) fail("NOTKIT", path + ": " + strerror(errno));
  try {
    return open(fd, opt);
  } catch (...) {
    close(fd);
    throw;
  }
}

std::unique_ptr<Kit> Kit::open(int fd, const OpenOptions &opt) {
  std::unique_ptr<Kit> k(new Kit);
  k->frame = readFrame(fd);
  const Frame &f = k->frame;
  if (f.major != 1) fail("VERSION", "kit format " + std::to_string(f.major) + "." + std::to_string(f.minor) + ": this reader reads format 1.x only");
  k->sig = checkSignature(f.statement, f.signature, opt.keys);
  if (opt.requireSigned && k->sig.state != "valid") fail("SIGNATURE", "the kit's signature is " + k->sig.state + ": " + k->sig.detail);
  void *m = mmap(nullptr, f.size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (m == MAP_FAILED) fail("IO", std::string("cannot map the file: ") + strerror(errno));
  madvise(m, f.size, MADV_RANDOM);
  try {
    k->load((const uint8_t *)m, opt);
  } catch (...) {
    munmap(m, f.size);
    throw;
  }
  munmap(m, f.size);
  k->fd = fd;
  return k;
}

Kit::~Kit() {
  if (fd >= 0) close(fd);
}

std::string Kit::field(const std::string &key) const {
  for (auto &kv : fields) if (kv.first == key) return kv.second;
  return std::string();
}

void Kit::load(const uint8_t *map, const OpenOptions &opt) {
  MapStrategy strat(map, frame.size);
  c4_Storage st(strat, false, 0);
  if (st.IsDamaged()) fail("STRUCTURE", "Metakit reports a damaged datafile");
  if ((uint64_t)strat._baseOffset != frame.storeStart) fail("STRUCTURE", "Metakit found its store somewhere else than the frame says");
  std::vector<Field> views;
  {
    const char *d = st.Description();
    const char *p = d ? d : "";
    parseFields(p, views);
  }
  for (const char *v : {"kit", "manifest", "needs", "provides", "perms", "entries", "effects", "dirs", "image"}) {
    const Field *fv = findField(views, v);
    if (!fv || fv->type != 'V') fail("STRUCTURE", std::string("the store has no '") + v + "' view");
  }
  auto layout = [&](const char *v) -> const std::vector<Field> & { return findField(views, v)->sub; };

  // ---- the format marker (section 9)
  needLayout(layout("kit"), "format:S,major:I,minor:I,requires:S", "kit");
  c4_View kv = st.View("kit");
  if (kv.GetSize() != 1) fail("STRUCTURE", "the kit view must have exactly one row");
  c4_StringProp pFormat("format"), pRequires("requires"), pWriter("writer");
  c4_IntProp pMajor("major"), pMinor("minor");
  std::string format = getS(kv[0], pFormat, "kit");
  major = (t4_i32)pMajor(kv[0]);
  minor = (t4_i32)pMinor(kv[0]);
  std::string req = getS(kv[0], pRequires, "kit");
  if (format != "ribbon-kit") fail("STRUCTURE", "the format marker says '" + format + "', not 'ribbon-kit'");
  if (major != 1) fail("VERSION", "kit format " + std::to_string(major) + "." + std::to_string(minor) + ": this reader reads format 1.x only");
  {
    // as Tcl's [lsort -unique [split [string trim $requires]]]
    size_t a = 0, b = req.size();
    auto ws = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; };
    while (a < b && ws(req[a])) ++a;
    while (b > a && ws(req[b - 1])) --b;
    std::vector<std::string> feats;
    if (b > a) {
      std::string cur;
      for (size_t i = a; i <= b; ++i) {
        if (i == b || req[i] == ' ' || req[i] == '\t' || req[i] == '\n' || req[i] == '\r') { feats.push_back(cur); cur.clear(); }
        else cur += req[i];
      }
    }
    std::sort(feats.begin(), feats.end());
    feats.erase(std::unique(feats.begin(), feats.end()), feats.end());
    for (const std::string &x : feats) {
      bool ok = !x.empty() && ((x[0] >= 'a' && x[0] <= 'z') || (x[0] >= '0' && x[0] <= '9'));
      for (char c : x) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) ok = false;
      if (!ok) fail("STRUCTURE", "bad feature name '" + x + "'");
      if (x != "codec-zstd") fail("FEATURE", "the kit requires feature '" + x + "', which this reader does not know");
    }
    features = feats;
  }
  if (findField(layout("kit"), "writer")) writer = getS(kv[0], pWriter, "kit");

  // ---- the manifest (section 4)
  struct MV { const char *view; const char *props; std::vector<std::vector<std::string>> *rows; };
  std::vector<std::vector<std::string>> mrows;
  MV mvs[] = {{"manifest", "key:S,value:S", &mrows}, {"needs", "name:S,range:S", &needs}, {"provides", "name:S,version:S", &provides},
              {"perms", "name:S,value:S", &perms}, {"entries", "name:S,path:S,args:S,type:S", &entries}, {"effects", "type:S,value:S", &effects}};
  for (MV &mv : mvs) {
    needLayout(layout(mv.view), mv.props, mv.view);
    c4_View v = st.View(mv.view);
    int n = v.GetSize();
    if ((uint64_t)n > kRows) fail("LIMIT", std::string("more than 10000 rows in ") + mv.view);
    std::vector<Field> pf;
    const char *pp = mv.props;
    parseFields(pp, pf);
    for (int i = 0; i < n; ++i) {
      std::vector<std::string> row;
      for (const Field &fd : pf) {
        c4_StringProp prop(fd.name.c_str());
        std::string x = getS(v[i], prop, std::string(mv.view) + " row " + std::to_string(i));
        if (x.size() > kValue) fail("LIMIT", std::string(mv.view) + " row " + std::to_string(i) + ": a value longer than 65536 bytes");
        if (!validUtf8(x)) fail("STRUCTURE", std::string(mv.view) + " row " + std::to_string(i) + ": a value that is not UTF-8");
        row.push_back(std::move(x));
      }
      mv.rows->push_back(std::move(row));
    }
  }
  {
    std::unordered_set<std::string> seen;
    for (auto &r : mrows) {
      if (!keyLike(r[0]) || r[0].size() > 64) fail("STRUCTURE", "bad manifest key '" + r[0] + "'");
      if (!seen.insert(r[0]).second) fail("STRUCTURE", "manifest key '" + r[0] + "' appears twice");
      fields.emplace_back(r[0], r[1]);
    }
    for (const char *key : {"name", "version", "kind"})
      if (!seen.count(key)) fail("STRUCTURE", std::string("the manifest has no '") + key + "'");
    std::string nm = field("name"), vs = field("version"), kd = field("kind");
    if (!dnsName(nm) || nm.size() > 255) fail("STRUCTURE", "manifest name '" + nm + "' is not a reverse-DNS name");
    if (!versionLike(vs) || vs.size() > 64) fail("STRUCTURE", "manifest version '" + vs + "' is not valid");
    if (kd != "app" && kd != "system") fail("STRUCTURE", "manifest kind must be app or system");
    for (auto &r : perms) if (!keyLike(r[0])) fail("STRUCTURE", "bad permission name '" + r[0] + "'");
  }

  // ---- the tree (section 5)
  needLayout(layout("dirs"),
             "name:S,parent:I,mode:I,files[name:S,size:I,date:I,contents:B,mode:I,link:S,fsize:L,codec:S,csize:I,hash:S,chunks[z:B,hash:S]]", "dirs");
  c4_View dv = st.View("dirs");
  int nd = dv.GetSize();
  if (nd < 1) fail("STRUCTURE", "the dirs view is empty (no root directory)");
  if ((uint64_t)nd > kEntries) fail("LIMIT", "more than 1000000 directories");
  c4_StringProp pName("name"), pLinkP("link"), pCodec("codec"), pHash("hash");
  c4_IntProp pParent("parent"), pMode("mode"), pSize("size"), pDate("date"), pCsize("csize");
  c4_LongProp pFsize("fsize");
  c4_BytesProp pContents("contents"), pZ("z"), pData("data");
  c4_ViewProp pFiles("files"), pChunks("chunks"), pSegs("segs");

  const uint8_t *storeLo = map + frame.storeStart, *mapHi = map + frame.size;
  // where a memo is in the file; refused if it is not inside the store (or not mapped at all)
  auto memo = [&](const c4_RowRef &r, const c4_BytesProp &p, uint32_t len, const std::string &where) -> uint64_t {
    if (len == 0) return 0;
    c4_Bytes b = p(r).Access(0, len, true);
    const uint8_t *q = b.Contents();
    if (!q || q < storeLo || q > mapHi || (uint64_t)(mapHi - q) < len) fail("STRUCTURE", where + ": its data is not inside the store");
    return (uint64_t)(q - map);
  };

  std::vector<std::string> dname(nd);
  std::vector<int32_t> dparent(nd);
  nodes.resize(nd);
  {
    int32_t p = (t4_i32)pParent(dv[0]);
    if (p != -1) fail("STRUCTURE", "directory row 0 (the root) must have parent -1");
    dparent[0] = -1;
    nodes[0].mode = 0;
    nodes[0].type = T_DIR;
  }
  int32_t rootMode = (t4_i32)pMode(dv[0]);
  for (int d = 1; d < nd; ++d) {
    std::string n = getS(dv[d], pName, "directory row " + std::to_string(d));
    int32_t p = (t4_i32)pParent(dv[d]), m = (t4_i32)pMode(dv[d]);
    if (p < 0 || p >= nd || p == d) fail("STRUCTURE", "directory row " + std::to_string(d) + " has an invalid parent " + std::to_string(p));
    validName(n, "directory row " + std::to_string(d));
    if (!validUtf8(n)) fail("STRUCTURE", "directory row " + std::to_string(d) + ": a name that is not UTF-8");
    if (m < 0 || m > 0777) fail("STRUCTURE", "directory row " + std::to_string(d) + ": mode has bits outside 0777");
    dname[d] = n;
    dparent[d] = p;
    nodes[d].mode = (uint16_t)m;
    nodes[d].type = T_DIR;
    nodes[d].parent = (uint32_t)p;
  }
  std::vector<std::string> dpath(nd);
  for (int d = 1; d < nd; ++d) {
    std::vector<int> chain;
    int x = d;
    uint64_t depth = 0;
    while (x != 0) {
      if (++depth > kDepth) fail("LIMIT", "directory row " + std::to_string(d) + " is nested deeper than 64 (or its parents form a cycle)");
      chain.push_back(x);
      x = dparent[x];
    }
    std::string s;
    for (size_t i = chain.size(); i-- > 0;) { if (!s.empty()) s += '/'; s += dname[chain[i]]; }
    dpath[d] = s;
  }
  std::unordered_set<std::string> seen;   // every path, as kitfmt's entry dict
  seen.reserve(nd * 2);
  for (int d = 1; d < nd; ++d) {
    if (!seen.insert(dpath[d]).second) fail("STRUCTURE", "duplicate entry " + dpath[d]);
    if (dpath[d].size() > kPath) fail("LIMIT", "path longer than 4096 bytes: " + dpath[d]);
  }
  if (rootMode < 0 || rootMode > 0777) fail("STRUCTURE", "the root directory's mode has bits outside 0777");
  nodes[0].mode = (uint16_t)rootMode;

  // node names into the pool (directories first; files and links are appended below)
  for (int d = 0; d < nd; ++d) {
    nodes[d].name = (uint32_t)pool.size();
    nodes[d].nameLen = (uint32_t)dname[d].size();
    pool += dname[d];
    pool += '\0';
  }
  std::vector<std::string> fpath;   // paths of file/link nodes (index = node - nd)
  uint64_t total = (uint64_t)nd;
  for (int d = 0; d < nd; ++d) {
    c4_View fv = pFiles(dv[d]);
    int nf = fv.GetSize();
    for (int fi = 0; fi < nf; ++fi) {
      if (++total > kEntries) fail("LIMIT", "more than 1000000 entries");
      c4_RowRef row = fv[fi];
      std::string where = "file row " + std::to_string(fi) + " of directory " + dpath[d];
      std::string n = getS(row, pName, where);
      std::string link = getS(row, pLinkP, where), codec = getS(row, pCodec, where), hash = getS(row, pHash, where);
      int32_t size = (t4_i32)pSize(row), date = (t4_i32)pDate(row), mode = (t4_i32)pMode(row), csize = (t4_i32)pCsize(row);
      int64_t fsize = (t4_i64)pFsize(row);
      validName(n, where);
      if (!validUtf8(n)) fail("STRUCTURE", where + ": a name that is not UTF-8");
      std::string p = dpath[d].empty() ? n : dpath[d] + "/" + n;
      if (!seen.insert(p).second) fail("STRUCTURE", "duplicate entry " + p);
      if (p.size() > kPath) fail("LIMIT", "path longer than 4096 bytes: " + p);
      if (mode < 0 || mode > 0777) fail("STRUCTURE", p + ": mode has bits outside 0777 (no setuid, setgid, sticky or file type bits)");
      int csz = itemSize(row, pContents);
      c4_View cv = pChunks(row);
      int nch = cv.GetSize();
      Node nd2;
      nd2.parent = (uint32_t)d;
      nd2.mode = (uint16_t)mode;
      nd2.date = date;
      nd2.name = (uint32_t)pool.size();
      nd2.nameLen = (uint32_t)n.size();
      pool += n;
      pool += '\0';
      if (!link.empty()) {
        if (link.size() > kLink) fail("LIMIT", p + ": symlink target too long");
        if (!validUtf8(link)) fail("STRUCTURE", p + ": a link target that is not UTF-8");
        if (!codec.empty() || fsize != 0 || size != 0 || csz != 0 || nch != 0 || !hash.empty()) fail("STRUCTURE", p + ": a symlink carries no data");
        nd2.type = T_LINK;
        nd2.link = (uint32_t)pool.size();
        nd2.linkLen = (uint32_t)link.size();
        pool += link;
        pool += '\0';
        nodes.push_back(nd2);
        fpath.push_back(p);
        continue;
      }
      if (fsize < 0 || (uint64_t)fsize > kFileMax) fail("LIMIT", p + ": size out of range");
      if ((fsize <= 0x7fffffff && size != fsize) || (fsize > 0x7fffffff && size != -1)) fail("STRUCTURE", p + ": size and fsize disagree");
      nd2.type = T_FILE;
      nd2.size = (uint64_t)fsize;
      nd2.chunk0 = (uint32_t)chunks.size();
      if (codec == "classic") {
        if (nch != 0 || csize != 0) fail("STRUCTURE", p + ": a classic file has no chunks");
        if ((uint64_t)fsize > kClassic || (uint64_t)csz > kClassic) fail("LIMIT", p + ": a classic file is limited to 16777216 bytes");
        Chunk c;
        if (!unhex64(hash, c.hash)) fail("STRUCTURE", p + ": a classic file needs its hash");
        if (csz != fsize && (uint64_t)csz > bound(fsize)) fail("STRUCTURE", p + ": stored more bytes than deflate can need");
        c.zlen = (uint32_t)csz;
        c.plain = (uint32_t)fsize;
        c.off = memo(row, pContents, c.zlen, p);
        chunks.push_back(c);
        nd2.codec = C_CLASSIC;
        nd2.nchunks = 1;
        stored += c.zlen;
      } else if (codec == "raw" || codec == "deflate" || codec == "zstd") {
        if (codec == "zstd" && std::find(features.begin(), features.end(), "codec-zstd") == features.end())
          fail("STRUCTURE", p + ": codec zstd needs the feature codec-zstd");
        if (csz != 0 || !hash.empty()) fail("STRUCTURE", p + ": a chunked file keeps its data in chunks only");
        if ((uint64_t)csize < kChunkMin || (uint64_t)csize > kChunkMax || (csize & (csize - 1)))
          fail("STRUCTURE", p + ": chunk size " + std::to_string(csize) + " is not a power of two from 4096 to 1048576");
        uint64_t want = ((uint64_t)fsize + csize - 1) / csize;
        if ((uint64_t)nch != want) fail("STRUCTURE", p + ": " + std::to_string(nch) + " chunks, " + std::to_string(want) + " expected");
        nd2.codec = codec == "raw" ? C_RAW : codec == "deflate" ? C_DEFLATE : C_ZSTD;
        nd2.csize = (uint32_t)csize;
        nd2.nchunks = (uint32_t)nch;
        for (int i = 0; i < nch; ++i) {
          Chunk c;
          std::string hx = getS(cv[i], pHash, p + " chunk " + std::to_string(i));
          if (!unhex64(hx, c.hash)) fail("STRUCTURE", p + ": chunk " + std::to_string(i) + " has no valid hash");
          int zl = itemSize(cv[i], pZ);
          uint64_t plain = i < nch - 1 ? (uint64_t)csize : (uint64_t)fsize - (uint64_t)i * csize;
          if ((nd2.codec == C_RAW && (uint64_t)zl != plain) || (nd2.codec != C_RAW && (zl < 1 || (uint64_t)zl > bound(plain))))
            fail("STRUCTURE", p + ": chunk " + std::to_string(i) + " stores " + std::to_string(zl) + " bytes for " + std::to_string(plain));
          c.zlen = (uint32_t)zl;
          c.plain = (uint32_t)plain;
          c.off = memo(cv[i], pZ, c.zlen, p + " chunk " + std::to_string(i));
          chunks.push_back(c);
          stored += c.zlen;
        }
        nChunks += nch;
      } else {
        fail("STRUCTURE", p + ": unknown codec '" + codec + "'");
      }
      bytes += nd2.size;
      nodes.push_back(nd2);
      fpath.push_back(p);
    }
  }
  nEntries = nodes.size() - 1;
  newest = 0;
  for (const Node &n : nodes) if (n.type != T_DIR && n.date > newest) newest = n.date;

  // ---- the image (section 8)
  needLayout(layout("image"), "fs:S,len:L,pad:I,seg:I,verity:S,salt:S,segs[hash:S],data:B", "image");
  c4_View iv = st.View("image");
  uint64_t memoOff = 0;
  if (iv.GetSize() > 1) fail("STRUCTURE", "a kit carries at most one image");
  if (iv.GetSize() == 1) {
    c4_RowRef r = iv[0];
    c4_StringProp pFs("fs"), pVerity("verity"), pSalt("salt");
    c4_LongProp pLen("len");
    c4_IntProp pPad("pad"), pSeg("seg");
    Image &I = image;
    I.fs = getS(r, pFs, "image");
    int64_t len = (t4_i64)pLen(r);
    int32_t pad = (t4_i32)pPad(r), seg = (t4_i32)pSeg(r);
    I.verity = getS(r, pVerity, "image");
    I.salt = getS(r, pSalt, "image");
    if (I.fs != "erofs" && I.fs != "squashfs") fail("STRUCTURE", "image: unknown filesystem '" + I.fs + "'");
    if (len <= 0 || len % 4096) fail("STRUCTURE", "image: length is not a positive multiple of 4096");
    if (pad < 0 || (uint64_t)pad >= kPad) fail("STRUCTURE", "image: pad out of range");
    if ((uint64_t)seg < kSegMin || (uint64_t)seg > kSegMax || (seg & (seg - 1))) fail("STRUCTURE", "image: segment size is not a power of two from 64 KiB to 16 MiB");
    if (!I.verity.empty() && !isHex64(I.verity)) fail("STRUCTURE", "image: verity root is not 64 hex digits");
    if (!I.salt.empty() && (I.salt.size() % 2 || I.salt.size() > 256 || !isHex(I.salt))) fail("STRUCTURE", "image: bad salt");
    c4_View sv = pSegs(r);
    uint64_t ns = (uint64_t)sv.GetSize();
    if (ns != ((uint64_t)len + seg - 1) / seg) fail("STRUCTURE", "image: wrong number of segment hashes");
    for (uint64_t i = 0; i < ns; ++i) {
      Hash h;
      if (!unhex64(getS(sv[(int)i], pHash, "image segment"), h)) fail("STRUCTURE", "image: segment " + std::to_string(i) + " has no valid hash");
      I.segs.push_back(h);
    }
    int msize = itemSize(r, pData);
    if ((int64_t)msize != (int64_t)pad + len) fail("STRUCTURE", "image: the memo's size is not pad + length");
    memoOff = memo(r, pData, (uint32_t)msize, "image");
    I.present = true;
    I.length = (uint64_t)len;
    I.pad = (uint32_t)pad;
    I.seg = (uint32_t)seg;
  }

  // ---- entry points name files or links of the kit
  {
    std::unordered_set<std::string> files(fpath.begin(), fpath.end());
    for (auto &e : entries)
      if (!files.count(e[1])) fail("STRUCTURE", "entry point '" + e[0] + "' names '" + e[1] + "', which is not a file of the kit");
  }

  // ---- children, sorted by name (lookups are binary searches)
  {
    std::vector<std::vector<uint32_t>> ch(nd);
    for (uint32_t i = 1; i < nodes.size(); ++i) ch[nodes[i].parent].push_back(i);
    for (int d = 0; d < nd; ++d) {
      std::sort(ch[d].begin(), ch[d].end(), [&](uint32_t a, uint32_t b) { return strcmp(nameOf(nodes[a]), nameOf(nodes[b])) < 0; });
      nodes[d].first = (uint32_t)kids.size();
      nodes[d].count = (uint32_t)ch[d].size();
      for (uint32_t c : ch[d]) { kids.push_back(c); if (nodes[c].type == T_DIR) ++nodes[d].ndirs; }
    }
  }

  // ---- the index and the root (section 6.2), the statement against the store (7.2)
  {
    std::vector<std::string> L;
    auto line = [](std::initializer_list<std::string> xs) {
      std::string s;
      bool first = true;
      for (const std::string &x : xs) { if (!first) s += '\t'; s += esc(x); first = false; }
      return s;
    };
    auto group = [&](std::vector<std::string> g) { std::sort(g.begin(), g.end()); for (auto &x : g) L.push_back(std::move(x)); };
    L.push_back("ribbon-kit-index 1");
    L.push_back(line({"format", std::to_string(major) + "." + std::to_string(minor)}));
    std::string rq;
    for (auto &x : features) { if (!rq.empty()) rq += ' '; rq += x; }
    L.push_back(line({"requires", rq}));
    std::vector<std::string> g;
    for (auto &kv2 : fields) g.push_back(line({"manifest", kv2.first, kv2.second}));
    group(std::move(g));
    g.clear(); for (auto &r : needs) g.push_back(line({"need", r[0], r[1]})); group(std::move(g));
    g.clear(); for (auto &r : provides) g.push_back(line({"provide", r[0], r[1]})); group(std::move(g));
    g.clear(); for (auto &r : perms) g.push_back(line({"perm", r[0], r[1]})); group(std::move(g));
    g.clear(); for (auto &r : entries) g.push_back(line({"entry", r[0], r[1], r[2], r[3]})); group(std::move(g));
    g.clear(); for (auto &r : effects) g.push_back(line({"effect", r[0], r[1]})); group(std::move(g));
    L.push_back(line({"rootdir", std::to_string(nodes[0].mode)}));
    std::vector<std::string> gd, gf, gl;
    for (int d = 1; d < nd; ++d) gd.push_back(line({"dir", dpath[d], std::to_string(nodes[d].mode)}));
    for (size_t i = (size_t)nd; i < nodes.size(); ++i) {
      const Node &n = nodes[i];
      const std::string &p = fpath[i - nd];
      if (n.type == T_LINK) {
        gl.push_back(line({"link", p, std::to_string(n.mode), std::to_string(n.date), linkOf(n)}));
      } else {
        std::string hs;
        for (uint32_t c = 0; c < n.nchunks; ++c) { if (c) hs += ','; hs += hex(chunks[n.chunk0 + c].hash.data(), 32); }
        gf.push_back(line({"file", p, std::to_string(n.mode), std::to_string(n.date), std::to_string(n.size), codecName(n.codec),
                           std::to_string(n.csize), hs}));
      }
    }
    group(std::move(gd));
    group(std::move(gf));
    group(std::move(gl));
    if (image.present) {
      std::string hs;
      for (size_t i = 0; i < image.segs.size(); ++i) { if (i) hs += ','; hs += hex(image.segs[i].data(), 32); }
      L.push_back(line({"image", image.fs, std::to_string(image.length), std::to_string(image.pad), std::to_string(image.seg),
                        image.verity, image.salt, hs}));
    }
    index.clear();
    for (auto &x : L) { index += x; index += '\n'; }
    uint8_t md[32];
    sha256(index.data(), index.size(), md);
    root = hex(md, 32);
    rootOk = root == frame.root;
  }
  // the statement against the store
  {
    std::string mv = std::to_string(major) + "." + std::to_string(minor), sv2 = std::to_string(frame.major) + "." + std::to_string(frame.minor);
    if (frame.major != major || frame.minor != minor) fail("STATEMENT", "the seal says format " + sv2 + ", the store " + mv);
    if (frame.kind != field("kind")) fail("STATEMENT", "the seal says kind '" + frame.kind + "', the manifest '" + field("kind") + "'");
    if (frame.name != field("name")) fail("STATEMENT", "the seal says name '" + frame.name + "', the manifest '" + field("name") + "'");
    if (frame.version != field("version")) fail("STATEMENT", "the seal says version '" + frame.version + "', the manifest '" + field("version") + "'");
    if (frame.image != image.present) fail("STATEMENT", "the seal and the store disagree about an embedded image");
    if (image.present) {
      if (frame.imgFs != image.fs || frame.imgLength != image.length) fail("STATEMENT", "the seal's image line does not match the image view");
      if (frame.imgVerity != (image.verity.empty() ? "-" : image.verity)) fail("STATEMENT", "the seal's image verity does not match the image view");
      if (frame.imgSalt != (image.salt.empty() ? "-" : image.salt)) fail("STATEMENT", "the seal's image salt does not match the image view");
      uint64_t off = frame.imgOffset;
      if (off % 4096) fail("STATEMENT", "the image offset is not 4096-aligned");
      if (off < frame.storeStart || off + image.length > frame.size) fail("STATEMENT", "the image offset points outside the store");
      if (memoOff + image.pad != off) fail("STATEMENT", "the image is not where the seal says it is (offset " + std::to_string(off) + ")");
      image.offset = off;
    }
  }
  if (!rootOk && !opt.force) fail("ROOT", "the kit's content does not match its seal: root " + root + ", the seal says " + frame.root);
}

// ---- lookups -----------------------------------------------------------------------------------------------
std::string Kit::pathOf(uint32_t node) const {
  std::string p;
  while (node != 0 && node < nodes.size()) {
    std::string n = nameOf(nodes[node]);
    p = p.empty() ? n : n + "/" + p;
    node = nodes[node].parent;
  }
  return p;
}

int64_t Kit::child(uint32_t dir, const char *name, size_t len) const {
  const Node &d = nodes[dir];
  if (d.type != T_DIR) return -1;
  size_t lo = 0, hi = d.count;
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    const Node &c = nodes[kids[d.first + mid]];
    int r = memcmp(nameOf(c), name, std::min<size_t>(c.nameLen, len));
    if (r == 0) r = c.nameLen < len ? -1 : c.nameLen > len ? 1 : 0;
    if (r == 0) return kids[d.first + mid];
    if (r < 0) lo = mid + 1; else hi = mid;
  }
  return -1;
}

int64_t Kit::find(const std::string &path) const {
  uint32_t cur = 0;
  size_t a = 0;
  while (a < path.size()) {
    if (path[a] == '/') { ++a; continue; }
    size_t b = path.find('/', a);
    if (b == std::string::npos) b = path.size();
    int64_t c = child(cur, path.data() + a, b - a);
    if (c < 0) return -1;
    cur = (uint32_t)c;
    a = b;
  }
  return cur;
}

// ---- reading -------------------------------------------------------------------------------------------------
namespace {
struct Scratch {
  std::vector<uint8_t> buf;
  libdeflate_decompressor *d = nullptr;
  ~Scratch() { if (d) libdeflate_free_decompressor(d); }
};
thread_local Scratch scratch;
}  // namespace

const char *Kit::loadChunk(uint32_t ci, uint8_t *out, uint8_t codec) const {
  const Chunk &c = chunks[ci];
  bool direct = codec == C_RAW || (codec == C_CLASSIC && c.zlen == c.plain);
  uint8_t *in = out;
  if (!direct) {
    if (scratch.buf.size() < c.zlen) scratch.buf.resize(std::max<size_t>(c.zlen, bound(kChunkMax)));
    in = scratch.buf.data();
  }
  size_t done = 0;
  while (done < c.zlen) {
    ssize_t k = pread(fd, in + done, c.zlen - done, (off_t)(c.off + done));
    if (k < 0 && errno == EINTR) continue;
    if (k <= 0) return "IO";
    done += (size_t)k;
  }
  uint8_t md[32];
  sha256(in, c.zlen, md);
  if (memcmp(md, c.hash.data(), 32)) return "HASH";
  if (direct) return "";
  if (codec == C_ZSTD) return "CODEC";
  if (!scratch.d && !(scratch.d = libdeflate_alloc_decompressor())) return "IO";
  size_t used = 0, got = 0;
  libdeflate_result r = libdeflate_zlib_decompress_ex(scratch.d, in, c.zlen, out, c.plain, &used, &got);
  if (r != LIBDEFLATE_SUCCESS || got != c.plain || used != c.zlen) return "CODEC";
  return "";
}

const char *Kit::readFile(uint32_t node, uint64_t off, size_t len, uint8_t *buf) const {
  const Node &n = nodes[node];
  if (n.type != T_FILE) return "TYPE";
  if (off >= n.size) return "";
  len = (size_t)std::min<uint64_t>(len, n.size - off);
  std::vector<uint8_t> piece;
  size_t done = 0;
  while (done < len) {
    uint64_t at = off + done;
    uint32_t ci = n.codec == C_CLASSIC ? 0 : (uint32_t)(at / n.csize);
    uint64_t base = n.codec == C_CLASSIC ? 0 : (uint64_t)ci * n.csize;
    const Chunk &c = chunks[n.chunk0 + ci];
    piece.resize(c.plain);
    const char *e = loadChunk(n.chunk0 + ci, piece.data(), n.codec);
    if (*e) return e;
    size_t from = (size_t)(at - base), k = std::min<size_t>(len - done, c.plain - from);
    memcpy(buf + done, piece.data() + from, k);
    done += k;
  }
  return "";
}

Kit::Verify Kit::verify() const {
  Verify v{true, image.present ? "ok" : "none", {}, 0};
  // the header (bytes in front of the seal)
  {
    std::vector<uint8_t> hd(frame.header);
    if (frame.header) {
      size_t done = 0;
      while (done < hd.size()) {
        ssize_t k = pread(fd, hd.data() + done, hd.size() - done, (off_t)done);
        if (k <= 0) break;
        done += (size_t)k;
      }
    }
    uint8_t md[32];
    sha256(hd.data(), hd.size(), md);
    if (hex(md, 32) != frame.headerHash) v.bad.push_back({"", "header", "the header does not match the seal"});
  }
  std::vector<uint8_t> out;
  for (size_t i = 1; i < nodes.size(); ++i) {
    const Node &n = nodes[i];
    if (n.type != T_FILE) continue;
    for (uint32_t c = 0; c < n.nchunks; ++c) {
      out.resize(chunks[n.chunk0 + c].plain);
      const char *e = loadChunk(n.chunk0 + c, out.data(), n.codec);
      ++v.chunks;
      // a zstd chunk's hash is checked; decoding it needs a decoder this reader does not have
      if (*e && !(n.codec == C_ZSTD && !strcmp(e, "CODEC")))
        v.bad.push_back({pathOf((uint32_t)i), std::to_string(c), std::string(e)});
    }
  }
  if (image.present) {
    std::vector<uint8_t> seg(image.seg);
    for (size_t i = 0; i < image.segs.size(); ++i) {
      uint64_t at = image.offset + (uint64_t)i * image.seg, n = std::min<uint64_t>(image.seg, image.length - (uint64_t)i * image.seg);
      size_t done = 0;
      while (done < n) {
        ssize_t k = pread(fd, seg.data() + done, n - done, (off_t)(at + done));
        if (k <= 0) break;
        done += (size_t)k;
      }
      uint8_t md[32];
      sha256(seg.data(), done, md);
      if (done != n || memcmp(md, image.segs[i].data(), 32)) {
        v.bad.push_back({"", "image", "segment " + std::to_string(i) + " does not match its hash"});
        v.image = "bad";
      }
    }
  }
  if (!rootOk) v.bad.push_back({"", "root", "the content does not match the seal's root hash"});
  v.ok = v.bad.empty();
  return v;
}

}  // namespace kit
