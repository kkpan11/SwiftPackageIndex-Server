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

import Dependencies
import Vapor


enum Gitlab {

    static let baseURL = "https://gitlab.com/api/v4"

    enum Error: LocalizedError {
        case missingConfiguration(String)
        case missingToken
        case requestFailed(HTTPStatus, URI)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .formatted(DateFormatter.iso8601Full)
        return d
    }()

}


// MARK: - Build specific constants


extension Gitlab {

    enum Builder {
        /// swiftpackageindex-builder project id
        static let projectId = 19564054
        static var projectURL: String { "\(Gitlab.baseURL)/projects/\(projectId)" }
    }

}


// MARK: - Builder pipeline triggers


extension Gitlab.Builder {

#if DEBUG
    nonisolated(unsafe) static var branch = "main"
#else
    static let branch = "main"
#endif

    struct Response: Content, Codable {
        var webUrl: String

        enum CodingKeys: String, CodingKey {
            case webUrl = "web_url"
        }
    }

    static func triggerBuild(client: Client,
                             buildId: Build.Id,
                             cloneURL: String,
                             isDocBuild: Bool,
                             platform: Build.Platform,
                             reference: Reference,
                             swiftVersion: SwiftVersion,
                             versionID: Version.Id) async throws -> Build.TriggerResponse {
        @Dependency(\.environment) var environment

        guard let pipelineToken = Current.gitlabPipelineToken(),
              let builderToken = environment.builderToken()
        else { throw Gitlab.Error.missingToken }
        guard let awsDocsBucket = environment.awsDocsBucket() else {
            throw Gitlab.Error.missingConfiguration("AWS_DOCS_BUCKET")
        }
        let timeout = environment.buildTimeout() + (isDocBuild ? 5 : 0)

        let uri: URI = .init(string: "\(projectURL)/trigger/pipeline")
        let response = try await client
            .post(uri) { req in
                let data = PostDTO(
                    token: pipelineToken,
                    ref: branch,
                    variables: [
                        "API_BASEURL": SiteURL.apiBaseURL,
                        "AWS_DOCS_BUCKET": awsDocsBucket,
                        "BUILD_ID": buildId.uuidString,
                        "BUILD_PLATFORM": platform.rawValue,
                        "BUILDER_TOKEN": builderToken,
                        "CLONE_URL": cloneURL,
                        "REFERENCE": "\(reference)",
                        "SWIFT_VERSION": "\(swiftVersion.major).\(swiftVersion.minor)",
                        "TIMEOUT": "\(timeout)m",
                        "VERSION_ID": versionID.uuidString
                    ])
                try req.query.encode(data)
            }
        do {
            let res = Build.TriggerResponse(
                status: response.status,
                webUrl: try response.content.decode(Response.self).webUrl
            )
            Current.logger().info("Triggered build: \(res.webUrl)")
            return res
        } catch {
            let body = response.body?.asString() ?? "nil"
            Current.logger().error("Trigger failed: \(cloneURL) @ \(reference), \(platform) / \(swiftVersion), \(versionID), status: \(response.status), body: \(body)")
            return .init(status: response.status, webUrl: nil)
        }
    }

    struct PostDTO: Codable, Equatable {
        var token: String
        var ref: String
        var variables: [String: String]
    }

}


// MARK: - Builder pipeline queries


extension Gitlab.Builder {

    enum Status: String, Decodable {
        case canceled
        case created
        case failed
        case manual
        case pending
        case running
        case skipped
        case success
    }

    // periphery:ignore
    struct Pipeline: Decodable {
        var id: Int
        var status: Status
    }

    // https://docs.gitlab.com/ee/api/pipelines.html
    static func fetchPipelines(client: Client,
                               status: Status,
                               page: Int,
                               pageSize: Int = 20) async throws -> [Pipeline] {
        guard let apiToken = Current.gitlabApiToken() else { throw Gitlab.Error.missingToken }

        let uri: URI = .init(string: "\(projectURL)/pipelines?status=\(status)&page=\(page)&per_page=\(pageSize)")
        let response = try await client.get(uri, headers: HTTPHeaders([("Authorization", "Bearer \(apiToken)")]))

        guard response.status == .ok else { throw Gitlab.Error.requestFailed(response.status, uri) }

        return try response.content.decode([Pipeline].self, using: Gitlab.decoder)
    }

    static func getStatusCount(client: Client,
                               status: Status,
                               page: Int = 1,
                               pageSize: Int = 20,
                               maxPageCount: Int = 5) async throws -> Int {
        let count = try await fetchPipelines(client: client, status: status, page: page, pageSize: pageSize).count
        if count == pageSize && page < maxPageCount {
            let statusCount = try await getStatusCount(client: client,
                                                       status: status,
                                                       page: page + 1,
                                                       pageSize: pageSize,
                                                       maxPageCount: maxPageCount)
            return count + statusCount
        } else {
            return count
        }
    }

}


private extension DateFormatter {
    static var iso8601Full: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
