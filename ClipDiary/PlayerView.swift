import SwiftUI
import AVKit

/// A video player view that keeps the on-hover playback controls but does not
/// dim the picture while they're showing.
///
/// SwiftUI's `VideoPlayer` wraps `AVPlayerView` with the *inline* controls
/// style, which darkens the whole frame behind the control bar — making the
/// clip hard to watch and forcing you to move the mouse away first. Wrapping
/// `AVPlayerView` directly lets us use the *floating* controls style, which
/// overlays a compact control bar without dimming the video.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
