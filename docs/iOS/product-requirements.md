# Product Requirements

- As a developer away from my desk, I want to connect my iPhone to Remote Agent on my Mac, so that I can use the Codex sessions in my local projects.
- As a developer, I want one activity-ordered list of recent sessions across every project, so that I can resume the right context without navigating through projects first.
- As a developer, I want to create a session from either the global list or an existing conversation, so that I can start work without returning to the Mac or backing out of my current project.
- As a developer, I want to rename a session, so that its title stays useful as the work changes.
- As a developer, I want to pin important sessions above recent activity, so that durable work stays easy to reach across projects.
- As a developer, I want to delete an idle session after confirming the destructive action, so that obsolete transcripts do not clutter the global list.
- As a developer, I want to queue follow-up prompts while an agent is working, so that my next instructions run automatically in order.
- As a developer, I want active turns to update automatically, so that I know when Codex has finished or failed.
- As a developer returning to an already-open conversation, I want newly delivered activity marked read immediately, so that its unread marker does not remain stale.
- As a developer, I want a session to open at its latest activity, so that I do not have to manually scroll through old messages.
- As an iPhone user, I want to swipe right from a conversation to return to the global session list with the same transition as Back, so that one-handed navigation stays familiar.
- As a security-conscious user, I want the bearer token kept in Keychain and excluded from diagnostics, so that credentials are not persisted in ordinary preferences.
- As a mobile user, I want unsent text preserved per session, so that navigation or an interruption does not discard my draft.
- As an iPad user, I want the interface to adapt to a wide layout, so that recent sessions and conversation context remain easy to navigate together.
- As a developer, I want to open Markdown and HTML files from a project, so that I can conveniently reference project documentation from my phone.
- As a developer, I want Markdown files rendered with document formatting, so that headings, emphasis, lists, quotes, and code are easy to scan.
- As a developer, I want source-code files omitted from Browse Files but previewable from conversation links with stable formatting and line numbers, so that documentation stays easy to browse while changed code remains inspectable.
- As a developer, I want links in transcripts and project documents to open on my phone, including links written as Mac project paths, so that desktop-generated references remain useful on mobile.
- As a developer, I want a notification when an agent turn finishes or fails, so that I do not need to keep watching the conversation.
- As a developer, I want the iOS app icon badge to show my unread-session count, so that pending agent updates are visible outside the app.

## Version-one constraints

- The Mac host must be reachable on the same local network.
- Configuration is manual; no Bonjour or QR pairing is included.
- Transport is HTTP with a bearer token and a narrow local-network ATS allowance.
- Only one turn can run per session.
- The iOS client does not run Codex or Claude itself and does not interpret project paths as iOS paths.
