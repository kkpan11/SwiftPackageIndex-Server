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

import Foundation

import VaporToOpenAPI
import DependencyResolution
import PackageCollectionsSigning


// MARK: - External types

extension Date: VaporToOpenAPI.WithExample {
    public static var example: Self { .init(rfc1123: "Sat, 25 Apr 2020 10:55:00 UTC")! }
}


// MARK: - Internal types

extension Badge: WithExample {
    static var example: Self { .init(significantBuilds: .example, badgeType: .platforms)}
}


extension API.PackageController.BadgeQuery: WithExample {
    static var example: Self { .init(type: .platforms) }
}


extension API.SearchController.Query: WithExample {
    static var example: Self { .init(query: "LinkedList") }
}


extension Search.Result: WithExample {
    static var example: Self {
        .package(
            .init(packageId: .example,
                  packageName: "LinkedList",
                  packageURL: "https://github.com/mona/LinkedList.git",
                  repositoryName: "LinkedList",
                  repositoryOwner: "mona",
                  stars: 123,
                  lastActivityAt: .example,
                  summary: "An example package",
                  keywords: [],
                  hasDocs: true)!
        )
    }
}


extension Search.Response: WithExample {
    static var example: Self {
        .init(hasMoreResults: false,
              searchTerm: "LinkedList",
              searchFilters: [.example],
              results: [.example])
    }
}


extension SearchFilter.ViewModel: WithExample {
    static var example: Self {
        .init(key: "author", operator: "is", value: "mona")
    }
}


extension SignificantBuilds: WithExample {
    static var example: Self {
        .init(buildInfo: [
            (.v5_8, Build.Platform.iOS, .ok)
        ])
    }
}


// MARK: - Package collection types

import PackageCollectionsModel


extension API.PostPackageCollectionDTO: WithExample {
    static var example: Self {
        .init(selection: .packageURLs(["https://github.com/mona/LinkedList.git"]),
              collectionName: "LinkedList collection",
              overview: "This is a package collection created for demonstration purposes.",
              revision: 3)
    }
}

extension PackageCollectionModel.V1.Collection: VaporToOpenAPI.WithExample {
    public static var example: Self {
        .init(name: "Packages by mona",
              overview: "A collection of packages authored by mona from the Swift Package Index",
              keywords: nil, packages: [
                .init(url: URL(string: "https://github.com/mona/LinkedList.git")!,
                      summary: "An example package",
                      keywords: nil,
                      versions: [],
                      readmeURL: URL(string: "https://github.com/mona/LinkedList/blob/main/README.md")!,
                      license: .init(name: "MIT",
                                     url: URL(string: "https://github.com/mona/LinkedList/blob/main/LICENSE")!))
              ],
              formatVersion: .v1_0,
              revision: nil,
              generatedBy: .init(name: "mona"))
    }
}

extension PackageCollectionModel.V1.Signature.Certificate: VaporToOpenAPI.WithExample {
    public static var example: Self {
        .init(subject: .init(userID: "V676TFACYJ",
                             commonName: "Swift Package Collection: SPI Operations Limited",
                             organizationalUnit: "V676TFACYJ",
                             organization: "SPI Operations Limited"),
              issuer: .init(userID: nil,
                            commonName: "Apple Worldwide Developer Relations Certification Authority",
                            organizationalUnit: "G3",
                            organization: "Apple Inc."))
    }
}

extension PackageCollectionModel.V1.Signature: VaporToOpenAPI.WithExample {
    public static var example: Self {
        .init(signature: "ewogICJhbGciIDogIlJ...<snip>...WD1pXXPrkvVJlv4w", certificate: .example)
    }
}

extension PackageCollectionSigning.Model.SignedCollection: VaporToOpenAPI.WithExample {
    public static var example: Self {
        .init(collection: .example, signature: .example)
    }
}


// MARK: - Package API

extension API.PackageController.GetRoute.Model.Activity: WithExample {
    static var example: Self {
        .init(
            openIssuesCount: 2,
            openIssuesURL: "https://github.com/mona/LinkedList/issues",
            openPullRequestsCount: 1,
            openPullRequestsURL: "https://github.com/mona/LinkedList/pulls",
            lastIssueClosedAt: .example,
            lastPullRequestClosedAt: .example
        )
    }
}


extension API.PackageController.GetRoute.Model.History: WithExample {
    static var example: Self {
        .init(createdAt: .example,
              commitCount: 433,
              commitCountURL: "https://github.com/mona/LinkedList/commits/main",
              releaseCount: 5,
              releaseCountURL: "https://github.com/mona/LinkedList/releases")
    }
}


extension API.PackageController.GetRoute.Model: WithExample {
    static var example: Self {
        .init(packageId: .example,
              repositoryOwner: "mona",
              repositoryOwnerName: "Mona",
              repositoryName: "LinkedList",
              activity: .example,
              authors: .fromSPIManifest("Mona"),
              swiftVersionBuildInfo: .init(
                stable: .init(
                    referenceName: "1.2.3",
                    results: .init(results: [.v5_8: .incompatible,
                                             .v5_9: .incompatible,
                                             .v5_10: .unknown,
                                             .v6_0: .compatible])),
                beta: .init(
                    referenceName: "2.0.0-b1",
                    results: .init(results: [.v5_8: .incompatible,
                                             .v5_9: .incompatible,
                                             .v5_10: .unknown,
                                             .v6_0: .compatible])),
                latest: .init(
                    referenceName: "main",
                    results: .init(results: [.v5_8: .incompatible,
                                             .v5_9: .incompatible,
                                             .v5_10: .unknown,
                                             .v6_0: .compatible]))
              ),
              platformBuildInfo: .init(
                stable: .init(
                    referenceName: "1.2.3",
                    results: .init(results: [.iOS: .compatible,
                                             .linux: .unknown,
                                             .macOS: .unknown,
                                             .tvOS: .unknown,
                                             .visionOS: .unknown,
                                             .watchOS: .unknown])),
                beta: .init(
                    referenceName: "2.0.0-b1",
                    results: .init(results: [.iOS: .compatible,
                                             .linux: .unknown,
                                             .macOS: .unknown,
                                             .tvOS: .unknown,
                                             .visionOS: .unknown,
                                             .watchOS: .unknown])),
                latest: .init(
                    referenceName: "main",
                    results: .init(results: [.iOS: .compatible,
                                             .linux: .compatible,
                                             .macOS: .compatible,
                                             .tvOS: .compatible,
                                             .visionOS: .compatible,
                                             .watchOS: .compatible]))
              ),
              history: .example,
              license: .mit,
              products: [.init(name: "lib", type: .library)],
              releases: .init(
                stable: .init(date: .example,
                              link: .init(label: "1.2.3",
                                          url: "https://github.com/mona/LinkedList/releases/tag/1.2.3")),
                latest: .init(date: .example,
                              link: .init(label: "main",
                                          url: "https://github.com/mona/LinkedList/tree/main"))),
              dependencies: nil,
              stars: 123,
              summary: "An example package",
              targets: [.init(name: "target", type: .macro)],
              title: "LinkedList",
              url: "https://github.com/mona/LinkedList.git",
              isArchived: false,
              defaultBranchReference: .branch("main"),
              releaseReference: .tag(1, 2, 3, "1.2.3"),
              preReleaseReference: nil,
              swift6Readiness: nil, 
              forkedFromInfo: nil,
              customCollections: [])
    }
}


// MARK: - Build/doc reporting types

extension API.PostBuildReportDTO: WithExample {
    static var example: Self {
        .init(builderVersion: "1.2.3",
              buildId: .example,
              platform: .iOS,
              productDependencies: [
                  ProductDependency(identity: "1",
                                    name: "name",
                                    url: "http://vapor.com",
                                    dependencies: [])
              ],
              status: .ok,
              swiftVersion: .v5_8)
    }
}

extension API.PostDocReportDTO: WithExample {
    static var example: Self {
        .init(docArchives: [.init(name: "linkedlist", title: "LinkedList")],
              error: nil,
              fileCount: 2639,
              linkablePathsCount: 137,
              logUrl: "https://us-east-2.console.aws.amazon.com/logs/123456678",
              mbSize: 23,
              status: .ok)
    }
}


// MARK: - Dependency types

extension API.DependencyController.PackageRecord: WithExample {
    static var example: Self {
        .init(id: .example,
              url: .init("https://github.com/foo/bar")!,
              resolvedDependencies: [.init("https://github.com/foo/dependency")!])
    }
}
