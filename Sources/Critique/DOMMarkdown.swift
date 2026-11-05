import Foundation

/// How the browser extension's findings read in feedback.md.
extension DOMElement {
    /// One line for the agent, e.g.
    /// `button#signup.btn.primary · data-testid=signup · React <SignupButton> (src/components/Signup.tsx:42) · “Sign up”`
    var summary: String {
        var head = tag
        if let id, !id.isEmpty { head += "#\(id)" }
        for cls in (classes ?? []).prefix(3) { head += ".\(cls)" }
        var parts = [head]
        // The selector only earns a spot when the head line alone wouldn't find the element.
        if let selector, !selector.isEmpty, selector != head, selector != "#\(id ?? "")" {
            parts.append("`\(selector)`")
        }
        if let testId, !testId.isEmpty { parts.append("\(testAttr ?? "data-testid")=\(testId)") }
        if let role, !role.isEmpty { parts.append("role=\(role)") }
        if let ariaLabel, !ariaLabel.isEmpty { parts.append("aria-label=“\(ariaLabel)”") }
        if let framework, component != nil || source != nil {
            var fw = framework
            if let component { fw += " <\(component)>" }
            if let parent = parents?.first { fw += " in <\(parent)>" }
            if let source { fw += " (\(source))" }
            parts.append(fw)
        }
        if let href, !href.isEmpty { parts.append("href=\(href)") }
        if let name, !name.isEmpty { parts.append("name=\(name)") }
        if let type, !type.isEmpty { parts.append("type=\(type)") }
        if let text, !text.isEmpty { parts.append("“\(text)”") }
        return parts.joined(separator: " · ")
    }
}

extension FeedbackRecord.ShotRecord {
    /// Lines under the shot: the page it was on, then one `DOM:` line per element.
    var domMarkdown: String {
        var md = ""
        if let page {
            md += "  - Page: \(page.url)"
            if let title = page.title, !title.isEmpty { md += " — “\(title)”" }
            md += "\n"
        }
        for element in dom ?? [] { md += "  - DOM: \(element.summary)\n" }
        return md
    }
}

extension FeedbackRecord {
    /// Explains the DOM lines once, when any shot has them.
    var domNote: String? {
        guard shots.contains(where: { !($0.dom ?? []).isEmpty }) else { return nil }
        return "DOM lines come from the Critique browser extension: tag#id.classes · unique selector · test id · "
            + "framework component (source file:line in dev builds) · text. Use the selector or test id to find "
            + "the element and the component name to find its code.\n\n"
    }
}
