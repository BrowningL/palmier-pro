# Palmier Pro Custom Fork Maintenance

This fork follows Palmier Pro upstream and keeps only behavior that upstream does not provide. Official implementations are preferred for denoising, beat detection, text rendering, blend modes, and audible scrubbing. Fork code owns compatibility migration, social audio mixing, persistent markers, Instagram pill captions, configurable text stroke, creator fonts, and custom keying effects.

## Safety invariants

- Never test a newly integrated build on the only copy of a project.
- A legacy project must survive decode, save, reopen, and a second save without losing fork-only fields.
- Legacy `voiceCleanup` is decoded once into upstream `audio.denoise`; it is never processed by both engines or written back.
- Official Sparkle updates remain disabled in custom builds. Upstream changes are incorporated from source, reviewed, and tested.
- The previous working app and source worktree remain untouched until the replacement has passed project round-trip and rendered audio/video checks.

## Updating from upstream

The durable branch is based directly on upstream history, so normal merges remain possible:

```bash
git remote add upstream https://github.com/palmier-io/palmier-pro.git  # first clone only
git fetch origin upstream --tags
git switch main
git merge upstream/main
swift test
```

Resolve conflicts by retaining upstream architecture and reapplying the smallest custom surface. Before pushing, run focused migration/render tests, the full suite, and a custom bundle build. Record the upstream commit in the merge message and release handoff.

## Building the transferable app

The custom wrapper builds Palmier Pro with release optimization and bundled on-device speech models, but without Palmier's production analytics SDKs. It stamps both source revisions, disables the official updater, verifies resources and code signing, then emits a ZIP and SHA-256 file:

```bash
scripts/build-custom.sh release
```

Runtime deployment URLs may come from environment variables. On the original Mac, the script can instead read them from an existing working app through `PALMIER_CONFIG_APP`; their values are never written to source control.

The generated artifacts live under `.build/custom/` and are ignored by git. The ad-hoc signed personal build may require Control-click > Open on a new Mac. It requires Apple Silicon and macOS 26 or newer.

## Project migration check

For every representative legacy project:

1. Duplicate or export it as a self-contained `.palmier` package.
2. Hash the original package and keep it read-only.
3. Open only the duplicate in the custom build.
4. Verify media, captions, markers, effects, audio sync, denoise strength, voice/music balance, and chat history.
5. Save, close, reopen, and verify again.
6. Render a short talking-head section and compare the first/last audible transients against the source video.
7. Save a second time and confirm the project schema is idempotent.

Palmier Project export collects external media into the package and carries project chat history. Use that form for moving work to another laptop.

## New Mac handoff

Transfer these separately:

- `.build/custom/PalmierPro-Custom.zip` and its `.sha256` file;
- self-contained `.palmier` project packages;
- `~/.palmier/skills/`, including the growing-pill caption skill;
- the fork repository, or clone it from the pushed durable branch for future maintenance.

Do not copy build caches, denoise proxies, search-model caches, or derived data. The new Mac regenerates them. Sign in again rather than copying Keychain credentials.

## Deferred backlog

- Export an in-app chat session directly to Markdown. Project exports already preserve the JSON chat history, but a readable standalone export still needs UI, formatting, and tests.
- Revisit person-key performance after real-media correctness, cancellation, memory, and export-throughput benchmarks.
