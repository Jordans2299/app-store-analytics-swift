# AppStoreAnalytics Swift SDK

An open-source, first-party analytics SDK for iOS 15+ and macOS 12+. It tracks a random per-installation identifier, process-level sessions, app/OS versions, and explicit product events. It does not access IDFA, account identity, location, device model, or cross-app identifiers.

```swift
import AppStoreAnalytics

AppStoreAnalytics.configure(
    projectKey: "asa_your_public_project_key",
    configuration: AnalyticsConfiguration()
)

AppStoreAnalytics.track("onboarding_completed")
AppStoreAnalytics.track("first_model_run", properties: ["model_family": .string("local")])
```

Collection starts after `configure`. To gate analytics on an app-specific consent choice, initialize with `collectionEnabled: false`, then call `setCollectionEnabled(true)`.

Event names must be lowercase snake case, properties are limited to 25 Boolean/number/string values, and common personal-data keys are rejected. The package includes a privacy manifest, but each integrating developer must review their complete app disclosure.

