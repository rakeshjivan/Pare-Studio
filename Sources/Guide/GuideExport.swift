// Export — HTML, Markdown, PDF, Word (.docx) and a shareable .pareguide file.
// Everything is made on your Mac; nothing is uploaded.

import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case docx = "Word (.docx)"
    case html = "Web page (.html)"
    case interactive = "Interactive demo (.html)"
    case markdown = "Markdown"
    case tutorial = "Tutorial video (.mp4)"
    case camtasia = "Camtasia project (to edit)"
    case mp4 = "Simple slideshow video (.mp4)"
    case gif = "GIF"
    case bundle = "Pare Guide file (to share)"
    var id: String { rawValue }
    var ext: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .html, .interactive: return "html"
        case .markdown: return "md"
        case .mp4, .tutorial: return "mp4"
        case .camtasia: return "cmproj"
        case .gif: return "gif"
        case .bundle: return "pareguide"
        }
    }
}

struct ExportItem {
    let number: Int
    let text: String
    let image: CGImage?
    var png: Data? { image.flatMap(Renderer.png) }
}

enum Exporter {
    /// Renders every step's picture (in the background).
    static func prepare(_ guide: Guide, store: GuideStore, maxWidth: Int) async -> [ExportItem] {
        let jobs: [(Int, Step, URL?)] = await MainActor.run {
            guide.steps.enumerated().map { (i, s) in (i + 1, s, s.image.map { store.imageURL(guide.id, $0) }) }
        }
        let zoom = guide.zoom
        return await Task.detached(priority: .userInitiated) {
            jobs.map { (n, s, url) in
                let img = url.flatMap(GuideStore.loadImage).flatMap { Renderer.render(s, base: $0, zoom: zoom, maxWidth: maxWidth) }
                return ExportItem(number: n, text: s.text, image: img)
            }
        }.value
    }

    static func run(_ format: ExportFormat, guide: Guide, to url: URL, narrate: Bool = false,
                    progress: @escaping (String) -> Void) async throws {
        let store = await MainActor.run { GuideStore.shared }
        switch format {
        case .bundle:
            let folder = await MainActor.run { store.folder(guide.id) }
            try bundle(folder: folder, to: url)
            return
        case .tutorial:
            try await TutorialVideo.make(guide: guide, to: url, progress: progress)
            return
        case .camtasia:
            try await CamtasiaExport.make(guide: guide, to: url, progress: progress)
            return
        case .mp4:
            progress("Rendering steps…")
            let items = await prepare(guide, store: store, maxWidth: 1920)
            try await VideoMaker.mp4(guide: guide, items: items, narrate: narrate, to: url, progress: progress)
            return
        case .interactive:
            progress("Rendering steps…")
            let slides = await prepareInteractive(guide, store: store)
            progress("Writing the interactive demo…")
            try await Task.detached(priority: .userInitiated) {
                try interactiveHTML(guide, slides).write(to: url, atomically: true, encoding: .utf8)
            }.value
            return
        case .gif:
            progress("Rendering steps…")
            let items = await prepare(guide, store: store, maxWidth: 1600)
            try VideoMaker.gif(guide: guide, items: items, to: url)
            return
        default: break
        }
        progress("Rendering steps…")
        let items = await prepare(guide, store: store, maxWidth: 1600)
        progress("Writing \(format.rawValue)…")
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .html: try html(guide, items).write(to: url, atomically: true, encoding: .utf8)
            case .markdown: try markdown(guide, items, to: url)
            case .pdf: try pdf(guide, items, to: url)
            case .docx: try docx(guide, items, to: url)
            default: break
            }
        }.value
    }

    // MARK: Interactive demo (one offline .html file)

    struct Slide {
        let number: Int
        let text: String
        let jpeg: Data?
        /// Where to click, as fractions of the picture (x, y, width, height).
        let hotspot: CGRect?
    }

    static func prepareInteractive(_ guide: Guide, store: GuideStore) async -> [Slide] {
        let jobs: [(Int, Step, URL?)] = await MainActor.run {
            guide.steps.enumerated().map { (i, s) in (i + 1, s, s.image.map { store.imageURL(guide.id, $0) }) }
        }
        let zoom = guide.zoom
        return await Task.detached(priority: .userInitiated) {
            jobs.map { (n, s, url) -> Slide in
                guard let base = url.flatMap(GuideStore.loadImage) else {
                    return Slide(number: n, text: s.text, jpeg: nil, hotspot: nil)
                }
                // The demo draws its own pulsing hotspot, so leave the static box off the picture.
                var clean = s
                clean.showHighlight = false
                let img = Renderer.render(clean, base: base, zoom: zoom, maxWidth: 1600)
                let frame = Renderer.outputFrame(s, zoom: zoom, size: CGSize(width: base.width, height: base.height))
                var spot: CGRect?
                let clickKinds: [StepKind] = [.click, .rightClick, .doubleClick, .type]
                if clickKinds.contains(s.kind) {
                    let u = CGFloat(s.scale)
                    let target = s.highlight ?? s.clickPoint.map { CGRect(x: $0.x - 22 * u, y: $0.y - 22 * u, width: 44 * u, height: 44 * u) }
                    if let t = target?.insetBy(dx: -6 * u, dy: -6 * u).intersection(frame), !t.isNull, t.width > 2 {
                        spot = CGRect(x: (t.minX - frame.minX) / frame.width, y: (t.minY - frame.minY) / frame.height,
                                      width: t.width / frame.width, height: t.height / frame.height)
                    }
                }
                return Slide(number: n, text: s.text, jpeg: img.flatMap { Renderer.jpeg($0, quality: 0.86) }, hotspot: spot)
            }
        }.value
    }

    static func interactiveHTML(_ g: Guide, _ slides: [Slide]) -> String {
        func r4(_ v: CGFloat) -> String { String(format: "%.4f", Double(v)) }
        let data: [String] = slides.map { sl in
            let img = sl.jpeg.map { "\"data:image/jpeg;base64,\($0.base64EncodedString())\"" } ?? "null"
            let hs = sl.hotspot.map { "[\(r4($0.minX)),\(r4($0.minY)),\(r4($0.width)),\(r4($0.height))]" } ?? "null"
            let text = jsString(htmlInline(sl.text).replacingOccurrences(of: "\n", with: "<br>"))
            return "{\"n\":\(sl.number),\"t\":\(text),\"img\":\(img),\"hs\":\(hs)}"
        }
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(g.title))</title>
        <style>
        :root{--accent:#ff5440;--fg:#1d1d1f;--muted:#6e6e73;--bg:#f5f5f7;--card:#fff}
        @media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#111;--card:#1c1c1e}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;min-height:100vh;display:flex;flex-direction:column}
        header{display:flex;align-items:center;gap:14px;padding:12px 20px}
        header h1{font-size:16px;margin:0;font-weight:600;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .count{color:var(--muted);font-size:14px;white-space:nowrap}
        .bar{height:4px;background:rgba(127,127,127,.2)}.bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .3s}
        main{flex:1;display:flex;align-items:center;justify-content:center;padding:20px}
        .stage{position:relative;width:100%;max-width:1200px}
        .stage img{display:block;width:100%;height:auto;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,.18);user-select:none;-webkit-user-drag:none}
        .hs{position:absolute;border-radius:10px;cursor:pointer;border:3px solid var(--accent);background:rgba(255,84,64,.12)}
        .hs::after{content:"";position:absolute;inset:-3px;border-radius:12px;border:3px solid var(--accent);animation:pulse 1.6s ease-out infinite}
        @keyframes pulse{0%{opacity:.9;transform:scale(1)}100%{opacity:0;transform:scale(1.35)}}
        .hs.nudge{animation:nudge .45s}
        @keyframes nudge{0%,100%{transform:translateX(0)}25%{transform:translateX(-6px)}75%{transform:translateX(6px)}}
        .tip{position:absolute;max-width:min(380px,90%);background:var(--card);color:var(--fg);border-radius:12px;padding:12px 14px;box-shadow:0 8px 30px rgba(0,0,0,.25);font-size:15px;z-index:2}
        .tip .num{display:inline-grid;place-items:center;width:24px;height:24px;border-radius:50%;background:var(--accent);color:#fff;font-weight:700;font-size:13px;margin-right:8px;vertical-align:-5px}
        .tip .hint{display:block;color:var(--muted);font-size:13px;margin-top:6px}
        .tip button{margin-top:10px}
        .card{background:var(--card);border-radius:16px;padding:40px;max-width:640px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.12)}
        .card h2{font-size:30px;margin:0 0 10px;letter-spacing:-.02em}.card p{color:var(--muted);margin:0 0 24px;font-size:18px}
        .note{background:var(--card);border-radius:16px;padding:34px;max-width:640px;font-size:20px;box-shadow:0 10px 40px rgba(0,0,0,.12)}
        button{font:inherit;border:0;border-radius:999px;padding:9px 18px;cursor:pointer;background:rgba(127,127,127,.18);color:var(--fg)}
        button.primary{background:var(--accent);color:#fff;font-weight:600}
        button:disabled{opacity:.4;cursor:default}
        footer{display:flex;justify-content:center;gap:10px;padding:0 20px 20px}
        footer small{color:var(--muted);align-self:center;margin-left:8px}
        </style></head><body>
        <header><h1>\(esc(g.title))</h1><span class="count" id="count"></span></header>
        <div class="bar"><i id="prog"></i></div>
        <main id="main"></main>
        <footer><button id="back">← Back</button><button id="next" class="primary">Next →</button><small>Tip: use the arrow keys</small></footer>
        <script>
        const S=[\(data.joined(separator: ",\n"))];
        const TITLE=\(jsString(g.title.plain)), SUMMARY=\(jsString(g.summary.plain));
        let i=-1;
        const main=document.getElementById('main'),back=document.getElementById('back'),next=document.getElementById('next');
        function show(n){
          i=Math.max(-1,Math.min(S.length,n));
          document.getElementById('prog').style.width=(i<0?0:Math.min(1,(i+1)/S.length)*100)+'%';
          document.getElementById('count').textContent=(i>=0&&i<S.length)?('Step '+(i+1)+' of '+S.length):'';
          back.disabled=i<0; next.style.visibility=(i>=S.length)?'hidden':'visible';
          next.textContent=i<0?'Start →':(i===S.length-1?'Finish →':'Next →');
          main.innerHTML='';
          if(i<0){main.innerHTML='<div class="card"><h2></h2><p></p><button class="primary" onclick="show(0)">Start the walkthrough →</button></div>';
            main.querySelector('h2').textContent=TITLE;main.querySelector('p').textContent=SUMMARY||(S.length+' steps');return}
          if(i>=S.length){main.innerHTML='<div class="card"><h2>All done 🎉</h2><p>You’ve finished all '+S.length+' steps.</p><button class="primary" onclick="show(0)">Start again</button></div>';return}
          const s=S[i];
          if(!s.img){main.innerHTML='<div class="note"><span class="num" style="display:inline-grid;place-items:center;width:28px;height:28px;border-radius:50%;background:var(--accent);color:#fff;font-weight:700;font-size:14px;margin-right:10px">'+s.n+'</span>'+s.t+'</div>';return}
          const st=document.createElement('div');st.className='stage';
          const im=new Image();im.src=s.img;im.alt='Step '+s.n;st.appendChild(im);
          const tip=document.createElement('div');tip.className='tip';
          tip.innerHTML='<span class="num">'+s.n+'</span>'+s.t+(s.hs?'<span class="hint">Click the highlighted area to continue</span>':'<br><button class="primary">Next →</button>');
          st.appendChild(tip);
          if(s.hs){const h=document.createElement('div');h.className='hs';
            h.style.left=s.hs[0]*100+'%';h.style.top=s.hs[1]*100+'%';h.style.width=s.hs[2]*100+'%';h.style.height=s.hs[3]*100+'%';
            h.onclick=e=>{e.stopPropagation();show(i+1)};st.appendChild(h);
            im.onclick=()=>{h.classList.remove('nudge');void h.offsetWidth;h.classList.add('nudge')};}
          else{tip.querySelector('button').onclick=()=>show(i+1)}
          main.appendChild(st);
          const place=()=>{const W=st.clientWidth,H=st.clientHeight,tw=tip.offsetWidth,th=tip.offsetHeight;
            if(!s.hs){tip.style.left=(W-tw)/2+'px';tip.style.top=Math.max(8,H-th-16)+'px';return}
            const x=s.hs[0]*W,y=s.hs[1]*H,w=s.hs[2]*W,hh=s.hs[3]*H;
            let left=Math.min(Math.max(8,x+w/2-tw/2),W-tw-8),top=y+hh+14;
            if(top+th>H-8)top=y-th-14; if(top<8)top=Math.min(H-th-8,y+hh+14);
            tip.style.left=left+'px';tip.style.top=Math.max(8,top)+'px'};
          im.onload=place;if(im.complete)place();window.onresize=place;
        }
        back.onclick=()=>show(i-1);next.onclick=()=>show(i+1);
        document.onkeydown=e=>{if(e.key==='ArrowRight'||e.key==='Enter')show(i+1);if(e.key==='ArrowLeft')show(i-1)};
        show(-1);
        </script>
        </body></html>
        """
    }

    /// A JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: HTML

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// **bold** → <strong>bold</strong>
    static func htmlInline(_ s: String) -> String {
        s.boldParts.map { $0.bold ? "<strong>\(esc($0.text))</strong>" : esc($0.text) }.joined()
    }

    static func html(_ g: Guide, _ items: [ExportItem]) -> String {
        var steps = ""
        for it in items {
            var img = ""
            if let d = it.png { img = "<img src=\"data:image/png;base64,\(d.base64EncodedString())\" alt=\"Step \(it.number)\">" }
            steps += "<li class=\"step\"><div class=\"text\"><span class=\"n\">\(it.number)</span><p>\(htmlInline(it.text))</p></div>\(img)</li>\n"
        }
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(g.title))</title>
        <style>
        :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--card:#f5f5f7;--accent:#ff5440}
        @media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#111;--card:#1c1c1e}}
        body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
        main{max-width:960px;margin:0 auto;padding:48px 24px 80px}
        h1{font-size:34px;line-height:1.15;margin:0 0 8px;letter-spacing:-.02em}
        .summary{color:var(--muted);margin:0 0 8px;font-size:19px}
        .meta{color:var(--muted);font-size:14px;margin-bottom:40px}
        ol{list-style:none;padding:0;margin:0}
        .step{background:var(--card);border-radius:16px;padding:20px;margin:0 0 24px}
        .text{display:flex;gap:14px;align-items:flex-start;margin-bottom:14px}
        .text p{margin:3px 0 0}
        .n{flex:none;width:30px;height:30px;border-radius:50%;background:var(--accent);color:#fff;font-weight:600;display:grid;place-items:center;font-size:15px}
        img{display:block;width:100%;height:auto;border-radius:10px;border:1px solid rgba(127,127,127,.25)}
        footer{color:var(--muted);font-size:13px;margin-top:40px;text-align:center}
        @media print{.step{break-inside:avoid;background:none;border:1px solid #ddd}}
        </style></head><body><main>
        <h1>\(esc(g.title))</h1>
        \(g.summary.isEmpty ? "" : "<p class=\"summary\">\(htmlInline(g.summary))</p>")
        <div class="meta">\(items.count) steps</div>
        <ol>
        \(steps)</ol>
        <footer>Made with Pare Guide</footer>
        </main></body></html>
        """
    }

    // MARK: Markdown (a folder with guide.md and images/)

    static func markdown(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingPathExtension()
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        var md = "# \(g.title)\n\n"
        if !g.summary.isEmpty { md += "\(g.summary)\n\n" }
        for it in items {
            md += "## Step \(it.number)\n\n\(it.text)\n\n"
            if let d = it.png {
                let name = String(format: "step-%02d.png", it.number)
                try d.write(to: folder.appendingPathComponent("images/\(name)"))
                md += "![Step \(it.number)](images/\(name))\n\n"
            }
        }
        try md.write(to: folder.appendingPathComponent("\(safeName(g.title)).md"), atomically: true, encoding: .utf8)
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmed
        return t.isEmpty ? "Guide" : String(t.prefix(80))
    }

    // MARK: PDF (A4)

    static func attributed(_ s: String, size: CGFloat, color: NSColor = .black, bold: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for part in s.boldParts {
            let isBold = bold || part.bold
            out.append(NSAttributedString(string: part.text, attributes: [
                .font: isBold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]))
        }
        return out
    }

    static func pdf(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PGError("Couldn't create the PDF.") }
        let margin: CGFloat = 48
        let width = box.width - margin * 2
        var y: CGFloat = 0
        var pageOpen = false

        func newPage() {
            if pageOpen { NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            pageOpen = true
            y = margin
        }
        func height(_ a: NSAttributedString, _ w: CGFloat) -> CGFloat {
            ceil(a.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        func draw(_ a: NSAttributedString, x: CGFloat, w: CGFloat) {
            let h = height(a, w)
            a.draw(with: CGRect(x: x, y: y, width: w, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h
        }

        newPage()
        draw(attributed(g.title, size: 24, bold: true), x: margin, w: width)
        y += 6
        if !g.summary.isEmpty { draw(attributed(g.summary, size: 12, color: .darkGray), x: margin, w: width); y += 4 }
        y += 18

        let accent = NSColor(cgColor: Renderer.accent) ?? .systemRed
        for it in items {
            let text = attributed(it.text, size: 12.5)
            let textH = max(22, height(text, width - 34))
            var imgSize = CGSize.zero
            if let img = it.image {
                let w = min(width, CGFloat(img.width) / 2)
                imgSize = CGSize(width: w, height: w * CGFloat(img.height) / CGFloat(img.width))
                let maxH = box.height - margin * 2 - textH - 20
                if imgSize.height > maxH { imgSize = CGSize(width: imgSize.width * maxH / imgSize.height, height: maxH) }
            }
            if y + textH + 10 + imgSize.height > box.height - margin { newPage() }

            // Number badge
            let badge = CGRect(x: margin, y: y, width: 22, height: 22)
            accent.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let num = NSAttributedString(string: "\(it.number)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
            let ns = num.size()
            num.draw(at: CGPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2))
            let top = y
            y += 3
            draw(text, x: margin + 34, w: width - 34)
            y = max(y, top + 22) + 10
            if let img = it.image {
                let r = CGRect(x: margin, y: y, width: imgSize.width, height: imgSize.height)
                NSImage(cgImage: img, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                                                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor(white: 0.85, alpha: 1).setStroke()
                NSBezierPath(rect: r).stroke()
                y += imgSize.height
            }
            y += 26
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Word (.docx)

    static func xml(_ s: String) -> String { esc(s).replacingOccurrences(of: "'", with: "&apos;") }

    static func runs(_ s: String, size: Int = 24, bold: Bool = false) -> String {
        s.boldParts.map { part -> String in
            let p = part.text
            guard !p.isEmpty else { return "" }
            let b = bold || part.bold
            return "<w:r><w:rPr>\(b ? "<w:b/>" : "")<w:sz w:val=\"\(size)\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(p))</w:t></w:r>"
        }.joined()
    }

    static func docx(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        var body = "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>\(runs(g.title, size: 44, bold: true))</w:p>"
        if !g.summary.isEmpty { body += "<w:p><w:pPr><w:spacing w:after=\"240\"/></w:pPr>\(runs(g.summary, size: 24))</w:p>" }
        var rels = ""
        let maxEMU = 5_943_600.0   // 6.5 inches
        for it in items {
            body += "<w:p><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr>\(runs("Step \(it.number). ", bold: true))\(runs(it.text))</w:p>"
            if let img = it.image, let png = it.png {
                let rid = "rIdImg\(it.number)"
                try png.write(to: dir.appendingPathComponent("word/media/image\(it.number).png"))
                rels += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(it.number).png\"/>"
                let wPts = min(Double(img.width) / 2, 468)          // points, max 6.5"
                var cx = wPts * 12700
                var cy = cx * Double(img.height) / Double(img.width)
                if cx > maxEMU { cy *= maxEMU / cx; cx = maxEMU }
                let maxH = 7_500_000.0
                if cy > maxH { cx *= maxH / cy; cy = maxH }
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(Int(cx))" cy="\(Int(cy))"/>\
                <wp:docPr id="\(it.number)" name="Step \(it.number)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(it.number)" name="image\(it.number).png"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(Int(cx))" cy="\(Int(cy))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
                <a:ln w="6350"><a:solidFill><a:srgbClr val="D9D9D9"/></a:solidFill></a:ln></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
        try contentTypes.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try document.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try docRels.write(to: dir.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        let status = Tools.runQuick("/usr/bin/zip", ["-X", "-r", "-q", url.path, "[Content_Types].xml", "_rels", "word"], cwd: dir)
        guard status == 0 else { throw PGError("Couldn't write the Word file.") }
    }

    // MARK: .pareguide (zip of the guide folder, without old versions)

    static func bundle(folder: URL, to url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let status = Tools.runQuick("/usr/bin/zip", ["-X", "-r", "-q", url.path, "guide.json", "images"], cwd: folder)
        guard status == 0 else { throw PGError("Couldn't write the file.") }
    }
}
