import SwiftUI
import UIKit
import WebKit

// MARK: - App entry

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = DownloadManager.shared   // reconnect to any downloads still running in the background
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.bgCompletion = completionHandler
    }
}

@main
struct GameBrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - Injected scripts

// Fullscreen polyfill: iPhone has no Fullscreen API for game canvases, so we fake it.
// The element (and any iframes around it, e.g. itch.io embeds) is stretched over the viewport,
// and the app hides all of its own chrome.
private let fullscreenJS = """
(function(){
  if (window.__kitsuFS) return;
  window.__kitsuFS = true;
  var cur = null, expanded = [], inFrame = (window.parent !== window);
  var FILL = 'position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;height:100dvh!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;border:0!important;transform:none!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important;';
  function post(m){ try { window.webkit.messageHandlers.kitsu.postMessage(m); } catch(e){} }
  function up(t){ if (inFrame) { try { window.parent.postMessage({__kitsu:t}, '*'); } catch(e){} } }
  function down(t){
    var fs = document.querySelectorAll('iframe');
    for (var i = 0; i < fs.length; i++) { try { fs[i].contentWindow.postMessage({__kitsu:t}, '*'); } catch(e){} }
  }
  function fire(el){
    ['fullscreenchange','webkitfullscreenchange'].forEach(function(n){
      document.dispatchEvent(new Event(n, {bubbles:true}));
      if (el) el.dispatchEvent(new Event(n, {bubbles:true}));
    });
    window.dispatchEvent(new Event('resize'));
  }
  function expandEl(el){
    expanded.push({el: el, css: el.getAttribute('style')});
    el.style.cssText = (el.getAttribute('style') || '') + ';' + FILL;
  }
  function restoreAll(){
    expanded.forEach(function(s){
      if (s.css === null) s.el.removeAttribute('style'); else s.el.setAttribute('style', s.css);
    });
    expanded = [];
  }
  function enter(){
    var el = this;
    if (cur === el) return Promise.resolve();
    if (cur) restoreAll();
    cur = el;
    expandEl(el);
    up('expand');
    post('enter');
    setTimeout(function(){ fire(el); }, 50);
    return Promise.resolve();
  }
  function exitAll(){
    var el = cur;
    cur = null;
    restoreAll();
    down('exit');
    up('collapse');
    setTimeout(function(){ fire(el); }, 50);
  }
  function exitFS(){ exitAll(); post('exit'); return Promise.resolve(); }
  function def(o, n, v){ try { Object.defineProperty(o, n, {value: v, configurable: true, writable: true}); } catch(e){} }
  function get(o, n, g){ try { Object.defineProperty(o, n, {get: g, configurable: true}); } catch(e){} }
  var E = Element.prototype, D = Document.prototype;
  def(E, 'requestFullscreen', enter);
  def(E, 'webkitRequestFullscreen', enter);
  def(E, 'webkitRequestFullScreen', enter);
  def(D, 'exitFullscreen', exitFS);
  def(D, 'webkitExitFullscreen', exitFS);
  def(D, 'webkitCancelFullScreen', exitFS);
  get(D, 'fullscreenElement', function(){ return cur; });
  get(D, 'webkitFullscreenElement', function(){ return cur; });
  get(D, 'webkitCurrentFullScreenElement', function(){ return cur; });
  get(D, 'webkitIsFullScreen', function(){ return !!cur; });
  get(D, 'fullscreenEnabled', function(){ return true; });
  get(D, 'webkitFullscreenEnabled', function(){ return true; });
  window.addEventListener('message', function(e){
    var d = e.data;
    if (!d || !d.__kitsu) return;
    if (d.__kitsu === 'expand') {
      var fs = document.querySelectorAll('iframe');
      for (var i = 0; i < fs.length; i++) { if (fs[i].contentWindow === e.source) { expandEl(fs[i]); break; } }
      up('expand');
    } else if (d.__kitsu === 'collapse') {
      restoreAll();
      up('collapse');
    } else if (d.__kitsu === 'exit') {
      exitAll();
    }
  });
  window.__kitsuExit = exitAll;
})();
"""

private let pageJS = """
(function(){
  try { navigator.storage && navigator.storage.persist && navigator.storage.persist(); } catch(e){}
  var unlock = function(){
    var C = window.AudioContext || window.webkitAudioContext;
    if (!C) return;
    try { var c = new C(); c.resume(); } catch(e){}
    window.removeEventListener('touchend', unlock, true);
  };
  window.addEventListener('touchend', unlock, true);
  try {
    var st = document.createElement('style');
    st.textContent = 'html,body{overscroll-behavior:none;-webkit-tap-highlight-color:transparent}canvas{touch-action:none;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}';
    (document.head || document.documentElement).appendChild(st);
  } catch(e){}
  if (window.parent === window) {
    var m = document.querySelector('meta[name=viewport]');
    if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head && document.head.appendChild(m); }
    m && (m.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover');
  }
})();
"""

// MARK: - Model

enum Sheet: String, Identifiable {
    case settings, downloads, bookmarks
    var id: String { rawValue }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate,
                          WKScriptMessageHandler, WKDownloadDelegate {
    @Published var urlText = ""
    @Published var crashCount = 0
    @Published var crashLoop = false
    @Published var sheet: Sheet?
    @Published var fullscreen = false {
        didSet {
            applyOrientation()
            UIApplication.shared.isIdleTimerDisabled = fullscreen      // keep the screen on while playing
            webView.allowsBackForwardNavigationGestures = !fullscreen  // no accidental back-swipes in games
        }
    }

    @AppStorage("desktopMode") var desktopMode = false
    @AppStorage("lockLandscape") var lockLandscape = true
    @AppStorage("blockAds") var blockAds = true
    @AppStorage("blockPopups") var blockPopups = true
    @AppStorage("autoDownloads") var autoDownloads = true
    @AppStorage("bookmarks") private var bookmarksRaw = "[]"

    private(set) var lastURL: URL?
    private(set) var adList: WKContentRuleList?
    private var crashTimes: [Date] = []
    private(set) lazy var webView: WKWebView = makeWebView()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            // Free whatever we can so iOS is less likely to kill the game page.
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache],
                                                    modifiedSince: Date.distantPast) {}
        }
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = false // our polyfill handles it
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let ucc = cfg.userContentController
        ucc.add(self, name: "kitsu")
        ucc.addUserScript(WKUserScript(source: fullscreenJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: pageJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "kitsu-ads", encodedContentRuleList: Self.adRulesJSON()) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self = self, let list = list else { return }
                self.adList = list
                if self.blockAds { ucc.add(list) }
            }
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        return wv
    }

    func applyAdBlock() {
        guard let list = adList else { return }
        let ucc = webView.configuration.userContentController
        ucc.remove(list)
        if blockAds { ucc.add(list) }
    }

    private static func adRulesJSON() -> String {
        let domains = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
                       "adnxs.com", "taboola.com", "outbrain.com", "popads.net", "popcash.net", "propellerads.com",
                       "exoclick.com", "adsterra.com", "juicyads.com", "trafficjunky.net", "onclickads.net",
                       "clickadu.com", "hilltopads.net", "adcash.com", "mgid.com", "revcontent.com"]
        let rules: [[String: Any]] = domains.map { d -> [String: Any] in
            ["trigger": ["url-filter": NSRegularExpression.escapedPattern(for: d)],
             "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: Fullscreen

    func enterFullscreen() { fullscreen = true }

    func exitFullscreen() {
        fullscreen = false
        webView.evaluateJavaScript("window.__kitsuExit && window.__kitsuExit()", completionHandler: nil)
    }

    private func applyOrientation() {
        guard lockLandscape else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = fullscreen ? .landscape : .all
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        DispatchQueue.main.async {
            if s == "enter" { self.fullscreen = true }
            else if s == "exit" { self.fullscreen = false }
        }
    }

    // MARK: Navigation

    func go() {
        var t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.contains("://") {
            if t.contains(" ") || !t.contains(".") {
                t = "https://duckduckgo.com/?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
            } else {
                t = "https://" + t
            }
        }
        guard let url = URL(string: t) else { return }
        lastURL = url
        webView.load(URLRequest(url: url))
    }

    func open(_ s: String) {
        urlText = s
        go()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        if navigationAction.shouldPerformDownload {   // <a download> links
            if autoDownloads, let u = navigationAction.request.url,
               u.scheme == "http" || u.scheme == "https" {
                decisionHandler(.cancel, preferences)
                startDownload(u)
            } else {
                decisionHandler(.download, preferences)   // blob:/data: links are saved by WebKit itself
            }
            return
        }
        decisionHandler(.allow, preferences)
    }

    // Files the page wants to download (attachments, zips, apks, anything it can't display) go to the download manager.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard autoDownloads, let url = navigationResponse.response.url,
              url.scheme == "http" || url.scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        var isFile = !navigationResponse.canShowMIMEType
        if let http = navigationResponse.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().hasPrefix("attachment") {
            isFile = true
        }
        if isFile {
            decisionHandler(.cancel)
            startDownload(url)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(DownloadManager.uniqueURL(for: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        DownloadManager.shared.toast("Saved to Files › Kitsu › Downloads")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadManager.shared.toast("Download failed: \(error.localizedDescription)")
    }

    /// Hands a URL to the parallel download manager, reusing the page's cookies so logged-in downloads work.
    func startDownload(_ url: URL) {
        let referer = webView.url?.absoluteString
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = url.host ?? ""
            let match = cookies.filter { c in
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return host == d || host.hasSuffix("." + d)
            }
            let header = HTTPCookie.requestHeaderFields(with: match)["Cookie"]
            DownloadManager.shared.add(url: url, referer: referer, cookie: header)
        }
    }

    // MARK: Crash handling

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashCount += 1
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 90 } + [now]
        if crashTimes.count >= 3 {
            // Crash loop: stop reloading and let the person decide.
            crashLoop = true
            fullscreen = false
            return
        }
        let target = webView.url ?? lastURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let target { webView.load(URLRequest(url: target)) } else { webView.reload() }
        }
    }

    func retryAfterCrash() {
        crashLoop = false
        crashTimes = []
        if let u = webView.url ?? lastURL { webView.load(URLRequest(url: u)) }
    }

    func closeAfterCrash() {
        crashLoop = false
        crashTimes = []
        urlText = ""
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        DispatchQueue.main.async {
            if let u = webView.url {
                if u.scheme == "http" || u.scheme == "https" { self.lastURL = u; self.urlText = u.absoluteString }
            }
            if self.fullscreen { self.fullscreen = false }
        }
    }

    // New-window requests: genuine link taps open in this tab; script-opened popups are blocked (optional).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            if !blockPopups || navigationAction.navigationType == .linkActivated {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    // MARK: Bookmarks

    var bookmarks: [Bookmark] {
        get { (try? JSONDecoder().decode([Bookmark].self, from: Data(bookmarksRaw.utf8))) ?? [] }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            bookmarksRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    func addBookmark() {
        guard let u = webView.url, u.scheme == "http" || u.scheme == "https" else { return }
        var b = bookmarks
        if b.contains(where: { $0.url == u.absoluteString }) {
            DownloadManager.shared.toast("Already bookmarked")
            return
        }
        let title = (webView.title?.isEmpty == false) ? webView.title! : (u.host ?? u.absoluteString)
        b.append(Bookmark(title: title, url: u.absoluteString))
        bookmarks = b
        DownloadManager.shared.toast("Bookmarked")
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

// MARK: - Views

struct ContentView: View {
    @StateObject private var m = BrowserModel()
    @ObservedObject private var dl = DownloadManager.shared

    private var activeDownloads: Int { dl.rows.filter { $0.status == "downloading" }.count }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            (m.fullscreen ? Color.black : Color(.systemBackground)).ignoresSafeArea()
            VStack(spacing: 0) {
                if !m.fullscreen { toolbar }
                WebContainer(model: m)
            }
            if m.fullscreen {
                Button { m.exitFullscreen() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title).foregroundColor(.white).padding(12)
                }
                .opacity(0.35)
                .padding(.top, 8)
                .padding(.trailing, 40)
            }
            if m.crashLoop { crashOverlay }
        }
        .overlay(alignment: .bottom) {
            if let msg = dl.lastMessage {
                Text(msg)
                    .font(.footnote).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: m.fullscreen ? .all : [])
        .statusBarHidden(m.fullscreen)
        .persistentSystemOverlays(m.fullscreen ? .hidden : .automatic)
        .sheet(item: $m.sheet) { s in
            switch s {
            case .settings: SettingsView(m: m)
            case .downloads: DownloadsView(m: m)
            case .bookmarks: BookmarksView(m: m)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search or enter URL", text: $m.urlText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).submitLabel(.go).onSubmit { m.go() }
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button { m.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
            Button { m.enterFullscreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            Button { m.sheet = .downloads } label: {
                Image(systemName: "arrow.down.circle")
                    .overlay(alignment: .topTrailing) {
                        if activeDownloads > 0 {
                            Text("\(activeDownloads)")
                                .font(.caption2).foregroundColor(.white)
                                .padding(3).background(Color.red, in: Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            Menu {
                Button { m.sheet = .bookmarks } label: { Label("Bookmarks", systemImage: "book") }
                Button { m.addBookmark() } label: { Label("Bookmark this page", systemImage: "star") }
                Button { m.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .padding(8)
        .background(Color(.systemBackground))
    }

    private var crashOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.yellow)
            Text("This game keeps crashing").font(.headline).foregroundColor(.white)
            Text("iOS is closing the page because it uses too much memory. Close other apps, turn off Desktop mode in Settings, then try again.")
                .font(.footnote).foregroundColor(Color.white.opacity(0.85))
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            HStack(spacing: 16) {
                Button("Retry") { m.retryAfterCrash() }.buttonStyle(.borderedProminent)
                Button("Close page") { m.closeAfterCrash() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.88).ignoresSafeArea())
    }
}

struct BookmarksView: View {
    @ObservedObject var m: BrowserModel
    var body: some View {
        NavigationStack {
            List {
                if m.bookmarks.isEmpty {
                    Text("No bookmarks yet. Use the ••• menu › Bookmark this page.").foregroundColor(.secondary)
                }
                ForEach(m.bookmarks) { b in
                    Button { m.sheet = nil; m.open(b.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).lineLimit(1)
                            Text(b.url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { offsets in
                    var b = m.bookmarks
                    b.remove(atOffsets: offsets)
                    m.bookmarks = b
                }
            }
            .navigationTitle("Bookmarks")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: BrowserModel
    @AppStorage("dlConnections") private var conns = 16

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Rendering"),
                        footer: Text("Desktop mode makes games render a bigger canvas, which is slower. Leave it off unless a game needs it, then reload the page.")) {
                    Toggle("Desktop mode", isOn: m.$desktopMode)
                }
                Section(footer: Text("Rotates to landscape when a game goes fullscreen.")) {
                    Toggle("Lock landscape in fullscreen", isOn: m.$lockLandscape)
                }
                Section(header: Text("Browsing"),
                        footer: Text("Blocking ads and script popups uses less memory and stops ads from hijacking a game page.")) {
                    Toggle("Block ads and trackers", isOn: m.$blockAds)
                    Toggle("Block script popups", isOn: m.$blockPopups)
                    Toggle("Send file downloads to Kitsu", isOn: m.$autoDownloads)
                }
                Section(header: Text("Downloads"),
                        footer: Text("More connections can be faster on servers that limit each connection. Restart the app to apply a change.")) {
                    Stepper("Connections per download: \(conns)", value: $conns, in: 4...32)
                }
                Section("Stats") { Text("Page crashes recovered: \(m.crashCount)") }
                Section { Button("Clear all site data", role: .destructive) { m.clearSiteData() } }
            }
            .navigationTitle("Settings")
            .onChange(of: m.blockAds) { _ in m.applyAdBlock() }
        }
    }
}
