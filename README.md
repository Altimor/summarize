# Summarize

Press **Caps Lock+2** (or ⌘⌥⌃⇧2) anywhere on your Mac to summarize, rewrite or ask about whatever you're looking at. The answer starts in about 0.7 seconds and a full summary is done in about one, because it runs on a fast open model served by Cerebras.

A single [Hammerspoon](https://www.hammerspoon.org) module. More at [flocrivello.com/summarize](https://flocrivello.com/summarize/).

## Install

```sh
curl -fsSL https://flocrivello.com/summarize/install.sh | bash
```

The installer installs Hammerspoon if you don't have it, copies the module to `~/.hammerspoon/summarize/`, adds one line to `~/.hammerspoon/init.lua` (backing it up first), and asks whether to turn Caps Lock into a Hyper key. Then:

1. Allow Hammerspoon under System Settings › Privacy & Security › Accessibility (and Screen Recording, for screenshot mode).
2. Press Caps Lock+2, or ⌘⌥⌃⇧2.
3. Paste an [OpenRouter API key](https://openrouter.ai/keys) when asked. It's kept in your Keychain.

**By hand:** copy the `summarize/` folder to `~/.hammerspoon/summarize/` and add this to `~/.hammerspoon/init.lua`:

```lua
require("summarize").start()
-- or: require("summarize").start({ capsLockHyper = true })        -- Caps Lock becomes Hyper
-- or: require("summarize").start({ hotkey = { {"cmd", "alt"}, "s" } })
```

## What it does

| You're looking at | What happens |
|---|---|
| Text selected in a text field | Type an instruction or pick "Clean up"; the reply replaces the selection |
| Text selected anywhere else | The answer opens in a floating panel |
| Nothing selected | It reads a screenshot of the front window; on an article in Chrome it reads the article's text instead |

In the answer panel you can ask follow-ups, copy as Markdown, and select part of an answer (or triple-click a paragraph) and click **Ask for details**. Beyond the presets (Summarize, Super summarize, Clean up) you can type any instruction. Choose **Settings** in the prompt box to edit the prompts behind each mode.

## How it works

- **Model:** Qwen on Cerebras through OpenRouter. When Cerebras is rate-limited, it retries on the fastest other provider.
- **Streaming:** `curl` in the background (Hammerspoon's HTTP client can't stream). The API key goes in a private temp file, never on the command line.
- **Article detection:** `extract.js` runs in the Chrome tab through AppleScript and scores containers by paragraph text, a small Readability. A page needs 250+ words in 4+ paragraphs to count as an article.
- **Caps Lock as Hyper** (optional): `hidutil` maps Caps Lock to F18, re-applied each time Hammerspoon starts. An event tap then adds ⌘⌥⌃⇧ to keys pressed while it's held. It does nothing if another remapping is already set. To undo, remove the option and run `hidutil property --set '{"UserKeyMapping":[]}'`.
- **Starts at login:** `start()` turns on Hammerspoon's "Launch at login", since Summarize only works while it runs. Opt out with `start({ autoLaunch = false })`.
- **Privacy:** your text or screenshot goes only to OpenRouter. The log (`~/.hammerspoon/summarize.log`) records timings, modes and sizes, never your text.

## License

GPL-3.0
