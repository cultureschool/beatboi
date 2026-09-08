# BEATBOI / AquaSort

A Game Boy-inspired four-channel step sequencer for iPhone.

## Protected baseline

The current arcade editor is the **pre-visual-overhaul baseline**. The baseline tag is created in version control after the validation suite passes. Visual work should happen on a separate branch and should not alter sequencing, persistence, import/export, or audio behavior without explicit approval.

## Build and test

Use the checked-in Xcode project:

```bash
xcodebuild test -project AquaSort.xcodeproj -scheme AquaSort -destination 'platform=iOS Simulator,id=C224773E-6479-44BF-9427-020DA6AC07F0'
```

If that simulator is unavailable, choose an installed simulator from `xcodebuild -showdestinations`.

## Before visual changes

1. Confirm the working tree is clean.
2. Create a short-lived visual branch from the protected baseline.
3. Keep data/audio model changes separate from visual commits.
4. Run the full test suite before and after each visual milestone.
5. Review the app on the Beatpad, Sound Lab, and Song pages, including drum gestures, channel mixer gestures, pattern switching during playback, Song Mode, and export.

## Recovery

The protected baseline can be restored with:

```bash
git switch --detach pre-visual-overhaul
```

Do not delete the tag. Create a new branch before making changes.
