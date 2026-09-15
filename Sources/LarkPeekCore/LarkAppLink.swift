import Foundation

public enum LarkAppLink {
    /// Uses the same native URL scheme as the AppLink landing page.
    public static func desktopChat(_ chatID: String) -> URL? {
        guard let webURL = chat(chatID),
              var url = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else { return nil }
        url.scheme = "lark"
        return url.url
    }

    /// A user-invoked navigation action; never used by the preview read path.
    public static func chat(_ chatID: String) -> URL? {
        guard (try? ReadOnlyCommand.chatDetails(chatID: chatID).arguments()) != nil else { return nil }
        var url = URLComponents(string: "https://applink.feishu.cn/client/chat/open")!
        url.queryItems = [URLQueryItem(name: "openChatId", value: chatID)]
        return url.url
    }
}
