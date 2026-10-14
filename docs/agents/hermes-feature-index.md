# Hermes Feature Index

Thin classification of what a Hermes host offers against Hermex: the Hermes counterpart of
[feature-gap-index.md](feature-gap-index.md), which keeps covering webui servers.

- **`HermesCall` and `HermesREST` are the authority for `shipped`.** A method or route they
  define is in the app; do not hand-list them here.
- This file holds only durable judgment: the gaps the migration plan confirmed (pinned at
  0.21.4) with how each ended, and the upstream RPC families Hermex never calls. Verify a
  row's contract just in time (AGENTS.md, Working with the server) when it is picked up.
- [hermes-server.md](hermes-server.md) owns the connection and feature detection;
  [bots.md](bots.md) owns screen behavior.

## Status vocabulary

| Status | Meaning |
| :--- | :--- |
| `shipped` | In the app, through a core method or route or the hermex-push companion plugin. |
| `covered` | The RPC is not called because a REST route or another method already serves it. |
| `accepted` | A host limit Hermex lives with; no work expected. |
| `dropped` | Owner decision: the webui feature has no Hermes form. |
| `n-a` | Desktop-, terminal- or host-administration surface, billing, or a method the app must never send. |
| `untriaged` | Could fit the phone; nobody has decided. File an issue before building it. |

## Confirmed gaps

The plan's gap table: webui features no core Hermes capability covered at 0.21.4.

| Gap | Status | Today |
| :--- | :--- | :--- |
| Git fetch, pull, new branch | shipped | hermex-push companion routes (#1236), gated on its `/capabilities`. |
| Git stash-and-checkout | dropped | A dirty tree refuses a switch with "Commit or discard first." |
| Workspace registry (add, remove, rename, reorder) | dropped | No registry: a chat's workspace is its session's `cwd`. |
| Session project tags, Move to Project | shipped | Projects are host folders; Move to Project changes the working folder (#1052, `CONTEXT.md` Project). |
| Kanban tenant edit | accepted | Tenant is set on create and read-only after (`kanban.md`). |
| Provider quota | shipped | hermex-push `GET /provider-quota` (#1237) in Usage. |
| Skill tags and related skills | dropped | The host sends no tags. |
| Reasoning levels per model | accepted | A fixed ladder plus the model's capability flags; the host clamps. |
| Insights message and activity counts | accepted | `insights.get` counts the newest 500 visible sessions, shown as "≈". |
| Cron run history past 100 runs | accepted | Run history shows the newest 100. |
| Password-less and trusted-header webui servers | accepted | A Hermes host needs a sign-in provider off loopback (`DEVELOPMENT.md` § Hermes Host Setup). |
| Bot name, update channel, max tokens settings | dropped | Settings hides webui-only rows on a Hermes server. |
| Hidden Bot Chats in a merged recency list | n-a | The home keeps Bots and Sessions as two sides (#709). |
| Live Activity outcome after a mid-turn compression while suspended | accepted | The relay's stale date covers it. |

## Upstream RPC methods Hermex never calls

At the pin (0.21.5, `ca678285`) the gateway contract has 237 methods and `HermesCall` sends
61 of them, plus `gateway.ready` and `gateway.ping`. The rest, by family:

| Family | Methods | Status | Note |
| :--- | :--- | :---: | :--- |
| Shell and CLI | `cli.exec`, `shell.exec` | n-a | A generic host shell; never sent. |
| Bot relay | `bot_relay.*` | n-a | Gateway-to-gateway traffic. |
| Room peers | `groups.promote`, `groups.demote`, `groups.replicate`, `groups.replica_state`, `groups.peer.*` | n-a | No peer administration (`bots.md` § Group rooms). |
| Billing | `billing.*`, `subscription.*`, `free_tier.*`, `usage.bars` | n-a | Nous account billing. |
| Diagnostics | `diagnostics.share_nous`, `session.events.stats` | n-a | Uploads a debug bundle; replay-buffer telemetry. |
| Reloads | `reload.env`, `reload.mcp` | n-a | Host administration that resets live sessions. |
| Desktop and terminal | `browser.*`, `display.*`, `clipboard.paste`, `paste.collapse`, `input.detect_drop`, `terminal.resize`, `system.battery`, `preview.restart`, `pet.*`, `wake.*`, `voice.record`, `voice.toggle` | n-a | Host screen, microphone, terminal or desktop UI. |
| Host setup | `onboarding.*`, `setup.*`, `profiles.remember_onboarding` | n-a | First-run setup on the host. |
| Foreign sessions | `session.foreign.*` | n-a | Claude Code and Codex sessions on the host. |
| Reactions | `message.react` | dropped | Removed from Hermex. |
| Covered elsewhere | `approval.pending`, `session.history`, `command.resolve`, `cron.manage`, `config.get`, `config.show`, `plugins.list`, `plugins.manage`, `image.attach`, `image.attach_bytes`, `image.detach`, `pdf.attach`, `voice.tts`, `session.branch_whole`, `session.branch_stored`, `session.activate`, `ping` | covered | Resume's `open_requests`, REST messages, `commands.catalog`, `/api/cron/jobs`, `/api/config`, the plugins hub, `/api/chat/image-upload` and `file.attach`, `/api/audio/speak`, `session.branch`, `session.resume`, `gateway.ping`. |
| Approval timing | `approval.received` | untriaged | Starts an approval's timeout when the card shows. |
| Host capabilities | `gateway.capabilities` | untriaged | What the build enforces; could replace some probes in `hermes-server.md`. |
| Session extras | `session.usage`, `session.context_breakdown`, `session.status`, `session.set_hidden`, `session.save` | untriaged | Per-chat cost and context, `/status` text, hide/unhide, export to the host. |
| Projects | `projects.list`, `projects.get`, `projects.archive`, `projects.add_folder`, `projects.remove_folder`, `projects.set_primary`, `projects.set_active`, `projects.for_cwd`, `projects.project_sessions`, `projects.discover_repos`, `projects.record_repos`, `project.facts` | untriaged | Hermex reads `projects.tree` and creates, renames and deletes. |
| Subagents and processes | `subagent.steer`, `delegation.*`, `spawn_tree.*`, `agents.list`, `process.*` | untriaged | Hermex lists, tails and interrupts subagents. |
| Checkpoints | `rollback.*` | untriaged | Restore a working tree to a checkpoint. |
| Tools and MCP | `tools.*`, `toolsets.list`, `mcp.*` | untriaged | Toolset switches and MCP server setup, including OAuth. |
| Connectors | `connectors.*` | untriaged | Hermex answers `connection.*` requests only. |
| Provider keys | `model.save_key`, `model.disconnect` | untriaged | Secrets; deliberate UX first. |
| Vault | `vault.*` | untriaged | Password managers; vault prompts get no card (#1148). |
| Skills hub and learning | `skills.manage`, `skills.reload`, `learning.*` | untriaged | Install from the hub, re-scan; edit or archive skills and memory chunks. |
| Messaging handoff | `handoff.*` | untriaged | Hand a session to a messaging platform's home channel. |
| Images and checks | `image.generate`, `verification.status` | untriaged | |

## Keeping it current

On every pin advance (AGENTS.md, Working with the server), list the contract's methods
against `HermesCall`'s and move any method that appeared or vanished into or out of the
table above:

```bash
C=~/Library/Caches/hermex-local-hermes/$(head -1 HERMES_AGENT_TESTED_SHA)/src/apps/shared/src/gateway-contract.openrpc.json
comm -23 <(python3 -c 'import json,sys; print("\n".join(sorted(m["name"] for m in json.load(open(sys.argv[1]))["methods"])))' "$C") \
         <(grep -ho '"[a-z_]*\(\.[a-z_]*\)\+"' HermesMobile/Networking/Hermes/HermesCall.swift | tr -d '"' | sort -u)
```

`scripts/local-hermes` creates that checkout on its first run. For REST, compare the live
host's `/openapi.json` paths with `HermesREST` the same way; a new route only needs a row
here once someone judges it.
