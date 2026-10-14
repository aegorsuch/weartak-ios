import Foundation

@main
struct DittoTrackChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let uid = "0f8e8f0c-3b7a-4f6e-9a39-6f1a1d2b3c4d"
        let detail = #"<detail><contact callsign="ODIN-2" endpoint="*:-1:stcp"/><__group name="Cyan" role="Team Member"/><track speed="1.5" course="90"/></detail>"#
        let xml = #"<event version="2.0" uid="\#(uid)" type="a-f-G-U-C" time="2023-11-14T22:13:20Z" start="2023-11-14T22:13:20Z" stale="2023-11-14T22:16:20Z" how="m-g"><point lat="38.8977" lon="-77.0365" hae="12.5" ce="4.5" le="9999999"/>\#(detail)</event>"#
        guard let document = DittoTrackDocument.make(fromPLI: xml, peerKey: "peer-1", appVersion: "2.0", now: now) else {
            fatalError("Valid self PLI was rejected")
        }
        precondition(document["_id"] as? String == uid)
        precondition(document["AuthorId"] as? String == uid && document["d"] as? String == uid)
        precondition(document["_r"] as? Bool == false && document["_v"] as? Int == 2)
        for key in ["authorCs", "c", "e"] { precondition(document[key] as? String == "ODIN-2") }
        precondition(document["authorType"] as? String == "a-f-G-U-C" && document["w"] as? String == "a-f-G-U-C")
        precondition(document["visible"] as? Bool == true && document["f"] as? Bool == true)
        precondition(document["a"] as? String == "peer-1" && document["g"] as? String == "2.0")
        precondition(document["b"] as? Int == 1_700_000_000_000 && document["n"] as? Int == 1_700_000_000_000)
        precondition(document["o"] as? Int == 1_700_000_180_000)
        precondition(document["j"] as? Double == 38.8977 && document["l"] as? Double == -77.0365)
        precondition(document["h"] as? Double == 4.5 && document["k"] as? Double == 9_999_999)
        precondition(document["i"] as? Double == 12.5 && document["r2"] as? String == "12.5")
        precondition(document["r1"] as? String == "1.5")
        precondition(document["p"] as? String == "m-g" && document["q"] as? String == "Undefined")
        precondition(document["r"] as? String == detail)
        precondition(document.count == 27)

        let unknownHeight = xml.replacingOccurrences(of: #"hae="12.5""#, with: #"hae="9999999""#)
            .replacingOccurrences(of: #"ce="4.5""#, with: #"ce="-1""#)
        let fallback = DittoTrackDocument.make(fromPLI: unknownHeight, peerKey: "p", appVersion: "1", now: now)
        precondition(fallback?["i"] as? Double == 9_999_999 && fallback?["h"] as? Double == 9_999_999)

        let marker = xml.replacingOccurrences(of: #"type="a-f-G-U-C""#, with: #"type="a-h-G""#)
        precondition(DittoTrackDocument.make(fromPLI: marker, peerKey: "p", appVersion: "1", now: now) == nil)
        let expired = DittoTrackDocument.make(fromPLI: xml, peerKey: "p", appVersion: "1",
                                              now: now.addingTimeInterval(600))
        precondition(expired == nil)
        let badPoint = xml.replacingOccurrences(of: #"lat="38.8977""#, with: #"lat="91""#)
        precondition(DittoTrackDocument.make(fromPLI: badPoint, peerKey: "p", appVersion: "1", now: now) == nil)
        precondition(DittoTrackDocument.make(fromPLI: "<!DOCTYPE x><event/>", peerKey: "p", appVersion: "1") == nil)
        precondition(DittoTrackDocument.make(fromPLI: "<message/>", peerKey: "p", appVersion: "1") == nil)
        precondition(DittoTrackDocument.detail(in: "<event/>") == "<detail/>")
        print("Ditto track checks passed")
    }
}
