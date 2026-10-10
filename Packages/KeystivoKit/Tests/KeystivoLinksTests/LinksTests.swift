import Foundation
@testable import KeystivoLinks
import Testing

@Suite("Link routing")
struct LinkRoutingTests {
    @Test func hostMatching() {
        #expect(LinkRouter.hostMatches("github.com", host: "github.com"))
        #expect(LinkRouter.hostMatches("github.com", host: "gist.github.com"))
        #expect(!LinkRouter.hostMatches("github.com", host: "notgithub.com"))
        #expect(LinkRouter.hostMatches("*.figma.com", host: "www.figma.com"))
        #expect(!LinkRouter.hostMatches("", host: "a.com"))
    }

    @Test func sourceAppRulesWin() {
        var settings = LinkSettings()
        settings.isEnabled = true
        settings.defaultBrowserBundleID = "com.apple.Safari"
        settings.rules = [
            LinkRule(hostPattern: "github.com", browserBundleID: "com.google.Chrome"),
            LinkRule(hostPattern: "*", sourceBundleID: "com.tinyspeck.slackmacgap", browserBundleID: "org.mozilla.firefox"),
        ]
        let url = URL(string: "https://github.com/apple")!
        #expect(LinkRouter.resolve(url, sourceBundleID: nil, settings: settings) == .open("com.google.Chrome"))
        #expect(LinkRouter.resolve(url, sourceBundleID: "com.tinyspeck.slackmacgap", settings: settings) == .open("org.mozilla.firefox"))
        #expect(LinkRouter.resolve(URL(string: "https://apple.com")!, sourceBundleID: nil, settings: settings) == .open("com.apple.Safari"))
        #expect(LinkRouter.resolve(url, sourceBundleID: nil, settings: settings, forcePicker: true) == .ask)
    }

    @Test func fallbackAsks() {
        var settings = LinkSettings()
        settings.fallback = .ask
        #expect(LinkRouter.resolve(URL(string: "https://a.com")!, sourceBundleID: nil, settings: settings) == .ask)
        settings.fallback = .defaultBrowser
        #expect(LinkRouter.resolve(URL(string: "https://a.com")!, sourceBundleID: nil, settings: settings) == .ask)
    }

    @Test func disabledRulesAreIgnored() {
        var settings = LinkSettings()
        settings.defaultBrowserBundleID = "default"
        var rule = LinkRule(hostPattern: "a.com", browserBundleID: "other")
        rule.isEnabled = false
        settings.rules = [rule]
        #expect(LinkRouter.resolve(URL(string: "https://a.com")!, sourceBundleID: nil, settings: settings) == .open("default"))
    }

    @Test func trackingParametersAreRemoved() {
        let url = URL(string: "https://example.com/p?id=7&utm_source=x&UTM_Medium=y&fbclid=abc&gclid=1")!
        #expect(LinkRouter.clean(url).absoluteString == "https://example.com/p?id=7")
        #expect(LinkRouter.clean(URL(string: "https://example.com/?utm_campaign=z")!).absoluteString == "https://example.com/")
        let untouched = URL(string: "https://example.com/?q=swift")!
        #expect(LinkRouter.clean(untouched) == untouched)
    }
}
