# vendor

`csqwhisper.c` / `csqwhisper.h`: our own thin C face over whisper.cpp (MIT, ggml-org, release b5454). `whisper.dll` is loaded at run
time; nothing links against it. The struct layouts of `whisper_context_params` and `whisper_full_params` in the C file are copied
from the pinned `whisper.h` (needed because both are passed by value), so the DLL must come from that release. Off Windows every
call reports "not available". License of the copied declarations: MIT, see docs/THIRD_PARTY.md of the repository.
