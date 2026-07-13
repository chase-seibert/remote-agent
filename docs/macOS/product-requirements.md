# Product Requirements

## Core stories

- As a developer, I want one recent-session list across all projects, so that I can resume the latest work without navigating a project hierarchy.
- As a developer, I want each recent session to show its project, activity time, and current status, so that I can identify the right work at a glance.
- As a developer, I want to start a session in a project, so that Codex reads and changes files in the correct working directory.
- As a developer, I want to send several prompts in one session, so that Codex retains the conversation and tool context.
- As an iOS client user, I want queued prompts persisted, editable, and executed by the Mac in FIFO order, so that follow-up work continues after the phone app closes.
- As a developer, I want my session list and visible transcript to survive an app restart, so that I can return to earlier work.
- As a developer, I want to run a project's Makefile targets from a split button that remembers the latest target for each session, so that common build, test, and deployment workflows stay close to the active session.
- As a developer, I want one Commit & Push control that stages every working-tree change, generates its subject on device, commits, and pushes when an upstream exists, so that I can publish completed work without opening Terminal or fail merely because a local branch has no upstream.
- As a developer, I want project commands to appear immediately with running status, become a success or failure summary in place, and expose full output on demand, so that terminal noise does not overwhelm the conversation.
- As a developer, I want sessions ordered by recent activity and unseen results clearly marked, so that I can quickly find work that needs attention.
- As a developer, I want to dictate a prompt using macOS speech recognition, so that I can compose without typing.
- As a developer, I want local Markdown and HTML links in agent responses to open inside Remote Agent, so that I can inspect generated reports without leaving the conversation workflow.
- As a Mac user, I want standard menus, keyboard shortcuts, sidebars, Settings, text selection, and Finder integration, so that the app behaves like a native Mac app.
- As a Mac user, I want exactly one main Remote Agent window and one running app process, so that repeated launches never create duplicate hosts or navigation windows.
- As a Mac user, I want the app to follow the system appearance or stay in my chosen light or dark mode, so that it remains comfortable in different environments.
- As an iOS client user, I want an authenticated local-network API, so that my phone can view sessions, submit prompts, run project commands, and inspect results produced by the Mac host.
- As a mobile user, I want Bonjour discovery and automatic recovery from malformed connections or host crashes, so that the Mac service remains available without routine intervention.
- As an iOS client user, I want read-only access to project Markdown, HTML, and source-code files, so that I can conveniently reference documentation and implementation details from my phone.
- As a user, I want to rename a saved session, so that its title remains meaningful as the work evolves.
- As a user, I want to pin important sessions above recent activity and permanently delete obsolete sessions with confirmation, so that the sidebar stays useful and safe to manage.
- As a plugin user, I want Codex to load my existing configuration, so that already-installed plugins remain usable without Remote Agent managing them.

## Non-goals for version one

- Scheduling or background task orchestration.
- Installing or attaching plugins.
- File/image prompt attachments.
- Streaming partial assistant prose to clients.
- Interactive approval handling.
- Remote internet access, accounts, or cloud relay.
- Claude or other agent CLIs.
