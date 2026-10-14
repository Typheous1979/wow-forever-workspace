"""wowf — stdlib-only tooling for WoW Forever addon development.

Modules:
  lua_lexer    Lua 5.1 tokenizer (also emits Lua 5.2+ tokens so lint can flag them)
  lua_literal  safe Lua table-literal parser (Blizzard API docs, SavedVariables) — never executes Lua
  config       repo root, wowf.config.json / wowf.local.json, client discovery
  toc          TOC parsing
  index        API index (docs + FrameXML + runtime) build/query
  lint         Forever lint rules + luacheck wrapper
  deploy       junction/copy deployment into client AddOns folders
  savedvars    read SavedVariables / AddOns.txt from WTF (read-only)
  client_logs  taint log, crash reports, client logs
  probe_report WowfProbe dump -> runtime surface
  cli          command-line entry point: python tools/wowf/cli.py <command>
"""
