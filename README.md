# AGX R/W iOS PoC

AGX firmware read/write PoC using ClearSword `pe_v3` for kernel read/write,
tested only on iPhone17,2 (iPhone 16 Pro Max) running iOS 18.6.2 (22G100).

## Modes

| Mode | Description |
| --- | --- |
| default | Copies two snapshots of the task's 16 KiB root table through Metal. |
| `--acquire-only` | Acquires KRW and validates the kernel objects. |
| `--agx-self-test` | Tests normal shared-buffer Metal R/W without ClearSword. |
| `--gfx-read-control` | Reads a fixed firmware value through device-control copyout. |
| `--gfx-read <gfx-va>` | Reads an aligned 64-bit GFX firmware address. |
| `--gfx-write-control` | Writes and verifies a marker through DropMDSID, then restores it. |
| `--gfx-write-panic` | Writes through DropMDSID to the panic target. [Write panic report](evidence/panics/panic-full-2026-10-26-051348.0002.ips) |
| `--gfx-auth-call-control` | Relocates and calls a PAC-signed callback through `BLRAAZ` with object zero. |
| `--gfx-auth-call-panic` | Calls it with controlled object `0x200000000`. [Authenticated-call panic report](evidence/panics/panic-full-2026-11-07-151326.0002.ips) |
| `--gfx-pac-reuse-control` | Relocates two signed power callbacks through compatible call sites. |
| `--gfx-pac-reuse` | Reuses signed power and active MBI callbacks and verifies their source slots. |
| `--micro-ppl-ttbr1-control` | Resolves the scratch page and validates the protected leaf-PTE slot without writing it. |
| `--micro-ppl-ttbr1-panic` | Attempts to change that protected leaf PTE. [Protected-PTE panic report](evidence/panics/panic-full-2026-11-07-151028.0002.ips) |

Panic evidence from the target device:

- Write: GFX data abort after the scheduler-pointer high word became `0x41414141`.
- Auth call: `agfaRemotePowerKick` received the controlled `0x200000000` object.
- Protected PTE: `iss=0x4f`, `far=0xfffffc0001fc8404`, at the firmware PTE
  store. The read-only PTE faults before the later SAPT transaction reached by
  the macOS test.

ClearSword acquisition can also panic, but those failures are not AGX test
evidence.

After the first successful acquisition, the app parks KRW in `launchd` for
reuse until reboot. The self-test and non-panic control modes pass on the target.

This is GFX virtual read/write, not a physical-memory primitive or an SPTM
bypass.

## Offsets

ClearSword offsets are in `clearsword/utils.c`; common structure offsets come
from Dopamine 3. AGX constants in `clearsword/agx.m` and `STATIC_RIPCBINFO` in
`clearsword/poc.c` are specific to the 22G100 G17P target.

## Credits

- [ClearSword](https://github.com/TheRealClarity/ClearSword) by Clarity
- [Dopamine 3](https://github.com/opa334/Dopamine/tree/3.x) by opa334 for the offset source
- [Cyanide](https://github.com/kolbicz/Cyanide) by Kolbicz for the A18 `pe_v3` path
- [Titan](https://github.com/alfiecg24/Titan) by AlfieCG for the original DropMDSID implementation

DarkSword is CVE-2025-43520.

## License

GNU AGPL v3.
