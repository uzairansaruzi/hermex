# 0080. Network path monitoring

Area: networking

## Treat a requiresConnection path as online

`NetworkPathSnapshot` counts only an `.unsatisfied` path as offline; a `.requiresConnection` path, such as an on-demand VPN, counts as online. A probe request is what brings an on-demand VPN up, so waiting for the path to become satisfied before probing would never end.

Lives in: `HermesMobile/Networking/NetworkPathMonitor.swift`, `HermesMobileTests/NetworkPathMonitorTests.swift`
