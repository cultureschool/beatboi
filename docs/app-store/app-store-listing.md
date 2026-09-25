# BEATBOI DMG STUDIO — App Store Connect listing

## App identity

- **App name:** BEATBOI DMG STUDIO
- **Requested short name:** BEATBOI (Apple rejected this because the name is already used by another developer account.)
- **Subtitle:** Make beats. Shape the sound.
- **Primary category:** Music
- **Secondary category:** Creativity
- **Copyright:** © 2026 Quinn Sencer
- **Bundle ID:** `com.bytepocket.studio`
- **Version:** 1.0
- **Build:** 16
- **Age rating:** See `age-rating.md`
- **Price:** Free, with the one-time Export Pack in-app purchase

## Promotional text

Turn four retro synth voices and shaped drums into a playable groove machine.

## Description

BEATBOI is a tactile four-channel step sequencer for making music on iPhone.

Build grooves on a responsive 16-step performance grid, then shape every part with a focused sound-design workstation. Tap notes, drag across steps to paint a run, hold to link notes, and swipe melodic pads to move through the active scale. Drum rows use distinct kick, snare, hi-hat, and percussion voices with their own colors and characters.

The studio is organized around four focused stations:

• Beatpad — perform and edit patterns on the hero sequencer.
• Sound Lab — shape the selected synth or drum part.
• FX Station — route the mix through global effects and sends.
• Song Mode — arrange patterns into a playable sequence.

BEATBOI includes:

• Four channels: PULSE A, SQUARE B, TRIANGLE C, and DRUMS.
• Sixteen-step patterns with undo and redo.
• Scale-aware melodic editing.
• Distinct drum voices with per-voice sample selection and shaping.
• Tempo-synced playback and one-bar drum auditioning.
• Pattern banks, naming, duplication, and deletion.
• Song arrangements up to 64 bars.
• Project and MIDI import.
• WAV export with the one-time Export Pack.
• VoiceOver labels and adjustable controls for pads, parts, and parameters.
• Offline-first project storage with no analytics or tracking.

BEATBOI is designed to feel immediate: make a change, hear it, and keep moving.

## Keywords

beat maker,step sequencer,drum machine,synth,music maker,groove,midi,drum pads

## What's new — build 16

This release is a full visual overhaul of the studio interface. Beatpad now centers the 16-step performance grid with compact channel tiles and clearer transport hierarchy. Sound Lab, FX Station, and Song Mode each have a distinct visual identity, with flatter surfaces, improved spacing, and stronger focus states. Existing editing gestures, playback behavior, export, and VoiceOver controls are preserved.

## URLs

- **Support URL:** https://github.com/cultureschool/beatboi/issues
- **Privacy policy URL:** https://github.com/cultureschool/beatboi/blob/visual-overhaul/docs/app-store/privacy-policy.md
- **Marketing URL:** leave blank unless a public product page is created

## Review notes

BEATBOI does not require an account, network connection, microphone, camera, contacts, location, or tracking permission. Projects are stored locally on the device. The Export Pack is a non-consumable in-app purchase that unlocks WAV audio export; importing projects and MIDI files remains available without purchase.

To test the paid feature in App Review, use the StoreKit product `exportunlock` in the app's purchase flow. The app's core sequencer, playback, editing, and project features are available without purchasing it.
