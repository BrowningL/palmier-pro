# Growing-Pill Kinetic Captions

Use this workflow when a caption should build one word at a time while each visual line remains one Instagram-style rounded pill. It works with Palmier's in-app agent and the shared MCP tool surface.

## The invariant

At every frame, represent each visible line with exactly one text clip containing all words revealed on that line so far. For example, one line becomes `we`, then `we built`, then `we built a`, then `we built a machine`.

Do not create one permanent pill per word. Each clip has its own padded background, so separate word clips either collide or need unnatural gaps. Do not animate scale to imitate the growing width; that scales the glyphs too.

Use cumulative, adjacent stages on one track per visual line:

```text
line-1: [Here's] [Here's how-------------------------]
line-2:                    [we] [we built] [we built a] [we built a machine---]
```

Only one stage is active on a line's track at once. Different lines use different tracks, so a completed earlier line can remain visible while the next line grows.

## Plan and time the stages

1. Finish dialogue cuts first. Later ripple edits invalidate transcript frames.
2. Call `get_timeline` to get the project frame rate and the linked audio clip ID.
3. Call `get_transcript`, scoped to that audio clip when possible. Word rows follow the returned `wordFormat`, currently `[index, text, start]`, in project frames.
4. Split each caption block into short visual lines. Prefer one or two lines for phone-first video. Start a new block at punctuation, a thought boundary, a pause, or before a line becomes too wide.
5. For each line, create a cumulative stage at every word start. Treat ranges as half-open: `[startFrame, endFrame)`.

For words starting at frames 27, 32, 40, and 47, with a block ending at 94:

| Content | Range |
| --- | --- |
| `we` | `[27, 32)` |
| `we built` | `[32, 40)` |
| `we built a` | `[40, 47)` |
| `we built a machine` | `[47, 94)` |

Every stage must last at least one frame. If rounded word starts collide, merge the word into the next valid stage. Hold each completed line through the block end, including while later lines build.

## Keep each visual line unwrapped

Choose one font size for the whole caption sequence using the longest completed line as the constraint. Pass only `centerX` and `centerY` in each transform so Palmier auto-fits the box. Do not pass a fixed width or height and do not put a newline inside a visual line.

If the longest line wraps, reduce the shared font size or rebalance words between visual lines, then rebuild all stages. Do not stretch the transform to force a fit.

## Create the sequence atomically

Submit every stage in one `add_texts` call:

- Omit `trackIndex` from every entry.
- Put a non-empty `trackGroup` on every entry. If one entry uses it, all entries must use it.
- Reuse one group name for every stage of the same visual line.
- Use different group names for different visual lines. Palmier creates one track per group, in first-seen top-to-bottom order.
- Repeat the preset, font size, alignment, position, and optional stroke on every stage because each clip owns its style.

Example:

```json
{
  "entries": [
    {
      "trackGroup": "line-1",
      "startFrame": 0,
      "endFrame": 23,
      "content": "Here's",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.20 }
    },
    {
      "trackGroup": "line-1",
      "startFrame": 23,
      "endFrame": 94,
      "content": "Here's how",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.20 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 27,
      "endFrame": 32,
      "content": "we",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 32,
      "endFrame": 40,
      "content": "we built",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 40,
      "endFrame": 47,
      "content": "we built a",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 47,
      "endFrame": 94,
      "content": "we built a machine",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "alignment": "center",
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    }
  ]
}
```

`instagramLight` applies bold system text, a white pill, black text, calibrated padding and line height, and no shadow. `instagramDark` inverts the colours. Explicit style fields override the preset.

For an optional glyph outline, repeat these fields on every stage:

```json
{
  "strokeEnabled": true,
  "strokeColor": "#000000",
  "strokeWidth": 3
}
```

Stroke width is a percentage of font size and accepts 0–20.

## Verify

1. Use `inspect_timeline` immediately before and at representative word boundaries, when a later line starts, and after the block completes.
2. Confirm that one word appears at each intended boundary, every visible line has one continuous pill, earlier lines persist, and final lines do not wrap.
3. Check phone-safe margins and line spacing. Apply any position correction consistently to every stage in that line.
4. Use `get_timeline` to confirm that stages in one group share a track and have adjacent, non-overlapping ranges.
5. If the structure is wrong, undo the single `add_texts` action, remove old separate-word attempts, and recreate the grouped batch.

The pill width changes in a clean step at each word boundary; Palmier does not currently interpolate a pill-only width. `add_captions` makes conventional phrase captions and does not build cumulative stages. Export rendered video when the custom pill or stroke must be preserved exactly, since editable FCPXML titles cannot carry those treatments.

## Reusable agent prompt

> Create growing-pill kinetic captions for the selected dialogue. Use `get_transcript` word start frames, split each block into at most two short visual lines, and build cumulative word-reveal stages. Give each visual line its own `trackGroup`, include a group on every entry, and create the full sequence in one `add_texts` call using `instagramLight`. Use one font size chosen so the longest completed line remains unwrapped, keep completed earlier lines visible through the block, then inspect the word boundaries and remove any older caption attempt.
