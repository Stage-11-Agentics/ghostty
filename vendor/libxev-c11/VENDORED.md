# C11-294 libxev backpressure patch

This directory stores a readable patch and reproducible archive recipe. It does
not duplicate libxev's source tree. The candidate archive contains the exact
previously pinned libxev source plus one change to `src/watcher/stream.zig`.

- Base: `mitchellh/libxev` commit `34fa50878aec6e5fa8f532867001ab3c36fae23e`.
- Original archive: `https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz`.
- Original archive SHA256: `6003ea6b96e4a518a128f932327d79a11bd30996b13b73baeb29916379487dd7`.
- Original Zig package hash: `libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs`.
- Adapted patch: Ghostty fork commit `2f6ee7b3dbe8291287c5e5920c1a23fe575a0b0d`,
  "fix: preserve queued writes through backpressure", by austinpower1258
  `<austinwang115@gmail.com>` (2026-07-28).

The callback retains the same queued request on `WouldBlock`, rearms its current
remaining buffer, and advances the queue only after completion or a terminal
error. It retains the existing partial-write suffix handling. No newer libxev
architecture or unrelated upstream changes are included.

Reproduce from this checkout with Python 3, curl and git:

```sh
python3 vendor/libxev-c11/build-archive.py /tmp/libxev-c11-build
```

Use a new output directory. The script checks the original archive checksum,
applies the checked-in patch, and emits normalized, sorted tar entries with a
zero-timestamp gzip header. Two independent builds during C11-294 produced
identical archive bytes:

`09894d19e0bef35b9d0b70bddcc722106fe0ad72f1fdff43a017a44b8f822e8d`

The integration owner publishes this archive at an immutable commit URL, computes
its Zig package hash with `zig fetch`, and updates `build.zig.zon`. Do not modify a
user's existing content-addressed Zig cache entry to apply this fix.

Runtime evidence uses the real pinned macOS kqueue backend, a nonblocking PTY,
and 64-byte queued writes. Ordinary consumer saturation delivered 524,288 bytes
exactly. An explicitly synthetic competing writer triggered a real `WouldBlock`
callback after the original watcher popped the request; all 8,192 callbacks ran
but exactly 64 bytes were missing. That establishes dependency reachability, not
normal c11 workload incidence. The candidate passed the same competing-writer
probe with all bytes in order. The parent repository contains the executable
probe under `tests/ghostty_patchset/`.
