import UIKit
import WebKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = WebViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }

    // Show reminders as banners even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

final class WebViewController: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private var web: WKWebView!
    private let stateKey = "kt_state"

    override func loadView() {
        let controller = WKUserContentController()
        if let saved = UserDefaults.standard.string(forKey: stateKey),
           let data = try? JSONSerialization.data(withJSONObject: [saved]),
           let arr = String(data: data, encoding: .utf8) {
            let literal = String(arr.dropFirst().dropLast()) // JSON string literal
            controller.addUserScript(WKUserScript(source: "window.__NATIVE_STATE=\(literal);",
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.047, green: 0.082, blue: 0.125, alpha: 1)
            : UIColor(red: 0.933, green: 0.953, blue: 0.969, alpha: 1) }
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // Open outside links in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme == "https", action.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        switch type {
        case "save":
            if let s = body["payload"] as? String { UserDefaults.standard.set(s, forKey: stateKey) }
            replyHandler(true, nil)
        case "schedule":
            schedule(body["payload"] as? [[String: Any]] ?? [])
            replyHandler(true, nil)
        case "gemini":
            gemini(body["payload"] as? [String: Any] ?? [:], replyHandler)
        default:
            replyHandler(nil, "unknown")
        }
    }

    /// Replaces all pending reminders (iOS keeps at most 64).
    private func schedule(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for item in items.prefix(64) {
            guard let atNum = item["at"] as? NSNumber, let title = item["title"] as? String else { continue }
            let date = Date(timeIntervalSince1970: atNum.doubleValue / 1000)
            if date <= now { continue }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = item["body"] as? String ?? ""
            content.sound = .default
            if #available(iOS 15.0, *) { content.interruptionLevel = .active }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = item["id"] as? String ?? UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    private func gemini(_ p: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        let key = p["key"] as? String ?? ""
        var model = p["model"] as? String ?? ""
        if model.isEmpty { model = "gemini-flash-latest" }
        let prompt = p["prompt"] as? String ?? ""
        guard !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            reply(nil, "Gemini kaliti kiritilmagan"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let payload: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.4]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { reply(nil, "Internet yo‘q yoki Gemini javob bermadi: \(err.localizedDescription)"); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data else { reply(nil, "Bo‘sh javob"); return }
                if code != 200 {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    reply(nil, "Gemini xatosi \(code): \(text.prefix(300))"); return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cands = obj["candidates"] as? [[String: Any]],
                      let content = cands.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let text = parts.first?["text"] as? String else {
                    reply(nil, "Gemini javobini o‘qib bo‘lmadi"); return
                }
                reply(text, nil)
            }
        }.resume()
    }
}
