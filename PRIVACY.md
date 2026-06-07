# Privacy Policy

Last updated: 2026-06-07

piep is a free, non-commercial iOS app for detecting bird calls. The app is
designed to process bird sound detection locally on the user's device.

## Data Processed by the App

### Microphone Audio

piep uses the microphone while the user starts a listening session or records a
benchmark sample. Audio is processed on device with bundled BirdNET model files.
The app does not upload microphone audio to a server operated by the app.

Imported benchmark audio files are processed locally. The app keeps the most
recent benchmark sample locally so the user can repeat benchmark runs.

### Location

piep can request the device location to improve BirdNET predictions with
regional bird occurrence information and to attach coordinates to listening
sessions. Location data is stored locally as part of the user's sessions. The
app does not upload session locations to a server operated by the app.

The app may use Apple frameworks such as MapKit and Core Location to show maps
and resolve location names. Data handled by Apple frameworks is governed by
Apple's privacy practices.

### Sessions and Detections

Listening sessions, detected bird species, timestamps, durations, confidence
values, counters, coordinates, and user deletions are stored locally on the
device. This data is not uploaded by the app.

### Bird Images

piep can download bird images and image metadata from Wikimedia Commons. Images
and metadata are cached locally. The app stores image source, author, and
license information so it can display attribution.

When images are loaded, the device connects to Wikimedia Commons. Wikimedia may
receive normal technical request data such as IP address and user agent as part
of that request.

## Data Sharing

piep does not operate a backend service and does not share audio, sessions,
detections, or location data with a developer-operated server.

The app integrates third-party model and library resources:

- BirdNET model files are bundled in the app and run on device.
- TensorFlow Lite is used for local model inference.
- Wikimedia Commons is contacted when bird images are downloaded.

## Data Retention and Deletion

Local app data remains on the user's device until the user deletes it or removes
the app. Users can delete sessions inside the app. Cached bird images can be
removed from Settings. Deleting the app removes its local data from the device.

## Tracking and Advertising

piep does not include advertising SDKs and does not track users across apps or
websites.

## Contact

Author: Ole Wulff  
Email: offlepoffle1@icloud.com
