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

import XCTest

@testable import App

import Dependencies
import Fluent
import S3Store
import Vapor


class IngestionTests: AppTestCase {

    func test_ingest_basic() async throws {
        // setup
        let packages = ["https://github.com/finestructure/Gala",
                        "https://github.com/finestructure/Rester",
                        "https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server"]
            .map { Package(url: $0, processingStage: .reconciliation) }
        try await packages.save(on: app.db)
        let lastUpdate = Date()

        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            $0.github.fetchMetadata = { @Sendable owner, repository in .mock(owner: owner, repository: repository) }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
        } operation: {
            // MUT
            try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(10))
        }

        // validate
        let repos = try await Repository.query(on: app.db).all()
        XCTAssertEqual(Set(repos.map(\.$package.id)), Set(packages.map(\.id)))
        repos.forEach {
            XCTAssertNotNil($0.id)
            XCTAssertNotNil($0.$package.id)
            XCTAssertNotNil($0.createdAt)
            XCTAssertNotNil($0.updatedAt)
            XCTAssertNotNil($0.description)
            XCTAssertEqual($0.defaultBranch, "main")
            XCTAssert($0.forks > 0)
            XCTAssert($0.stars > 0)
        }
        // assert packages have been updated
        (try await Package.query(on: app.db).all()).forEach {
            XCTAssert($0.updatedAt != nil && $0.updatedAt! > lastUpdate)
            XCTAssertEqual($0.status, .new)
            XCTAssertEqual($0.processingStage, .ingestion)
        }
    }

    func test_ingest_continue_on_error() async throws {
        // Test completion of ingestion despite early error
        try await withDependencies {
            $0.github.fetchLicense = { @Sendable _, _ in Github.License(htmlUrl: "license") }
            $0.github.fetchMetadata = { @Sendable owner, repository throws(Github.Error) in
                if owner == "foo" && repository == "1" {
                    throw Github.Error.requestFailed(.badRequest)
                }
                return .mock(owner: owner, repository: repository)
            }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
        } operation: {
            // setup
            let packages = try await savePackages(on: app.db, ["https://github.com/foo/1",
                                                               "https://github.com/foo/2"], processingStage: .reconciliation)
                .map(Joined<Package, Repository>.init(model:))

            // MUT
            await Ingestion.ingest(client: app.client, database: app.db, packages: packages)

            do {
                // validate the second package's license is updated
                let repo = try await Repository.query(on: app.db)
                    .filter(\.$name == "2")
                    .first()
                    .unwrap()
                XCTAssertEqual(repo.licenseUrl, "license")
                for pkg in try await Package.query(on: app.db).all() {
                    XCTAssertEqual(pkg.processingStage, .ingestion, "\(pkg.url) must be in ingestion")
                }
            }
        }
    }

    func test_updateRepository_insert() async throws {
        let pkg = try await savePackage(on: app.db, "https://github.com/foo/bar")
        let repo = Repository(packageId: try pkg.requireID())

        // MUT
        try await Ingestion.updateRepository(on: app.db,
                                             for: repo,
                                             metadata: .mock(owner: "foo", repository: "bar"),
                                             licenseInfo: .init(htmlUrl: ""),
                                             readmeInfo: .init(html: "", htmlUrl: "", imagesToCache: []),
                                             s3Readme: nil)

        // validate
        do {
            let app = self.app!
            try await XCTAssertEqualAsync(try await Repository.query(on: app.db).count(), 1)
            let repo = try await Repository.query(on: app.db).first().unwrap()
            XCTAssertEqual(repo.summary, "This is package foo/bar")
        }
    }

    func test_updateRepository_update() async throws {
        let pkg = try await savePackage(on: app.db, "https://github.com/foo/bar")
        let repo = Repository(packageId: try pkg.requireID())
        let md: Github.Metadata = .init(defaultBranch: "main",
                                        forks: 1,
                                        fundingLinks: [
                                            .init(platform: .gitHub, url: "https://github.com/username"),
                                            .init(platform: .customUrl, url: "https://example.com/username1"),
                                            .init(platform: .customUrl, url: "https://example.com/username2")
                                        ],
                                        homepageUrl: "https://swiftpackageindex.com/Alamofire/Alamofire",
                                        isInOrganization: true,
                                        issuesClosedAtDates: [
                                            Date(timeIntervalSince1970: 0),
                                            Date(timeIntervalSince1970: 2),
                                            Date(timeIntervalSince1970: 1),
                                        ],
                                        license: .mit,
                                        openIssues: 1,
                                        parentUrl: nil,
                                        openPullRequests: 2,
                                        owner: "foo",
                                        pullRequestsClosedAtDates: [
                                            Date(timeIntervalSince1970: 1),
                                            Date(timeIntervalSince1970: 3),
                                            Date(timeIntervalSince1970: 2),
                                        ],
                                        releases: [
                                            .init(description: "a release",
                                                  descriptionHTML: "<p>a release</p>",
                                                  isDraft: false,
                                                  publishedAt: Date(timeIntervalSince1970: 5),
                                                  tagName: "1.2.3",
                                                  url: "https://example.com/1.2.3")
                                        ],
                                        repositoryTopics: ["foo", "bar", "Bar", "baz"],
                                        name: "bar",
                                        stars: 2,
                                        summary: "package desc")

        // MUT
        try await Ingestion.updateRepository(on: app.db,
                                             for: repo,
                                             metadata: md,
                                             licenseInfo: .init(htmlUrl: "license url"),
                                             readmeInfo: .init(etag: "etag",
                                                               html: "readme html https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com",
                                                               htmlUrl: "readme html url",
                                                               imagesToCache: []),
                                             s3Readme: .cached(s3ObjectUrl: "url", githubEtag: "etag"),
                                             fork: .parentURL("https://github.com/foo/bar.git"))

        // validate
        do {
            let app = self.app!
            try await XCTAssertEqualAsync(try await Repository.query(on: app.db).count(), 1)
            let repo = try await Repository.query(on: app.db).first().unwrap()
            XCTAssertEqual(repo.defaultBranch, "main")
            XCTAssertEqual(repo.forks, 1)
            XCTAssertEqual(repo.forkedFrom, .parentURL("https://github.com/foo/bar.git"))
            XCTAssertEqual(repo.fundingLinks, [
                .init(platform: .gitHub, url: "https://github.com/username"),
                .init(platform: .customUrl, url: "https://example.com/username1"),
                .init(platform: .customUrl, url: "https://example.com/username2")
            ])
            XCTAssertEqual(repo.hasSPIBadge, true)
            XCTAssertEqual(repo.homepageUrl, "https://swiftpackageindex.com/Alamofire/Alamofire")
            XCTAssertEqual(repo.isInOrganization, true)
            XCTAssertEqual(repo.keywords, ["bar", "baz", "foo"])
            XCTAssertEqual(repo.lastIssueClosedAt, Date(timeIntervalSince1970: 2))
            XCTAssertEqual(repo.lastPullRequestClosedAt, Date(timeIntervalSince1970: 3))
            XCTAssertEqual(repo.license, .mit)
            XCTAssertEqual(repo.licenseUrl, "license url")
            XCTAssertEqual(repo.openIssues, 1)
            XCTAssertEqual(repo.openPullRequests, 2)
            XCTAssertEqual(repo.owner, "foo")
            XCTAssertEqual(repo.ownerName, "foo")
            XCTAssertEqual(repo.ownerAvatarUrl, "https://avatars.githubusercontent.com/u/61124617?s=200&v=4")
            XCTAssertEqual(repo.s3Readme, .cached(s3ObjectUrl: "url", githubEtag: "etag"))
            XCTAssertEqual(repo.readmeHtmlUrl, "readme html url")
            XCTAssertEqual(repo.releases, [
                .init(description: "a release",
                      descriptionHTML: "<p>a release</p>",
                      isDraft: false,
                      publishedAt: Date(timeIntervalSince1970: 5),
                      tagName: "1.2.3",
                      url: "https://example.com/1.2.3")
            ])
            XCTAssertEqual(repo.name, "bar")
            XCTAssertEqual(repo.stars, 2)
            XCTAssertEqual(repo.summary, "package desc")
        }
    }

    func test_homePageEmptyString() async throws {
        // setup
        let pkg = try await savePackage(on: app.db, "2")
        let repo = Repository(packageId: try pkg.requireID())
        let md: Github.Metadata = .init(defaultBranch: "main",
                                        forks: 1,
                                        homepageUrl: "  ",
                                        isInOrganization: true,
                                        issuesClosedAtDates: [],
                                        license: .mit,
                                        openIssues: 1,
                                        parentUrl: nil,
                                        openPullRequests: 2,
                                        owner: "foo",
                                        pullRequestsClosedAtDates: [],
                                        releases: [],
                                        repositoryTopics: ["foo", "bar", "Bar", "baz"],
                                        name: "bar",
                                        stars: 2,
                                        summary: "package desc")

        // MUT
        try await Ingestion.updateRepository(on: app.db,
                                             for: repo,
                                             metadata: md,
                                             licenseInfo: .init(htmlUrl: "license url"),
                                             readmeInfo: .init(html: "readme html",
                                                               htmlUrl: "readme html url",
                                                               imagesToCache: []),
                                             s3Readme: nil)

        // validate
        do {
            let repo = try await Repository.query(on: app.db).first().unwrap()
            XCTAssertNil(repo.homepageUrl)
        }
    }

    func test_updatePackage() async throws {
        // setup
        let pkgs = try await savePackages(on: app.db, ["https://github.com/foo/1",
                                                       "https://github.com/foo/2"])
            .map(Joined<Package, Repository>.init(model:))
        let pkgId0 = try pkgs[0].model.requireID()
        let results: [Result<Joined<Package, Repository>, Ingestion.Error>] = [
            .failure(.init(packageId: pkgId0, underlyingError: .fetchMetadataFailed(owner: "", name: "", details: ""))),
            .success(pkgs[1])
        ]

        // MUT
        for result in results {
            try await Ingestion.updatePackage(client: app.client,
                                              database: app.db,
                                              result: result,
                                              stage: .ingestion)
        }

        // validate
        do {
            let pkgs = try await Package.query(on: app.db).sort(\.$url).all()
            XCTAssertEqual(pkgs.map(\.status), [.ingestionFailed, .new])
            XCTAssertEqual(pkgs.map(\.processingStage), [.ingestion, .ingestion])
        }
    }

    func test_updatePackage_new() async throws {
        // Ensure newly ingested packages are passed on with status = new to fast-track
        // them into analysis
        let pkgs = [
            Package(id: UUID(), url: "https://github.com/foo/1", status: .ok, processingStage: .reconciliation),
            Package(id: UUID(), url: "https://github.com/foo/2", status: .new, processingStage: .reconciliation)
        ]
        try await pkgs.save(on: app.db)
        let results: [Result<Joined<Package, Repository>, Ingestion.Error>] = [ .success(.init(model: pkgs[0])),
                                                                                .success(.init(model: pkgs[1]))]

        // MUT
        for result in results {
            try await Ingestion.updatePackage(client: app.client,
                                              database: app.db,
                                              result: result,
                                              stage: .ingestion)
        }

        // validate
        do {
            let pkgs = try await Package.query(on: app.db).sort(\.$url).all()
            XCTAssertEqual(pkgs.map(\.status), [.ok, .new])
            XCTAssertEqual(pkgs.map(\.processingStage), [.ingestion, .ingestion])
        }
    }

    func test_partial_save_issue() async throws {
        // Test to ensure futures are properly waited for and get flushed to the db in full
        // setup
        let packages = testUrls.map { Package(url: $0, processingStage: .reconciliation) }
        try await packages.save(on: app.db)

        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            $0.github.fetchMetadata = { @Sendable owner, repository in .mock(owner: owner, repository: repository) }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
        } operation: {
            // MUT
            try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(testUrls.count))
        }

        // validate
        let repos = try await Repository.query(on: app.db).all()
        XCTAssertEqual(repos.count, testUrls.count)
        XCTAssertEqual(Set(repos.map(\.$package.id)), Set(packages.map(\.id)))
    }

    func test_ingest_badMetadata() async throws {
        // setup
        let urls = ["https://github.com/foo/1",
                    "https://github.com/foo/2",
                    "https://github.com/foo/3"]
        try await savePackages(on: app.db, urls.asURLs, processingStage: .reconciliation)
        let lastUpdate = Date()

        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            $0.github.fetchMetadata = { @Sendable owner, repository throws(Github.Error) in
                if owner == "foo" && repository == "2" {
                    throw Github.Error.requestFailed(.badRequest)
                }
                return .mock(owner: owner, repository: repository)
            }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
        } operation: {
            // MUT
            try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(10))
        }

        // validate
        let repos = try await Repository.query(on: app.db).all()
        XCTAssertEqual(repos.count, 2)
        XCTAssertEqual(repos.compactMap(\.summary).sorted(),
                       ["This is package foo/1",
                        "This is package foo/3"])
        (try await Package.query(on: app.db).all()).forEach { pkg in
            switch pkg.url {
                case "https://github.com/foo/2":
                    XCTAssertEqual(pkg.status, .ingestionFailed)
                default:
                    XCTAssertEqual(pkg.status, .new)
            }
            XCTAssert(pkg.updatedAt! > lastUpdate)
        }
    }

    func test_ingest_unique_owner_name_violation() async throws {
        // Test error behaviour when two packages resolving to the same owner/name are ingested:
        //   - don't create repository records
        // setup
        try await Package(id: .id0, url: "https://github.com/foo/0", status: .ok, processingStage: .reconciliation)
            .save(on: app.db)
        try await Package(id: .id1, url: "https://github.com/foo/1", status: .ok, processingStage: .reconciliation)
            .save(on: app.db)

        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            // Return identical metadata for both packages, same as a for instance a redirected
            // package would after a rename / ownership change
            $0.github.fetchMetadata = { @Sendable _, _ in
                Github.Metadata.init(
                    defaultBranch: "main",
                    forks: 0,
                    homepageUrl: nil,
                    isInOrganization: false,
                    issuesClosedAtDates: [],
                    license: .mit,
                    openIssues: 0,
                    parentUrl: nil,
                    openPullRequests: 0,
                    owner: "owner",
                    pullRequestsClosedAtDates: [],
                    name: "name",
                    stars: 0,
                    summary: "desc")
            }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
        } operation: {
            // MUT
            try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(10))
        }

        // validate repositories (single element pointing to the ingested package)
        let repos = try await Repository.query(on: app.db).all()
        XCTAssertEqual(repos.count, 1)

        // validate packages - one should have succeeded, one should have failed
        let succeeded = try await Package.query(on: app.db)
            .filter(\.$status == .ok)
            .first()
            .unwrap()
        let failed = try await Package.query(on: app.db)
            .filter(\.$status == .ingestionFailed)
            .first()
            .unwrap()
        XCTAssertEqual(succeeded.processingStage, .ingestion)
        XCTAssertEqual(failed.processingStage, .ingestion)
        // an error must have been logged
        try logger.logs.withValue { logs in
            XCTAssertEqual(logs.count, 1)
            let log = try XCTUnwrap(logs.first)
            XCTAssertEqual(log.level, .critical)
            XCTAssertEqual(log.message, #"Ingestion.Error(\#(try failed.requireID()), repositorySaveUniqueViolation(owner, name, duplicate key value violates unique constraint "idx_repositories_owner_name"))"#)
        }

        // ensure analysis can process these packages
        try await withDependencies {
            $0.date.now = .now
            $0.environment.allowSocialPosts = { false }
            $0.environment.loadSPIManifest = { _ in nil }
            $0.fileManager.fileExists = { @Sendable _ in true }
        } operation: { [db = app.db] in
            Current.git.commitCount = { @Sendable _ in 1 }
            Current.git.firstCommitDate = { @Sendable _ in .t0 }
            Current.git.lastCommitDate = { @Sendable _ in .t0 }
            Current.git.getTags = { @Sendable _ in [] }
            Current.git.hasBranch = { @Sendable _, _ in true }
            Current.git.revisionInfo = { @Sendable _, _ in .init(commit: "sha0", date: .t0) }
            Current.git.shortlog = { @Sendable _ in "" }
            Current.shell.run = { @Sendable cmd, _ in
                if cmd.description.hasSuffix("package dump-package") {
                    return .packageDump(name: "foo")
                }
                return ""
            }

            try await Analyze.analyze(client: app.client, database: db, mode: .id(.id0))
            try await Analyze.analyze(client: app.client, database: db, mode: .id(.id1))
            try await XCTAssertEqualAsync(try await Package.find(.id0, on: db)?.processingStage, .analysis)
            try await XCTAssertEqualAsync(try await Package.find(.id1, on: db)?.processingStage, .analysis)
        }
    }

    func test_S3Store_Key_readme() throws {
        try withDependencies {
            $0.environment.awsReadmeBucket = { "readme-bucket" }
        } operation: {
            XCTAssertEqual(try S3Store.Key.readme(owner: "foo", repository: "bar").path, "foo/bar/readme.html")
            XCTAssertEqual(try S3Store.Key.readme(owner: "FOO", repository: "bar").path, "foo/bar/readme.html")
        }
    }

    func test_ingest_storeS3Readme() async throws {
        let fetchCalls = QueueIsolated(0)
        let storeCalls = QueueIsolated(0)
        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            $0.github.fetchMetadata = { @Sendable owner, repository in .mock(owner: owner, repository: repository) }
            $0.github.fetchReadme = { @Sendable _, _ in
                fetchCalls.increment()
                if fetchCalls.value <= 2 {
                    return .init(etag: "etag1",
                                 html: "readme html 1",
                                 htmlUrl: "readme url",
                                 imagesToCache: [])
                } else {
                    return .init(etag: "etag2",
                                 html: "readme html 2",
                                 htmlUrl: "readme url",
                                 imagesToCache: [])
                }
            }
            $0.s3.storeReadme = { owner, repo, html in
                storeCalls.increment()
                XCTAssertEqual(owner, "foo")
                XCTAssertEqual(repo, "bar")
                if fetchCalls.value <= 2 {
                    XCTAssertEqual(html, "readme html 1")
                } else {
                    XCTAssertEqual(html, "readme html 2")
                }
                return "objectUrl"
            }
        } operation: {
            // setup
            let app = self.app!
            let pkg = Package(url: "https://github.com/foo/bar".url, processingStage: .reconciliation)
            try await pkg.save(on: app.db)

            do { // first ingestion, no readme has been saved
                 // MUT
                try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(1))

                // validate
                try await XCTAssertEqualAsync(await Repository.query(on: app.db).count(), 1)
                let repo = try await XCTUnwrapAsync(await Repository.query(on: app.db).first())
                // Ensure fetch and store have been called, etag save to repository
                XCTAssertEqual(fetchCalls.value, 1)
                XCTAssertEqual(storeCalls.value, 1)
                XCTAssertEqual(repo.s3Readme, .cached(s3ObjectUrl: "objectUrl", githubEtag: "etag1"))
            }

            do { // second pass, readme has been saved, no new save should be issued
                pkg.processingStage = .reconciliation
                try await pkg.save(on: app.db)

                // MUT
                try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(1))

                // validate
                try await XCTAssertEqualAsync(await Repository.query(on: app.db).count(), 1)
                let repo = try await XCTUnwrapAsync(await Repository.query(on: app.db).first())
                // Ensure fetch and store have been called, etag save to repository
                XCTAssertEqual(fetchCalls.value, 2)
                XCTAssertEqual(storeCalls.value, 1)
                XCTAssertEqual(repo.s3Readme, .cached(s3ObjectUrl: "objectUrl", githubEtag: "etag1"))
            }

            do { // third pass, readme has changed upstream, save should be issues
                pkg.processingStage = .reconciliation
                try await pkg.save(on: app.db)

                // MUT
                try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(1))

                // validate
                try await XCTAssertEqualAsync(await Repository.query(on: app.db).count(), 1)
                let repo = try await XCTUnwrapAsync(await Repository.query(on: app.db).first())
                // Ensure fetch and store have been called, etag save to repository
                XCTAssertEqual(fetchCalls.value, 3)
                XCTAssertEqual(storeCalls.value, 2)
                XCTAssertEqual(repo.s3Readme, .cached(s3ObjectUrl: "objectUrl", githubEtag: "etag2"))
            }
        }
    }

    func test_ingest_storeS3Readme_withPrivateImages() async throws {
        let pkg = Package(url: "https://github.com/foo/bar".url,
                          processingStage: .reconciliation)
        try await pkg.save(on: app.db)
        let storeS3ReadmeImagesCalls = QueueIsolated(0)

        try await withDependencies {
            $0.date.now = .now
            $0.github.fetchLicense = { @Sendable _, _ in nil }
            $0.github.fetchMetadata = { @Sendable owner, repository in .mock(owner: owner, repository: repository) }
            $0.github.fetchReadme = { @Sendable _, _ in
                return .init(etag: "etag",
                             html: """
                         <html>
                         <body>
                             <img src="https://private-user-images.githubusercontent.com/with-jwt-1.jpg?jwt=some-jwt" />
                             <img src="https://private-user-images.githubusercontent.com/with-jwt-2.jpg?jwt=some-jwt" />
                             <img src="https://private-user-images.githubusercontent.com/without-jwt.jpg" />
                         </body>
                         </html>
                         """,
                             htmlUrl: "readme url",
                             imagesToCache: [
                                .init(originalUrl: "https://private-user-images.githubusercontent.com/with-jwt-1.jpg?jwt=some-jwt",
                                      s3Key: .init(bucket: "awsReadmeBucket",
                                                   path: "/foo/bar/with-jwt-1.jpg")),
                                .init(originalUrl: "https://private-user-images.githubusercontent.com/with-jwt-2.jpg?jwt=some-jwt",
                                      s3Key: .init(bucket: "awsReadmeBucket",
                                                   path: "/foo/bar/with-jwt-2.jpg"))
                             ])
            }
            $0.s3.storeReadme = { _, _, _ in "objectUrl" }
            $0.s3.storeReadmeImages = { imagesToCache in
                storeS3ReadmeImagesCalls.increment()
                XCTAssertEqual(imagesToCache.count, 2)
            }
        } operation: {
            // MUT
            try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(1))
        }

        // There should only be one call as `storeS3ReadmeImages` takes the array of images.
        XCTAssertEqual(storeS3ReadmeImagesCalls.value, 1)
    }

    func test_ingest_storeS3Readme_error() async throws {
        // Test caching behaviour in case the storeS3Readme call fails
        // setup
        let pkg = Package(url: "https://github.com/foo/bar".url, processingStage: .reconciliation)
        try await pkg.save(on: app.db)
        let storeCalls = QueueIsolated(0)

        do { // first ingestion, no readme has been saved
            try await withDependencies {
                $0.date.now = .now
                $0.github.fetchLicense = { @Sendable _, _ in nil }
                $0.github.fetchMetadata = { @Sendable owner, repository in .mock(owner: owner, repository: repository) }
                $0.github.fetchReadme = { @Sendable _, _ in
                    return .init(etag: "etag1",
                                 html: "readme html 1",
                                 htmlUrl: "readme url",
                                 imagesToCache: [])
                }
                $0.s3.storeReadme = { owner, repo, html throws(S3Readme.Error) in
                    storeCalls.increment()
                    throw .storeReadmeFailed
                }
            } operation: {
                // MUT
                let app = self.app!
                try await Ingestion.ingest(client: app.client, database: app.db, mode: .limit(1))
            }

            // validate
            let app = self.app!
            try await XCTAssertEqualAsync(await Repository.query(on: app.db).count(), 1)
            let repo = try await XCTUnwrapAsync(await Repository.query(on: app.db).first())
            XCTAssertEqual(storeCalls.value, 1)
            // Ensure an error is recorded
            XCTAssert(repo.s3Readme?.isError ?? false)
        }
    }

    func test_issue_761_no_license() async throws {
        // https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/761
        try await withDependencies {
            // use live fetch request for fetchLicense, whose behaviour we want to test ...
            $0.github.fetchLicense = GithubClient.liveValue.fetchLicense
            // use mock for metadata request which we're not interested in ...
            $0.github.fetchMetadata = { @Sendable _, _ in .init() }
            $0.github.fetchReadme = { @Sendable _, _ in nil }
            $0.github.token = { "token" }
            $0.httpClient.get = { @Sendable url, _ in
                if url.hasSuffix("/license") {
                    return .notFound
                } else {
                    XCTFail("unexpected url \(url)")
                    struct TestError: Error { }
                    throw TestError()
                }
            }
        } operation: {
            // setup
            let pkg = Package(url: "https://github.com/foo/1")
            try await pkg.save(on: app.db)

            // MUT
            let (_, license, _) = try await Ingestion.fetchMetadata(package: pkg, owner: "foo", repository: "1")

            // validate
            XCTAssertEqual(license, nil)
        }
    }

    func test_migration076_updateRepositoryResetReadmes() async throws {
        let package = Package(url: "https://example.com/owner/repo")
        try await package.save(on: app.db)
        let repository = try Repository(package: package, s3Readme: .cached(s3ObjectUrl: "object-url", githubEtag: "etag"))
        try await repository.save(on: app.db)

        // Validation that the etag exists
        let preMigrationFetchedRepo = try await XCTUnwrapAsync(try await Repository.query(on: app.db).first())
        XCTAssertEqual(preMigrationFetchedRepo.s3Readme, .cached(s3ObjectUrl: "object-url", githubEtag: "etag"))

        // MUT
        try await UpdateRepositoryResetReadmes().prepare(on: app.db)

        // Validation
        let postMigrationFetchedRepo = try await XCTUnwrapAsync(try await Repository.query(on: app.db).first())
        XCTAssertEqual(postMigrationFetchedRepo.s3Readme, .cached(s3ObjectUrl: "object-url", githubEtag: ""))
    }

    func test_getFork() async throws {
        try await Package(id: .id0, url: "https://github.com/foo/parent.git".url, processingStage: .analysis).save(on: app.db)
        try await Package(url: "https://github.com/bar/forked.git", processingStage: .analysis).save(on: app.db)

        // test lookup when package is in the index
        let fork = await Ingestion.getFork(on: app.db, parent: .init(url: "https://github.com/foo/parent.git"))
        XCTAssertEqual(fork, .parentId(id: .id0, fallbackURL: "https://github.com/foo/parent.git"))

        // test lookup when package is in the index but with different case in URL
        let fork2 = await Ingestion.getFork(on: app.db, parent: .init(url: "https://github.com/Foo/Parent.git"))
        XCTAssertEqual(fork2, .parentId(id: .id0, fallbackURL: "https://github.com/Foo/Parent.git"))

        // test whem metadata repo url doesn't have `.git` at end
        let fork3 = await Ingestion.getFork(on: app.db, parent: .init(url: "https://github.com/Foo/Parent"))
        XCTAssertEqual(fork3, .parentId(id: .id0, fallbackURL: "https://github.com/Foo/Parent.git"))

        // test lookup when package is not in the index
        let fork4 = await Ingestion.getFork(on: app.db, parent: .init(url: "https://github.com/some/other.git"))
        XCTAssertEqual(fork4, .parentURL("https://github.com/some/other.git"))

        // test lookup when parent url is nil
        let fork5 = await Ingestion.getFork(on: app.db, parent: nil)
        XCTAssertEqual(fork5, nil)
    }
}


private extension String {
    static func packageDump(name: String) -> Self {
        #"""
            {
              "name": "\#(name)",
              "products": [
                {
                  "name": "p1",
                  "targets": [],
                  "type": {
                    "executable": null
                  }
                }
              ],
              "targets": []
            }
            """#
    }
}
