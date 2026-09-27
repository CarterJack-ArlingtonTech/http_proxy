import Foundation
import Alamofire
import WebKit

/// Core browser engine that uses Alamofire for network requests and macOS WebKit for rendering
class BrowserEngine: NSObject, WKNavigationDelegate, WKUIDelegate {
    
    // MARK: - Properties
    
    private let networkManager: NetworkManager
    private let jsExecutor: JavaScriptExecutor
    private let cookieManager: HTTPCookieStorage
    private var webView: WKWebView?
    private var navigationDelegate: BrowserNavigationDelegate?
    
    weak var delegate: BrowserEngineDelegate?
    
    private var pendingRequests: [String: URLSessionDataTask] = [:]
    private let requestQueue = DispatchQueue(label: "com.alamofire.browser.requests", attributes: .concurrent)
    
    // MARK: - Initialization
    
    override init() {
        self.networkManager = NetworkManager()
        self.jsExecutor = JavaScriptExecutor()
        self.cookieManager = HTTPCookieStorage.shared
        super.init()
        setupWebView()
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        
        // Enable JavaScript execution
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        
        // Configure user agent to bypass restrictions
        configuration.applicationNameForUserAgent = "AlamofireBrowser/1.0"
        
        // Setup message handlers for JS communication
        configuration.userContentController.add(self, name: "alamofireAPI")
        
        // Create web view
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        
        // Setup custom URL scheme handling
        self.navigationDelegate = BrowserNavigationDelegate(networkManager: networkManager)
        webView.navigationDelegate = self.navigationDelegate
    }
    
    // MARK: - Navigation
    
    func loadURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            delegate?.browserEngine(self, didFailWithError: BrowserError.invalidURL)
            return
        }
        
        loadURL(url)
    }
    
    func loadURL(_ url: URL) {
        delegate?.browserEngineDidStartLoad(self)
        
        networkManager.fetchContent(from: url) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let (html, response)):
                    self?.loadHTML(html, baseURL: url, response: response)
                case .failure(let error):
                    self?.delegate?.browserEngine(self!, didFailWithError: error)
                }
            }
        }
    }
    
    func loadHTML(_ html: String, baseURL: URL?, response: HTTPURLResponse? = nil) {
        guard let webView = webView else { return }
        
        // Inject Alamofire bridge for custom network handling
        let injectedHTML = injectAlaofireBridge(into: html, baseURL: baseURL)
        
        webView.loadHTMLString(injectedHTML, baseURL: baseURL)
    }
    
    // MARK: - JavaScript Execution
    
    func executeJavaScript(_ script: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        guard let webView = webView else {
            completion(.failure(BrowserError.webViewNotAvailable))
            return
        }
        
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(result))
            }
        }
    }
    
    func executeAsyncJavaScript(_ script: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        let wrappedScript = """
        (async function() {
            \(script)
        })()
        """
        
        executeJavaScript(wrappedScript, completion: completion)
    }
    
    // MARK: - Private Methods
    
    private func injectAlaofireBridge(into html: String, baseURL: URL?) -> String {
        let bridge = """
        <script>
        window.alamofireAPI = {
            fetch: async function(url, options) {
                return new Promise((resolve, reject) => {
                    webkit.messageHandlers.alamofireAPI.postMessage({
                        action: 'fetch',
                        url: url,
                        options: options
                    });
                });
            },
            
            executeScript: async function(script) {
                return new Promise((resolve, reject) => {
                    webkit.messageHandlers.alamofireAPI.postMessage({
                        action: 'executeScript',
                        script: script
                    });
                });
            },
            
            getCookies: async function() {
                return new Promise((resolve, reject) => {
                    webkit.messageHandlers.alamofireAPI.postMessage({
                        action: 'getCookies'
                    });
                });
            }
        };
        </script>
        """
        
        // Inject bridge before closing body tag
        if let bodyEndIndex = html.range(of: "</body>", options: .backwards) {
            return html.replacingCharacters(in: bodyEndIndex, with: bridge + "</body>")
        }
        
        return html + bridge
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.browserEngineDidStartLoad(self)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.browserEngineDidFinishLoad(self)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.browserEngine(self, didFailWithError: error)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Use Alamofire for custom network handling
        decisionHandler(.allow)
    }
    
    // MARK: - WKUIDelegate
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle window.open() calls
        if let url = navigationAction.request.url {
            loadURL(url)
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard let action = body["action"] as? String else { return }
        
        switch action {
        case "fetch":
            handleFetchRequest(body)
        case "executeScript":
            handleExecuteScript(body)
        case "getCookies":
            handleGetCookies()
        default:
            break
        }
    }
    
    private func handleFetchRequest(_ data: [String: Any]) {
        guard let urlString = data["url"] as? String,
              let url = URL(string: urlString) else { return }
        
        let options = data["options"] as? [String: Any] ?? [:]
        
        networkManager.fetchContent(from: url) { result in
            switch result {
            case .success(let (html, response)):
                self.executeJavaScript("""
                window.alamofireAPI._lastFetchResult = {
                    success: true,
                    data: '\(html)',
                    status: \(response.statusCode)
                };
                """)
            case .failure(let error):
                self.executeJavaScript("""
                window.alamofireAPI._lastFetchResult = {
                    success: false,
                    error: '\(error.localizedDescription)'
                };
                """)
            }
        }
    }
    
    private func handleExecuteScript(_ data: [String: Any]) {
        guard let script = data["script"] as? String else { return }
        executeJavaScript(script)
    }
    
    private func handleGetCookies() {
        let cookies = cookieManager.cookies ?? []
        let cookieData = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        
        executeJavaScript("""
        window.alamofireAPI._cookies = '\(cookieData)';
        """)
    }
}

// MARK: - Delegate Protocol

protocol BrowserEngineDelegate: AnyObject {
    func browserEngineDidStartLoad(_ engine: BrowserEngine)
    func browserEngineDidFinishLoad(_ engine: BrowserEngine)
    func browserEngine(_ engine: BrowserEngine, didFailWithError error: Error)
}

// MARK: - Error Handling

enum BrowserError: LocalizedError {
    case invalidURL
    case webViewNotAvailable
    case networkError(String)
    case javascriptExecutionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The provided URL is invalid"
        case .webViewNotAvailable:
            return "WebKit web view is not available"
        case .networkError(let message):
            return "Network error: \(message)"
        case .javascriptExecutionFailed(let message):
            return "JavaScript execution failed: \(message)"
        }
    }
}
