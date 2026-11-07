# AGX R/W iOS PoC

AGX firmware read/write PoC for iPhone 16 Pro Max on iOS 18.6.2 (22G100),
using ClearSword `pe_v3` for kernel read/write.

## Target

| Device | Identifier | iOS | Build |
| --- | --- | --- | --- |
| iPhone 16 Pro Max | iPhone17,2 | 18.6.2 | 22G100 |

Only this device and build have been tested.

## Modes

| Mode | Description |
| --- | --- |
| default | Snapshots the current task's 16 KiB root table twice and copies the snapshot through Metal. |
| `--acquire-only` | Stops after ClearSword acquisition and the kernel slide/proc/task/pmap checks. |
| `--agx-self-test` | Tests normal shared-buffer Metal read/write without running ClearSword. |
| `--gfx-read-control` | Runs the device-control copyout path with a fixed firmware source. |
| `--gfx-read <gfx-va>` | Reads an aligned 64-bit value from the mapped main-firmware range. |
| `--gfx-write-control` | Writes a marker through DropMDSID, checks it through the CPU alias, then restores the changed fields. |
| `--gfx-write-panic` | Writes through DropMDSID to the panic target. [Panic](evidence/panics/panic-full-2026-10-26-051348.0002.ips) |

`--acquire-only` passed twice in a row on iPhone17,2. The Metal self-test and
`--gfx-write-control` pass. The read modes still need another device run after
the latest ClearSword changes.

This is GFX virtual read/write, not a physical-memory primitive or an SPTM
bypass.

## Offsets

ClearSword offsets are in `clearsword/utils.c`. The common structure offsets
come from Dopamine 3; the A18 post-acquisition walk is specific to this port.

The AGX vtables and firmware addresses in `clearsword/agx.m` target the 22G100
G17P kernel and firmware. `STATIC_RIPCBINFO` in `clearsword/poc.c` is also tied
to 22G100. Update both for another device or build.

## Build

Open `clearsword.xcodeproj`, select a development team, and build the
`clearsword` scheme for a physical device.

Unsigned build check:

```sh
xcodebuild -project clearsword.xcodeproj -scheme clearsword -sdk iphoneos \
  -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Command-line build:

```sh
make binary
```

## Run

The app starts in the default mode. To select another mode:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --acquire-only
```

Replace `--acquire-only` with another mode from the table above. The explicit
read form takes an address:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- \
  --gfx-read 0xfffffc0000000400
```

ClearSword can panic or reboot the phone. After a successful KRW run, reboot
before trying again because the modified sockets remain pinned.
`--gfx-write-panic` intentionally panics the device.

## Credits

- [ClearSword](https://github.com/TheRealClarity/ClearSword) by Clarity
- [Dopamine 3](https://github.com/opa334/Dopamine/tree/3.x) by opa334 for the offset source
- [Cyanide](https://github.com/kolbicz/Cyanide) by Kolbicz for the A18 `pe_v3` path
- [Titan](https://github.com/alfiecg24/Titan) by AlfieCG for the original DropMDSID implementation

DarkSword is CVE-2025-43520.

## License

GNU AGPL v3.
