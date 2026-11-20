# 0111. Performance signposts

Area: performance

## Keep signpost names and metadata free of user data

`PerformanceSignposts.swift` records signpost intervals on the paths users feel most, for Instruments' `os_signpost` instrument under the app's subsystem and category `Performance` (`DEVELOPMENT.md` § Launch arguments and profiling): `Launch`, `Session Open`, `Load Earlier`, `Transcript Apply`, `Markdown Parse`, `Stream Batch Apply`, `Cache Read`, and `Cache Write`. `Stream Batch Apply` covers both a stream's reveal ticks (`forced=0`) and the flushes that skip the tick on completion, cancel, error, interim reply and snapshot (`forced=1`). The signposter is compiled into every build, because Instruments profiles Release builds and an idle signposter costs almost nothing until a recording turns it on. Names are static strings and metadata is integer counts only, marked `.public`; never put prompt or message text, titles, paths, URLs, session IDs, or model names into a name or its metadata, because a trace leaves the device with whoever records it.

Lives in: `HermesMobile/Config/PerformanceSignposts.swift`
