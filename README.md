# AppStoreAnalytics Swift SDK

An open-source, first-party analytics SDK for iOS 15+ and macOS 12+. It tracks a random per-installation identifier, sessions, app/OS versions, and explicit product events. It does not access IDFA, account identity, location, device model, or cross-app identifiers.

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

A session is one period of use. It ends after `sessionTimeout` (30 minutes by default) passes with no activity, not every time the app leaves the foreground. A trip to Control Centre, a notification banner, an app-switcher peek, or a relaunch inside the timeout all continue the session they interrupted. The session is stored, so it survives the app being killed. `session_ended` is therefore sent when the *next* launch or foreground finds the previous session expired: it is timestamped at the last activity that session saw, and its `duration_seconds` counts only foreground time. An installation that never comes back has no `session_ended`, which is why the dashboard reports started and completed sessions separately.

Event names must be lowercase snake case, properties are limited to 25 Boolean/number/string values, and common personal-data keys are rejected. The package includes a privacy manifest, but each integrating developer must review their complete app disclosure.
