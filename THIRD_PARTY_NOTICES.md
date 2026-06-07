# Third-Party Notices

## BirdNET

This app bundles BirdNET model resources:

- `piep/BirdNET_v2/audio-model.tflite`
- `piep/BirdNET_v2/meta-model.tflite`
- `piep/BirdNET_v2/labels/*.txt`

BirdNET was developed by the K. Lisa Yang Center for Conservation Bioacoustics
at the Cornell Lab of Ornithology in collaboration with Chemnitz University of
Technology.

The BirdNET Analyzer source code is distributed under the MIT License. The
BirdNET model resources are distributed under Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0).

Project sources:

- https://github.com/birdnet-team/BirdNET-Analyzer
- https://birdnet.cornell.edu

## TensorFlow Lite

TensorFlow Lite is integrated through CocoaPods. See the corresponding Pod
metadata and upstream TensorFlow license terms for details.

The CocoaPods dependency tree is restored with `pod install`; the `Pods/`
directory is intentionally not committed.

## Bird Images

Bird images are downloaded from free Wikimedia Commons sources at runtime and
cached locally. Per-image author, license, and source information is shown in
the app where the image is displayed.

Only images with license metadata recognized as free by the app are cached and
shown. License decisions are made from Wikimedia Commons metadata at download
time.
