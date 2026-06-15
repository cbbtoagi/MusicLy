# MusicLy

MusicLy is a local-first macOS menu bar app that shows the current lyric line of
whatever Apple Music is playing, in real time — whether the Music window is
visible, hidden, or minimized.

## How it works

The display is driven by **synced LRC lyrics** keyed to the track, not by reading
the screen:

1. **Playback position** is read locally via Apple Events (`player position`).
   This works regardless of the Music window's state, so lyrics keep flowing when
   the window is minimized or in the background.
2. **Synced lyrics (LRC)** are fetched once per track from
   [LRCLIB](https://lrclib.net) — free, no API key, read-only — then cached on
   disk. You can also drop your own `.lrc` files in
   `~/Library/Application Support/MusicLy/Lyrics/` (named `Artist - Title.lrc`),
   which always take priority.
3. **Position interpolation** advances the line smoothly at 10 fps between the
   ~2 Hz Apple Events samples, so the lyric never stalls even if a poll is slow.

## Features

- Real-time synced lyric display in the menu bar, working when minimized
- Current line + translation pairing + previous/next context in the popover
- Local on-disk lyric cache and user-supplied `.lrc` override
- Per-track sync offset adjustment (right-click menu)
- Local packaging script that keeps all build outputs inside this project directory

## Requirements

- macOS 13+
- Apple Music app installed
- Apple Events permission for playback metadata (prompted on first launch)

## Install (from a release)

1. Download `MusicLy-<version>.dmg` from the
   [Releases](../../releases) page and open it.
2. Drag **MusicLy** into **Applications**.
3. Because the app is not signed with a paid Apple Developer certificate, macOS
   Gatekeeper blocks the first launch. Clear the quarantine flag once (most
   reliable on macOS 14/15):
   ```bash
   xattr -dr com.apple.quarantine /Applications/MusicLy.app
   ```
   Alternatively: try to open it, then go to **System Settings → Privacy &
   Security** and click **Open Anyway**.
4. Allow Apple Events access when prompted, then open Apple Music and play a song.
   MusicLy lives in the menu bar (no Dock icon); left-click it for the lyrics
   panel, right-click for options.

## Build from source

```bash
# Build the app bundle (ad-hoc signed)
./scripts/build_local.sh        # → dist/MusicLy.app, dist/MusicLy.zip

# Drag-to-install disk image
./scripts/build_dmg.sh          # → dist/MusicLy-<version>.dmg
```

## Notes

Synced lyrics are fetched from the free LRCLIB service (HTTPS GET, no key, no
account, no personal data beyond the track's name/artist/album/duration) and then
cached locally, so each track only hits the network once. Playback position is
read entirely locally. To stay fully offline, pre-populate
`~/Library/Application Support/MusicLy/Lyrics/` with your own `.lrc` files.
