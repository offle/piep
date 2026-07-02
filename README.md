# piep

piep is an iOS app for detecting bird calls on device. It uses bundled
BirdNET model files through TensorFlow Lite, stores listening sessions locally,
can optionally sync session data through iCloud, and can download freely
licensed bird photos from Wikimedia Commons for local cache use.

The app is currently a personal, free, non-commercial project.

## Features

- Live bird call detection from the microphone
- Overlapping 3 second analysis windows, processed once per second
- On-device BirdNET inference with location/date filtering
- Local listening sessions with timestamp, duration, coordinates, and species
- Optional iCloud Sync for sessions and detections
- Bird overview with search, sorting, day counts, and session references
- Map view with detected species by location
- Wikimedia Commons image loading with local cache and license attribution
- Configurable confidence threshold and expert audio profiles
- Manual benchmark sample recording/import for comparing audio profiles
- Apple Watch companion recording for clips of up to three minutes; analysis
  runs on the paired iPhone after transfer
- Alternate app icons

## Privacy

piep is designed to keep user data local:

- Audio is analyzed on device and is not uploaded by the app.
- Watch recordings are transferred directly to the paired iPhone, analyzed
  there, and removed after import.
- Location is used on device for BirdNET filtering and session coordinates.
- Sessions and bird detections are stored locally on the device.
- Optional iCloud Sync can synchronize sessions, detections, and coordinates
  through Apple's CloudKit service in the user's private iCloud database.
- Bird images are fetched from Wikimedia Commons and cached locally.

See [PRIVACY.md](PRIVACY.md) for the full privacy policy draft.

## Requirements

- Xcode 26 or newer
- The matching watchOS platform component in Xcode for Watch builds
- CocoaPods
- An Apple developer team for device builds or App Store distribution

## Setup

Install dependencies:

```sh
pod install
```

Build without a local signing configuration:

```sh
./build.sh
```

Install on a local device:

```sh
cp xcbuild.example.conf xcbuild.conf
# edit xcbuild.conf with your local device ID
./build.sh
./deploy.sh
```

`xcbuild.conf` is intentionally ignored because it contains local device and
signing configuration.

## App Store Notes

Review [APP_STORE_REVIEW_NOTES.md](APP_STORE_REVIEW_NOTES.md) before submitting
to App Review. The most important point is that the bundled BirdNET model
resources are licensed for non-commercial use.

## Licensing

The app source code is licensed under the MIT License. See [LICENSE](LICENSE).

The bundled BirdNET model files and third-party resources have separate license
terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Bird photos are loaded at runtime from freely licensed Wikimedia Commons
sources. The app displays per-image author, license, and source information.
