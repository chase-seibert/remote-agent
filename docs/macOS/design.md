# macOS Design

Remote Agent uses one resizable main window with a two-column `NavigationSplitView`, matching Finder and other session-oriented Mac apps. The main window is a singleton within the process, and the bundle prohibits launching a second app process. Closing and reopening Remote Agent therefore returns to the same main-window identity rather than creating duplicates. Document previews may still open in separate supporting windows.

The main window contains:

- The sidebar lists and filters the 50 most recently active sessions across every project.
- The detail column shows the selected transcript and prompt composer.

Pinned sessions appear first, ordered by recent activity within the pinned group; remaining sessions follow in recent-activity order. Every row shows the session title, project name, abbreviated activity date and time, and compact status pills. Pinned rows show an orange pin label, unread status uses a blue chat bubble inside its pill, and active sessions use the same rotating green sparkle and green Running pill as the companion iOS app. Selecting the session while the app is active marks it read. Results that arrive while another session is selected or the app is inactive remain unread.

Sessions have contextual actions for pinning or unpinning, creating another session in the same project, revealing the project in Finder, toggling read or unread state, and deleting the session. Marking unread does not change activity ordering. Deletion requires destructive confirmation and is unavailable while the session is running. A toolbar item and Command-N open a native project picker before creating a session, Command-R refreshes project discovery, and Command-Return sends a prompt. Conversation text supports selection and copy. Command-Plus, Command-Minus, and Command-0 adjust a persisted interface text scale, also available in Settings. The scale applies to session titles, projects, activity timestamps, status badges, transcript labels and content, progress status, and the prompt composer.

The conversation toolbar includes a native Make split button plus one Commit & Push button, mirrored in the Project menu. The Make button always shows the hammer and active target name; its primary region runs that target immediately, while its arrow menu changes the target remembered for that session. Commit & Push stages the full working tree with `git add --all`, generates a short subject with Apple's on-device Foundation Models framework, commits, and pushes only when the current branch has a configured upstream. Project actions are disabled while the agent or another project command is running.

The main toolbar shows a green checkmark with “Mobile active” when a non-loopback API request has arrived within 30 seconds and a gray “Mobile idle” indicator otherwise. Settings includes a Mobile Debug tab with the same connection treatment, last-seen status, and a persistent, copyable request table. The log is capped at 500 entries and can be cleared explicitly.

Local Network API settings apply enabled-state and port changes automatically, while retaining an explicit Restart API Now recovery action. A Reliability section exposes the enabled-by-default crash relaunch setting and its watchdog status. Normal Quit always disarms the watchdog.

Conversation messages use the same bubble hierarchy as iOS: the user's blue, white-text bubbles align to the right, while agent and system bubbles use semantic gray backgrounds on the left. Headers include role and time. Responses use a native Markdown block renderer that preserves paragraph spacing, headings, unordered and ordered lists, block quotes, dividers, fenced code blocks, inline emphasis, links, and inline code. Plain-text line breaks remain visible, and the original response remains selectable and available through the Copy context-menu action. While a turn runs, a rotating green sparkle appears beside the latest concise Codex reasoning summary. Each new summary replaces the previous one, and the working surface disappears when the final response or failure is appended.

Starting a Make or Commit & Push action immediately adds a compact green running placeholder and scrolls it into view. The same row becomes a success or failure summary when the command completes. Placeholders include a View Output affordance and open a live-updating, resizable sheet with command metadata and selectable, scrollable monospaced output. The full result is stored separately from session messages so it does not appear in the main conversation; the iOS client fetches it on demand through the authenticated result endpoint.

Local Markdown, HTML, and supported source-code links open in separate Remote Agent document windows. Markdown uses the same native renderer and text-size setting as conversations. HTML uses a local WebKit view with JavaScript disabled, relative assets scoped to the document folder, and external links handed to the default browser. Source code uses a selectable monospaced preview with line numbers and two-axis scrolling. Document windows include Reload, Show in Finder, and Open in Default App toolbar actions. Relative document links resolve from the active project or the open document's folder.

The composer uses a native multiline text editor. The microphone button starts macOS speech recognition and inserts partial/final transcription into the same text editor; the user reviews and explicitly submits it. Active turns show progress without blocking navigation to other transcripts.

System colors, fonts, materials, controls, sidebars, toolbars, alerts, Settings, and SF Symbols keep the app responsive to appearance, accent color, accessibility, and keyboard-navigation preferences. Appearance settings offer System, Light, and Dark modes; the choice applies immediately to the main window, document windows, and Settings and persists across launches.

## App icon

The app icon uses a minimal desktop-and-phone mark on a deep navy field, with cobalt and cyan device outlines connected by a small light bridge. `Resources/AppIcon/RemoteAgentIcon-1024.png` is the opaque, square, shared source for both macOS and the future iOS app; neither platform-specific corner mask is baked into the source. The macOS build derives its multi-resolution `.icns` through `make icons`.
