# 0016. Agent theme requests

Area: chat

## Answer set_theme requests at once, in English

`HermesThemeRequest` handles `set_theme`'s requests to the window showing the session (#1727). A Hermex chat gets them on a gateway Webapp, whose session policy gives the `gui` source the `desktop_ui` toolset; `hermes serve` gives that toolset only to the Desktop's `desktop` platform. `theme.apply` sets the app's light or dark mode and accent as Settings > Appearance does and answers with what it applied; `theme.pick` asks for a picker card the phone does not have, so its answer tells the agent to ask in the chat instead. Both are answered at once, without a tap. The answers are read by the agent, not the user, so their text is English and stays out of the String Catalog.

Lives in: `HermesMobile/Features/Chat/HermesThemeRequest.swift`
