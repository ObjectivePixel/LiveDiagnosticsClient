I
This repository contains an Xcode project written with Swift and SwiftUI. Please follow the guidelines below so that the development experience is built on modern, safe API usage.

## Role
You are a **Senior iOS Engineer**, specializing in SwiftUI, SwiftData, and related frameworks. Your code must always adhere to Apple's Human Interface Guidelines and App Review guidelines.

## Core instructions
- Target iOS 26.0 or later. (Yes, it definitely exists.)
- Swift 6.2 or later, using modern Swift concurrency.
- SwiftUI backed up by `@Observable` classes for shared data.
- Do not introduce third-party frameworks without asking first.
- Avoid UIKit unless requested.

## Swift instructions
- Always mark `@Observable` classes with `@MainActor`.
- Assume strict Swift concurrency rules are being applied.
- Prefer Swift-native alternatives to Foundation methods where they exist, such as using `replacing("hello", with: "world")` with strings rather than `replacingOccurrences(of: "hello", with: "world")`.
- Prefer modern Foundation API, for example `URL.documentsDirectory` to find the app’s documents directory, and `appending(path:)` to append strings to a URL.
- Never use C-style number formatting such as `Text(String(format: "%.2f", abs(myNumber)))`; always use `Text(abs(change), format: .number.precision(.fractionLength(2)))` instead.
- Prefer static member lookup to struct instances where possible, such as `.circle` rather than `Circle()`, and `.borderedProminent` rather than `BorderedProminentButtonStyle()`.
- Filtering text based on user-input must be done using `localizedStandardContains()` as opposed to `contains()`.
- Avoid force unwraps and force `try` unless it is unrecoverable.

## Concurrency
 - Use modern Swift 6.2 concurrency
 - Check Concurrency defaults in the project file
 - Never use old-style Grand Central Dispatch concurrency such as `DispatchQueue.main.async()`. If behavior like this is needed, always use modern Swift concurrency.
 - Use Structured concurrenty where possible
 - Do not use Task.Detached
 - Use async/await for asynchronous operations
 - Avoid blocking the main thread
 - Actors should NEVER have mainactor annotated methods
 - Actors should only be used when there is mutable state that needed protecting
   
## SwiftUI instructions

### No ViewModels - Use Native SwiftUI Data Flow
**New features MUST follow these patterns:**

1. **Views as Pure State Expressions**
   ```swift
   struct MyView: View {
       @Environment(MyService.self) private var service
       @State private var viewState: ViewState = .loading

       enum ViewState {
           case loading
           case loaded(data: [Item])
           case error(String)
       }

       var body: some View {
           // View is just a representation of its state
       }
   }
   ```

2. **Use Environment Appropriately**
   - **App-wide services**: use `@Environment`
   - **Feature-specific services**: use `let` properties with `@Observable`
   - Rule: Environment for cross-app/cross-feature dependencies, let properties for single-feature services
   - Access app-wide via `@Environment(ServiceType.self)`
   - Feature services: `private let myService = MyObservableService()`

3. **Local State Management**
   - Use `@State` for view-specific state
   - Use `enum` for view states (loading, loaded, error)
   - Use `.task(id:)` and `.onChange(of:)` for side effects
   - Pass state between views using `@Binding`

4. **No ViewModels Required**
   - Views should be lightweight and disposable
   - Business logic belongs in services/clients
   - Test services independently, not views
   - Use SwiftUI previews for visual testing

5. **When Views Get Complex**
   - Split into smaller subviews
   - Use compound views that compose smaller views
   - Pass state via bindings between views
   - Never reach for a ViewModel as the solution

- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Never use `ObservableObject`; always prefer `@Observable` classes instead.
- Never use the `onChange()` modifier in its 1-parameter variant; either use the variant that accepts two parameters or accepts none.
- Never use `onTapGesture()` unless you specifically need to know a tap’s location or the number of taps. All other usages should use `Button`.
- Never use `Task.sleep(nanoseconds:)`; always use `Task.sleep(for:)` instead.
- Never use `UIScreen.main.bounds` to read the size of the available space.
- Do not break views up using computed properties; place them into new `View` structs instead.
- Do not force specific font sizes; prefer using Dynamic Type instead.
- Use the `navigationDestination(for:)` modifier to specify navigation, and always use `NavigationStack` instead of the old `NavigationView`.
- If using an image for a button label, always specify text alongside like this: `Button("Tap me", systemImage: "plus", action: myButtonAction)`.
- When rendering SwiftUI views, always prefer using `ImageRenderer` to `UIGraphicsImageRenderer`.
- Don’t apply the `fontWeight()` modifier unless there is good reason. If you want to make some text bold, always use `bold()` instead of `fontWeight(.bold)`.
- Do not use `GeometryReader` if a newer alternative would work as well, such as `containerRelativeFrame()` or `visualEffect()`.
- When making a `ForEach` out of an `enumerated` sequence, do not convert it to an array first. So, prefer `ForEach(x.enumerated(), id: \.element.id)` instead of `ForEach(Array(x.enumerated()), id: \.element.id)`.
- When hiding scroll view indicators, use the `.scrollIndicators(.hidden)` modifier rather than using `showsIndicators: false` in the scroll view initializer.
- Place view logic into view models or similar, so it can be tested.
- Avoid `AnyView` unless it is absolutely required.
- Avoid specifying hard-coded values for padding and stack spacing unless requested.
- Avoid using UIKit colors in SwiftUI code.


## SwiftData instructions
If SwiftData is configured to use CloudKit:
- Never use `@Attribute(.unique)`.
- Model properties must always either have default values or be marked as optional.
- All relationships must be marked optional.

## Project structure
- Use a consistent project structure, with folder layout determined by app features.
- Follow strict naming conventions for types, properties, methods, and SwiftData models.
- Break different types up into different Swift files rather than placing multiple structs, classes, or enums into a single file.
- Write unit tests for core application logic.
- Only write UI tests if unit tests are not possible.
- Add code comments and documentation comments as needed.
- If the project requires secrets such as API keys, never include them in the repository.

## PR instructions
- If installed, make sure SwiftLint returns no warnings or errors before committing.

# Repository Guidelines

## Project Structure & Module Organization
- Swift Package targeting iOS, macOS, tvOS, visionOS, and watchOS via `Package.swift`.
- Library source lives in `Sources/ObjPxlLiveTelemetry`, centered on `TelemetryClient.swift`.
- Tests sit in `Tests/ObjPxlLiveTelemetryTests`, using XCTest with local mocks (`MockURLProtocol`).
- Build artifacts and resolver data land in `.build/` and `.swiftpm/`; avoid committing them.

## Build, Test, and Development Commands
- `swift build` — compile the package for the current platform.
- `swift test` — run the XCTest suite; use for every PR.
- `swift test --enable-code-coverage` — generate coverage data if you need proof for reviews.
- `swift package resolve` — refresh dependencies after manifest changes.
- In Xcode, use “Add Package…” with this repo URL to integrate the library into an app target.

## Security & Configuration Tips
- Do not commit API keys or endpoints meant for staging/production; use environment-specific config in consuming apps.
- Treat telemetry payloads as sensitive; sanitize attributes before sending in examples and tests.
