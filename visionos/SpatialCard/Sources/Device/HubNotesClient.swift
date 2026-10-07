import Foundation

/// The hub's REST half (工作包 D): the ten recent notes and their covers.
///
/// The `/vp` WebSocket only ever carries a **hint** (`{"t":"notes","rev":N}`) because one line there is capped
/// at 512 bytes; the list itself is pulled over HTTP from the same host, and the covers come through the hub's
/// proxy (the CDN refuses a request without a Referer, and the headset must not talk to it directly).
///
/// Everything goes through `URLSession.shared`, whose `URLCache` is the one `AsyncImage` reads: prefetching a
/// cover here is what makes the cards show their picture the moment they fan out. Console prefix `[notes]`.
@MainActor
final class HubNotesClient {
    /// `http://<host>:<port>` — the `/vp` URL with `ws` → `http` and the path dropped.
    let origin: URL
    static let timeout: TimeInterval = 6

    /// nil when the `/vp` URL has no usable host (there is no REST endpoint to ask, e.g. `--fake-hub`).
    init?(hubURL: URL) {
        guard var components = URLComponents(url: hubURL, resolvingAgainstBaseURL: false), let host = components.host else { return nil }
        components.scheme = hubURL.scheme == "wss" ? "https" : "http"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return nil }
        self.origin = origin
        print("[notes] hub REST origin \(origin.absoluteString) (host \(host))")
    }

    /// `GET /api/notes?limit=10`. Never cached: the point of the call is that the list changed.
    func fetch(limit: Int = RecentNotesPayload.limit) async -> RecentNotesPayload? {
        guard var components = URLComponents(url: origin.appendingPathComponent("api/notes"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(RecentNotesPayload.limit, limit))))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: HubNotesClient.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[notes] GET /api/notes → \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let payload = RecentNotesPayload.decode(data) else {
                print("[notes] /api/notes answered something that is not a notes payload")
                return nil
            }
            return payload
        } catch {
            print("[notes] GET /api/notes failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The absolute URL of a note's cover: the hub hands out a **relative** path on purpose.
    func coverURL(for note: RecentNote) -> URL? {
        guard let path = note.coverURL, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return URL(string: path, relativeTo: origin)?.absoluteURL
    }

    /// Warm `URLCache.shared` with the covers, so the cards are not ten grey rectangles when the fan opens.
    /// Sequential and best-effort: a 502 from the proxy is negative-cached for 10 minutes upstream, and
    /// hammering it would only cost the fan its first second.
    func prefetchCovers(_ notes: [RecentNote]) async {
        let urls = notes.compactMap { coverURL(for: $0) }
        guard !urls.isEmpty else { return }
        let started = Date()
        var loaded = 0
        for url in urls {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: HubNotesClient.timeout)
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { loaded += 1 }
        }
        print(String(format: "[notes] prefetched %d/%d covers in %.1f s", loaded, urls.count, Date().timeIntervalSince(started)))
    }
}
