# App Review Notes — Local Linux and Agent Runtime

ETOS LLM Studio includes an optional local Linux userland for user-directed terminal, MCP, and AI Agent tasks on iPhone and Apple Watch.

## Bundled runtime

- The submitted app bundle contains a fixed, versioned AArch64 Alpine Linux RootFS archive. Enabling the setting does not download a replacement operating system.
- The RootFS is installed into the app sandbox only after the user explicitly starts an Agent task, interactive terminal, local MCP server, or reviewed installation recipe.
- Linux ELF files are interpreted through the bundled iSH guest ABI and instruction emulation layer. They cannot be launched as native iOS or watchOS executables.
- Guest processes remain inside the app sandbox. They do not gain access to native platform APIs, Keychain, HealthKit, Photos, other apps, or arbitrary device files.

## User control and downloaded packages

- The default RootFS is intentionally minimal. The app does not silently install Bash, Python, Node.js, compilers, MCP servers, Skill dependencies, or other optional packages.
- Package installation happens only after a user enters a command, explicitly asks an Agent to install software, or confirms a built-in recipe that displays its exact command and persistent effect.
- Adding an MCP configuration, importing a Skill, opening settings, or encountering a missing command never triggers automatic package installation.
- The app exposes the RootFS package manifest, licenses, SBOM, source offer, deletion controls, and a reset action.

## Files, browser, and permissions

- Guest access is limited to its RootFS, Home, Shared, current workspace, and the app-specific iCloud Documents/Linux directory.
- An external File Provider directory is unavailable until the user explicitly selects and authorizes it. Read-only mounts are enforced by the guest mount layer; write access follows the selected permission and tool approval policy.
- Browser Agent actions use an app-owned WKWebView. Browser cookies are not mounted into Linux. Sensitive navigation, cross-site submission, JavaScript, screenshots, and downloads are subject to visible user approval, and Agent control pauses during user takeover.
- Skills and imported archives are treated as data. Importing them does not execute scripts or restore active processes.

## Agent behavior and diagnostics

- Chat mode does not expose Linux tools, inject the Agent prompt, install the RootFS, or start the runtime. Agent mode exposes the tools, while actual startup remains demand-driven.
- Users may independently operate interactive terminals in either Chat or Agent mode. Terminal screen contents are not automatically sent to the model.
- Runtime failures produce structured compatibility diagnostics for unsupported AArch64 instructions or Linux syscalls. Feedback submission includes such a diagnostic only when the user or Agent explicitly references its diagnostic ID, and excludes raw command output, arguments, environment values, and file content by default.
- Environment variables are injected directly into selected processes. They are not placed in model prompts. The default privacy mode redacts exact environment values from model-visible output while preserving local raw output for the user.

This feature does not expose native iOS/watchOS APIs to guest software and does not bypass Apple sandbox permissions. Users can inspect, edit, remove, or reset the Linux files that are stored inside the app container.
