# Distribution

AnemllAgentHost currently targets direct development or Developer ID distribution. Its automation and skill-sync features require Screen Recording, Accessibility, synthetic input, local HTTP serving, process restart, and writes to user tool directories. The Xcode target therefore intentionally has App Sandbox disabled.

Do not submit this target to the Mac App Store as-is: Mac App Store apps must use App Sandbox, and enabling it without redesigning these capabilities would make the documented behavior unreliable or unavailable.

For release builds:

1. Use the Release configuration and Swift 6.
2. Sign with a Developer ID Application certificate.
3. Enable the hardened runtime (already configured).
4. Notarize and staple the final app.
5. Verify Accessibility and Screen Recording onboarding using the exact signed artifact.
6. Keep the listener loopback-only and preserve bearer-header authentication.

`APP_STORE_DESCRIPTION.txt` is marketing copy only. A future App Store edition should be a separate, sandboxed target with a reduced capability set and separate QA plan.
