import Foundation
import DropForgeCore

/// EPUB 3 writer (with an EPUB 2 NCX for older readers).
public enum EPUBWriter {
    public static func make(title: String, author: String? = nil, chapters: [(title: String, paragraphs: [RichParagraph])],
                            identifier: String = "urn:uuid:\(UUID().uuidString)", date: Date = Date()) -> Data {
        var zip = ZipWriter(date: date)
        zip.add("mimetype", text: "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        let css = "body{font-family:serif;line-height:1.45;margin:0 5%}h1,h2,h3{font-family:sans-serif;line-height:1.2}pre{white-space:pre-wrap}"
        zip.add("OEBPS/style.css", text: css)
        var manifest = ""
        var spine = ""
        var navItems = ""
        var ncxPoints = ""
        for (i, chapter) in chapters.enumerated() {
            let file = String(format: "chapter%03d.xhtml", i + 1)
            let xhtml = RichXHTML.page(title: chapter.title, body: RichXHTML.body(chapter.paragraphs), stylesheet: "style.css")
            zip.add("OEBPS/\(file)", text: xhtml)
            manifest += "<item id=\"c\(i + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            navItems += "<li><a href=\"\(file)\">\(RichXHTML.escape(chapter.title))</a></li>\n"
            ncxPoints += """
            <navPoint id="n\(i + 1)" playOrder="\(i + 1)"><navLabel><text>\(RichXHTML.escape(chapter.title))</text></navLabel><content src="\(file)"/></navPoint>

            """
        }
        let nav = RichXHTML.page(title: "Contents", body: "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\(navItems)</ol></nav>")
        zip.add("OEBPS/nav.xhtml", text: nav)
        zip.add("OEBPS/toc.ncx", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(identifier)"/></head>
        <docTitle><text>\(RichXHTML.escape(title))</text></docTitle>
        <navMap>\(ncxPoints)</navMap>
        </ncx>
        """)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        zip.add("OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(identifier)</dc:identifier>
            <dc:title>\(RichXHTML.escape(title))</dc:title>
            <dc:language>en</dc:language>
            \(author.map { "<dc:creator>\(RichXHTML.escape($0))</dc:creator>" } ?? "")
            <meta property="dcterms:modified">\(iso.string(from: date).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest)
          </manifest>
          <spine toc="ncx">
            \(spine)
          </spine>
        </package>
        """)
        return zip.finalize()
    }
}

/// Reads the reading order of an extracted EPUB.
public enum EPUBReader {
    /// Returns spine documents in order, given the folder an EPUB was extracted into.
    public static func spine(in root: URL) throws -> [URL] {
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        let container = try XMLDocument(contentsOf: containerURL, options: [])
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw ValidationError("This EPUB has no package file.")
        }
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try XMLDocument(contentsOf: opfURL, options: [])
        var manifest: [String: String] = [:]
        for node in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let el = node as? XMLElement, let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = href
        }
        let base = opfURL.deletingLastPathComponent()
        let refs = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref").compactMap(\.stringValue)
        let urls = refs.compactMap { manifest[$0] }.map { base.appendingPathComponent($0.removingPercentEncoding ?? $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { throw ValidationError("This EPUB has no readable chapters.") }
        return urls
    }
}

/// Minimal PresentationML writer: one full-bleed picture per slide (used for PDF → PPTX).
public enum PPTXWriter {
    static let emuPerInch = 914_400

    public static func make(slides: [Data], imageExtension: String = "png", aspect: Double) -> Data {
        let cx = 12_192_000
        let cy = Int((Double(cx) / max(aspect, 0.1)).rounded())
        var zip = ZipWriter()
        let mime = imageExtension == "png" ? "image/png" : "image/jpeg"
        var overrides = ""
        for i in 1...max(slides.count, 1) where i <= slides.count {
            overrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        zip.add("[Content_Types].xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="\(imageExtension)" ContentType="\(mime)"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        \(overrides)
        </Types>
        """)
        zip.add("_rels/.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """)
        zip.add("docProps/core.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Slides</dc:title></cp:coreProperties>
        """)
        zip.add("docProps/app.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>DropForge</Application><Slides>\(slides.count)</Slides></Properties>
        """)
        var slideIds = "", presRels = ""
        for i in 1...max(slides.count, 1) where i <= slides.count {
            slideIds += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 1)\"/>"
            presRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        zip.add("ppt/presentation.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(ns)>
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(slideIds)</p:sldIdLst>
        <p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """)
        zip.add("ppt/_rels/presentation.xml.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        \(presRels)
        <Relationship Id="rId\(slides.count + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        </Relationships>
        """)
        let emptyTree = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
        zip.add("ppt/slideMasters/slideMaster1.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(ns)>\(emptyTree)
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """)
        zip.add("ppt/slideLayouts/slideLayout1.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(ns) type="blank">\(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """)
        zip.add("ppt/theme/theme1.xml", text: theme)
        for (i, image) in slides.enumerated() {
            let n = i + 1
            zip.add("ppt/media/image\(n).\(imageExtension)", data: image, store: true)
            zip.add("ppt/slides/slide\(n).xml", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(ns)><p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
            </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(n).\(imageExtension)"/>
            </Relationships>
            """)
        }
        return zip.finalize()
    }

    static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="DropForge">
    <a:themeElements>
    <a:clrScheme name="DropForge">
    <a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
    <a:dk2><a:srgbClr val="1F2A37"/></a:dk2><a:lt2><a:srgbClr val="EEF2F5"/></a:lt2>
    <a:accent1><a:srgbClr val="0F7C86"/></a:accent1><a:accent2><a:srgbClr val="4F5BD5"/></a:accent2>
    <a:accent3><a:srgbClr val="2E9E6A"/></a:accent3><a:accent4><a:srgbClr val="8A5CC7"/></a:accent4>
    <a:accent5><a:srgbClr val="3B82C4"/></a:accent5><a:accent6><a:srgbClr val="6B7280"/></a:accent6>
    <a:hlink><a:srgbClr val="0F7C86"/></a:hlink><a:folHlink><a:srgbClr val="4F5BD5"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="DropForge"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="DropForge">
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme>
    </a:themeElements>
    </a:theme>
    """
}
