// Copyright Dave Verwer, Sven A. Schmidt, and other contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Vapor
import SwiftSoup
import Plot

struct DocumentationPageProcessor {
    let document: SwiftSoup.Document
    let repositoryOwner: String
    let repositoryOwnerName: String
    let repositoryName: String
    let packageName: String
    let reference: String
    let referenceLatest: Version.Kind?
    let referenceKind: Version.Kind
    let canonicalUrl: String?
    let availableArchives: [AvailableArchive]
    let availableVersions: [AvailableDocumentationVersion]
    let updatedAt: Date

    struct AvailableArchive {
        let archive: DocArchive
        let isCurrent: Bool

        var name: String { archive.name }
        var title: String { archive.title }
    }

    struct AvailableDocumentationVersion {
        let kind: Version.Kind
        let reference: String
        let docArchives: [DocArchive]
        let isLatestStable: Bool
    }

    init?(repositoryOwner: String,
          repositoryOwnerName: String,
          repositoryName: String,
          packageName: String,
          reference: String,
          referenceLatest: Version.Kind?,
          referenceKind: Version.Kind,
          canonicalUrl: String?,
          availableArchives: [AvailableArchive],
          availableVersions: [AvailableDocumentationVersion],
          updatedAt: Date,
          rawHtml: String) {
        self.repositoryOwner = repositoryOwner
        self.repositoryOwnerName = repositoryOwnerName
        self.repositoryName = repositoryName
        self.packageName = packageName
        self.reference = reference
        self.referenceLatest = referenceLatest
        self.referenceKind = referenceKind
        self.canonicalUrl = canonicalUrl
        self.availableArchives = availableArchives
        self.availableVersions = availableVersions
        self.updatedAt = updatedAt

        do {
            document = try SwiftSoup.parse(rawHtml)

            // Base URL rewrite
            try Self.rewriteBaseUrl(document: document, owner: repositoryOwner, repository: repositoryName, reference: reference)
            try Self.rewrite(document: document, attribute: "href", owner: repositoryOwner, repository: repositoryName, reference: reference)
            try Self.rewrite(document: document, attribute: "src", owner: repositoryOwner, repository: repositoryName, reference: reference)

            // SPI related modifications
            try document.title("\(packageName) Documentation – Swift Package Index")
            if let metaNoIndex = self.metaNoIndex {
                try document.head()?.prepend(metaNoIndex)
            }
            try document.head()?.append(self.stylesheetLink)
            if let canonicalUrl = self.canonicalUrl {
                try document.head()?.append(
                    // We should not use `url` here as some of the DocC JavaScript lowercases
                    // both the `og:url` and `twitter:url` properties, if present. It is better
                    // to have no `og:url` and `twitter:url` properties than incorrect ones.
                    Plot.Node.link(
                        .rel(.canonical),
                        .href(canonicalUrl)
                    ).render()
                )
            }
            try document.body()?.prepend(self.header)
            try document.body()?.append(self.footer)
            if let analyticsScript = self.analyticsScript {
                try document.head()?.append(analyticsScript)
            }
        } catch {
            return nil
        }
    }

    var metaNoIndex: String? {
        guard Current.environment() != .production else { return nil }
        return Plot.Node.meta(
            .name("robots"),
            .content("noindex")
        ).render()
    }

    var stylesheetLink: String {
        Plot.Node.link(
            .rel(.stylesheet),
            .href(SiteURL.stylesheets("docc").relativeURL() + "?" + ResourceReloadIdentifier.value)
        ).render()
    }

    var analyticsScript: String? {
        guard Current.environment() == .production else { return nil }
        return PublicPage.analyticsScriptTags
    }

    var header: String {
        let documentationVersionChoices: [Plot.Node<HTML.ListContext>] = availableVersions.compactMap { version in
            // If a version has no docArchives, it has no documentation we can switch to.
            guard let currentArchive = availableArchives.first(where: { $0.isCurrent })
            else { return nil }

            return .li(
                .if(version.reference == reference, .class("current")),
                .a(
                    .href(
                        SiteURL.relativeURL(
                            owner: repositoryOwner,
                            repository: repositoryName,
                            documentation: .internal(reference: version.reference,
                                                     archive: currentArchive.name),
                            fragment: .documentation
                        )
                    ),
                    .span(
                        .class(version.kind.cssClass),
                        .text(version.reference)
                    )
                )
            )
        }

        var breadcrumbs = [
            Breadcrumb(title: "Swift Package Index", url: SiteURL.home.relativeURL()),
            Breadcrumb(title: repositoryOwnerName, url: SiteURL.author(.value(repositoryOwner)).relativeURL()),
            Breadcrumb(title: packageName, url: SiteURL.package(.value(repositoryOwner), .value(repositoryName), .none).relativeURL()),
            Breadcrumb(title: .init(
                .text("Documentation for "),
                .span(
                    .class(referenceKind.cssClass),
                    .text(reference)
                )
            ), choices: documentationVersionChoices.count > 0 ? documentationVersionChoices : nil)
        ]

        if availableArchives.count > 1,
           let currentArchive = availableArchives.first(where: { $0.isCurrent }) {
            breadcrumbs.append(Breadcrumb(title: currentArchive.title, choices: [
                .forEach(availableArchives, { archive in
                        .li(
                            .if(archive.isCurrent, .class("current")),
                            .a(
                                .href(
                                    SiteURL.relativeURL(
                                        owner: repositoryOwner,
                                        repository: repositoryName,
                                        documentation: .internal(reference: reference,
                                                                 archive: archive.name),
                                        fragment: .documentation
                                    )
                                ),
                                .text(archive.title)
                            )
                        )
                })
            ]))
        }

        return Plot.Node.group(
            .header(
                .class("spi"),
                .if(Current.environment() == .development, stagingBanner()),
                .div(
                    .class("inner breadcrumbs"),
                    .nav(
                        .ul(
                            .group(breadcrumbs.map { $0.listNode() })
                        )
                    )
                ),
                .if(referenceLatest != .release,
                    // Only try and show a link to the latest stable if there *is* a latest stable.
                    .unwrap(availableVersions.first(where: \.isLatestStable)) { latestStable in
                            .div(
                                .class("latest-stable-wrap"),
                                .div(
                                    .class("inner latest-stable"),
                                    .text(latestStableLinkExplanatoryText),
                                    .text(" "),
                                    .unwrap(latestStable.docArchives.first) { docArchive in
                                            .group(
                                                .a(
                                                    .href(
                                                        SiteURL.relativeURL(
                                                            owner: repositoryOwner,
                                                            repository: repositoryName,
                                                            documentation: .internal(reference: latestStable.reference,
                                                                                     archive: docArchive.name),
                                                            fragment: .documentation
                                                        )
                                                    ),
                                                    .text("View latest release documentation")
                                                ),
                                                .text(".")
                                            )
                                    }
                                )
                            )
                    })
            )
        ).render()
    }

    var footer: String {
        return Plot.Node.footer(
            .class("spi"),
            .div(
                .class("inner"),
                .publishedTime(updatedAt, label: "Last updated on"),
                .nav(
                    .ul(
                        .li(
                            .a(
                                .href(SiteURL.blog.relativeURL()),
                                "Blog"
                            )
                        ),
                        .li(
                            .a(
                                .href(ExternalURL.projectGitHub),
                                "GitHub"
                            )
                        ),
                        .li(
                            .a(
                                .href(SiteURL.privacy.relativeURL()),
                                "Privacy and Cookies"
                            )
                        ),
                        .li(
                            .a(
                                .href("https://swiftpackageindex.statuspage.io"),
                                "Uptime and System Status"
                            )
                        ),
                        .li(
                            .a(
                                .href(ExternalURL.mastodon),
                                "Mastodon"
                            )
                        )
                    )
                ),
                .small(
                    .text("The Swift Package Index is entirely funded by sponsorship. Thank you to "),
                    .a(
                        .href("https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server#funding-and-sponsorship"),
                        "all our sponsors for their generosity"
                    ),
                    .text(".")
                )
            ),
            .if(Current.environment() == .development, stagingBanner())
        ).render()
    }

    var processedPage: String {
        do {
            return try document.html()
        } catch {
            return "An error occurred while rendering processed documentation."
        }
    }

    var latestStableLinkExplanatoryText: String {
        switch referenceKind {
            case .release: return "This documentation is from a previous release and may not reflect the latest released version."
            case .preRelease: return "This documentation is from a pre-release and may not reflect the latest released version."
            case .defaultBranch: return "This documentation is from the \(reference) branch and may not reflect the latest released version."
        }
    }

    func stagingBanner() -> Plot.Node<HTML.BodyContext> {
        .div(
            .class("staging"),
            .text("This is a staging environment. For live and up-to-date documentation, "),
            .a(
                .href("https://swiftpackageindex.com"),
                "visit swiftpackageindex.com"
            ),
            .text(".")
        )
    }

    static func rewriteBaseUrl(document: SwiftSoup.Document, owner: String, repository: String, reference: String) throws {
        for e in try document.select("script") {
            let value = e.data()
            if value == #"var baseUrl = "/""# {
                let path = "/\(owner)/\(repository)/\(reference)/".lowercased()
                try e.html(#"var baseUrl = "\#(path)""#)
            }
        }
    }

    static func rewrite(document: SwiftSoup.Document, attribute: String, owner: String, repository: String, reference: String) throws {
        for e in try document.select(#"[\#(attribute)^="/"]"#) {
            let value = try e.attr(attribute)
            let path = "/\(owner)/\(repository)".lowercased()
            if !value.lowercased().hasPrefix(path) {
                try e.attr(attribute, "\(path)/\(reference)\(value)")
            }
        }
    }
}
