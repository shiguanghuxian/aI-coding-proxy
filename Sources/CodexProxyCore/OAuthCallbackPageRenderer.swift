import Foundation

public enum OAuthCallbackPageKind: String, Sendable, Equatable {
    case success
    case failure
    case cancelled
    case invalidPath
}

public enum OAuthCallbackPageLanguage: String, Sendable, Equatable {
    case zhHans
    case english

    public var htmlLanguageCode: String {
        switch self {
        case .zhHans:
            return "zh-CN"
        case .english:
            return "en"
        }
    }
}

public struct OAuthCallbackPageResponse: Sendable, Equatable {
    public var statusCode: Int
    public var kind: OAuthCallbackPageKind
    public var title: String
    public var message: String
    public var detail: String?
    public var preferredLanguage: OAuthCallbackPageLanguage
    public var accountLabel: String?

    public init(
        statusCode: Int,
        kind: OAuthCallbackPageKind,
        title: String,
        message: String,
        detail: String? = nil,
        preferredLanguage: OAuthCallbackPageLanguage,
        accountLabel: String? = nil
    ) {
        self.statusCode = statusCode
        self.kind = kind
        self.title = title
        self.message = message
        self.detail = detail
        self.preferredLanguage = preferredLanguage
        self.accountLabel = accountLabel
    }
}

public enum OAuthCallbackPageRenderer {
    public static func preferredLanguage(fromAcceptLanguage value: String?) -> OAuthCallbackPageLanguage {
        guard let value else { return .english }
        return value.lowercased().contains("zh") ? .zhHans : .english
    }

    public static func success(accountLabel: String, preferredLanguage: OAuthCallbackPageLanguage) -> OAuthCallbackPageResponse {
        OAuthCallbackPageResponse(
            statusCode: 200,
            kind: .success,
            title: self.localized(
                preferredLanguage,
                zh: "授权完成",
                en: "Authorization Completed"
            ),
            message: self.localized(
                preferredLanguage,
                zh: "OAuth 授权已经完成，账号已成功导入到 AI Coding Proxy。",
                en: "The OAuth authorization completed and the account was imported into AI Coding Proxy."
            ),
            preferredLanguage: preferredLanguage,
            accountLabel: accountLabel
        )
    }

    public static func failure(detail: String, preferredLanguage: OAuthCallbackPageLanguage) -> OAuthCallbackPageResponse {
        OAuthCallbackPageResponse(
            statusCode: 400,
            kind: .failure,
            title: self.localized(
                preferredLanguage,
                zh: "授权失败",
                en: "Authorization Failed"
            ),
            message: self.localized(
                preferredLanguage,
                zh: "浏览器回调没有顺利完成。你可以关闭此页面，回到 AI Coding Proxy 重试，或把完整回调链接粘贴到桌面端继续处理。",
                en: "The browser callback could not be completed. Close this page, retry from AI Coding Proxy, or paste the full callback URL into the desktop app to continue."
            ),
            detail: detail,
            preferredLanguage: preferredLanguage
        )
    }

    public static func cancelled(preferredLanguage: OAuthCallbackPageLanguage) -> OAuthCallbackPageResponse {
        OAuthCallbackPageResponse(
            statusCode: 200,
            kind: .cancelled,
            title: self.localized(
                preferredLanguage,
                zh: "授权已取消",
                en: "Authorization Cancelled"
            ),
            message: self.localized(
                preferredLanguage,
                zh: "当前 OAuth 授权监听已取消。你可以关闭此页面，并返回 AI Coding Proxy 重新发起授权。",
                en: "The OAuth listener was cancelled. Close this page and return to AI Coding Proxy to start again."
            ),
            preferredLanguage: preferredLanguage
        )
    }

    public static func invalidPath(preferredLanguage: OAuthCallbackPageLanguage) -> OAuthCallbackPageResponse {
        OAuthCallbackPageResponse(
            statusCode: 404,
            kind: .invalidPath,
            title: self.localized(
                preferredLanguage,
                zh: "未识别的回调地址",
                en: "Unrecognized Callback Address"
            ),
            message: self.localized(
                preferredLanguage,
                zh: "当前地址不是 AI Coding Proxy 的 OAuth 回调地址。你可以直接关闭此页面。",
                en: "This address is not an AI Coding Proxy OAuth callback. You can close this page."
            ),
            preferredLanguage: preferredLanguage
        )
    }

    public static func renderHTML(_ response: OAuthCallbackPageResponse) -> String {
        let palette = self.palette(for: response.kind)
        let title = self.escapeHTML(response.title)
        let message = self.escapeHTML(response.message)
        let detail = response.detail.flatMap(Self.cleanDetail).map(Self.escapeHTML)
        let accountLabel = response.accountLabel.flatMap(Self.cleanDetail).map(Self.escapeHTML)
        let badgeText = self.escapeHTML(self.badgeText(for: response.kind, language: response.preferredLanguage))
        let badgeClass = self.badgeClass(for: response.kind)
        let accountHeading = self.escapeHTML(self.localized(response.preferredLanguage, zh: "已导入账号", en: "Imported Account"))
        let detailHeading = self.escapeHTML(self.localized(response.preferredLanguage, zh: "详情", en: "Details"))
        let nextHeading = self.escapeHTML(self.localized(response.preferredLanguage, zh: "下一步", en: "Next Step"))
        let nextStep = self.escapeHTML(self.nextStep(for: response.kind, language: response.preferredLanguage))
        let tip = self.escapeHTML(self.tipText(for: response.kind, language: response.preferredLanguage))

        let accountSection = accountLabel.map { label in
            """
            <section class="panel account">
              <div class="panel-label">\(accountHeading)</div>
              <div class="account-value">\(label)</div>
            </section>
            """
        } ?? ""

        let detailSection = detail.map { detail in
            """
            <section class="panel detail">
              <div class="panel-label">\(detailHeading)</div>
              <pre>\(detail)</pre>
            </section>
            """
        } ?? ""

        return """
        <!doctype html>
        <html lang="\(response.preferredLanguage.htmlLanguageCode)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root{
          color-scheme: light;
          --bg-top:\(palette.backgroundTop);
          --bg-bottom:\(palette.backgroundBottom);
          --panel:\(palette.panel);
          --panel-soft:\(palette.panelSoft);
          --border:\(palette.border);
          --text:\(palette.text);
          --muted:\(palette.muted);
          --accent:\(palette.accent);
          --accent-soft:\(palette.accentSoft);
          --shadow:\(palette.shadow);
        }
        *{box-sizing:border-box}
        body{
          margin:0;
          min-height:100vh;
          padding:32px 20px;
          font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
          color:var(--text);
          background:
            radial-gradient(circle at top left, rgba(255,255,255,.9), transparent 38%),
            linear-gradient(180deg, var(--bg-top), var(--bg-bottom));
        }
        .shell{
          max-width:680px;
          margin:0 auto;
        }
        .card{
          background:linear-gradient(180deg, rgba(255,255,255,.96), rgba(255,255,255,.92));
          border:1px solid var(--border);
          border-radius:28px;
          box-shadow:0 24px 60px var(--shadow);
          overflow:hidden;
        }
        .header{
          padding:28px 28px 20px;
          border-bottom:1px solid rgba(15,23,42,.06);
        }
        .badge{
          display:inline-flex;
          align-items:center;
          padding:7px 12px;
          border-radius:999px;
          font-size:12px;
          font-weight:700;
          letter-spacing:.02em;
        }
        .badge.\(badgeClass){
          color:var(--accent);
          background:var(--accent-soft);
        }
        h1{
          margin:16px 0 10px;
          font-size:30px;
          line-height:1.15;
          letter-spacing:-0.02em;
        }
        .message{
          margin:0;
          font-size:15px;
          line-height:1.72;
          color:var(--muted);
        }
        .content{
          display:grid;
          gap:14px;
          padding:22px 28px 28px;
        }
        .panel{
          border:1px solid rgba(15,23,42,.08);
          background:var(--panel);
          border-radius:18px;
          padding:16px 18px;
        }
        .panel.next{
          background:var(--panel-soft);
        }
        .panel-label{
          margin-bottom:8px;
          font-size:12px;
          font-weight:700;
          color:var(--accent);
          text-transform:uppercase;
          letter-spacing:.06em;
        }
        .account-value{
          font-size:18px;
          font-weight:700;
          word-break:break-word;
        }
        pre{
          margin:0;
          white-space:pre-wrap;
          word-break:break-word;
          font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
          font-size:12px;
          line-height:1.7;
          color:var(--text);
        }
        .tip{
          margin:12px 2px 0;
          font-size:13px;
          line-height:1.7;
          color:var(--muted);
        }
        @media (max-width: 640px) {
          body{padding:20px 14px}
          .header{padding:22px 20px 18px}
          .content{padding:18px 20px 22px}
          h1{font-size:26px}
        }
        </style>
        </head>
        <body>
          <div class="shell">
            <main class="card">
              <header class="header">
                <div class="badge \(badgeClass)">\(badgeText)</div>
                <h1>\(title)</h1>
                <p class="message">\(message)</p>
              </header>
              <section class="content">
                \(accountSection)
                \(detailSection)
                <section class="panel next">
                  <div class="panel-label">\(nextHeading)</div>
                  <p class="message">\(nextStep)</p>
                </section>
                <p class="tip">\(tip)</p>
              </section>
            </main>
          </div>
        </body>
        </html>
        """
    }

    private struct Palette {
        let backgroundTop: String
        let backgroundBottom: String
        let panel: String
        let panelSoft: String
        let border: String
        let text: String
        let muted: String
        let accent: String
        let accentSoft: String
        let shadow: String
    }

    private static func palette(for kind: OAuthCallbackPageKind) -> Palette {
        switch kind {
        case .success:
            return Palette(
                backgroundTop: "#edf6ff",
                backgroundBottom: "#dcecff",
                panel: "rgba(255,255,255,0.92)",
                panelSoft: "rgba(235,247,255,0.96)",
                border: "rgba(45,123,211,0.18)",
                text: "#102238",
                muted: "#51667d",
                accent: "#0e78c9",
                accentSoft: "rgba(14,120,201,0.12)",
                shadow: "rgba(16,34,56,0.16)"
            )
        case .failure:
            return Palette(
                backgroundTop: "#fff3ef",
                backgroundBottom: "#ffe4dc",
                panel: "rgba(255,255,255,0.94)",
                panelSoft: "rgba(255,244,240,0.96)",
                border: "rgba(196,77,45,0.18)",
                text: "#2f1a17",
                muted: "#7b5b56",
                accent: "#c44d2d",
                accentSoft: "rgba(196,77,45,0.12)",
                shadow: "rgba(63,27,20,0.14)"
            )
        case .cancelled:
            return Palette(
                backgroundTop: "#fff8ea",
                backgroundBottom: "#ffedd3",
                panel: "rgba(255,255,255,0.94)",
                panelSoft: "rgba(255,248,232,0.96)",
                border: "rgba(180,118,22,0.18)",
                text: "#35240f",
                muted: "#75624c",
                accent: "#b47616",
                accentSoft: "rgba(180,118,22,0.12)",
                shadow: "rgba(53,36,15,0.12)"
            )
        case .invalidPath:
            return Palette(
                backgroundTop: "#eef4fb",
                backgroundBottom: "#e3edf9",
                panel: "rgba(255,255,255,0.94)",
                panelSoft: "rgba(239,244,250,0.96)",
                border: "rgba(74,102,141,0.16)",
                text: "#162436",
                muted: "#5d7085",
                accent: "#4a668d",
                accentSoft: "rgba(74,102,141,0.11)",
                shadow: "rgba(22,36,54,0.12)"
            )
        }
    }

    private static func badgeClass(for kind: OAuthCallbackPageKind) -> String {
        switch kind {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .cancelled:
            return "cancelled"
        case .invalidPath:
            return "neutral"
        }
    }

    private static func badgeText(for kind: OAuthCallbackPageKind, language: OAuthCallbackPageLanguage) -> String {
        switch kind {
        case .success:
            return self.localized(language, zh: "OAuth 成功", en: "OAuth Success")
        case .failure:
            return self.localized(language, zh: "OAuth 失败", en: "OAuth Failure")
        case .cancelled:
            return self.localized(language, zh: "OAuth 已取消", en: "OAuth Cancelled")
        case .invalidPath:
            return self.localized(language, zh: "AI Coding Proxy", en: "AI Coding Proxy")
        }
    }

    private static func nextStep(for kind: OAuthCallbackPageKind, language: OAuthCallbackPageLanguage) -> String {
        switch kind {
        case .success:
            return self.localized(
                language,
                zh: "现在可以关闭此页面，并切回 AI Coding Proxy。桌面端如果没有立刻刷新，等待几秒后再查看即可。",
                en: "You can close this page and return to AI Coding Proxy now. If the desktop app does not refresh immediately, wait a few seconds and check again."
            )
        case .failure:
            return self.localized(
                language,
                zh: "关闭此页面后，回到 AI Coding Proxy 重新发起 OAuth 授权，或直接粘贴完整回调链接继续处理。",
                en: "After closing this page, return to AI Coding Proxy to retry OAuth, or paste the full callback URL in the desktop app to continue."
            )
        case .cancelled:
            return self.localized(
                language,
                zh: "关闭此页面后，回到 AI Coding Proxy 重新打开授权页面即可。",
                en: "After closing this page, return to AI Coding Proxy and open the authorization page again."
            )
        case .invalidPath:
            return self.localized(
                language,
                zh: "如果你是从浏览器手动打开的这个地址，请回到 AI Coding Proxy，从应用中重新发起 OAuth 授权。",
                en: "If you opened this address manually, return to AI Coding Proxy and start OAuth from the app again."
            )
        }
    }

    private static func tipText(for kind: OAuthCallbackPageKind, language: OAuthCallbackPageLanguage) -> String {
        switch kind {
        case .success:
            return self.localized(
                language,
                zh: "此页面只用于确认浏览器回调结果，不会保存额外网页数据。",
                en: "This page only confirms the browser callback result and does not store extra web data."
            )
        case .failure, .cancelled, .invalidPath:
            return self.localized(
                language,
                zh: "如果问题持续出现，请回到 AI Coding Proxy 查看桌面端里的错误提示和授权状态。",
                en: "If this continues to happen, return to AI Coding Proxy and review the desktop app error details and authorization state."
            )
        }
    }

    private static func cleanDetail(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localized(_ language: OAuthCallbackPageLanguage, zh: String, en: String) -> String {
        switch language {
        case .zhHans:
            return zh
        case .english:
            return en
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
