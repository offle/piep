# Privacy Policy

Last updated: 2026-06-18

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

### Sessions, Detections, and iCloud Sync

Listening sessions, detected bird species, timestamps, durations, confidence
values, counters, coordinates, and user deletions are stored locally on the
device.

iCloud Sync is optional and disabled until the user enables it in Settings. If
iCloud Sync is enabled, the app synchronizes listening sessions and bird
detections through Apple's CloudKit service in the user's private iCloud
database. Synchronized session data can include timestamps, durations,
coordinates, location names, detected species names, confidence values,
detection counters, and deletion markers.

The app does not sync microphone audio, imported benchmark samples, cached bird
images, image files, image licenses, app settings, or expert profile settings
through iCloud.

If iCloud Sync is turned off later, local data remains on the device. The app
stops synchronizing until the user enables iCloud Sync again.

### Bird Images

piep can download bird images and image metadata from Wikimedia Commons. Images
and metadata are cached locally. The app stores image source, author, and
license information so it can display attribution.

When images are loaded, the device connects to Wikimedia Commons. Wikimedia may
receive normal technical request data such as IP address and user agent as part
of that request.

## Data Sharing

piep does not operate a developer-controlled backend service and does not share
audio, sessions, detections, or location data with a developer-operated server.

The app integrates third-party model and library resources:

- BirdNET model files are bundled in the app and run on device.
- TensorFlow Lite is used for local model inference.
- Wikimedia Commons is contacted when bird images are downloaded.
- Apple CloudKit is used only if the user enables optional iCloud Sync.

## Data Retention and Deletion

Local app data remains on the user's device until the user deletes it or removes
the app. Users can delete sessions inside the app. Cached bird images can be
removed from Settings. Deleting the app removes its local data from the device.

Data synchronized through iCloud is stored in the user's private iCloud account
and can be removed from iCloud by deleting the synchronized sessions in the app
while iCloud Sync is enabled, or through Apple's iCloud data management tools.

## Tracking and Advertising

piep does not include advertising SDKs and does not track users across apps or
websites.

## Contact

Author: Ole Wulff  
Email: offlepoffle1@icloud.com
