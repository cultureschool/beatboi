# App Store submission package

This folder contains the prepared store copy, privacy policy, age-rating recommendation, and screenshot exports for BEATBOI.

## Files

- `app-store-listing.md` — name, subtitle, description, keywords, URLs, review notes, and build 16 release notes.
- `privacy-policy.md` — publish this page at the privacy URL before submitting.
- `age-rating.md` — recommended questionnaire answers.
- `screenshots/` — fresh iPhone 6.5-inch and iPad 12.9-inch simulator captures for Beatpad, Sound Lab, FX Station, Song Mode, plus the Export Pack in-app-purchase review screenshot.

## App Store Connect checklist

1. Publish `privacy-policy.md` at the GitHub URL listed in `app-store-listing.md`.
2. Enter the listing copy and keywords.
3. Set copyright to `© 2026 Quinn Sencer`.
4. Complete the age-rating questionnaire using `age-rating.md`.
5. Add the fresh 6.5-inch listing captures from `screenshots/`: Beatpad, Sound Lab, FX Station, and Song Mode. They are 1284×2778 and have already been uploaded to the matching `APP_IPHONE_65` slot.
6. Add the iPad captures from `screenshots/*-ipad.png` to the 12.9-inch iPad screenshot set. They are 2048×2732 and have already been uploaded to `APP_IPAD_PRO_3GEN_129`, the slot that maps to Apple’s current 13-inch iPad display shelf.
7. For the Export Pack IAP, use `screenshots/export-pack-iphone17pro.png` as the App Store Review Screenshot, then confirm the $1.99 price and attach the IAP to the app version.
8. Select build 16 under the app version.
9. Review the completed App Review contact information and export-compliance prompts.
10. Submit the version and Export Pack for review.

The API has already attached build 16, completed the age rating, uploaded the iPhone 6.7-inch screenshot, created the App Review contact record, populated the Export Pack localization, and uploaded `screenshots/export-pack-iphone17pro.png` as the IAP review screenshot. Apple rejected changing the existing app name to BEATBOI because that name belongs to another developer account; the listing remains BEATBOI DMG STUDIO.

The App Store Connect API credentials currently configured in the local release tooling can upload builds and beta notes, but the repository's release script does not submit a version for App Review. Apple requires the app's metadata, review contact, and legal declarations to be confirmed in App Store Connect before that final submission.
