# Simmer

A volume knob for every app on your Mac. Turn the call up, the music down,
and that one browser tab off, right from the menu bar.

**[simmer.bnapier.dev](https://simmer.bnapier.dev)**

- **One slider per app.** Every app that plays sound shows up with its icon.
- **Mute any app.** One click. The rest keep playing.
- **Remembers.** Each app's volume is saved and used again next time.
- **Follows your speakers.** Switch to headphones and the volumes come along.
- **Private.** No account, no server, no tracking. The code is open.

## Install

[Download Simmer](https://github.com/barry-napier/simmer/releases/latest/download/Simmer.dmg),
open it, and drag Simmer to Applications. Simmer updates itself.

Needs macOS 15 or later.

## Use

1. Click the sliders icon in the menu bar.
2. Move an app's slider, or click its speaker to mute it.
3. **Reset All** puts every app back to full volume.

The first time you turn an app down, macOS asks to let Simmer hear other
apps. Say yes. You can change it later in System Settings > Privacy &
Security > Screen & System Audio Recording, under "System Audio Recording Only".

## How it works

macOS has no volume per app. So Simmer uses Core Audio process taps
(macOS 14.2 and later):

1. Simmer asks macOS for a tap on the app. macOS silences the app and hands
   its sound to Simmer.
2. Simmer joins that tap to your speakers with a private device only it can see.
3. Simmer plays the sound on your speakers at the volume you picked.

An app at 100% is never tapped, so its sound is not touched at all. When
Simmer quits, every app goes straight back to its own volume.

Browsers play sound from helper processes. Simmer works out which app each
helper belongs to, so Chrome or Safari shows up as one row.

The code: [`Simmer/Audio/AppTap.swift`](Simmer/Audio/AppTap.swift) does the
tap, [`Mixer.swift`](Simmer/Audio/Mixer.swift) keeps the list and the saved
volumes, and [`AudioProcesses.swift`](Simmer/Audio/AudioProcesses.swift)
finds the apps.

## Privacy

- Sound passes through Simmer and straight back out. It is never recorded or saved.
- Volumes are saved in Simmer's preferences on your Mac, by app ID.
- The only network use is updates: checking for them and downloading them
  from this repository's releases.
- The debug log is in `~/Library/Logs/Simmer`. It lists app names, never sound.

## Build from source

You need Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and an Apple Development certificate.

```sh
./scripts/build.sh
```

This builds, signs with your certificate, installs to `/Applications`, and
relaunches Simmer. Always use it for test builds: a stable path and signature
keep macOS from forgetting the sound permission. On first run it writes your
Team ID to `Config/Local.xcconfig`, which is not committed.

The Xcode project is generated from `project.yml`. Edit that, not the project.

### Debugging

**Debug Log** in the menu lists what Simmer saw and did. The same log is in
`~/Library/Logs/Simmer/simmer.log`.

If the permission goes stale:

```sh
tccutil reset AudioCapture com.barrynapier.simmer
```

## Website

[simmer.bnapier.dev](https://simmer.bnapier.dev) is the plain HTML in `site/`,
hosted on Vercel. There is no build step: open `site/index.html` to preview it.

## Releasing

Releases are built by GitHub Actions. To ship a new version:

```sh
./scripts/ship.sh 0.2.0
```

That pushes `main` and a `v0.2.0` tag. The [Release workflow](.github/workflows/release.yml)
then builds Simmer, signs it with Developer ID, has Apple notarize it, packs
the DMG, signs it for Sparkle, and publishes the GitHub release with
`appcast.xml`. Installed copies of Simmer check
`releases/latest/download/appcast.xml` and offer the update by themselves.

The workflow needs these repository secrets: `MACOS_CERT_P12`,
`MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` and
`SPARKLE_PRIVATE_KEY`. The workflow file says what each one is.

To build a release on a Mac instead, without publishing:

```sh
./scripts/release.sh 0.2.0                  # needs: xcrun notarytool store-credentials simmer-notary
./scripts/release.sh 0.2.0 --skip-notarize  # quick local check
```

Keep a backup of the Sparkle update key (`generate_keys --account
com.barrynapier.simmer -x FILE`) somewhere safe. Without it, no update can
ever reach people who already installed Simmer.

## License

MIT. See [LICENSE](LICENSE).
