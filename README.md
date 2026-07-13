# OfficeCheckin

Native macOS Wi-Fi automatic check-in app. It uses SwiftUI, SwiftData, CoreWLAN, and ServiceManagement; all check-in data stays on the Mac.

## Highlights

- Target Wi-Fi: `XXX` (editable inside the app)
- Checks every five minutes; automatically checks in on the first target Wi-Fi connection each day
- Local SwiftData database
- Native dashboard with Today, Current Wi-Fi, quarterly workdays, Avg / Week, and heat maps
- Persistent menu-bar app, manual operations, and Excel exports
- Automatically writes `OfficeCheckin_Latest.xlsx` and retains two historical versions
- Optional Launch at Login
- The app stays running in the menu bar when its dashboard window is closed. It checks Wi-Fi at launch, when the Mac wakes, and every five minutes until that day's check-in succeeds.

## Install without Xcode

1. Open the GitHub repository's **Actions** tab and download the `OfficeCheckin-macOS` artifact, or download `OfficeCheckin-macOS.zip` from a tagged GitHub Release.
2. Unzip it and move `OfficeCheckin.app` to **Applications**.
3. The first time, Control-click the app and choose **Open**. This is required because the current build is ad-hoc signed, not notarized.
4. Allow the location permission if macOS asks. macOS may require it to read the current Wi-Fi name.

No Xcode is required to use the downloaded app.

## Build a distributable app

On a Mac with full Xcode installed:

```zsh
zsh scripts/build-release.sh
```

This produces `release/OfficeCheckin-macOS.zip`, containing an ad-hoc signed `OfficeCheckin.app`. To ship without the first-launch Gatekeeper prompt, add an Apple Developer ID certificate and notarize the app before release.

## Run from Xcode

1. Open `OfficeCheckin.xcodeproj` in Xcode 16+.
2. Select the **OfficeCheckin** scheme, choose **My Mac**, and run.
3. Allow the location permission if asked; macOS may require it to read the current Wi-Fi name.

Excel files are written to an `OfficeCheckin Exports` folder beside the installed app. If that directory is not writable (for example, `/Applications`), the app safely falls back to `~/Library/Application Support/OfficeCheckin/exports/`.

## Publish to GitHub

The local repository is ready for GitHub. Create an empty GitHub repository named `OfficeCheckin`, then add its URL and push:

```zsh
git remote add origin git@github.com:YOUR_ACCOUNT/OfficeCheckin.git
git branch -M main
git push -u origin main
```

Every push to `main` builds an installable ZIP in **Actions**. Push a version tag to create a GitHub Release with the ZIP attached:

```zsh
git tag v1.0.0
git push origin v1.0.0
```

## Requirements

- macOS 14 Sonoma or later (SwiftData)
- Xcode 16 or later is required only for development/building
