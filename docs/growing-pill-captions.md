# Growing-Pill Kinetic Captions

Use this workflow when a caption should build one word at a time while each visual line remains a single rounded pill. It is designed for Palmier's built-in agent and the shared MCP tool surface.

## Goal

At every frame, represent each visible line with exactly one text clip containing every word revealed on that line so far. As the content changes from `Make` to `Make it` to `Make it feel`, Palmier auto-fits the text box and redraws one wider pill.

For a two-line caption block, the completed first line stays visible while the second line grows. Each visual line therefore needs its own timeline track.

## Why Separate Word Pills Fail

Do not create one permanent text clip per word. Every text clip draws its own background, so that method produces disconnected capsules instead of one growing shape. Centered, auto-fit word clips can also overlap, while overlapping clips on the same track invoke overwrite and trim behavior.

Do not animate scale to fake the width change. Scale keyframes resize the glyphs and pill together; they do not animate the pill independently.

The reliable construction is cumulative content on one track per visual line:

```text
line-1: [Make] [Make it] [Make it feel----------------]
line-2:                         [more] [more premium---]
```

Only one stage is active on each line track at a time. Completed earlier lines may overlap later lines because the lines are on different tracks and at different vertical positions.

## Plan the Caption Blocks

1. Finish dialogue cuts before building captions. Any later ripple edit invalidates the transcript frames and requires the kinetic captions to be rebuilt.
2. Call `get_timeline` for the project frame rate and source clip IDs.
3. Call `get_transcript`, scoped to the intended speech clip when possible. Its nested word rows use the reported `wordFormat`: `[index, text, startFrame, endFrame]` in project frames. Pass the spoken language when it differs from the system language.
4. Divide the transcript into short caption blocks. Prefer one or two visual lines on phone-first video. Start a new block at strong punctuation, a clear thought boundary, a long pause, or before a line would become too wide.
5. Decide the final text of every line before creating stages. Reuse visual slots such as `line-1` and `line-2` across non-overlapping caption blocks so the whole sequence needs only as many tracks as its maximum line count.

## Timing and Stage Rules

Treat every clip range as half-open: `[startFrame, endFrame)`.

For a line whose words start at `s0`, `s1`, and `s2`, create:

| Stage | Content | Range |
| --- | --- | --- |
| 1 | first word | `[s0, s1)` |
| 2 | first + second words | `[s1, s2)` |
| 3 | completed line | `[s2, blockEnd)` |

Apply these rules:

- Start a stage when its newly revealed word starts.
- End every intermediate stage at the next word's start. Stages on the same `trackGroup` must be adjacent and must not overlap.
- Give every stage at least one frame. If rounded transcript boundaries collapse, merge that word into the next valid stage.
- Keep each line's completed final stage visible through the caption block's end, including while later lines are building.
- Set `blockEnd` no earlier than the final word's end. For a short pause, hold until the next block starts. For a long pause, clear after a brief readable hold rather than leaving the pill on screen indefinitely.
- Do not show a later line before its first word starts.

## Keep Every Line Unwrapped

Choose one font size for the entire caption sequence. Use the longest completed line as the fit constraint, then apply that same `fontSize` to every stage on every line. Consistent sizing prevents shorter lines from jumping in scale as the caption builds.

Pass only `centerX` and `centerY` in `transform`. This preserves auto-fit width and height. Do not pass a fixed `width` or `height`, and do not put a newline inside a line entry. If the longest completed line wraps during verification, reduce the font size everywhere or rebalance the words between lines, then recreate the sequence.

For a vertical 1080 × 1920 project, a caption size around 54–64 points is a practical starting range, but the longest line and safe-area placement decide the final value.

## Create Every Line in One `add_texts` Call

Submit every stage for the caption sequence in one `add_texts` call:

- Omit `trackIndex` from every entry.
- Include a non-empty `trackGroup` on every entry. If one entry uses `trackGroup`, all entries in the call must use it.
- Repeat the same group for every stage of one visual line. Different groups create separate tracks atomically, in first-seen top-to-bottom order.
- Put the first `line-1` entry before the first `line-2` entry for deterministic track order.
- Repeat the preset, font size, alignment, transform, and optional stroke on every stage; each text clip owns its own style.

Example for a two-line block ending at frame 390:

```json
{
  "entries": [
    {
      "trackGroup": "line-1",
      "startFrame": 300,
      "durationFrames": 18,
      "content": "Make",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.76 }
    },
    {
      "trackGroup": "line-1",
      "startFrame": 318,
      "durationFrames": 18,
      "content": "Make it",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.76 }
    },
    {
      "trackGroup": "line-1",
      "startFrame": 336,
      "durationFrames": 54,
      "content": "Make it feel",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.76 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 354,
      "durationFrames": 18,
      "content": "more",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.83 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 372,
      "durationFrames": 18,
      "content": "more premium",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.83 }
    }
  ]
}
```

`instagramLight` applies the Instagram-style bold system face, black text, opaque white pill, calibrated padding and line height, and no shadow. Explicit fields in an entry override the preset.

### Optional Glyph Stroke

The Instagram preset does not require a stroke. When a creative treatment does, add the same values to every stage:

```json
{
  "strokeEnabled": true,
  "strokeColor": "#000000",
  "strokeWidth": 3
}
```

`strokeWidth` is a percentage of font size and accepts 0–20. A positive width or a supplied color enables the stroke unless `strokeEnabled` is explicitly `false`. Keep the width restrained and verify that it does not make small phone text feel crowded.

## Verify and Clean Up

1. Use `inspect_timeline` at the first word, a middle boundary, the first frame of the second line, and the completed block. Inspect frames immediately before and at a boundary when timing is uncertain.
2. Confirm that each word appears on its spoken boundary, each line has one continuous pill, completed earlier lines persist, and the final lines do not wrap.
3. Check phone-safe margins and that adjacent line pills do not collide. Adjust every stage of a line to the same corrected `centerY`.
4. Use `get_timeline` to confirm that stages sharing a visual line are on one track with non-overlapping ranges, and that different visual lines occupy different tracks.
5. If the result is structurally wrong, undo the single `add_texts` action and rebuild the full grouped call. Remove any older conventional captions or separate-word-pill attempts before adding the replacement.

## Limitations

- Width changes are stepped at word boundaries. Palmier does not currently interpolate a pill-only width, so this is not a smooth shape morph.
- The result is only as accurate as the transcript's word timing. Use the correct language and inspect questionable boundaries.
- `add_captions` creates conventional whole-phrase captions; it does not create this cumulative reveal.
- Editable FCPXML titles do not carry Palmier's custom pill or glyph stroke. Export rendered video when those treatments must be preserved.

## Built-In Agent Prompt

> Create growing-pill kinetic captions for the selected dialogue. Use `get_transcript` word frames, split each block into at most two short visual lines, and build cumulative word-reveal stages. Give each visual line its own `trackGroup`, include it on every entry, and create the full sequence in one `add_texts` call with `instagramLight`. Use one font size chosen so the longest final line stays unwrapped, keep completed earlier lines visible through each block, then inspect the word boundaries and clean up any old caption attempt.
