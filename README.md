# AGX R/W iOS PoC

AGX firmware read/write on an iPhone 16 Pro Max running iOS 18.6.2 build
22G100. ClearSword `pe_v3` provides the kernel read/write transport.

## PoCs

| Mode | What it does |
| --- | --- |
| default | Takes two stable snapshots of the current task's 16 KiB root table and copies the snapshot through Metal. |
| `--acquire-only` | Acquires ClearSword KRW and verifies the kernel slide and current process, task and pmap. |
| `--agx-self-test` | Verifies ordinary shared-buffer Metal read/write without running ClearSword. |
| `--gfx-read-control` | Exercises the device-control copyout path with a fixed firmware source. |
| `--gfx-read <gfx-va>` | Reads an aligned 64-bit value from the mapped main-firmware range. |
| `--gfx-write-control` | Writes a marker through DropMDSID, verifies it through the CPU alias, then restores the modified fields. |
| `--gfx-write-panic` | Writes through DropMDSID to the panic target. |

`--acquire-only` has completed twice consecutively on iPhone17,2. The Metal
self-test and `--gfx-write-control` also work on that hardware. The privileged
read modes are implemented but have not completed a fresh end-to-end hardware
run after the current ClearSword acquisition changes.

ClearSword prepares the kernel transport, and AGX firmware performs the GFX
virtual source reads and target writes. This is not standalone physical
read/write or an SPTM bypass.

## Tested target

| Hardware | Identifier | iOS | Build |
| --- | --- | --- | --- |
| iPhone 16 Pro Max | iPhone17,2 | 18.6.2 | 22G100 |

This is the only hardware configuration tested. The ClearSword KRW structure
offsets in `clearsword/utils.c` follow Dopamine 3's ClearSword/libjailbreak
values, with the additional A18 post-acquisition walk used by this port.

The AGX kernel vtables and firmware addresses in `clearsword/agx.m` are a
22G100 G17P profile. They are build and firmware specific, not universal
ClearSword offsets. The static kernel address in `clearsword/poc.c` is also
22G100-specific. Re-profile those constants before using another device or OS
build whose kernelcache or G17P firmware differs.

## Build

Open `clearsword.xcodeproj`, select a development team, and build the
`clearsword` scheme for a physical device.

For an unsigned build check:

```sh
xcodebuild -project clearsword.xcodeproj -scheme clearsword -sdk iphoneos \
  -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The command-line build produces an ad-hoc-signed arm64 executable:

```sh
make binary
```

## Run

The app starts the default snapshot mode when opened. Launch another mode with
`devicectl`:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --acquire-only

xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --gfx-read-control

xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- \
  --gfx-read 0xfffffc0000000400

xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --gfx-write-control
```

ClearSword is a race and can panic or reboot the phone. A successful KRW run
pins the modified sockets, so reboot before another attempt. The
`--gfx-write-panic` mode intentionally panics and reboots the device.

## Credit

[Clarity](https://github.com/TheRealClarity) for
[ClearSword](https://github.com/TheRealClarity/ClearSword),
[opa334](https://github.com/opa334) for the
[Dopamine 3](https://github.com/opa334/Dopamine/tree/3.x) offset source,
[Kolbicz](https://github.com/kolbicz) for the A18 `pe_v3` path, and
[AlfieCG](https://github.com/alfiecg24) for the original DropMDSID
implementation in [Titan](https://github.com/alfiecg24/Titan).

DarkSword is CVE-2025-43520. This port is licensed under the GNU AGPL v3.
