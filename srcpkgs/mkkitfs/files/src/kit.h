// kit.h -- a reader of Ribbon kit files, format 1.0 (docs/KIT-FORMAT.md).
//
// The second implementation of the format (the first, the reference, is kit/kitfmt/kitfmt.tcl).
// It keeps the rules of KIT-FORMAT.md section 11: the frame and the seal are read before Metakit
// sees the file; the store is opened read-only and nothing is written next to it; every limit of
// section 10 is enforced; the index is rebuilt and its SHA-256 must be the seal's root; no payload
// value is fetched whole; every chunk is hashed before it is used and a mismatch is an error, never
// data.  Errors carry the same codes as kitfmt's (-errorcode {KITFMT <CODE>}).
//
// Metakit is used only while a kit is opened: the tree, the manifest and the position and hash of
// every chunk are copied into the compact tables below, and the Metakit storage and its file
// mapping are closed again.  Reading a chunk afterwards is one pread() of its stored bytes, a
// SHA-256 and (for deflate) one libdeflate call, with no lock, no Metakit and no allocation.
#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace kit {

// An error with one of kitfmt's codes: NOTKIT TRUNCATED SEAL VERSION FEATURE STRUCTURE LIMIT ROOT
// STATEMENT HASH CODEC NOENT TYPE PATH SIGNATURE CONFIG IO
struct Error {
  std::string code, msg;
  Error(std::string c, std::string m) : code(std::move(c)), msg(std::move(m)) {}
};

enum Type : uint8_t { T_DIR = 0, T_FILE = 1, T_LINK = 2 };
enum Codec : uint8_t { C_NONE = 0, C_RAW, C_DEFLATE, C_CLASSIC, C_ZSTD };
const char *codecName(uint8_t c);

using Hash = std::array<uint8_t, 32>;

// One stored piece of a file: a chunk, or a classic file's whole `contents`.
struct Chunk {
  uint64_t off;    // file offset of the stored bytes
  uint32_t zlen;   // stored length
  uint32_t plain;  // length once decoded
  Hash hash;       // SHA-256 of the stored bytes
};

// A directory, file or link.  Node 0 is the root.  Strings live in Kit::pool.
struct Node {
  uint32_t name = 0, nameLen = 0;
  uint32_t parent = 0;
  uint32_t first = 0, count = 0;  // directories: children are kids[first .. first+count), sorted by name
  uint32_t ndirs = 0;             // directories: how many children are directories
  uint32_t link = 0, linkLen = 0; // links: the target
  uint32_t chunk0 = 0, nchunks = 0;  // files: their pieces (a classic file has exactly one)
  uint64_t size = 0;
  int32_t date = 0;
  uint32_t csize = 0;             // chunk size (0 for classic)
  uint16_t mode = 0;
  uint8_t type = T_DIR, codec = C_NONE;
};

struct SigInfo {
  std::string state = "unsigned";   // unsigned unchecked untrusted valid invalid
  std::string detail, keyid, comment;
};

struct Image {
  bool present = false;
  std::string fs, verity, salt;
  uint64_t length = 0, offset = 0;
  uint32_t pad = 0, seg = 0;
  std::vector<Hash> segs;
};

struct OpenOptions {
  bool force = false;                 // open a kit whose root does not match its seal (to inspect it)
  bool requireSigned = false;         // refuse unless the signature is valid, before Metakit parses
  std::vector<std::string> keys;      // trusted minisign public keys (the base64 line)
};

// What "frame" reading finds without Metakit (section 1.1 and 7).
struct Frame {
  uint64_t size = 0, storeStart = 0, sealStart = 0, sealSize = 0;
  bool wide = false;
  std::string statement, signature;
  // the statement
  int major = 0, minor = 0;
  std::string kind, name, version, root, headerHash;
  uint64_t header = 0;
  bool image = false;
  std::string imgFs, imgVerity, imgSalt;
  uint64_t imgOffset = 0, imgLength = 0;
};

// Reads the frame and the seal of an open file (never Metakit).  Throws Error.
Frame readFrame(int fd);
// The signature state of a seal, given trusted keys (section 7.3).
SigInfo checkSignature(const std::string &statement, const std::string &signature,
                       const std::vector<std::string> &keys);

class Kit {
 public:
  // Opens and checks a kit (section 11, steps 1-5).  Takes ownership of fd on success.
  static std::unique_ptr<Kit> open(int fd, const OpenOptions &opt);
  static std::unique_ptr<Kit> open(const std::string &path, const OpenOptions &opt);
  ~Kit();

  int fd = -1;
  Frame frame;
  SigInfo sig;
  int major = 0, minor = 0;
  std::vector<std::string> features;
  std::string writer;

  // the manifest views, as rows of strings, in store order
  std::vector<std::pair<std::string, std::string>> fields;   // manifest: key value
  std::vector<std::vector<std::string>> needs, provides, perms, entries, effects;
  std::string field(const std::string &k) const;

  std::vector<Node> nodes;
  std::vector<uint32_t> kids;
  std::vector<Chunk> chunks;
  std::string pool;
  Image image;

  std::string index;     // the index text (section 6.2)
  std::string root;      // hex SHA-256 of the index
  bool rootOk = false;
  uint64_t nEntries = 0, nChunks = 0, stored = 0, bytes = 0;
  int32_t newest = 0;    // newest date of any entry (what directories show)

  // names and paths
  const char *nameOf(const Node &n) const { return pool.data() + n.name; }
  std::string pathOf(uint32_t node) const;
  std::string linkOf(const Node &n) const { return pool.substr(n.link, n.linkLen); }
  // the child of a directory with this name, or -1
  int64_t child(uint32_t dir, const char *name, size_t len) const;
  // a path ("" or "/" for the root) to a node, or -1
  int64_t find(const std::string &path) const;

  // Reads stored piece `ci` and decodes it into out (exactly chunks[ci].plain bytes).
  // Returns "" on success, else an error code: HASH, CODEC or IO.  Thread-safe, no allocation once
  // the calling thread has read a piece of this size before.
  const char *loadChunk(uint32_t ci, uint8_t *out, uint8_t codec) const;
  // Reads [off, off+len) of a file into buf (for the command line tools).
  const char *readFile(uint32_t node, uint64_t off, size_t len, uint8_t *buf) const;

  struct Bad { std::string path; std::string what; std::string detail; };
  // verify: every chunk, the image, the header, the root (section 11; kitfmt verify)
  struct Verify { bool ok; std::string image; std::vector<Bad> bad; uint64_t chunks; };
  Verify verify() const;

 private:
  Kit() = default;
  void load(const uint8_t *map, const OpenOptions &opt);
  void buildIndex();
};

// SHA-256 (OpenSSL's libcrypto, SHA-NI where the CPU has it)
void sha256(const void *p, size_t n, uint8_t out[32]);
std::string hex(const uint8_t *p, size_t n);
bool unhex64(const std::string &s, Hash &out);
// the escaping of index fields (section 6.2)
std::string esc(const std::string &s);
// Tcl list quoting of one element (for the .expect format)
std::string tclElement(const std::string &s);

}  // namespace kit
