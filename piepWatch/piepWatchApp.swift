import SwiftUI

@main
struct piepWatchApp: App {
    @State private var recorder = WatchAudioRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRecordingView(recorder: recorder)
        }
    }
}
