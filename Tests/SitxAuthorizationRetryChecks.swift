import Foundation

@main
struct SitxAuthorizationRetryChecks {
    static func main() {
        let transient: [URLError.Code] = [
            .networkConnectionLost, .timedOut, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
        ]
        for code in transient {
            var retry = SitxAuthorizationRetry()
            precondition(retry.delay(for: URLError(code), pollingInterval: 1) == 5)
            precondition(retry.delay(for: URLError(code), pollingInterval: 1) == 10)
            precondition(retry.delay(for: URLError(code), pollingInterval: 1) == 20)
            precondition(retry.delay(for: URLError(code), pollingInterval: 1) == nil)
            precondition(retry.retries == 3)
        }
        print("PASS: transient failures get exactly three retries with 5/10/20-second backoff")

        var retry = SitxAuthorizationRetry()
        precondition(retry.delay(for: URLError(.networkConnectionLost), pollingInterval: 30) == 30)
        precondition(retry.delay(for: URLError(.timedOut), pollingInterval: 40) == 40)
        precondition(retry.delay(for: URLError(.notConnectedToInternet), pollingInterval: 45) == 45)
        precondition(retry.delay(for: URLError(.dnsLookupFailed), pollingInterval: 45) == nil)
        print("PASS: server polling interval is respected and mixed errors share one retry budget")

        enum Rejection: Error { case denied }
        for error: Error in [
            URLError(.cancelled), URLError(.secureConnectionFailed),
            URLError(.serverCertificateUntrusted), URLError(.badServerResponse),
            Rejection.denied, CancellationError()
        ] {
            var retry = SitxAuthorizationRetry()
            precondition(retry.delay(for: error, pollingInterval: 1) == nil)
            precondition(retry.retries == 0)
            precondition(retry.delay(for: URLError(.networkConnectionLost), pollingInterval: 1) == 5)
        }
        let failure = "Sit(x) token exchange network error -1005 (connection lost)"
        precondition(SitxAuthorizationRetry.status(failure) == "Retrying authorization: " + failure)
        print("PASS: cancellation, TLS, HTTP and definitive errors are not retried; retry status retains the failure")
    }
}
