import Foundation
import Testing
@testable import DropForgeCore

/// Selections built from synthetic URLs: the resolver only looks at names and kinds.
func item(_ name: String, size: Int64 = 1000, directory: Bool = false) -> DroppedItem {
    let url = URL(fileURLWithPath: "/tmp/dropforge-tests/\(name)")
    if directory { return DroppedItem(url: url, format: nil, kind: .folder, byteSize: 0, isDirectory: true) }
    let format = FileFormat.detect(url)
    return DroppedItem(url: url, format: format, kind: format?.kind ?? .other, byteSize: size, isDirectory: false)
}

func selection(_ names: String...) -> Selection { Selection(items: names.map { item($0) }) }

extension Resolution {
    var ids: [String] { available.map(\.id) }
    var unavailableIDs: [String] { unavailable.map(\.descriptor.id) }
}

@Suite("Capability selection")
struct CapabilityTests {
    let all = CapabilityResolver(availability: .everything)
    let native = CapabilityResolver(availability: .nativeOnly)

    @Test func formatDetection() {
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/B.JPEG")) == .jpeg)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.tar.gz")) == .tgz)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.gz")) == .gz)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.markdown")) == .md)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/noextension")) == nil)
        #expect(FileFormat.jpeg.preferredExtension == "jpg")
        #expect(FileFormat.svg.isInputOnly && FileFormat.rar.isInputOnly && !FileFormat.webp.isInputOnly)
    }

    @Test func singleImageExcludesItsOwnFormat() {
        let r = all.resolve(selection("photo.png"), category: .convert)
        #expect(r.ids == ["convert.jpeg", "convert.webp", "convert.heic", "convert.avif", "convert.tiff", "convert.gif", "convert.bmp", "convert.pdf"])
        #expect(!r.ids.contains("convert.png"))
    }

    @Test func webpNeedsTheBundledEncoder() {
        let r = native.resolve(selection("photo.png"), category: .convert)
        #expect(!r.ids.contains("convert.webp"))
        #expect(r.unavailableIDs == ["convert.webp"])
        #expect(r.unavailable[0].reason.contains("WebP"))
    }

    @Test func inputOnlyFormatsAreNeverTargets() {
        for f in FileFormat.allCases {
            let r = all.resolve(Selection(items: [item("x.\(f.extensions[0])")]), category: .convert)
            for d in r.available { #expect(d.outputFormat.map { !$0.isInputOnly } ?? true, "\(f) offers \(d.id)") }
        }
    }

    @Test func videoOffersAudioExtraction() {
        let r = all.resolve(selection("clip.mov"), category: .convert)
        #expect(r.ids.contains("convert.mp3"))
        #expect(r.available.first { $0.id == "convert.mp3" }?.title == "Extract audio as MP3")
        #expect(!r.ids.contains("convert.mov"))
    }

    @Test func wmvAndAviAreInputOnly() {
        #expect(all.resolve(selection("old.wmv"), category: .convert).ids.contains("convert.mp4"))
        #expect(!all.resolve(selection("old.mp4"), category: .convert).ids.contains("convert.wmv"))
        #expect(all.resolve(selection("song.wma"), category: .convert).ids.contains("convert.mp3"))
    }

    @Test func mediaNeedsFFmpeg() {
        let r = native.resolve(selection("clip.mp4"), category: .convert)
        #expect(r.available.allSatisfy { $0.outputFormat?.kind == .archive })
        #expect(r.unavailableIDs.contains("convert.webm"))
    }

    @Test func batchOfSameKindKeepsOwnFormatAsTarget() {
        // PNG + JPG: both can become PNG (the PNG is skipped at run time).
        let r = all.resolve(selection("a.png", "b.jpg"), category: .convert)
        #expect(r.ids.contains("convert.png"))
        #expect(r.ids.contains("convert.jpeg"))
        let plan = JobPlanner.plan(r.available.first { $0.id == "convert.png" }!, selection: selection("a.png", "b.jpg"), parameters: .none)
        #expect(plan.units.map(\.skipReason) == ["Already PNG.", nil])
    }

    @Test func allSameFormatDropsThatTarget() {
        let r = all.resolve(selection("a.png", "b.png"), category: .convert)
        #expect(!r.ids.contains("convert.png"))
    }

    @Test func mixedSelectionShowsCommonTargetsPlusArchives() {
        let r = all.resolve(selection("a.png", "b.mp4"), category: .convert)
        #expect(r.ids.contains("convert.gif"))     // both images and videos can become GIF
        #expect(r.ids.contains("convert.zip") && r.ids.contains("convert.tar") && r.ids.contains("convert.tgz"))
        #expect(!r.ids.contains("convert.jpeg"))
        let zip = r.available.first { $0.id == "convert.zip" }!
        #expect(zip.batchMode == .combined)
    }

    @Test func folderGetsArchiveTargets() {
        let r = all.resolve(Selection(items: [item("Folder", directory: true)]), category: .convert)
        #expect(r.ids == ["convert.zip", "convert.tar", "convert.tgz"])
    }

    @Test func archiveOffersExtractAndRepack() {
        let r = all.resolve(selection("bundle.zip"), category: .convert)
        #expect(r.ids.first == "convert.extract")
        #expect(r.ids.contains("convert.tar") && !r.ids.contains("convert.zip"))
        let rar = all.resolve(selection("old.rar"), category: .convert)
        #expect(rar.ids.contains("convert.extract"))
        let unknown = all.resolve(selection("data.bin"), category: .convert)
        #expect(unknown.ids == ["convert.zip", "convert.tar", "convert.tgz"])
    }

    @Test func documentRoutes() {
        let md = all.resolve(selection("notes.md"), category: .convert)
        #expect(md.ids == ["convert.pdf", "convert.docx", "convert.txt", "convert.html", "convert.rtf", "convert.odt", "convert.epub"])
        // DOCX → PDF prefers LibreOffice but works natively too.
        let docx = native.resolve(selection("letter.docx"), category: .convert)
        #expect(docx.ids.contains("convert.pdf"))
        let d = docx.available.first { $0.id == "convert.pdf" }!
        #expect(all.engine(for: d, item: item("letter.docx")) == .libreOffice)
        #expect(native.engine(for: d, item: item("letter.docx")) == .native)
    }

    @Test func pagesNeedsPagesOrLibreOffice() {
        let r = native.resolve(selection("Letter.pages"), category: .convert)
        #expect(r.available.allSatisfy { $0.outputFormat?.kind == .archive })
        #expect(r.unavailable.contains { $0.reason.contains("Pages") })
        let lo = CapabilityResolver(availability: EngineAvailability(available: [.libreOffice]))
        #expect(lo.resolve(selection("Letter.pages"), category: .convert).ids.contains("convert.pdf"))
    }

    @Test func spreadsheetsAndSlides() {
        let csv = native.resolve(selection("t.csv"), category: .convert)
        #expect(csv.ids.contains("convert.tsv"))            // native
        #expect(csv.unavailableIDs.contains("convert.xlsx")) // needs an office engine
        let pptx = CapabilityResolver(availability: EngineAvailability(available: [.libreOffice])).resolve(selection("deck.pptx"), category: .convert)
        #expect(pptx.ids.starts(with: ["convert.pdf", "convert.jpeg", "convert.png"]))
        let key = CapabilityResolver(availability: EngineAvailability(available: [.keynote]))
        let k = key.resolve(selection("deck.key"), category: .convert)
        #expect(k.ids.contains("convert.pptx"))
        #expect(key.engine(for: k.available[0], item: item("deck.key")) == .keynote)
    }

    @Test func subtitleRoutes() {
        #expect(native.resolve(selection("a.srt"), category: .convert).ids == ["convert.vtt", "convert.txt"])
        #expect(native.resolve(selection("a.vtt"), category: .convert).ids == ["convert.srt", "convert.txt"])
    }

    @Test func toolsDependOnKindAndCount() {
        let one = all.resolve(selection("p.jpg"), category: .tools)
        #expect(one.ids.contains("tool.crop") && one.ids.contains("tool.annotate") && one.ids.contains("tool.readQR"))
        #expect(one.unavailableIDs.contains("tool.collage"))   // needs 2+
        let many = all.resolve(selection("p.jpg", "q.png"), category: .tools)
        #expect(many.ids.contains("tool.collage") && many.ids.contains("tool.imagesToPDF"))
        #expect(many.unavailableIDs.contains("tool.annotate"))   // one at a time
        #expect(many.unavailable.first { $0.descriptor.id == "tool.annotate" }?.reason == "Works on one file at a time.")
    }

    @Test func mergeAndJoinRules() {
        #expect(all.resolve(selection("a.pdf", "b.pdf"), category: .tools).ids.contains("tool.merge"))
        #expect(all.resolve(selection("a.pdf"), category: .tools).unavailableIDs.contains("tool.merge"))
        #expect(all.resolve(selection("a.mp4", "b.mov"), category: .tools).ids.contains("tool.join"))
        #expect(all.resolve(selection("a.mp3", "b.wav"), category: .tools).ids.contains("tool.join"))
        // Mixed media kinds share no join.
        let mixed = all.resolve(selection("a.mp4", "b.mp3"), category: .tools)
        #expect(!mixed.ids.contains("tool.join"))
        #expect(mixed.ids.contains("tool.rename") && mixed.ids.contains("tool.archive"))
    }

    @Test func actionsForEverythingButITermNeedsITerm() {
        let r = native.resolve(Selection(items: [item("Folder", directory: true), item("a.png")]), category: .actions)
        #expect(r.ids == ["action.airdrop", "action.float", "action.copyTo", "action.moveTo", "action.copyPath", "action.terminal"])
        #expect(r.unavailableIDs == ["action.iterm"])
        #expect(all.resolve(selection("a.png"), category: .actions).ids.contains("action.iterm"))
    }

    @Test func emptySelectionOffersNothing() {
        for c in OperationCategory.allCases where c != .actions {
            #expect(all.resolve(Selection(items: []), category: c).isEmpty)
        }
    }

    @Test func selectionSummaryAndDedup() {
        let s = Selection(items: [item("a.png", size: 1_000_000), item("a.png"), item("b.png", size: 500_000)])
        #expect(s.count == 2)
        #expect(s.summary.hasPrefix("2 Images"))
        #expect(Selection(items: [item("a.png"), item("b.pdf")]).summary.hasPrefix("2 items"))
        #expect(Selection(items: [item("F", directory: true)]).summary == "Folder")
    }

    @Test func routeCountIsBroad() {
        // Rough breadth check across all known sources with every engine available.
        var routes = 0
        for f in FileFormat.allCases {
            routes += all.resolve(Selection(items: [item("x.\(f.extensions[0])")]), category: .convert).available.count
        }
        #expect(routes >= 250, "only \(routes) routes")
    }
}
