# Chapter Export Verification

Use this checklist on a Mac with VLC, QuickTime Player, and a browser available. It covers the manual playback proof for Phase 44 chapter export; automated tests cover the YouTube sidecar formatter and validator, but they cannot prove each player exposes embedded chapter metadata in its UI.

## Test Project

1. Create or open a project with a video timeline at least 35 seconds long.
2. Add at least three chapter markers:
   - `00:00` - `Intro`
   - `00:12` - `Demo`
   - `00:25` - `Wrap`
3. Confirm the Tutorial Finishing inspector shows no chapter validation issues.
4. Export to `.mp4` or `.mov`.

## Artefacts

1. Confirm the movie file exists at the selected destination.
2. Confirm the sidecar exists next to it as `<movie-stem>.chapters.txt`.
3. Open the sidecar and confirm it contains the expected timestamp/title lines.

## VLC

1. Open the exported movie in VLC.
2. Open VLC's chapter navigation menu.
3. Confirm `Intro`, `Demo`, and `Wrap` appear as selectable chapters.
4. Select each chapter and confirm playback seeks to the expected time.

## QuickTime Player

1. Open the exported movie in QuickTime Player.
2. Open the player chapter list or chapter navigation control when available for the file.
3. Confirm the chapter titles appear.
4. Select each chapter and confirm playback seeks to the expected time.

## YouTube Description Smoke

1. Copy the sidecar text into a YouTube description draft.
2. Confirm YouTube recognizes the timestamps as chapters after processing.
3. If YouTube treats them as plain timestamps, re-check that the first chapter is `00:00`, there are at least three chapters, times are monotonic, and every span is at least 10 seconds.

## Result

Record the app build, export preset, container, codec, and player versions in the PR or release note. If a player does not expose embedded chapters for a valid `.mp4` or `.mov`, keep the sidecar result as the fallback proof and note the player/version-specific behavior.
