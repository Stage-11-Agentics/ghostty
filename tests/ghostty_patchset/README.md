# Native read ABI fixture

The opt-in library root `src/c11_read_test.zig` imports the production C exports
and adds controls used only by this harness. Normal builds use `main_c.zig` and
contain none of the `c11_read_test_*` or `c11_test_*` exports. No test flags or
hooks are added to the shipping header.

On an unlocked macOS GUI host, from the Ghostty checkout:

```sh
zig build -Dc11-read-test=true build-c11-read-test
zig build -Dc11-read-test=true test-c11-read
```

Use the owning project's build lock and authorized build machine. The target is
native-only: use the host architecture and SDK. `c11-test-library` installs the
combined test archive to `zig-out/lib/libghostty-c11-read-test.a` for another
fixture host. These targets are absent unless `-Dc11-read-test=true` is given.

The host creates a real embedded surface with NSView/Metal and manual IO. It
opens no visible window, launches no shell, and loads no tenant configuration.
The fixture fills the terminal with `alpha bravo`, selects known ranges, and
calls the actual old/new C exports. A worker holds the real renderer mutex
until both BUSY checks finish. A 30-second SIGALRM watchdog terminates a hang;
it never releases the mutex to let an accidentally blocking read pass.

The allocator proxy is installed before app/surface creation. Fault injection
and allocation accounting are thread-local, so renderer allocations continue
normally. Selection setup is excluded from read allocation accounting. At the
end, read allocation bytes must balance to zero. Debug allocator checks also
remain enabled in the test library. Every successful result is freed once
through the existing two-argument C free API.

Coverage: BUSY before releasing the holder, absent and invalid selections,
exact text and viewport parity, replacement and clearing of the selection,
formatter allocation failure, zero results on every non-OK outcome, and retry
after error exits. Timing output distinguishes rejected acquisition from
acquisition plus synchronous formatting. The latter is not a wall-time bound.

This is a real-export development fixture, not a packaged GhosttyKit validation
or a visible selection/copy smoke test. Those remain separate evidence gates.
