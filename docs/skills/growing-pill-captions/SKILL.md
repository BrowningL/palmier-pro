---
name: growing-pill-captions
description: Create or repair word-timed kinetic captions in Palmier where each visual line is one Instagram-style rounded pill that grows cumulatively as words are spoken. Use for requests such as "one word at a time," "growing pill," "Instagram captions," stacked progressive captions, or fixing overlapping per-word caption boxes.
---

# Growing Pill Captions

Build cumulative text stages so each visual line has one clean pill, natural spaces, and exact speech timing.

## Preserve the invariant

Never place adjacent words as separate Instagram-pill clips. Each clip gets its own padded box, so borders collide or require unnatural gaps.

Build sequential cumulative stages on one track instead:

`we` -> `we built` -> `we built a` -> `we built a machine`

Keep only one stage active per visual line. The pill snaps wider at each word boundary; it does not morph smoothly.

## Build the sequence

1. Call `get_timeline` and identify the spoken clip, its linked audio clip, the frame rate, and the intended caption-block end.
2. Call `get_transcript` on the linked audio clip when possible. Read word rows using the returned `wordFormat`, currently `[index, text, start]` in project frames.
3. Confirm the wording. Correct a transcript error only when the intended word is unambiguous.
4. Split the copy into short visual lines. Prefer one or two lines for phone-first video.
5. Coalesce words with the same project start frame into one reveal event. Every stage must last at least one frame.
6. Create cumulative adjacent half-open ranges for each line:
   - Set `startFrame` to the newly revealed word's start.
   - Set `endFrame` to the next reveal start on that line.
   - Set `content` to all words revealed on that line so far.
   - Hold the final completed stage to the caption-block end.
7. Submit all lines and stages in one `add_texts` call:
   - Omit `trackIndex` from every entry.
   - Set a non-empty `trackGroup` on every entry.
   - Reuse one group for all stages of a visual line.
   - Use a different group for each stacked line.
   - Put groups in desired top-to-bottom order on first occurrence.
   - Set `textPreset` to `instagramLight` or `instagramDark` on every stage.
   - Use one `fontSize` across the sequence.
   - Pass only `centerX` and `centerY` in `transform` so Palmier auto-fits.
8. Call `inspect_timeline` immediately before and at representative word boundaries, when later lines start, and when the block is complete.

Do not use `add_captions` for this effect. It creates conventional phrase captions rather than cumulative stages.

## Fit and place the block

- Center rows horizontally and space their `centerY` values evenly. Adjust positions for the actual footage and phone-safe areas.
- Choose the shared font size using the longest completed line. If it wraps, reduce the size everywhere or rebalance the line break.
- Do not force a wide fixed transform or insert a newline inside a visual line.
- Preserve punctuation and casing in every cumulative stage.
- Add a restrained optional outline with `strokeEnabled: true`, `strokeColor: "#000000"`, and `strokeWidth: 2` or `3`. Stroke width is a percentage of font size.

## Use this request pattern

```json
{
  "entries": [
    {
      "trackGroup": "line-2",
      "startFrame": 27,
      "endFrame": 32,
      "content": "we",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    },
    {
      "trackGroup": "line-2",
      "startFrame": 32,
      "endFrame": 40,
      "content": "we built",
      "textPreset": "instagramLight",
      "fontSize": 60,
      "transform": { "centerX": 0.5, "centerY": 0.29 }
    }
  ]
}
```

Extend the group through the completed line and include every other visual-line group in the same call.

## Repair an existing attempt

Inspect every overlapping text clip in the range. Remove only obsolete caption experiments, including orphaned phrase clips hidden behind the intended stages. Preserve unrelated titles and graphics. Rebuild the full block atomically, then verify that each group occupies one track, its stages are adjacent and non-overlapping, old experiments are gone, rows do not collide, and final lines remain unwrapped.
