# Initial Brainstorm

## Original request

Create a desktop Mac application called Remote Agent that invokes LLM agents through their command-line interfaces and relays prompts and responses in the desktop app. The first version should support Codex, discover existing projects, start a session in a selected project, and allow an ongoing text conversation. It should use macOS Foundation frameworks for speech-to-text prompt entry. A future iOS app should connect directly to the running Mac app over the local network, list previous sessions, start sessions, and exchange messages. Existing Codex plugins should continue to work through the session. Scheduling and plugin installation are out of scope.

## First-version scope

- Native SwiftUI macOS application, not a web shell.
- Immediate-child project discovery under a configurable root directory.
- Codex CLI JSONL transport with persistent Codex thread resumption.
- Local transcript index owned by Remote Agent.
- Text and speech-to-text prompt composition.
- Authenticated HTTP/JSON API on the local network.
- No task scheduling, attachment support, plugin management, or Claude adapter yet.

## Product direction

The agent transport is deliberately kept behind a small client boundary. Codex is the only implementation in version one; another CLI such as Claude can later implement the same send/resume contract without changing the views, local sessions, or client API.
