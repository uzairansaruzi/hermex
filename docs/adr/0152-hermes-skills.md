# 0152. Hermes Skills client

Area: skills

## Confine skill linked-file paths to the skill's folder

`HermesSkillsClient` serves the Skills screens on a Hermes host (#1069): one Profile's skills under `/api/skills`, over the sign-in, headers and cookie jar the server's Bot screens share, with every read and the toggle naming that Profile. The host sends no tags or related skills. A skill's linked files (#1070) are the other files in its SKILL.md's folder, read through `/api/fs/*`, which accepts any host path, so every requested path is built from that folder and stays inside it. The folder is an opaque handle, never shown, logged or persisted. A refusal the host explains, such as a skill that is gone, reads as its `detail`.

Lives in: `HermesMobile/Networking/Hermes/HermesSkillsClient.swift`
