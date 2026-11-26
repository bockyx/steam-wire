> Fork of [steam-wire](https://github.com/Widowan/steam-wire) by Widowan, rewritten as `steam-game-audio`. MIT licensed; original copyright retained in `LICENSE`.

Steam's game recording on Linux captures the entire system audio instead of just the game. This WirePlumber script makes Steam listen only to the game's audio, for both native and Wine/Proton games.

## How it works
- A game's audio stream is detected by being a Wine preloader binary (`wine64-preloader`, `wine-preloader`) or by having `media.role = Game` (set by SDL and most native engines). Games that set neither can be added by binary name in `EXTRA_BINARIES` at the top of `steam-game-audio.lua`.
- While at least one game is running, Steam's recording input node is unlinked from any sink and linked to the game's output stream(s), matching channels (mono is handled).
- With no game running, nothing is touched.
- Several games at once: all their streams are mixed into the recording.

> [!TIP]
> Microphone, voice chat and streaming (Chromium streams) are not affected.

## Installation

Put `90-steam-game-audio.conf` in `~/.config/wireplumber/wireplumber.conf.d/` and `steam-game-audio.lua` in `~/.local/share/wireplumber/scripts/` (create if they don't exist), then restart WirePlumber:

```
systemctl restart --user wireplumber.service
```

> [!IMPORTANT]
> Remove the legacy `90-steam-wire.conf` / `steam-wire.lua` if installed; they do the same job and conflict.

Debug (stop the service first): `WIREPLUMBER_DEBUG=steam-game-audio:5 wireplumber`.

---

P.S. [Wireplumber's documentation sucks](https://blog.wido.dev/wireplumber-scripting)
