import Foundation

nonisolated struct UpdateChecker: Sendable {
    private let releasesURL = URL(string: "https://api.github.com/repos/leibnizli/DeepClean/releases/latest")!

    func checkForNewVersion(completion: @escaping (String) -> Void) {
        URLSession.shared.dataTask(with: releasesURL) { data, _, error in
            guard let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tagName = json["tag_name"] as? String,
                   let htmlURL = json["html_url"] as? String {
                    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    let latestVersion = tagName.replacingOccurrences(of: "v", with: "")
                    let currentVersionClean = currentVersion.replacingOccurrences(of: "v", with: "")

                    if latestVersion.compare(currentVersionClean, options: .numeric) == .orderedDescending {
                        completion(htmlURL)
                    }
                }
            } catch {
                print("Error parsing update info: \(error)")
            }
        }.resume()
    }
}
