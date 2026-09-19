# App Store submission package

This folder contains the prepared store copy, privacy policy, age-rating recommendation, and screenshot exports for BEATBOI.

## Files

- `app-store-listing.md` — name, subtitle, description, keywords, URLs, review notes, and build 16 release notes.
- `privacy-policy.md` — publish this page at the privacy URL before submitting.
- `age-rating.md` — recommended questionnaire answers.
- `screenshots/` — screenshots captured from the release archive where available.

## App Store Connect checklist

1. Publish `privacy-policy.md` at the GitHub URL listed in `app-store-listing.md`.
2. Enter the listing copy and keywords.
3. Set copyright to `© 2026 Quinn Sencer`.
4. Complete the age-rating questionnaire using `age-rating.md`.
5. Add the required iPhone screenshots for the device sizes App Store Connect requests. The checked-in screenshot is a source capture; verify its content and crop in the final device-size slots.
6. Select build 16 under the app version.
7. Review the completed App Review contact information and export-compliance prompts.
8. Submit the version for review.

The API has already attached build 16, completed the age rating, uploaded the iPhone 6.7-inch screenshot, and created the App Review contact record. Apple rejected changing the existing app name to BEATBOI because that name belongs to another developer account; the listing remains BEATBOI DMG STUDIO.

The App Store Connect API credentials currently configured in the local release tooling can upload builds and beta notes, but the repository's release script does not submit a version for App Review. Apple requires the app's metadata, review contact, and legal declarations to be confirmed in App Store Connect before that final submission.
