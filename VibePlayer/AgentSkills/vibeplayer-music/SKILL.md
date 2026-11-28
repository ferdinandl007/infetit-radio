---
name: vibeplayer-music
description: Create original songs and new arrangements from editable ABC melodies with VibePlayer on a local Mac. Use when asked to write, render, or revise music with VibePlayer or infetit radio.
---

# VibePlayer Music

Use the installed Mac app's built-in renderer. The app appears as **infetit radio**. The usual executable is:

```sh
music="/Applications/infetit radio.app/Contents/MacOS/infetit radio"
"$music" --music-cli --help
"$music" --music-cli status
```

If the app is elsewhere, use its actual bundle path. **Settings → Copy Help Command** gives the exact path. When `modelReady` is false, ask the user to download the music model in Create. Keep music and references local.

Send one JSON request to `--music-cli render` on stdin. It emits WAV bytes on stdout and progress on stderr. Create a fresh output filename for each take and confirm the command succeeded before presenting it. Use a JSON encoder when including lyrics or a score from a file.

```sh
printf '%s\n' '{"style":"warm acoustic soul, upright bass and brushed drums","seconds":20,"seed":42}' |
  "$music" --music-cli render > acoustic-take.wav
```

- For vocals, provide `lyrics` with the words to sing. Preserve lyrics the user supplied. Omit lyrics to request an instrumental.
- For a cover, pass the ABC text as `score`. Keep notes, key, and timing fixed when the user wants the same melody, and change `style` to change the arrangement. For a composition edit, save a copy of the score and modify only the requested passage.
- Use a short preview and a fixed seed when comparing edits. Inspect and listen to the result before claiming the melody matches.
- For audio transcription or automatic ABC score generation, use the separately installed development tools if they are already available. Run `vibeplayer-music --help` to check. With the Mac App Store app alone, start with existing ABC or compose a new score yourself.
- The user can open your output in the app's Library or import an ABC file from **Create → Melody**.
