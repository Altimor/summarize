-- Summarize: Hyper-2 (⌘⌥⌃⇧2) asks a fast LLM about whatever you're looking at.
--
--   * text selected in a text field: type an instruction (or pick a preset); the reply replaces the selection
--   * text highlighted anywhere else (web page, PDF, email): the answer opens in a small panel
--   * nothing selected: a screenshot of the front window is sent instead (in Chrome, a page that reads like
--     an article sends the article's text)
--
-- The answer panel streams, renders Markdown, copies as Markdown, takes follow-ups; select text in it for
-- "Ask for details" (or triple-click a paragraph).
--
-- Model: Qwen 3.8 27B on Cerebras via OpenRouter (fast), falling back to the fastest other provider when
-- Cerebras is rate-limited. Needs an OpenRouter API key: asked for on first use, kept in the macOS Keychain.
--
-- Use: require("summarize").start()   or   require("summarize").start({ hotkey = { {"cmd","alt"}, "s" } })
--      require("summarize").start({ capsLockHyper = true })   also makes Caps Lock a Hyper key (Caps Lock+2)
--      Turns on "Launch Hammerspoon at login" so it survives restarts; start({ autoLaunch = false }) to opt out.

local M = {}

-- This module's folder (extract.js sits next to it).
local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or (os.getenv("HOME") .. "/.hammerspoon/summarize")

-- Log (no keys, no content): ~/.hammerspoon/summarize.log
local LOG = os.getenv("HOME") .. "/.hammerspoon/summarize.log"
local function wlog(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S "), ok and line or fmt, "\n"); f:close() end
end
local windows = { wlog = wlog }

local MODEL = "qwen/qwen3.8-27b"
local PROVIDER = { only = { "cerebras" }, allow_fallbacks = false }
-- when Cerebras is rate-limited (OpenRouter shares one Cerebras pool between all its users): the same
-- model on whichever other provider is fastest right now
local FALLBACK_PROVIDER = { ignore = { "cerebras" }, sort = "throughput" }

-- System prompts, editable from the prompt box ("Settings"), saved in hs.settings. "base" is
-- prepended to every request; the other three are per mode.
local DEFAULT_PROMPTS = {
  base = "",
  editable = [[You edit text inside the user's apps. You get an instruction and, usually, the text they selected.
Reply with ONLY the text that will replace the selection: no preamble, no explanation, no quotes around it,
no markdown code fences unless the content itself is code. Keep the selection's language, tone and formatting
(line breaks, lists, markdown) unless the instruction says otherwise. If no text was selected, write the text
the instruction asks for.]],
  screenshot = [[You get a screenshot of the user's screen, an instruction, and sometimes text they highlighted.
Answer the instruction directly and concisely, using what's on screen as context. Plain text or light
markdown (short lists, bold). No preamble.
If the screen shows a black box of subtitles, captions or a live meeting transcript, that transcript is what
the user wants summarized or asked about: focus on it and ignore the rest of the screen.]],
  selected = [[You get text the user highlighted (on a web page, in a document, an email…) and an instruction.
Answer the instruction about that text directly and concisely. Plain text or light markdown (short lists,
bold). No preamble.]],
}
local PROMPTS_KEY = "summarize.prompts"

local function prompts()
  local saved = hs.settings.get(PROMPTS_KEY) or {}
  local out = {}
  for k, v in pairs(DEFAULT_PROMPTS) do out[k] = (type(saved[k]) == "string") and saved[k] or v end
  return out
end

local function systemPrompt(kind)
  local p = prompts()
  local base = p.base:gsub("^%s+", ""):gsub("%s+$", "")
  return (base ~= "" and (base .. "\n\n") or "") .. p[kind]
end

-- OpenRouter key: OPENROUTER_API_KEY in Hammerspoon's environment, else the macOS Keychain
-- (service "summarize-openrouter"). Asked for on first use; never logged.
local KC_SERVICE, KC_ACCOUNT = "summarize-openrouter", "openrouter"

local function apiKey()
  if M.key then return M.key end
  local env = os.getenv("OPENROUTER_API_KEY")
  if env and env ~= "" then M.key = env; return M.key end
  local out, ok = hs.execute(string.format("/usr/bin/security find-generic-password -s %s -a %s -w 2>/dev/null", KC_SERVICE, KC_ACCOUNT))
  local k = ok and out and out:gsub("%s+$", "") or ""
  if k ~= "" then M.key = k end
  return M.key
end

local function storeKey(k)
  M.key = k
  M.kcTask = hs.task.new("/usr/bin/security", function(code)
    if code ~= 0 then hs.alert.show("Couldn't save the key to the Keychain (it's kept until Hammerspoon restarts)") end
  end, { "add-generic-password", "-U", "-s", KC_SERVICE, "-a", KC_ACCOUNT, "-w", k })
  M.kcTask:start()
end

-- Ask for the key (first use, "Change API key", or after the key was refused). onDone(key or nil).
function M.askKey(onDone, why)
  hs.focus()
  local info = (why and (why .. "\n\n") or "")
    .. "Summarize sends your text or screenshot to an AI model through OpenRouter.\n"
    .. "Paste an OpenRouter API key (it's stored in your Keychain).\n\n"
    .. "Don't have one? Leave the field empty and press Save to open https://openrouter.ai/keys"
  while true do
    local button, text = hs.dialog.textPrompt("OpenRouter API key", info, "", "Save", "Cancel")
    if button == "Save" then
      local k = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if k ~= "" then storeKey(k); if onDone then onDone(k) end; return end
      hs.urlevent.openURL("https://openrouter.ai/keys")
    else
      if onDone then onDone(nil) end
      return
    end
  end
end

-- "Working" indicator: a ✨ in the menu bar while a request is in flight (no on-screen alert).
local busyCount = 0
local function busy(on)
  busyCount = math.max(0, busyCount + (on and 1 or -1))
  if busyCount > 0 and not M.menu then
    M.menu = hs.menubar.new()
    if M.menu then M.menu:setTitle("✨"); M.menu:setTooltip("Summarize is working…") end
  elseif busyCount == 0 and M.menu then
    M.menu:delete(); M.menu = nil
  end
end

-- Copy the selection, then call back with it ("" when nothing is selected) and the saved clipboard.
local function grabSelection(cb, focused)
  local saved = hs.pasteboard.getContents()
  -- Ask the app first: instant, and no clipboard round-trip. Only apps that don't say get the
  -- ⌘C fallback (which has to wait to see whether anything landed).
  local ax = focused and focused:attributeValue("AXSelectedText")
  if type(ax) == "string" then return cb(ax, saved) end
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  local tries = 0
  M.timer = hs.timer.doEvery(0.01, function()
    tries = tries + 1
    if hs.pasteboard.changeCount() == before and tries < 15 then return end
    M.timer:stop(); M.timer = nil
    local text = hs.pasteboard.changeCount() ~= before and (hs.pasteboard.getContents() or "") or ""
    cb(text, saved)
  end)
end

-- The model sometimes wraps a whole rewrite in a code fence or backticks despite the instructions;
-- pasted into a note those show up literally. Strip a wrapper around the entire reply only.
local function unwrap(t)
  local inner = t:match("^```[%w%-]*\n(.-)\n?```$")
  if inner then return inner end
  inner = t:match("^`([^`\n]+)`$")
  return inner or t
end

local function paste(text, saved)
  text = unwrap(text)
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- give the app time to read the pasteboard before putting the old clipboard back
  M.restoreTimer = hs.timer.doAfter(0.4, function()
    if saved then hs.pasteboard.setContents(saved) end
  end)
end

-- One request over a whole conversation, streamed; onDone(reply) or onDone(nil, error message).
-- onDelta(textSoFar), when given, is called as the answer arrives (at most every 40ms).
-- curl in the background (hs.http can't stream); the key goes in a private temp file (mkstemp, 0600),
-- not on the command line where `ps` would show it.
local function complete(messages, onDone, logLabel, fallback, onDelta)
  local key = apiKey()
  if not key then
    return M.askKey(function(k)
      if k then complete(messages, onDone, logLabel, fallback, onDelta) else onDone(nil, "No OpenRouter API key") end
    end)
  end
  local bodyFile = os.tmpname()
  local f = io.open(bodyFile, "w")
  f:write(hs.json.encode({
    model = MODEL, provider = fallback and FALLBACK_PROVIDER or PROVIDER, reasoning = { enabled = false },
    temperature = 0.3, max_tokens = 4000, messages = messages, stream = true,
  }))
  f:close()
  local headerFile = os.tmpname()
  local h = io.open(headerFile, "w")
  h:write("Authorization: Bearer " .. key .. "\nContent-Type: application/json\n")
  h:close()
  local t0 = hs.timer.secondsSinceEpoch()
  local ms = function() return math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000) end
  local buf, text, raw, provider, streamErr, status, firstMs, lastPush = "", "", "", nil, nil, nil, nil, 0
  local reparsing = false
  local function handle(line)
    line = line:gsub("\r$", "")
    local code = line:match("^__HTTP__(%d+)$")
    if code then status = tonumber(code); return end
    local d = line:match("^data: (.*)$")
    if not d then
      -- an error arrives as a plain JSON body, not as events; ":" lines are keep-alive comments
      if line ~= "" and not line:match("^:") then raw = raw .. line .. "\n" end
      return
    end
    if d == "[DONE]" then return end
    local ok, j = pcall(hs.json.decode, d)
    if not ok or type(j) ~= "table" then return end
    if j.provider then provider = j.provider end
    if type(j.error) == "table" then streamErr = j.error end
    local c = j.choices and j.choices[1] and j.choices[1].delta and j.choices[1].delta.content
    if type(c) == "string" and c ~= "" then
      text = text .. c
      firstMs = firstMs or ms()
      local now = hs.timer.secondsSinceEpoch()
      if onDelta and not reparsing and now - lastPush > 0.04 then lastPush = now; onDelta(text) end
    end
  end
  local function feed(chunk)
    buf = buf .. chunk
    while true do
      local n = buf:find("\n", 1, true)
      if not n then break end
      handle(buf:sub(1, n - 1)); buf = buf:sub(n + 1)
    end
  end
  local task
  local outFile = os.tmpname()
  task = hs.task.new("/bin/sh", function(exitCode, out, errOut)
    os.remove(bodyFile); os.remove(headerFile)
    if out and out ~= "" then feed(out) end
    if buf ~= "" then handle(buf); buf = "" end
    -- the whole response, from the copy curl wrote to a file: streamed chunks can still be in flight
    -- when the task ends (a fallback request then reported "Empty answer" with no status)
    local fh = io.open(outFile, "r")
    local full = fh and fh:read("a") or ""
    if fh then fh:close() end
    os.remove(outFile)
    if full ~= "" then
      reparsing = true
      buf, text, raw, provider, streamErr, status = "", "", "", nil, nil, nil
      feed(full)
      if buf ~= "" then handle(buf); buf = "" end
      reparsing = false
    end
    M.streams[task] = nil
    local e = streamErr
    if not e and raw ~= "" then
      local ok, j = pcall(hs.json.decode, raw)
      if ok and type(j) == "table" and type(j.error) == "table" then e = j.error end
    end
    if (status == 401 or (e and tonumber(e.code) == 401)) and text == "" and not M.reasking then
      -- the key was refused: ask for a new one, then try again once
      M.key = nil
      M.reasking = true
      return M.askKey(function(k)
        M.reasking = false
        if k then complete(messages, onDone, logLabel, fallback, onDelta) else onDone(nil, "OpenRouter refused the API key") end
      end, "OpenRouter refused the API key.")
    end
    local limited = status == 429 or (e and tonumber(e.code) == 429)
    if limited and not fallback and text == "" then
      wlog("summarize: Cerebras rate-limited after %dms, retrying on another provider", ms())
      return complete(messages, onDone, logLabel, true, onDelta)
    end
    local reply = text:gsub("^%s+", ""):gsub("%s+$", "")
    if status ~= 200 or e or reply == "" then
      -- OpenRouter's message is just "Provider returned error": the provider's own words are in metadata.raw
      local r = e and type(e.metadata) == "table" and e.metadata.raw
      local err = (type(r) == "string" and r ~= "" and ((e.metadata.provider_name and (e.metadata.provider_name .. ": ") or "") .. r))
                  or (e and e.message)
                  or (status and status ~= 200 and ("HTTP " .. status .. (raw ~= "" and (": " .. raw:sub(1, 300)) or "")))
                  or ((errOut and errOut ~= "") and errOut:gsub("%s+$", "")) or "Empty answer"
      err = tostring(err)
      wlog("summarize: failed after %dms (HTTP %s): %s", ms(), tostring(status), err)
      hs.alert.show("⚠️ " .. err, 2.5)
      return onDone(nil, err)
    end
    wlog("summarize: %s -> %d chars out, first text %sms, done %dms%s", logLabel or "?", #reply, tostring(firstMs), ms(),
                 fallback and (" (fallback: " .. tostring(provider) .. ")") or "")
    onDone(reply)
  end, function(_, out) if out and out ~= "" then feed(out) end; return true end,
  { "-c", [[/usr/bin/curl -sS -N -H "@$1" --data-binary "@$2" -w '\n__HTTP__%{http_code}\n' https://openrouter.ai/api/v1/chat/completions | tee "$3"]],
    "sh", headerFile, bodyFile, outFile })
  M.streams[task] = true   -- keep a reference: an unreferenced hs.task can be garbage-collected mid-run
  task:start()
end
M.streams = M.streams or {}

-- First turn: instruction + selection (+ screenshot). onDone(reply, messages) where messages is the
-- conversation including the reply, for follow-ups.
local function ask(instruction, selection, onDone, imageURL, system, onDelta)
  local user = selection ~= "" and ("Instruction: " .. instruction .. "\n\nSelected text:\n" .. selection)
                               or ("Instruction: " .. instruction .. "\n\n(No text selected.)")
  local content = user
  if imageURL then
    content = { { type = "text", text = user }, { type = "image_url", image_url = { url = imageURL } } }
  end
  local messages = { { role = "system", content = system or systemPrompt(imageURL and "screenshot" or "editable") }, { role = "user", content = content } }
  complete(messages, function(reply, err)
    if reply then messages[#messages + 1] = { role = "assistant", content = reply } end
    onDone(reply, messages, err)
  end, #selection .. " chars in", nil, onDelta)
end

-- Is keyboard focus in an editable text field? (role of the focused element)
local EDITABLE = { AXTextField = true, AXTextArea = true, AXComboBox = true, AXSearchField = true }
local function inTextField()
  local f = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  local role = f and f:attributeValue("AXRole")
  return role and EDITABLE[role] or false, role, f
end

-- The screen the frontmost window is on, as a JPEG data URL (downscaled: plenty for the model,
-- and a smaller upload).
-- The front window (12ms, vs ~250ms for a whole 5K screen, and the prompt can't end up in it),
-- falling back to the screen. Encoding is separate so it can run while the prompt is up.
-- The screenshot is taken and encoded entirely in a background process: screencapture grabs just the front
-- window by its id (so the prompt box can't end up in it), sips shrinks it to 1024px and JPEG quality 60.
-- Doing any of this in Hammerspoon (snapshot, PNG write) blocked its only thread, so Esc right after the
-- box appeared went unanswered. onDone(dataURL or nil).
local SHOT_TMP = (os.getenv("TMPDIR") or "/tmp/") .. "summarize-shot"
local function captureScreenshot(onDone)
  local win = hs.window.focusedWindow()
  local target = (win and win:id()) and ("-l" .. win:id()) or "-m"   -- the front window, else the main display
  local script = string.format(
    "/usr/sbin/screencapture -x -o %s -t png %q && /usr/bin/sips -Z 1024 -s format jpeg -s formatOptions 60 %q --out %q >/dev/null",
    target, SHOT_TMP .. ".png", SHOT_TMP .. ".png", SHOT_TMP .. ".jpg")
  M.shotTask = hs.task.new("/bin/sh", function(code)
    local f = io.open(SHOT_TMP .. ".jpg", "rb")
    local data = f and f:read("a"); if f then f:close() end
    os.remove(SHOT_TMP .. ".png"); os.remove(SHOT_TMP .. ".jpg")
    onDone((code == 0 and data) and ("data:image/jpeg;base64," .. hs.base64.encode(data)) or nil)
  end, { "-c", script })
  M.shotTask:start()
end

-- A small floating panel with the answer: selectable text, Copy, Esc / ⌘W to close.
local PANEL_HTML = [==[<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: light; }
  /* header on top, the answer scrolls in the middle, the reply box stays pinned at the bottom */
  html, body { height: 100%; margin: 0; overflow: hidden; }
  body { display: flex; flex-direction: column; font: 14px/1.55 -apple-system, system-ui, sans-serif; color: #1d1d1f; background: #fbfbfd; }
  .bar { flex: none; display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-bottom: 1px solid #ececf0;
         font-size: 12px; color: #6e6e73; background: #fbfbfd; }
  .q { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  button { font: 600 12px -apple-system, system-ui; border: 0; border-radius: 7px; padding: 6px 12px;
           background: #1d1d1f; color: #fff; cursor: pointer; }
  button.done { background: #34c759; }
  .a { flex: 1; min-height: 0; overflow-y: auto; overflow-x: hidden; padding: 6px 16px 18px;
       user-select: text; -webkit-user-select: text; overflow-wrap: anywhere; }
  .a p, .a li { text-wrap: pretty; }
  .a p { margin: 10px 0; }
  .a h1, .a h2, .a h3, .a h4 { margin: 16px 0 6px; line-height: 1.25; text-wrap: balance; }
  .a h1 { font-size: 18px; } .a h2 { font-size: 16px; } .a h3, .a h4 { font-size: 14px; }
  .a ul, .a ol { margin: 8px 0; padding-left: 22px; } .a li { margin: 3px 0; }
  .a li > ul, .a li > ol { margin: 3px 0; }
  .a code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: #f0f0f3; border-radius: 4px; padding: 1px 4px; }
  .a pre { background: #f0f0f3; border-radius: 8px; padding: 10px 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .a pre code { background: none; padding: 0; }
  .a blockquote { margin: 10px 0; padding-left: 12px; border-left: 3px solid #d2d2d7; color: #515154; }
  .a a { color: #0a64d6; }
  .thinking { color: #8e8e93; margin: 10px 0; }
  .turn { border-top: 1px solid #ececf0; margin-top: 14px; padding-top: 12px; }
  .you { display: inline-block; background: #eef0f6; color: #1d1d1f; border-radius: 12px; padding: 6px 11px; margin: 2px 0 6px;
         white-space: pre-wrap; overflow-wrap: anywhere; max-width: 100%; box-sizing: border-box; }
  .pending { color: #8e8e93; }
  /* "Ask for details" over a selection in the answer */
  #ask { position: fixed; display: none; z-index: 10; font: 600 12px -apple-system, system-ui; padding: 5px 10px;
         border-radius: 7px; background: #1d1d1f; color: #fff; box-shadow: 0 2px 8px rgba(0,0,0,.18); }
  .reply { flex: none; background: #fbfbfd; padding: 10px 14px 12px; border-top: 1px solid #ececf0; }
  .reply textarea { width: 100%; box-sizing: border-box; resize: none; border: 1px solid #dcdce2; border-radius: 10px;
                    padding: 8px 11px; font: 14px/1.4 -apple-system, system-ui, sans-serif; color: #1d1d1f; background: #fff;
                    outline: none; max-height: 120px; }
  .reply textarea:focus { border-color: #9db8e6; box-shadow: 0 0 0 3px rgba(10,100,214,.12); }
</style></head><body>
<div class="bar"><span class="q" id="q"></span><button id="copy" onclick="copy()">Copy</button></div>
<div class="a" id="a"><div id="first"></div></div>
<button id="ask">Ask for details</button>
<div class="reply"><textarea id="r" rows="1" placeholder="Ask a follow-up…  (⏎ to send, ⇧⏎ new line)"></textarea></div>
<script>
  // Small markdown renderer: headings, bold/italic, inline + fenced code, lists, quotes, links.
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function inline(s) {
    return esc(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/__([^_]+)__/g, "<strong>$1</strong>")
      .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>")
      .replace(/(^|[^_\w])_([^_\n]+)_(?!\w)/g, "$1<em>$2</em>")
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>');
  }
  function md(src) {
    const lines = src.replace(/\r/g, "").split("\n");
    let out = "", para = [], i = 0;
    const stack = [];   // open lists: { indent, tag } — items indented deeper nest inside the previous item
    const flushPara = () => { if (para.length) { out += "<p>" + inline(para.join(" ")) + "</p>"; para = []; } };
    const closeList = () => { while (stack.length) out += "</li></" + stack.pop().tag + ">"; };
    const item = (indent, tag, text) => {
      while (stack.length && indent < stack[stack.length - 1].indent) out += "</li></" + stack.pop().tag + ">";
      const top = stack[stack.length - 1];
      if (top && indent === top.indent) {
        if (top.tag === tag) out += "</li>";
        else { out += "</li></" + stack.pop().tag + "><" + tag + ">"; stack.push({ indent, tag }); }
      } else { out += "<" + tag + ">"; stack.push({ indent, tag }); }
      out += "<li>" + inline(text);
    };
    while (i < lines.length) {
      const l = lines[i];
      let m;
      if (/^\s*```/.test(l)) {
        flushPara(); closeList();
        const code = []; i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
        out += "<pre><code>" + esc(code.join("\n")) + "</code></pre>"; i++; continue;
      }
      if ((m = l.match(/^\s{0,3}(#{1,6})\s+(.*)$/))) { flushPara(); closeList(); const n = Math.min(4, m[1].length); out += "<h" + n + ">" + inline(m[2].replace(/\s#+\s*$/, "")) + "</h" + n + ">"; }
      else if ((m = l.match(/^([ \t]*)[-*+]\s+(.*)$/))) { flushPara(); item(m[1].replace(/\t/g, "    ").length, "ul", m[2]); }
      else if ((m = l.match(/^([ \t]*)\d+[.)]\s+(.*)$/))) { flushPara(); item(m[1].replace(/\t/g, "    ").length, "ol", m[2]); }
      else if ((m = l.match(/^\s*>\s?(.*)$/))) { flushPara(); closeList(); out += "<blockquote>" + inline(m[1]) + "</blockquote>"; }
      else if (/^\s*$/.test(l)) { flushPara(); closeList(); }
      else { closeList(); para.push(l.trim()); }
      i++;
    }
    flushPara(); closeList();
    return out;
  }
  function plain() { return document.getElementById("a").innerText.trim(); }
  function copy() {
    window.webkit.messageHandlers.summarize.postMessage({ copy: plain() });
    const b = document.getElementById("copy"); b.textContent = "Copied"; b.className = "done";
    setTimeout(() => { b.textContent = "Copy"; b.className = ""; }, 1200);
  }
  document.addEventListener("keydown", e => {
    if (e.key === "Escape" || (e.metaKey && e.key === "w")) window.webkit.messageHandlers.summarize.postMessage("close");
    if (e.metaKey && e.key === "c" && !String(window.getSelection())) { e.preventDefault(); copy(); }
  });
  function setAnswer(t) { document.getElementById("first").innerHTML = md(t); fit(); }
  // ask Hammerspoon to grow the window to fit the content, up to 700px (then it scrolls)
  function fit() {
    requestAnimationFrame(() => {
      const a = document.getElementById("a");
      const need = document.querySelector(".bar").offsetHeight + a.scrollHeight + document.querySelector(".reply").offsetHeight;
      window.webkit.messageHandlers.summarize.postMessage({ height: need });
    });
  }
  // follow-ups: each exchange is appended under the previous one. Several can be in flight at once
  // (each has an id); "Ask for details" ones don't scroll, so you can keep stacking them.
  const box = document.getElementById("r");
  let nextId = 0;
  const pending = {};   // id -> { el, quiet }
  function grow() { box.style.height = "auto"; box.style.height = Math.min(120, box.scrollHeight) + "px"; }
  box.addEventListener("input", grow);
  function send(q, quiet) {
    const id = ++nextId;
    const turn = document.createElement("div"); turn.className = "turn";
    const you = document.createElement("div"); you.className = "you"; you.textContent = q;
    const el = document.createElement("div"); el.className = "pending"; el.textContent = "…";
    turn.appendChild(you); turn.appendChild(el);
    document.getElementById("a").appendChild(turn);
    pending[id] = { el, quiet };
    if (!quiet) el.scrollIntoView({ block: "end" });
    fit();
    window.webkit.messageHandlers.summarize.postMessage({ followup: q, id });
  }
  box.addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      const q = box.value.trim();
      if (!q) return;
      box.value = ""; grow();
      send(q, false);
    }
  });
  // streamed: updateReply as text arrives, addReply with the final text
  function updateReply(id, t) {
    const p = pending[id]; if (!p) return;
    if (!p.div) {
      p.div = document.createElement("div"); p.el.replaceWith(p.div);
      if (!p.quiet) p.div.scrollIntoView({ block: "start" });
    }
    p.div.innerHTML = md(t);
    fit();
  }
  function addReply(id, t) {
    if (!pending[id]) return;
    updateReply(id, t);
    delete pending[id];
  }
  // Select text in the answer -> "Ask for details" button over it; triple click asks right away.
  const askBtn = document.getElementById("ask");
  const ans = document.getElementById("a");
  function selectedInAnswer() {
    const sel = window.getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return null;
    const r = sel.getRangeAt(0);
    if (!ans.contains(r.commonAncestorContainer)) return null;
    const t = String(sel).trim();
    return t ? { t, r } : null;
  }
  function askDetails(t) {
    const quoted = t.split("\n").map(l => "> " + l).join("\n");
    send(quoted + "\ntell me more about this", true);
    askBtn.style.display = "none";
    window.getSelection().removeAllRanges();
  }
  function hideAsk() { askBtn.style.display = "none"; }
  ans.addEventListener("mouseup", e => {
    setTimeout(() => {
      const s = selectedInAnswer();
      if (!s) return hideAsk();
      if (e.detail === 3) return askDetails(s.t);
      const rect = s.r.getBoundingClientRect();
      askBtn.style.display = "block";
      const bw = askBtn.offsetWidth, bh = askBtn.offsetHeight;
      const top = rect.top - bh - 6 < 50 ? rect.bottom + 6 : rect.top - bh - 6;
      askBtn.style.top = top + "px";
      askBtn.style.left = Math.max(8, Math.min(window.innerWidth - bw - 8, rect.left + rect.width / 2 - bw / 2)) + "px";
    }, 0);
  });
  askBtn.addEventListener("mousedown", e => e.preventDefault());   // keep the selection
  askBtn.addEventListener("click", () => { const s = selectedInAnswer(); if (s) askDetails(s.t); });
  ans.addEventListener("scroll", hideAsk);
  document.addEventListener("mousedown", e => { if (e.target !== askBtn) hideAsk(); });
</script></body></html>]==]

-- The answer panel, opened on the first streamed text (filled at load, no placeholder state).
local function jsString(t) return hs.json.encode({ t }):sub(2, -2) end

-- JavaScript into the panel. Until its page has loaded, calls are queued (evaluateJavaScript on a
-- loading page is silently dropped: a streamed answer stayed at its first word).
local panelReady, panelQueue = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local function panelJS(view, js)
  if not view or M.panel ~= view then return end
  if panelReady[view] then view:evaluateJavaScript(js) return end
  local q = panelQueue[view] or {}; panelQueue[view] = q
  q[#q + 1] = js
end

local function showPanel(title, answer, messages)
  M.answer = answer
  M.convo = messages
  -- a panel closed with its close button is already gone: deleting it again errored and nothing showed
  if M.panel then pcall(function() M.panel:delete() end); M.panel = nil end
  local uc = hs.webview.usercontent.new("summarize")
  uc:setCallback(function(msg)
    -- Copy puts the answer on the clipboard as Markdown (the panel only renders it)
    if type(msg.body) == "table" and msg.body.copy then hs.pasteboard.setContents(M.answer or msg.body.copy)
    elseif type(msg.body) == "table" and msg.body.height and M.panel then
      -- grow (never shrink) to fit the content plus the title bar, up to 700pt
      local f = M.panel:frame()
      local want = math.min(700, math.ceil(msg.body.height) + 30)
      if want > f.h then M.panel:frame({ x = f.x, y = f.y, w = f.w, h = want }) end
    elseif type(msg.body) == "table" and msg.body.followup and M.convo then
      -- each follow-up is sent with the conversation as it is now; several can run at once, and each
      -- exchange joins the conversation when its answer arrives
      local convo, view, id, q = M.convo, M.panel, msg.body.id or 0, msg.body.followup
      local messages = {}
      for i, m in ipairs(convo) do messages[i] = m end
      messages[#messages + 1] = { role = "user", content = q }
      busy(true)
      local onDelta = function(t)
        panelJS(view, "updateReply(" .. id .. ", " .. jsString(t) .. ")")
      end
      complete(messages, function(reply, err)
        busy(false)
        reply = reply or ("⚠️ " .. (err or "Something went wrong."))
        convo[#convo + 1] = { role = "user", content = q }
        convo[#convo + 1] = { role = "assistant", content = reply }
        M.answer = reply   -- Copy copies the latest answer
        panelJS(view, "addReply(" .. id .. ", " .. jsString(reply) .. ")")
      end, "follow-up", nil, onDelta)
    elseif msg.body == "close" and M.panel then pcall(function() M.panel:delete() end); M.panel = nil end
  end)
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local w, h = 560, 400
  local v = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + sf.h * 0.2, w = w, h = h }, {}, uc)
  v:windowStyle({ "titled", "closable", "resizable", "utility", "nonactivating" })
  v:shadow(true)
  v:windowTitle("✨ " .. title)
  v:allowTextEntry(true)
  v:level(hs.canvas.windowLevels.floating)
  v:deleteOnClose(true)
  v:windowCallback(function(action) if action == "closing" and M.panel == v then M.panel = nil end end)
  local function ready()
    if panelReady[v] then return end
    panelReady[v] = true
    for _, js in ipairs(panelQueue[v] or {}) do v:evaluateJavaScript(js) end
    panelQueue[v] = nil
  end
  v:navigationCallback(function(action) if action == "didFinishNavigation" then ready() end end)
  M.panelReadyTimer = hs.timer.doAfter(0.5, ready)   -- in case the load callback never comes
  -- fill the answer, then put the cursor in the follow-up box so you can type straight away
  local fill = "<script>setAnswer(" .. jsString(answer) .. "); document.getElementById('q').textContent = " .. jsString(title) .. "; document.getElementById('r').focus();</script></body>"
  v:html((PANEL_HTML:gsub("</body>", function() return fill end, 1)))
  v:show()
  v:bringToFront(true)
  M.panelFocusTimer = hs.timer.doAfter(0.1, function() if M.panel == v then v:evaluateJavaScript("document.getElementById('r').focus()") end end)
  M.panel = v
  return v
end

-- Ready-made instructions, listed before anything is typed: Hyper-2 then Return = the first one.
local PRESETS = {
  { text = "Summarize", icon = "summarize", instruction = "Summarize this concisely: the key points only." },
  { text = "Super summarize", icon = "supersummarize", instruction = "Summarize this in one single sentence: the single most important point. Reply with that one sentence only." },
  { text = "Clean up", icon = "cleanup", instruction = "Clean this up: fix typos, grammar and punctuation, and tighten the wording, keeping the meaning, tone and formatting." },
}

-- Raycast-style launcher: big input, a "Suggestions" list with icons and a right-hand label, the
-- selected row highlighted, an action bar at the bottom. ↑/↓ move, Return runs, Esc or clicking
-- away closes. What's typed becomes the first row; matching presets stay below it.
local PROMPT_HTML = [==[<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: light; --ink: #1d1d1f; --muted: #86868b; --line: rgba(0,0,0,.07); --sel: rgba(0,0,0,.075); }
  html, body { margin: 0; height: 100%; background: transparent; font-family: -apple-system, system-ui, sans-serif; color: var(--ink); -webkit-font-smoothing: antialiased; overflow: hidden; }
  /* the window is larger than the card on every side so the soft shadow isn't clipped */
  .card { position: fixed; inset: 36px 48px 64px; border-radius: 22px; background: rgba(242, 242, 245, 0.97);
          box-shadow: 0 0 0 0.5px rgba(0,0,0,.12), 0 18px 50px rgba(0,0,0,.28); display: flex; flex-direction: column; overflow: hidden; }
  .top { display: flex; align-items: center; gap: 12px; padding: 18px 20px 14px; }
  .top svg { flex: none; width: 22px; height: 22px; color: #8e8e93; }
  input { flex: 1; border: 0; outline: 0; background: transparent; font: 400 21px/1.2 -apple-system, system-ui; color: var(--ink); caret-color: #0a64d6; }
  input::placeholder { color: #a1a1a6; }
  .ctx { flex: none; font-size: 13px; color: var(--muted); }
  .head { font-size: 12px; font-weight: 500; color: var(--muted); padding: 6px 22px 6px; border-top: 1px solid var(--line); padding-top: 12px; }
  .list { flex: 1; overflow-y: auto; padding: 0 8px; }
  .row { display: flex; align-items: center; gap: 12px; padding: 9px 12px; border-radius: 10px; cursor: default; }
  .row.sel { background: var(--sel); }
  .ic { flex: none; width: 26px; height: 26px; border-radius: 7px; display: grid; place-items: center; color: #fff; }
  .ic svg { width: 16px; height: 16px; }   /* (26 - 16) / 2 = 5: whole pixels, so icons sit dead centre */
  .t { font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .s { font-size: 14px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; }
  .k { flex: none; font-size: 13px; color: var(--muted); }
  .bar { display: flex; align-items: center; justify-content: flex-end; gap: 10px; padding: 10px 14px; border-top: 1px solid var(--line); font-size: 13px; }
  .bar .act { font-weight: 500; }
  .kbd { display: inline-grid; place-items: center; min-width: 20px; height: 20px; padding: 0 4px; border-radius: 5px; border: 1px solid rgba(0,0,0,.15); font-size: 11px; color: var(--muted); }
</style></head><body><div class="card">
  <div class="top">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l1.9 4.6L18.5 9.5l-4.6 1.9L12 16l-1.9-4.6L5.5 9.5l4.6-1.9z"/><path d="M19 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/></svg>
    <input id="q" autofocus spellcheck="false" autocomplete="off">
    <span class="ctx" id="ctx"></span>
  </div>
  <div class="head" id="head">Suggestions</div>
  <div class="list" id="list"></div>
  <div class="bar"><span class="act" id="act">Run</span><span class="kbd">↵</span></div>
</div>
<script>
  const ICONS = {
    summarize: ['#ff9f0a', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M5 7h14M5 12h10M5 17h6"/></svg>'],
    supersummarize: ['#ff375f', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M5 12h14"/></svg>'],
    cleanup: ['#30b0c7', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6z"/><path d="M18 15l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6z"/></svg>'],
    settings: ['#8e8e93', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg>'],
    ask: ['#5e5ce6', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M13 6l6 6-6 6"/></svg>'],
  };
  let C = { placeholder: "", context: "", kind: "", presets: [] };
  const q = document.getElementById("q"), list = document.getElementById("list");
  let rows = [], sel = 0, open = false;
  function configure(cfg) {
    C = cfg; q.value = ""; sel = 0; open = true;
    q.placeholder = C.placeholder; document.getElementById("ctx").textContent = C.context;
    render(); q.focus();
  }
  function focusInput() { q.focus(); }
  function setContext(ctx, placeholder) { document.getElementById("ctx").textContent = ctx; if (placeholder) q.placeholder = placeholder; }
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
  function render() {
    const typed = q.value.trim();
    rows = [];
    if (typed) rows.push({ text: typed, sub: "", icon: "ask", instruction: typed, label: "Ask" });
    for (const p of C.presets) if (!typed || p.text.toLowerCase().includes(typed.toLowerCase())) rows.push({ text: p.text, sub: "", icon: p.icon, instruction: p.instruction, label: C.kind });
    const t = typed.toLowerCase();
    if (!typed || "settings".includes(t) || "system prompts".includes(t)) rows.push({ text: "Settings", sub: "", icon: "settings", instruction: "", label: "System prompts", settings: true });
    if (!typed || "change api key".includes(t) || "openrouter".includes(t)) rows.push({ text: "Change API key", sub: "", icon: "settings", instruction: "", label: "OpenRouter", apikey: true });
    sel = Math.min(sel, Math.max(0, rows.length - 1));
    list.innerHTML = rows.map((r, i) => `<div class="row${i === sel ? " sel" : ""}" data-i="${i}"><span class="ic" style="background:${ICONS[r.icon][0]}">${ICONS[r.icon][1]}</span><span class="t">${esc(r.text)}</span><span class="s">${esc(r.sub)}</span><span class="k">${esc(r.label)}</span></div>`).join("");
    document.getElementById("act").textContent = rows[sel] ? (rows[sel].icon === "ask" ? "Ask" : rows[sel].text) : "Run";
  }
  function post(m) { window.webkit.messageHandlers.prompt.postMessage(m); }
  function run() { const r = rows[sel]; if (r && open) { open = false; post(r.settings ? { settings: true } : r.apikey ? { apikey: true } : { run: r.instruction, label: r.text }); } }
  q.addEventListener("input", () => { sel = 0; render(); });
  document.addEventListener("keydown", e => {
    if (e.key === "ArrowDown") { e.preventDefault(); sel = Math.min(rows.length - 1, sel + 1); render(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); sel = Math.max(0, sel - 1); render(); }
    else if (e.key === "Enter") { e.preventDefault(); run(); }
    else if (e.key === "Escape") { open = false; post("cancel"); }
  });
  list.addEventListener("mousemove", e => { const r = e.target.closest(".row"); if (r && +r.dataset.i !== sel) { sel = +r.dataset.i; render(); } });
  list.addEventListener("click", e => { if (e.target.closest(".row")) run(); });
  window.addEventListener("blur", () => { if (open) { open = false; post("cancel"); } });
</script></body></html>]==]

-- One prompt webview, created at load and kept hidden between uses, so Hyper-2 shows it at once
-- (creating and loading a webview each time cost a visible beat).
local promptView
local onPromptRun

-- Esc as a hotkey while the prompt is up: works even before the box has taken the keyboard.
M.escKey = hs.hotkey.new({}, "escape", function()
  onPromptRun = nil
  if promptView then promptView:hide() end
  M.escKey:disable()
end)

local function hidePrompt()
  if promptView then promptView:hide() end
  M.escKey:disable()
end

local function buildPrompt()

  local uc = hs.webview.usercontent.new("prompt")
  uc:setCallback(function(msg)
    if type(msg.body) == "table" and msg.body.run then
      local run = onPromptRun; onPromptRun = nil
      hidePrompt()
      if run then run(msg.body.run, msg.body.label) end
    elseif type(msg.body) == "table" and msg.body.settings then
      onPromptRun = nil
      hidePrompt()
      M.editPrompts()
    elseif type(msg.body) == "table" and msg.body.apikey then
      onPromptRun = nil
      hidePrompt()
      M.askKey(nil)
    elseif msg.body == "cancel" then
      onPromptRun = nil
      hidePrompt()
    end
  end)
  local w, h = 740 + 96, 242 + 92 + 100 + 44   -- card (input, heading, six rows, action bar) plus room for the shadow
  local v = hs.webview.new({ x = 0, y = 0, w = w, h = h }, {}, uc)
  -- Non-activating panel (like Spotlight / Raycast): takes the keyboard while the app you were in
  -- stays active. Activating Hammerspoon instead set off its window filters, which froze it for
  -- seconds, and its blur event never fired, so clicking away was slow to dismiss.
  v:windowStyle({ "borderless", "nonactivating" })
  v:transparent(true)
  v:shadow(false)   -- the card draws its own
  v:allowTextEntry(true)
  v:level(hs.canvas.windowLevels.modalPanel)
  v:deleteOnClose(false)
  v:html(PROMPT_HTML)
  promptView = v
end

local function prompt(placeholder, context, kind, onInstruction)
  if not promptView then buildPrompt() end
  onPromptRun = onInstruction
  local presets = {}
  for _, p in ipairs(PRESETS) do presets[#presets + 1] = { text = p.text, icon = p.icon, instruction = p.instruction } end
  promptView:evaluateJavaScript("configure(" .. hs.json.encode({ placeholder = placeholder, context = context, kind = kind, presets = presets }) .. ")")
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local f = promptView:frame()
  promptView:topLeft({ x = sf.x + (sf.w - f.w) / 2, y = sf.y + sf.h * 0.18 - 36 })
  promptView:show()
  promptView:bringToFront(true)
  promptView:evaluateJavaScript("focusInput()")
  M.escKey:enable()
  local t = M.showTimingFor; M.showTimingFor = nil
  if t then wlog("summarize timing: focus check %dms, selection %dms, screenshot %dms, prompt shown %dms",
    t.focus, t.sel, t.shot, math.floor((hs.timer.secondsSinceEpoch() - t.t0) * 1000)) end
end

-- The system prompt editor: four text areas, Save / Reset to defaults. Esc or ⌘W closes.
local EDITOR_HTML = [==[<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: light; }
  html, body { height: 100%; margin: 0; }
  body { font: 13px/1.5 -apple-system, system-ui, sans-serif; color: #1d1d1f; background: #fbfbfd; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding: 16px 18px 6px; display: grid; gap: 16px; }
  label { display: grid; gap: 6px; font-weight: 600; font-size: 13px; }
  label span { font-weight: 400; color: #6e6e73; font-size: 12px; }
  textarea { width: 100%; box-sizing: border-box; min-height: 92px; resize: vertical; border: 1px solid #dcdce2; border-radius: 10px;
             padding: 9px 11px; font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #1d1d1f; background: #fff; outline: none; }
  textarea:focus { border-color: #9db8e6; box-shadow: 0 0 0 3px rgba(10,100,214,.12); }
  .bar { flex: none; display: flex; gap: 8px; justify-content: flex-end; padding: 12px 18px; border-top: 1px solid #ececf0; }
  button { font: 600 13px -apple-system, system-ui; border: 0; border-radius: 8px; padding: 7px 14px; cursor: pointer; }
  .save { background: #1d1d1f; color: #fff; } .reset { background: #ececf0; color: #1d1d1f; } .done { background: #34c759; color: #fff; }
</style></head><body>
<div class="scroll">
  <label>Base <span>Added at the start of every request.</span><textarea id="base" placeholder="e.g. I work in marketing. Be direct."></textarea></label>
  <label>Screenshot <span>Nothing selected: the front window is sent as a screenshot.</span><textarea id="screenshot"></textarea></label>
  <label>Selected text <span>Text highlighted outside a text field (web page, PDF, email). Answers in the panel.</span><textarea id="selected"></textarea></label>
  <label>Editable text <span>Text selected in a text field. The reply replaces the selection, so it must be only the new text.</span><textarea id="editable"></textarea></label>
</div>
<div class="bar"><button class="reset" onclick="post({reset:true})">Reset to defaults</button><button class="save" id="save" onclick="save()">Save</button></div>
<script>
  const ids = ["base", "screenshot", "selected", "editable"];
  function post(m) { window.webkit.messageHandlers.prompts.postMessage(m); }
  function fill(p) { for (const k of ids) document.getElementById(k).value = p[k] || ""; }
  function save() { const p = {}; for (const k of ids) p[k] = document.getElementById(k).value; post({ save: p });
    const b = document.getElementById("save"); b.textContent = "Saved"; b.className = "done"; setTimeout(() => { b.textContent = "Save"; b.className = "save"; }, 1200); }
  document.addEventListener("keydown", e => {
    if (e.key === "Escape" || (e.metaKey && e.key === "w")) post("close");
    if (e.metaKey && e.key === "s") { e.preventDefault(); save(); }
  });
</script></body></html>]==]

function M.editPrompts()
  if M.editor then pcall(function() M.editor:delete() end); M.editor = nil end
  local uc = hs.webview.usercontent.new("prompts")
  uc:setCallback(function(msg)
    local b = msg.body
    if type(b) == "table" and b.save then
      local out = {}
      for k in pairs(DEFAULT_PROMPTS) do if type(b.save[k]) == "string" then out[k] = b.save[k] end end
      hs.settings.set(PROMPTS_KEY, out)
    elseif type(b) == "table" and b.reset then
      hs.settings.clear(PROMPTS_KEY)
      if M.editor then M.editor:evaluateJavaScript("fill(" .. hs.json.encode(prompts()) .. ")") end
    elseif b == "close" and M.editor then
      pcall(function() M.editor:delete() end); M.editor = nil
    end
  end)
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local w, h = 640, 680
  local v = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + math.max(20, (sf.h - h) / 2), w = w, h = h }, {}, uc)
  v:windowStyle({ "titled", "closable", "resizable", "utility", "nonactivating" })
  v:windowTitle("Summarize: system prompts")
  v:allowTextEntry(true)
  v:level(hs.canvas.windowLevels.floating)
  v:deleteOnClose(true)
  v:windowCallback(function(action) if action == "closing" and M.editor == v then M.editor = nil end end)
  local fill = "<script>fill(" .. hs.json.encode(prompts()) .. ");</script></body>"
  v:html((EDITOR_HTML:gsub("</body>", function() return fill end, 1)))
  v:show()
  v:bringToFront(true)
  M.editor = v
end

-- Chrome in front with nothing selected: is the page an article (blog post, essay)? onDone(info or nil).
-- Runs extract.js in the page, which needs Chrome's View > Developer > Allow JavaScript from Apple Events;
-- without it the screenshot is used.
local EXTRACT_JS = DIR .. "/extract.js"
local function detectArticle(onDone)
  M.articleTask = hs.task.new("/usr/bin/osascript", function(code, out)
    local ok, j = pcall(hs.json.decode, out or "")
    onDone(code == 0 and ok and type(j) == "table" and j.article and j or nil, "page")
  end, { "-e", 'set js to read (POSIX file "' .. EXTRACT_JS .. '") as «class utf8»',
         "-e", 'tell application "Google Chrome" to execute active tab of front window javascript js' })
  M.articleTask:start()
end

-- First answer streamed into the panel: it opens on the first text, fills in as the rest arrives.
-- Returns onDelta, onDone for ask().
local function streamToPanel(title)
  local view
  local function live() return view and M.panel == view end
  local onDelta = function(t)
    if not view then showPanel(title, t, nil); view = M.panel
    elseif live() then M.answer = t; panelJS(view, "setAnswer(" .. jsString(t) .. ")") end
  end
  local onDone = function(reply, messages)
    busy(false)
    if not reply then
      if live() then panelJS(view, "setAnswer(" .. jsString((M.answer or "") .. "\n\n⚠️ The answer was cut off.") .. ")") end
      return
    end
    if not view then showPanel(title, reply, messages); return end
    if live() then
      M.answer, M.convo = reply, messages
      panelJS(view, "setAnswer(" .. jsString(reply) .. ")")
    end
  end
  return onDelta, onDone
end

function M.run()
  local t0 = hs.timer.secondsSinceEpoch()
  local ms = function() return math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000) end
  local app = hs.application.frontmostApplication()
  local editable, role, focused = inTextField()
  local tFocus = ms()
  grabSelection(function(selection, saved)
    local tSel = ms()
    hs.pasteboard.setContents(saved or "")   -- clipboard back right away; the paste swaps it briefly
    if editable and selection ~= "" then
      prompt("What should I do with the selection?", #selection .. " characters selected", "Selection",
             function(instruction)
        if app then app:activate() end
        busy(true)
        ask(instruction, selection, function(reply)
          busy(false)
          if reply then paste(reply, saved) end
        end)
      end)
      return
    end
    if selection ~= "" then
      -- text highlighted outside a text field (web page, PDF, email…): work on that text only, answer in the panel
      wlog("summarize: selected-text mode (focus role %s, %d chars)", tostring(role), #selection)
      prompt("What should I do with the selected text?", #selection .. " characters selected", "Selection",
             function(instruction, label)
        busy(true)
        local onDelta, onDone = streamToPanel(label or instruction)
        ask(instruction, selection, onDone, nil, systemPrompt("selected"), onDelta)
      end)
      return
    end
    -- nothing selected: screenshot mode

    local tShot = ms()
    -- encoded after the prompt is on screen (writing the PNG alone took a visible beat before it showed),
    -- in the background while you type; a quick Return waits for it
    local shot, shotReady, waiting = nil, false, nil
    captureScreenshot(function(url)
      shot, shotReady = url, true
      if waiting then local w = waiting; waiting = nil; w() end
    end)
    -- in Chrome, look for an article at the same time; found -> its text replaces the screenshot
    local article, articleDone, articleWaiting = nil, true, nil
    if app and app:bundleID() == "com.google.Chrome" and hs.fs.attributes(EXTRACT_JS) then
      articleDone = false
      local tA = hs.timer.secondsSinceEpoch()
      detectArticle(function(a, how)
        wlog("summarize: article check %s in %dms%s", a and "found" or "none",
                     math.floor((hs.timer.secondsSinceEpoch() - tA) * 1000), a and string.format(" (%s, %d words)", how, a.words or 0) or "")
        article, articleDone = a, true
        if a and promptView then
          local t = a.title and a.title ~= "" and a.title or "Article"
          promptView:evaluateJavaScript("setContext(" .. hs.json.encode({ string.format("Article · %s · %s words", t, a.words or "?") }):sub(2, -2)
                                        .. ", 'Ask about this article…')")
        end
        if articleWaiting then local w = articleWaiting; articleWaiting = nil; w() end
      end)
    end
    wlog("summarize: screenshot mode (focus role %s, %d selected chars)", tostring(role), #selection)
    M.showTimingFor = { focus = tFocus, sel = tSel, shot = tShot, t0 = t0 }
    prompt("Ask about what's on screen…", "Screenshot", "Screenshot",
           function(instruction, label)
      busy(true)
      local function go()
        if article then
          local text = "Title: " .. (article.title or "") .. "\nURL: " .. (article.url or "") .. "\n\n" .. (article.text or "")
          local onDelta, onDone = streamToPanel(label or instruction)
          ask(instruction, text, onDone, nil, systemPrompt("selected"), onDelta)
          return
        end
        if not shot then busy(false); hs.alert.show("Couldn't take the screenshot (Screen Recording permission?)"); return end
        local onDelta, onDone = streamToPanel(label or instruction)
        ask(instruction, selection, onDone, shot, nil, onDelta)
      end
      local function proceed()
        if article or shotReady then go() else waiting = go end
      end
      if articleDone then proceed()
      else
        -- a quick Return waits for the article check, at most 3s (then the screenshot)
        local fired = false
        local once = function() if not fired then fired = true; articleWaiting = nil; proceed() end end
        articleWaiting = once
        M.articleTimer = hs.timer.doAfter(3, once)
      end
    end)
  end, focused)
end

-- Bind the hotkey (default Hyper-2 = ⌘⌥⌃⇧2). opts.hotkey = { mods, key }.
-- Optional: Caps Lock as a Hyper key (start({ capsLockHyper = true }), offered by the installer).
-- macOS can't map one key to four modifiers by itself, so: hidutil turns Caps Lock into F18 (re-applied
-- each time Hammerspoon starts, since hidutil mappings don't survive a restart), and an event tap adds
-- ⌘⌥⌃⇧ to every key pressed while F18 is held. Caps Lock+2 runs Summarize directly.
-- Leaves things alone if another keyboard remapping is already set with hidutil.
local CAPS, F18 = 0x700000039, 0x70000006D
local F18_CODE = hs.keycodes.map.f18
local HYPER = { cmd = true, alt = true, ctrl = true, shift = true }

local function startCapsHyper(hk)
  M.capsMapTask = hs.task.new("/usr/bin/hidutil", function(_, out)
    out = out or ""
    local mine = out:find(tostring(CAPS), 1, true) and out:find(tostring(F18), 1, true)
    local _, entries = out:gsub("MappingSrc", "")
    if entries > 0 and not (mine and entries == 1) then
      hs.alert.show("Summarize: Caps Lock wasn't turned into Hyper, another key remapping is already set")
      return
    end
    if not mine then
      M.capsSetTask = hs.task.new("/usr/bin/hidutil", nil, { "property", "--set", string.format(
        '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":%d,"HIDKeyboardModifierMappingDst":%d}]}', CAPS, F18) })
      M.capsSetTask:start()
    end
  end, { "property", "--get", "UserKeyMapping" })
  M.capsMapTask:start()

  local held = false
  local runKey = hs.keycodes.map[hk[2]]
  if M.capsTap then M.capsTap:stop() end
  M.capsTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp }, function(e)
    local code = e:getKeyCode()
    if code == F18_CODE then
      held = e:getType() == hs.eventtap.event.types.keyDown
      return true
    end
    if not held then return false end
    if code == runKey then
      if e:getType() == hs.eventtap.event.types.keyDown then M.run() end
      return true
    end
    e:setFlags(HYPER)   -- every other key: pass it on as Hyper+key
    return false
  end)
  M.capsTap:start()
  -- macOS switches off an event tap whose callback runs long; turn it back on
  M.capsWatch = hs.timer.doEvery(10, function()
    if M.capsTap and not M.capsTap:isEnabled() then M.capsTap:start() end
  end)
end

function M.start(opts)
  opts = opts or {}
  -- Summarize only works while Hammerspoon runs, and Hammerspoon doesn't start at login by default: turn that on
  -- (start({ autoLaunch = false }) to leave it alone).
  if opts.autoLaunch ~= false and hs.autoLaunch and not hs.autoLaunch() then hs.autoLaunch(true) end
  local hk = opts.hotkey or { { "cmd", "alt", "ctrl", "shift" }, "2" }
  if M.hotkey then M.hotkey:delete() end
  M.hotkey = hs.hotkey.bind(hk[1], hk[2], function() M.run() end)
  if opts.capsLockHyper then startCapsHyper(hk) end
  if not promptView then buildPrompt() end
  return M
end

return M
