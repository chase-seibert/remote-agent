# Initial Brainstorm

## Original request

> Implement a new iOS app that acts as a remote agent to my desktop app that runs Codex and Claude sessions inside my various projects. It's going to connect over the local network as specified in this plan file. You don't have to worry about connecting over the internet for now.

## Initial scope

The first release is a thin local-network client for the existing Remote Agent macOS HTTP/JSON API. It manually accepts a host, port, and bearer token; lists projects and sessions; creates sessions; sends prompts; and polls while a turn is running. Internet connectivity, Bonjour, pairing, TLS identity pinning, streaming, cancellation, and provider metadata remain future work.
