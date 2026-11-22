import SwiftUI
import WebKit

// Single-file SwiftUI app. Add to a new iOS App project (iOS 16+), replace the generated App file.
// For sideloading with extra memory, add the entitlement
// com.apple.developer.kernel.increased-memory-limit (affects the app process only).

@main
struct GameBrowserApp: App {
    var body: some Scene { WindowGroup { ContentView().ignoresSafeArea(.keyboard) } }
}

final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var urlText = ""
    @Published var crashCount = 0
    @Published var showSettings = false
    @AppStorage("desktopMode") var desktopMode = true
    @AppStorage("jitHint") var jitHint = false      // placeholder: JIT can't affect WebContent
    @AppStorage("moreRamHint") var moreRamHint = false // placeholder: needs entitlement at signing

    private(set) var lastURL: URL?
    private(set) lazy var webView: WKWebView = makeWebView()

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default() // persistent: saves survive relaunch
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences.preferredContentMode = desktopMode ? .desktop : .mobile

        let js = """
        (function(){
          try { navigator.storage && navigator.storage.persist && navigator.storage.persist(); } catch(e){}
          // Unlock WebAudio on first touch
          var unlock = function(){
            var C = window.AudioContext || window.webkitAudioContext;
            if (!C) return;
            try { var c = new C(); c.resume(); } catch(e){}
            window.removeEventListener('touchend', unlock, true);
          };
          window.addEventListener('touchend', unlock, true);
          // Block pinch/double-tap zoom so taps map cleanly to clicks
          var m = document.querySelector('meta[name=viewport]');
          if (!m) { m = document.createElement('meta'); m.name='viewport'; document.head && document.head.appendChild(m); }
          m && (m.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover');
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        return wv
    }

    func go() {
        var t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t) else { return }
        lastURL = url
        webView.load(URLRequest(url: url))
    }

    // Memory kill: reload instead of showing a blank page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashCount += 1
        let target = webView.url ?? lastURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let target { webView.load(URLRequest(url: target)) } else { webView.reload() }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url?.absoluteString { DispatchQueue.main.async { self.urlText = u } }
    }

    // Open target=_blank in the same view (single tab keeps memory free)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func clearSiteData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs) {}
        }
    }
}

struct WebContainer: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var m = BrowserModel()
    @State private var fullscreen = false

    var body: some View {
        VStack(spacing: 0) {
            if !fullscreen {
                HStack(spacing: 8) {
                    TextField("Game URL", text: $m.urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.go).onSubmit { m.go() }
                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button { m.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    Button { m.showSettings = true } label: { Image(systemName: "gearshape") }
                }.padding(8)
            }
            WebContainer(model: m)
                .overlay(alignment: .topTrailing) {
                    if fullscreen {
                        Button { fullscreen = false } label: {
                            Image(systemName: "xmark.circle.fill").font(.title).padding(8)
                        }.opacity(0.4)
                    }
                }
        }
        .sheet(isPresented: $m.showSettings) { SettingsView(m: m) }
    }
}

struct SettingsView: View {
    @ObservedObject var m: BrowserModel
    var body: some View {
        NavigationStack {
            Form {
                Section("Rendering") {
                    Toggle("Desktop mode", isOn: m.$desktopMode)
                }
                Section(footer: Text("JIT already runs inside iOS's WebContent process. These are hints only; extra memory needs the entitlement when signing.")) {
                    Toggle("JIT (optional)", isOn: m.$jitHint)
                    Toggle("More RAM (optional)", isOn: m.$moreRamHint)
                }
                Section("Stats") { Text("Page crashes recovered: \(m.crashCount)") }
                Section { Button("Clear all site data", role: .destructive) { m.clearSiteData() } }
            }
            .navigationTitle("Settings")
        }
    }
}
