# Status

## Current: Phase 0 (not started)
Next session: set up XcodeGen project + packages skeleton, scripts/build.sh + scripts/test.sh, then the decode/scrub spike.

## Known facts
- Sony clips (e.g. ~/Documents/Videos/iOS 27 Features #2/C2160.MP4): H.264, 2160×3840 (vertical), LPCM audio → likely XAVC S-I or XAVC S. Bit depth / chroma / frame rate to be measured in the spike. H.264 10-bit 4:2:2 is probably software-decoded on M1 Max — measure, don't assume.
- iPhone clips: .MOV in project folders (e.g. ~/Documents/Videos/Käsiger michael/IMG_1281.MOV).

## Open decisions
- (none besides engine route)
- Engine route: after the spike.
