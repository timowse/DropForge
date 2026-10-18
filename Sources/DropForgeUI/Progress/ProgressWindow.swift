import AppKit
import SwiftUI
import DropForgeCore

struct UnitRowView: View {
    @ObservedObject var row: UnitRow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrics.spacingXS) {
            HStack(spacing: Tokens.Metrics.spacingS) {
                statusIcon
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.title)
                Spacer(minLength: 4)
                if row.status == .succeeded, !row.outputs.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(row.outputs)
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(row.outputs.first?.lastPathComponent ?? "result") in Finder")
                }
            }
            if row.status == .running || row.status == .queued {
                ProgressView(value: row.progress)
                    .progressViewStyle(.linear)
                    .tint(.dfAccent)
                    .accessibilityLabel("Progress for \(row.title)")
                    .accessibilityValue("\(Int(row.progress * 100)) percent")
            }
            if let output = row.outputs.first, row.status == .succeeded {
                Text(row.outputs.count == 1 ? "→ \(output.lastPathComponent)" : "→ \(row.outputs.count) items")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let message = row.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(row.status == .failed ? Color.dfDanger : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var statusIcon: some View {
        switch row.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .running: Image(systemName: "gearshape.2").foregroundStyle(Color.dfAccent).accessibilityLabel("Working")
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dfSuccess).accessibilityLabel("Done")
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.dfDanger).accessibilityLabel("Failed")
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityLabel("Cancelled")
        }
    }
}

struct JobView: View {
    @ObservedObject var job: JobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrics.spacingS) {
            HStack {
                Text(job.title).font(.headline)
                Spacer()
                Text(job.summary).font(.caption).foregroundStyle(.secondary)
                if !job.isFinished {
                    Button("Cancel", role: .cancel) { job.cancel() }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel \(job.title)")
                } else if !job.outputs.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                        .controlSize(.small)
                }
            }
            if job.rows.count > 1 && !job.isFinished {
                ProgressView(value: job.overallProgress).tint(.dfAccent)
                    .accessibilityLabel("Overall progress")
            }
            ForEach(job.rows) { UnitRowView(row: $0) }
        }
        .padding(Tokens.Metrics.spacingM)
        .background(RoundedRectangle(cornerRadius: Tokens.Metrics.cornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct ProgressListView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(spacing: 0) {
            if center.jobs.isEmpty {
                VStack(spacing: Tokens.Metrics.spacingS) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recent work").font(.headline)
                    Text("Drag files and tap ⇧, ⌘ or ⌃ to start.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Tokens.Metrics.spacingXL)
            } else {
                ScrollView {
                    VStack(spacing: Tokens.Metrics.spacingS) {
                        ForEach(center.jobs) { JobView(job: $0) }
                    }
                    .padding(Tokens.Metrics.spacingM)
                }
                Divider()
                HStack {
                    Button("Clear finished") { center.clearFinished() }
                        .disabled(!center.jobs.contains { $0.isFinished })
                    Spacer()
                    if center.hasRunningJobs {
                        Button("Cancel all") { center.cancelAll() }
                    }
                }
                .padding(Tokens.Metrics.spacingS)
            }
        }
        .frame(width: Tokens.Metrics.progressWidth)
        .frame(minHeight: 140, maxHeight: 520)
    }
}

/// Small floating window listing jobs (S06).
@MainActor
public final class ProgressWindowController {
    let center: JobCenter
    lazy var window: NSPanel = {
        let host = NSHostingController(rootView: ProgressListView(center: center))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView]
        panel.title = "DropForge"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("DropForgeProgress")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()
    private var closeWork: DispatchWorkItem?

    public init(center: JobCenter) {
        self.center = center
    }

    public func show() {
        closeWork?.cancel()
        if !window.isVisible {
            if let screen = NSScreen.main, window.frame.origin == .zero || !screen.visibleFrame.intersects(window.frame) {
                let vf = screen.visibleFrame
                window.setFrameTopLeftPoint(CGPoint(x: vf.maxX - Tokens.Metrics.progressWidth - 24, y: vf.maxY - 24))
            }
        }
        window.orderFrontRegardless()
    }

    /// Closes shortly after everything succeeded; stays open when something needs attention.
    public func scheduleAutoClose() {
        guard !center.hasRunningJobs else { return }
        let clean = center.jobs.allSatisfy { $0.failures.isEmpty && !$0.wasCancelled }
        guard clean else { return }
        let work = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    public var isVisible: Bool { window.isVisible }
}
