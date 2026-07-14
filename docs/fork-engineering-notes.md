# Palmier Pro Fork Engineering Notes

This file records compatibility and implementation details that must survive future upstream integrations. Keep upstream architecture where it already covers the use case, and carry only fork behavior that is still unique.

## Text architecture

- `TextStyle` is the persisted style model. Add decoding defaults and migration tests whenever its JSON changes.
- `TextLayout` owns auto-fit sizing. Inspector and agent edits that affect glyph or background geometry must refit through existing editor mutations.
- `TextFrameRenderer` is the single preview, inspection, and rendered-export path. Keep upstream animation modes and draw custom backgrounds inside this renderer; do not reintroduce the removed CALayer or rasterizer pipeline.
- `TextBackgroundPath` builds the per-line pill shape from the same finite Core Text frame used for glyph drawing. Sharing that frame prevents an invisible extra wrap from creating the lower white tab at fractional widths.
- `CaptionBuilder` remains the conventional caption-generation path. Growing-pill word reveals use adjacent text stages instead; see [`growing-pill-captions.md`](growing-pill-captions.md).

## Persisted compatibility rules

- `TextStyle.background` accepts `box` and `pill`. Legacy upstream JSON containing only `{enabled,color}` decodes as `box`. Fork JSON carrying `paddingH`, `paddingV`, or `cornerRadius` without a shape decodes as `pill`. Newly encoded styles write an explicit shape.
- `TextStyle.border` remains the persisted key but represents a glyph stroke. Width is a percentage of font size. Legacy upstream borders missing `width` decode as 4%; newly created strokes default to 3%; an explicitly persisted fork width is preserved.
- `lineHeightMultiple` defaults to 1 and is clamped to 0.5–2 for rendering and agent input.
- `SF Pro Bold` is a compatibility sentinel used by Instagram presets. Old styles with that name and no `isBold` key must infer the bold trait.
- `instagramLight` and `instagramDark` apply one shared preset implementation: bold system text, calibrated 0.912 line height, pill background, matching colours, and disabled shadow. Explicit agent fields apply after the preset.

## UI and agent surface

- Inspector and caption controls expose line height, box/pill background mode, pill padding/corner radius, stroke thickness, and Instagram light/dark presets.
- `add_texts`, `add_captions`, and `update_text` share the style patch fields. Compatibility aliases are `lineHeightMultiple` for `lineHeight` and `borderColor` for `strokeColor`.
- In `add_texts`, `trackGroup` atomically creates one new text track per named visual line. If any entry supplies a group, all must supply one, and grouped entries may not also specify `trackIndex`. Stages with the same group share a track; groups follow first-seen top-to-bottom order. The whole call remains one undoable edit.
- Typography or geometry edits must use the existing editor mutations so undo, dirty-state notifications, caption-group updates, and auto-fit remain intact.

## Fonts and interchange

- Creator Connect fonts are `Space Grotesk` and `IBM Plex Mono`. `BundledFonts` registers resources asynchronously, pins these families in the picker when available, and clears the text render cache after registration.
- Use Space Grotesk for Creator Connect display/body text and IBM Plex Mono for compact labels, numbers, and technical text.
- FCPXML exports dynamic glyph stroke width from the persisted percentage. Palmier's custom pill geometry is rendered output only; do not promise that editable titles preserve it.

## Required regression coverage

- Legacy upstream and fork JSON migration, preset round trips, SF Pro sentinel migration, and document round trips.
- Pill path/layout behavior at fractional widths, including straight and curly apostrophes, plus box compatibility.
- Inspector-independent style parsing, aliases, validation, grouped placement, track order, and undo/redo.
- FCPXML stroke width and font-resource discovery.

Before shipping an integration, run focused text tests and the full suite with the full Xcode developer directory selected. A running app keeps its launched binary and resources until fully quit and reopened.
