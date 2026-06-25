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
    /// The trim editor draws its own crop box over the video and supplies its
    /// own transport bar, so it passes `.none` to hide the built-in controls
    /// (which the crop overlay would block anyway). The preview window keeps the
    /// default floating controls.
    var controlsStyle: AVPlayerViewControlsStyle = .floating

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        if nsView.controlsStyle != controlsStyle { nsView.controlsStyle = controlsStyle }
    }
}
