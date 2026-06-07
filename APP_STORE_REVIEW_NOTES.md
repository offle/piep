# App Store Review Notes

piep is a free, non-commercial bird sound detection app.

## Core Functionality

- The user starts and stops listening manually.
- The microphone is used only while listening or while recording a benchmark
  sample in Settings > Expert.
- Bird sound detection runs on device with bundled BirdNET model files.
- Audio is not uploaded by the app.
- The app stores listening sessions locally so the user can review detected
  species later.

## Location Use

Location is used to improve BirdNET predictions with regional occurrence data
and to show detected birds on the local map. If location permission is not
available, the app can still analyze audio without regional filtering.

## Network Use

The main detection workflow works offline after the app is installed.

Network access is used when bird images are loaded from Wikimedia Commons.
Downloaded images are cached locally and each image includes author, license,
and source attribution in the app.

## AI and Accuracy

Bird detections are probabilistic model suggestions and may be wrong. The app
shows confidence values and lets users delete incorrect detections or sessions.

## Third-Party Licenses

The app bundles BirdNET model resources. BirdNET Analyzer source code is MIT
licensed, while the BirdNET model resources are licensed under Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0).

The app is distributed as a free, non-commercial project. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Privacy Policy

See [PRIVACY.md](PRIVACY.md).
