import AppKit
import AVFoundation
import AVKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// Minimal AVPlayerView wrapper; exposes the player so the editor can read the playhead.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFrameSteppingButtons = true
        v.setAccessibilityLabel("Media preview")
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

@MainActor
final class MediaPreview: ObservableObject {
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var hasVideo = false

    init(url: URL) {
        player = AVPlayer(url: url)
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            var d = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var v = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
            if !d.isFinite || d <= 0, let info = try? await MediaEngine().probe(url) {
                // AVI, WMV, MKV and friends: AVFoundation cannot open them, ffprobe can.
                d = info.duration ?? 0
                v = info.hasVideo
            }
            self?.duration = d.isFinite ? d : 0
            self?.hasVideo = v
        }
    }

    var playhead: Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }
}

struct MediaToolEditor: View {
    let context: EditorContext
    let tool: ToolKind
    @StateObject private var media: MediaPreview
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var speed = 2.0
    @State private var splitMode = 0
    @State private var splitTimes = ""
    @State private var parts = 2
    @State private var every = 60.0
    @State private var snapMode = 0
    @State private var snapTimes = ""
    @State private var snapCount = 5
    @State private var snapFormat: FileFormat = .png
    @State private var loudness = -16.0
    @State private var channels: ChannelMode = .mono
    @State private var bleepText = ""
    @State private var bleepTone = true
    @State private var error: String?

    init(context: EditorContext, tool: ToolKind) {
        self.context = context
        self.tool = tool
        _media = StateObject(wrappedValue: MediaPreview(url: context.selection.items[0].url))
    }

    var title: String { context.descriptor.title }

    var body: some View {
        EditorChrome(title: title, subtitle: context.subtitle, primaryTitle: primaryTitle, error: error, canApply: true,
                     onCancel: { media.player.pause(); context.cancel() }, onApply: apply) {
            PlayerView(player: media.player)
                .frame(minHeight: media.hasVideo ? 280 : 60, maxHeight: media.hasVideo ? .infinity : 70)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Metrics.cornerRadius))
            if media.duration > 0 {
                Text("Length \(InputParsing.formatTime(media.duration))").font(.caption).foregroundStyle(.secondary)
            }
            controls
        }
        .onChange(of: media.duration) { _, d in if end == 0 { end = d } }
        .onDisappear { media.player.pause() }
    }

    var primaryTitle: String {
        switch tool {
        case .trim: "Trim"
        case .split: "Split"
        case .snapshot: "Save snapshots"
        default: "Save copy"
        }
    }

    @ViewBuilder var controls: some View {
        switch tool {
        case .trim:
            HStack {
                Text("From"); TimeField(label: "Start", seconds: $start)
                Button("Use playhead") { start = media.playhead }
                Text("to"); TimeField(label: "End", seconds: $end)
                Button("Use playhead") { end = media.playhead }
                Spacer()
                Text("Keeps \(InputParsing.formatTime(max(0, end - start)))").foregroundStyle(.secondary)
            }
        case .speed:
            Picker("Speed", selection: $speed) {
                ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .pickerStyle(.segmented)
        case .split:
            Picker("Split", selection: $splitMode) {
                Text("Equal parts").tag(0); Text("Every…").tag(1); Text("At times").tag(2)
            }
            .pickerStyle(.segmented)
            switch splitMode {
            case 0: Stepper("\(parts) parts", value: $parts, in: 2...50)
            case 1: HStack { Text("Every"); TimeField(label: "Segment length", seconds: $every); Text("(m:ss)") }
            default:
                HStack {
                    TextField("Times, e.g. 0:30, 1:15", text: $splitTimes).accessibilityLabel("Split times")
                    Button("Add playhead") { splitTimes += (splitTimes.isEmpty ? "" : ", ") + InputParsing.formatTime(media.playhead) }
                }
            }
        case .snapshot:
            Picker("Take", selection: $snapMode) {
                Text("At playhead").tag(0); Text("Evenly spaced").tag(1); Text("At times").tag(2)
            }
            .pickerStyle(.segmented)
            HStack {
                if snapMode == 1 { Stepper("\(snapCount) images", value: $snapCount, in: 1...200) }
                if snapMode == 2 {
                    TextField("Times, e.g. 0:05, 0:42", text: $snapTimes).accessibilityLabel("Snapshot times")
                    Button("Add playhead") { snapTimes += (snapTimes.isEmpty ? "" : ", ") + InputParsing.formatTime(media.playhead) }
                }
                Picker("Format", selection: $snapFormat) { Text("PNG").tag(FileFormat.png); Text("JPG").tag(FileFormat.jpeg) }
                    .frame(width: 140)
            }
        case .normalize:
            Picker("Loudness target", selection: $loudness) {
                Text("Streaming (−14 LUFS)").tag(-14.0)
                Text("Podcast (−16 LUFS)").tag(-16.0)
                Text("Broadcast (−23 LUFS)").tag(-23.0)
            }
            .pickerStyle(.radioGroup)
        case .channels:
            Picker("Channels", selection: $channels) {
                ForEach(ChannelMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
        case .bleep:
            HStack {
                TextField("Intervals, e.g. 0:05-0:07, 1:10-1:12", text: $bleepText).accessibilityLabel("Intervals to bleep")
                Button("Mark playhead ±½ s") {
                    let t = media.playhead
                    let s = "\(InputParsing.formatTime(max(0, t - 0.5)))-\(InputParsing.formatTime(t + 0.5))"
                    bleepText += (bleepText.isEmpty ? "" : ", ") + s
                }
            }
            Toggle("Use a tone (off = silence)", isOn: $bleepTone)
        default:
            EmptyView()
        }
    }

    func apply() {
        media.player.pause()
        let params: ToolParameters
        switch tool {
        case .trim: params = .trim(TimeSpan(start: start, end: end))
        case .speed: params = .speed(speed)
        case .split:
            switch splitMode {
            case 0: params = .split(SplitOptions(mode: .equalParts(parts)))
            case 1: params = .split(SplitOptions(mode: .every(every)))
            default:
                guard let t = InputParsing.times(splitTimes) else { error = "Enter times like 0:30, 1:15."; return }
                params = .split(SplitOptions(mode: .atTimes(t)))
            }
        case .snapshot:
            switch snapMode {
            case 0: params = .snapshot(SnapshotOptions(mode: .atTimes([media.playhead]), format: snapFormat))
            case 1: params = .snapshot(SnapshotOptions(mode: .count(snapCount), format: snapFormat))
            default:
                guard let t = InputParsing.times(snapTimes) else { error = "Enter times like 0:05, 0:42."; return }
                params = .snapshot(SnapshotOptions(mode: .atTimes(t), format: snapFormat))
            }
        case .normalize: params = .normalize(NormalizeOptions(targetLUFS: loudness))
        case .channels: params = .channels(channels)
        case .bleep:
            do {
                params = .bleep(BleepOptions(intervals: try InputParsing.intervals(bleepText, duration: media.duration > 0 ? media.duration : nil),
                                             frequency: bleepTone ? 1000 : 0))
            } catch {
                self.error = UserMessage.describe(error)
                return
            }
        default: params = .none
        }
        error = context.apply(params)
    }
}
