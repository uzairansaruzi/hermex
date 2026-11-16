# Security Policy

## Reporting a vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use GitHub's private vulnerability reporting: go to the repository's
**Security** tab and click **Report a vulnerability** (or open
`https://github.com/uzairansaruzi/hermex/security/advisories/new`). This opens a
private security advisory that only the maintainer can see.

Include as much of the following as you can:

- A description of the vulnerability and its impact
- Steps to reproduce, or a proof of concept
- The app version (or commit) and iOS version you tested against

You should get an initial response within a week. Please give the maintainer a
reasonable window to ship a fix before disclosing publicly.

## Scope

This repository contains only the iOS client. Vulnerabilities in the
[Hermes Agent](https://github.com/NousResearch/hermes-agent) or legacy
[hermes-webui](https://github.com/nesquena/hermes-webui) servers should be
reported to those projects instead. Issues with how *this app* stores
credentials, talks to the server, or handles untrusted server responses are in
scope here.
