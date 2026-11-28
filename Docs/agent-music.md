# Create and edit music from the Mac CLI

For an installed Mac app, open **Settings → Install Skill…** to add VibePlayer Music to Codex or Claude Code. Choose the agent's user or project skills folder. The app also exposes **Copy Help Command**. Its `--music-cli` mode prints model status or renders one JSON request from stdin to a WAV on stdout using the built-in model. It also accepts an ABC score in the request's `score` field. Both paths are included in the Mac App Store build configuration.

The following standalone development CLI adds recording transcription and automatic score export.

Build the CLI once from this repository. It uses the same native YuE2 model and the same optional SheetSage2 transcriber as the Mac app.

```sh
swift build --package-path Packages/YuE2Kit -c release --product vibeplayer-music
music="$(swift build --package-path Packages/YuE2Kit -c release --show-bin-path)/vibeplayer-music"
```

For song rendering, use the [native Mac runtime and weights](../Packages/YuE2Kit/README.md#runtime-and-weights). The CLI finds the same `~/Library/Application Support/YuE2NativeAssets` directory as the app. Use `--native-assets DIRECTORY` to select another installation. For recording transcription, run `python3 Scripts/install_melody_tools.py` once. You can use `--reference-assets DIRECTORY` if you installed the transcriber elsewhere.

## Make a cover

```sh
"$music" transcribe reference.m4a --out melody.abc
"$music" render --score melody.abc --lyrics lyrics.txt \
  --style "acoustic soul, brushed drums, upright bass" --seed 42 --out acoustic-take
```

Review `melody.abc` before rendering. The transcription keeps the notes and timing and omits chord labels so YuE2 has room to arrange the song. Supply the lyrics you want sung in a UTF-8 text file, with section tags such as `[Verse]` and `[Chorus]` where useful. Match syllables to the melody when changing words. Omit `--lyrics` to request an instrumental.

## Compose and revise

```sh
"$music" render --lyrics lyrics.txt --style "intimate piano pop" --seed 42 --out first-take
cp first-take/score.abc revised.abc
# Edit revised.abc before rendering the next take.
"$music" render --score revised.abc --lyrics lyrics.txt \
  --style "intimate piano pop" --seed 42 --out revised-take
```

For a new song, omit `--score` so YuE2 writes the score. To change the arrangement while keeping the melody, keep the score and lyrics fixed and change the style. To edit the melody itself, copy the score and change only the intended bars. Keep previous takes and listen to the affected passage before accepting the change. A fixed seed helps compare takes. `--seconds` sets a duration ceiling and `--steps` sets synthesis steps.

Successful commands emit a JSON object to standard output with absolute paths. Render directories contain `song.wav` and `score.abc`, and the JSON includes the seed as a string. Choose a fresh output path for every take. To continue in VibePlayer, open the ABC from **Create → Melody → Open ABC**. To hear a CLI take in the app, open its WAV through the Library's audio file action.
