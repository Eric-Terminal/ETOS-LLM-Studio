# Repository Guidelines

## Project Structure & Module Organization
- `ETOS LLM Studio iOS App/` contains the iPhone interface and app-specific assets, while `ETOS LLM Studio Watch App/` mirrors the watchOS UI.
- The shared business layer lives in `Shared/Shared/`, including adapters (`APIAdapter.swift`), memory tooling, and similarity search utilities; keep cross-platform logic here.
- Tests reside in `Shared/SharedTests/SharedTests.swift`, exercising the shared module; add new suites alongside related features.
- Static media sits in `assets/`; screenshots under `assets/screenshots/` should be exported at 3x scale to match existing images.

## Build, Test, and Development Commands
- `xcodebuild -workspace "ETOS LLM Studio.xcworkspace" -scheme "ETOS LLM Studio iOS App" -destination 'platform=iOS Simulator,name=iPhone 15' build` – verify the iOS target builds cleanly.
- `xcodebuild -workspace "ETOS LLM Studio.xcworkspace" -scheme "ETOS LLM Studio Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' build` – confirm the watchOS target.
- `xcodebuild -workspace "ETOS LLM Studio.xcworkspace" -scheme "Shared" test -destination 'platform=iOS Simulator,name=iPhone 15'` – run the shared XCTest suite; share schemes before invoking CI.
- Development flows faster inside Xcode; enable the scheme’s “Use Run Destination” option so the RAG memory files under `Documents/Providers` initialize properly in the simulator.

## Coding Style & Naming Conventions
- Adopt Swift 5 defaults: four-space indentation, 120-character soft wrap, and trailing commas in multi-line literals.
- Prefer `struct` + `ObservableObject` for state, pair with `@MainActor` on async UI-facing APIs, and mirror existing naming (`MemoryManager`, `SimilarityIndex`) when adding collaborators.
- Organize extensions by feature with `// MARK:` separators; keep files under 500 lines by factoring helper types into `Shared/SimilaritySearch/`.

## Testing Guidelines
- NUnit-style naming is discouraged; follow XCTest conventions (`testFeatureScenario`) and align fixtures with the `Shared` module’s namespaces.
- Seed memory indices via `MemoryManager` helpers instead of writing raw JSON; this keeps embedding tests deterministic.
- Target ≥80% coverage on new shared components; document intentional gaps in the PR description.

## Commit & Pull Request Guidelines
- Follow the repository’s conventional commits (`feat:`, `docs:`, `refactor:`); include short context in English, optionally adding concise Chinese detail where user-facing strings change.
- One logical change per commit; note schema migrations or data format bumps (e.g., provider JSON) in body text.
- Pull requests should link the corresponding roadmap item, describe simulator steps, and attach updated screenshots when UI is affected (iPhone + watchOS).

## Security & Configuration Tips
- Never hardcode provider credentials; rely on the in-app “模型设置” forms and ensure new adapters write encrypted payloads to the sandboxed `Documents` directory.
- When debugging network flows, prefer the `URLSession` “Protocol Logging” toggle inside the scheme instead of adding temporary print statements to adapters.
