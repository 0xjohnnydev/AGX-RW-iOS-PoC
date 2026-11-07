# AGX-RW-iOS-PoC

A fixed-target iOS PoC for ClearSword kernel read/write and AGX firmware
read/write research on A18 Pro.

## Target

| Device | Identifier | iOS | Build |
| --- | --- | --- | --- |
| iPhone 16 Pro Max | iPhone17,2 | 18.6.2 | 22G100 |

The app refuses to run on other targets. Offsets are fixed for this build.

## PoCs

The command-line modes correspond to the first two tests in the macOS repo.
They are one iOS app/binary rather than separate executables.

| macOS test | iOS mode | Status on iPhone17,2 / 22G100 |
| --- | --- | --- |
| `gfx-read-poc control` | `--gfx-read-control` | Implemented. ClearSword acquisition is now verified; the privileged read control still needs a fresh device run. |
| `gfx-read-poc read <gfx-va>` | `--gfx-read <gfx-va>` | Implemented for aligned addresses in the mapped main-firmware range; not yet run because the control must pass first. |
| `gfx-write-poc` control | `--gfx-write-control` | Verified on hardware. Two firmware-originated 32-bit writes produced `0x4141414141414141` through the CPU alias, then all scratch and host fields were restored. |
| `gfx-write-poc` panic | `--gfx-write-panic` | Implemented as an explicit panic mode; not run automatically. |
| `gfx-auth-call-poc` | — | Not ported. |
| `gfx-pac-reuse-poc` | — | Not ported. |
| `micro-ppl-ttbr1-probe` | — | Not ported. |

The write path uses the 22G100 `DropMDSID` object chain, validates the target
objects and method bytes, builds an `IOSurfaceAddressRanges` MDSID table, and
submits ordinary AGX command buffers. The read path uses the 22G100
device-control command type 30 and copyout-table layout.

Before the race, every mode also verifies ordinary shared-buffer Metal
read/write. The default mode takes two stable KRW snapshots of the current
task's 16 KiB root table and copies only that snapshot through Metal; it never
maps or modifies the live type-17 root-table frame.

This is GFX virtual read/write research, not standalone physical read/write or
an SPTM bypass. ClearSword acquisition itself is unstable on this target and
can panic or reboot the phone before an AGX test starts.

`--acquire-only` has completed twice consecutively on the target after adding
an immediate readback of each newly freed-and-sprayed page. Both runs verified
the kernel slide and current process/task/pmap chain without entering the
post-acquisition AGX test.

## Build check

```sh
xcodebuild -project clearsword.xcodeproj -scheme clearsword -sdk iphoneos \
  -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The command-line `make binary` path also includes the Metal implementation and produces an ad-hoc-signed arm64 executable with the macOS `codesign` tool.

## Run

Open `clearsword.xcodeproj`, select your development team, and run it on the target device. The PoC starts once when the app opens.

This race can panic or reboot the device. Reboot before another run if the app shows **Reboot required**.

For a non-racing smoke test, launch the app with `--agx-self-test`. This runs only the ordinary shared-buffer AGX read/write check. The command-line binary accepts the same argument:

```sh
./clearsword.bin --agx-self-test
```

Use `--acquire-only` while tuning ClearSword. It verifies kernel acquisition and
skips the post-acquisition AGX test. A successful run pins the modified sockets
and therefore still requires a reboot before another attempt.

Device test modes can be selected with `devicectl`:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --gfx-write-control

xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- --gfx-read-control

xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.0xjohnnydev.agxrwios -- \
  --gfx-read 0xfffffc0000000400
```

Reboot between successful KRW runs because the parked transport is deliberately
not reused. `--gfx-write-panic` is destructive and is never selected by the
default UI or any control test.

## Credits

- [ClearSword](https://github.com/TheRealClarity/ClearSword) by Clarity
- [Cyanide](https://github.com/kolbicz/Cyanide) by Kolbicz for the A18 `pe_v3` path
- DarkSword and CVE-2025-43520

Licensed under the GNU AGPL v3 because this port includes Cyanide-derived code.
