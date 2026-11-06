# AGX-RW-iOS-PoC

A fixed-target iOS PoC for bringing ClearSword kernel read/write to A18 before adding AGX work.

## Target

| Device | Identifier | iOS | Build |
| --- | --- | --- | --- |
| iPhone 16 Pro Max | iPhone17,2 | 18.6.2 | 22G100 |

The app refuses to run on other targets. Offsets are fixed for this build.

## Status

The ClearSword base uses Cyanide's A18 `pe_v3` flow: 2 GB wired-page staging, one physical-page hunt, and socket reoccupation on pages already found by the race.

The path reached the socket handoff on this target, but stable KRW is not confirmed. That run panicked in raw ICMPv6 filter handling after a failed read. The transport now restores and verifies the full filter snapshot after each operation. A later bounded run missed acquisition, so the fix has not completed a live KRW run yet.

AGX firmware R/W is not implemented.

## Run

Open `clearsword.xcodeproj`, select your development team, and run it on the target device. The PoC starts once when the app opens.

This race can panic or reboot the device. Reboot before another run if the app shows **Reboot required**.

## Credits

- [ClearSword](https://github.com/TheRealClarity/ClearSword) by Clarity
- [Cyanide](https://github.com/kolbicz/Cyanide) by Kolbicz for the A18 `pe_v3` path
- DarkSword and CVE-2025-43520

Licensed under the GNU AGPL v3 because this port includes Cyanide-derived code.
