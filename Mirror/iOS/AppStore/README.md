# Prowl Mirror on the App Store

The App Store record of Prowl Mirror (app ID `6831901271`) is kept here as files and applied with
[`asc`](https://asccli.sh), so a release changes text in Git, not in a web form.

| Path | Content |
| --- | --- |
| `metadata/app-info/en-US.json` | Name, subtitle, privacy policy URL |
| `metadata/version/<version>/en-US.json` | Description, keywords, promotional text, marketing and support URLs |
| `metadata/categories.json` | Developer Tools, with Productivity |
| `metadata/age-rating.json` | Every answer "none" (4+) |
| `metadata/review-information.json` | Notes for App Review: how to review with the demo |
| `capture-screenshots.sh` | Captures the screenshot sets from the demo |

The version directory must match the App Store version, which must match the build's
`CFBundleShortVersionString` (CalVer, `YYYY.M.D`, from `scripts/release-mirror-ios.sh`).

## Update the metadata

```bash
cd Mirror/iOS/AppStore
asc versions update --version-id <VERSION_ID> --version <YYYY.M.D>   # only when the build changes
asc metadata plan --app 6831901271 --version <YYYY.M.D> --platform IOS --dir ./metadata \
  --include localizations,categories,age-rating,review-information
asc metadata approve --review-dir .asc/metadata/review --all
asc metadata apply --app 6831901271 --version <YYYY.M.D> --platform IOS --dir ./metadata \
  --include localizations,categories,age-rating,review-information \
  --review-dir .asc/metadata/review --confirm
```

`--include` replaces the default scope, so list `localizations` too. The review contact
(name, phone, email) is personal and is not in the file: set it in App Store Connect, or with
`asc review details-create`/`details-update`. A new version needs `whatsNew` in its version file;
the first version must not have one.

Not covered by the API, so done in App Store Connect: **App Privacy** (the answer is "Data Not
Collected"; see the privacy policy at https://prowl.cat/privacy/), and selecting the build for the
version.

## Screenshots

```bash
Mirror/iOS/AppStore/capture-screenshots.sh build/mirror-ios/screenshots
asc screenshots upload --version-localization <LOCALIZATION_ID> --path build/mirror-ios/screenshots/iphone --device-type IPHONE_69
asc screenshots upload --version-localization <LOCALIZATION_ID> --path build/mirror-ios/screenshots/ipad --device-type IPAD_PRO_3GEN_129
asc screenshots upload --version-localization <LOCALIZATION_ID> --path build/mirror-ios/screenshots/duo --device-type IPHONE_DUO
```

Five screens from the demo, in dark appearance: Agents, a permission prompt, the answered
conversation, the terminal with the key bar, and New Session. The iPhone Duo set (cover display)
lets the product page show the app as optimized for iPhone Duo. `asc screenshots list
--version-localization <LOCALIZATION_ID>` shows the current sets; delete old ones before uploading
replacements.

## Demo video for App Review

Apple asks apps that need other hardware for a video of the app on a physical device. The demo
covers the features without a Mac; the video shows the real pairing. Film the iPhone and the Mac
screen together (a second phone or a camera; a screen recording alone does not show the Mac), no
narration needed, about two to three minutes.

Before filming: a release build of Prowl on the Mac with **Remote Mirror** on; a Claude Code or
Codex agent ready in a project; the TestFlight build of Prowl Mirror freshly installed; the Mac and
the iPhone on the same Wi-Fi.

1. Open Prowl Mirror: the onboarding screen.
2. On the Mac: the **Remote Mirror** toolbar button → **Add a Device**, showing the QR code.
3. On the iPhone: **Pair with a Mac** → allow the camera → scan → allow local network. The
   Agents list of the Mac appears.
4. Open an agent: the chat; switch to **Terminal** and back.
5. On the Mac, ask the agent for something that needs permission (for example, to run the
   tests). The iPhone shows it as **Blocked** with the choices; tap **Yes**; the Mac continues.
6. Send a message from the iPhone; it arrives in the Mac pane.
7. **New Session** on the iPhone; a new tab opens on the Mac.
8. Notifications: turn them on in Prowl on the Mac and in Prowl Mirror (gear → Settings);
   lock the Mac; when the agent is blocked, the notification arrives; tap it to open the pane.
9. Gear → Settings → About → **Privacy Policy**.

Upload the video as an App Review attachment (`asc review attachments-upload`) or link it in the
review notes, and mention it in `metadata/review-information.json`.
