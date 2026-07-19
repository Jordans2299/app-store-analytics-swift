# AppStoreAnalytics Swift SDK

An open-source, first-party analytics SDK for iOS 15+ and macOS 12+. It tracks a random per-installation identifier, process-level sessions, app/OS versions, and explicit product events. It does not access IDFA, account identity, location, device model, or cross-app identifiers.

```swift
import AppStoreAnalytics

AppStoreAnalytics.configure(
    projectKey: "asa_your_public_project_key",
    configuration: AnalyticsConfiguration(
        endpoint: URL(string: "https://analytics-api.example.com/v1")!
    )
)

AppStoreAnalytics.track("onboarding_completed")
AppStoreAnalytics.track("first_model_run", properties: ["model_family": .string("local")])
```

Collection starts after `configure`. To gate analytics on an app-specific consent choice, initialize with `collectionEnabled: false`, then call `setCollectionEnabled(true)`.

Use a different project key for Development, TestFlight, and Production builds. Select the key through Xcode build configuration so local activity and beta testing never affect production activation or retention. The installation identifier and local queue are project-key-specific.

The SDK queues events offline, retries failed uploads with exponential backoff and jitter, and flushes when the app backgrounds. Calling `setCollectionEnabled(false)` deletes queued events immediately.

Event names must be lowercase snake case, properties are limited to 25 Boolean/number/string values, and common personal-data keys are rejected. The package includes a privacy manifest, but each integrating developer must review their complete app disclosure.
