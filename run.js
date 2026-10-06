// Host for json2dir.wasm: instantiate it under Bun's WASI with the current directory as fd 3.
// All decisions live in the module; the host only fills gaps in the runtime (see README):
//  - host.make_executable: WASI preview1 has no chmod.
//  - path_filestat_get without SYMLINK_FOLLOW and path_unlink_file: Bun's WASI realpath()s the
//    final path component first, so a symlink that points outside the directory gets ENOTCAPABLE
//    instead of being inspected / removed. These two calls are re-implemented with lstat/unlink.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { WASI } = require("node:wasi");

const wasi = new WASI({
  version: "preview1",
  args: ["json2dir", ...process.argv.slice(2)],
  env: {},
  preopens: { ".": "." },
});

let memory;
const pathAt = (ptr, len) => Buffer.from(memory.buffer, ptr, len).toString();

// WASI errno values for the errors these calls can hit.
const ERRNO = { ENOENT: 44, ENOTDIR: 54, EACCES: 2, EPERM: 63, EISDIR: 31, ELOOP: 32, ENAMETOOLONG: 37, EBUSY: 10 };
const errno = (e) => ERRNO[e && e.code] || 28; // EINVAL

// Resolve a guest path below the preopened "." without following its final component;
// the parent directory must stay inside the preopen.
const base = fs.realpathSync(".");
function resolveNoFollow(ptr, len) {
  const full = path.resolve(base, pathAt(ptr, len));
  const parent = fs.realpathSync(path.dirname(full));
  if (full === base || (parent !== base && !parent.startsWith(base + path.sep))) throw { code: "EPERM" };
  return path.join(parent, path.basename(full));
}

function fileType(st) {
  if (st.isDirectory()) return 3;
  if (st.isFile()) return 4;
  if (st.isSymbolicLink()) return 7;
  if (st.isBlockDevice()) return 1;
  if (st.isCharacterDevice()) return 2;
  if (st.isSocket()) return 6;
  return 0; // unknown (FIFO)
}

const imports = { ...wasi.wasiImport };

imports.path_filestat_get = (fd, flags, ptr, len, buf) => {
  if (fd !== 3 || (flags & 1) !== 0) return wasi.wasiImport.path_filestat_get(fd, flags, ptr, len, buf);
  try {
    const st = fs.lstatSync(resolveNoFollow(ptr, len), { bigint: true });
    const view = new DataView(memory.buffer);
    view.setBigUint64(buf, st.dev, true);
    view.setBigUint64(buf + 8, st.ino, true);
    view.setBigUint64(buf + 16, BigInt(fileType(st)), true);
    view.setBigUint64(buf + 24, st.nlink, true);
    view.setBigUint64(buf + 32, st.size, true);
    view.setBigUint64(buf + 40, st.atimeNs, true);
    view.setBigUint64(buf + 48, st.mtimeNs, true);
    view.setBigUint64(buf + 56, st.ctimeNs, true);
    return 0;
  } catch (e) {
    return errno(e);
  }
};

imports.path_unlink_file = (fd, ptr, len) => {
  if (fd !== 3) return wasi.wasiImport.path_unlink_file(fd, ptr, len);
  try {
    fs.unlinkSync(resolveNoFollow(ptr, len));
    return 0;
  } catch (e) {
    return errno(e);
  }
};

const host = {
  // WASI preview1 has no chmod: add the execute bits (0o111) to a file the module just created.
  make_executable(ptr, len) {
    try {
      const p = resolveNoFollow(ptr, len);
      fs.chmodSync(p, fs.statSync(p).mode | 0o111);
      return 0;
    } catch (e) {
      return errno(e);
    }
  },
};

const wasmModule = new WebAssembly.Module(fs.readFileSync(path.join(__dirname, "out", "json2dir.wasm")));
const instance = new WebAssembly.Instance(wasmModule, { wasi_snapshot_preview1: imports, host });
memory = instance.exports.memory;
wasi.start(instance);
