-- ~/.config/yay/init.lua
-- OmaShield — yay v13 native guard hooks (managed by OmaShield).
--
-- Registered in yay >= 13.0 via ~/.config/yay/init.lua. This file combines:
--   * yay-guard  (aur_audit.py) — heuristics + AUR metadata verdict; blocks
--     high/critical on install, excludes risky packages from upgrades.
--   * aur-scan   (aur-scan) — static pattern review of each downloaded
--     PKGBUILD before it is built.
--
-- Behaviour is governed by OmaShield's state file, so the panel's ON/OFF
-- switch works for the native hooks too:
--   * enabled=1   -> hooks run (yay is guarded on every invocation).
--   * enabled=0   -> no hooks are registered (yay behaves like stock).
--
-- Emergency bypass: OMASHIELD_OFF=1 (legacy AUR_SHIELD_OFF=1, or yay-guard's
-- AUR_AUDIT_OFF=1) disables these hooks for a single command. This file is
-- installed by OmaShield's first-ON wiring; the marker line "OmaShield"
-- above lets uninstall recognise and remove it safely (the pre-rename
-- "AUR Shield" marker is honoured the same way).

yay.log.debug("omashield: init.lua loaded")

----------------------------------------------------------- OmaShield state

local state_f = io.open(os.getenv("HOME") .. "/.config/omashield/state", "r")
if not state_f then
  -- Pre-rename state location (dalibor.aur-shield era).
  state_f = io.open(os.getenv("HOME") .. "/.config/aur-shield/state", "r")
end
local shield_on = true  -- default ON: absent state file still protects
if state_f then
  for line in state_f:lines() do
    if line:match("^enabled=0$") then shield_on = false end
  end
  state_f:close()
end

if not shield_on
   or os.getenv("OMASHIELD_OFF") == "1"
   or os.getenv("AUR_SHIELD_OFF") == "1"
   or os.getenv("AUR_AUDIT_OFF") == "1" then
  yay.log.info("omashield: OFF — hooks not registered (yay behaves as stock)")
  return
end

----------------------------------------------------------- binary locations

-- Locate the yay-guard audit engine wherever the package installed it.
local audit_bin = nil
for _, c in ipairs({
  os.getenv("HOME") .. "/.local/bin/aur_audit.py",
  "/usr/local/bin/aur_audit.py",
  "/usr/bin/aur_audit.py",
  "/usr/share/yay-guard/aur_audit.py",
}) do
  local f = io.open(c, "r")
  if f then f:close(); audit_bin = c; break end
end

if not audit_bin then
  yay.log.warn("omashield: aur_audit.py not found — yay-guard hooks are inert (fail-open).")
end

local PY = "python3"

-- When to request an AI verdict from the audit hook. "suspicious" only calls
-- the AI when heuristics/denylist already raised flags. Kept conservative
-- (heuristics + metadata only by default) so the report is deterministic and
-- offline; export AUR_AUDIT_ENGINE to enable your engine of choice.
local AI_MODE   = "suspicious"
local ENGINE    = nil          -- nil = inherit AUR_AUDIT_ENGINE from env
local FAIL_ON   = "high"
local STRICT    = false        -- fail-open: missing auditor warns, doesn't block
local RECENT_DAYS = 2          -- pre-exclude AUR pkgs modified this many days ago

local ALLOWLIST = {
  -- ["my-own-package"] = true,
}

----------------------------------------------------------- utilities

local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function envprefix()
  if ENGINE then return "AUR_AUDIT_ENGINE=" .. shquote(ENGINE) .. " " end
  return ""
end

local function audit(pkgbase, dir)
  if not audit_bin then return "error" end
  local cmd = envprefix() .. table.concat({
    PY, shquote(audit_bin), "hook", shquote(pkgbase), shquote(dir),
    "--ai", AI_MODE, "--fail-on", FAIL_ON, "2>&1",
  }, " ")
  local f = io.popen(cmd, "r")
  if not f then return "error" end
  local verdict = "error"
  for line in f:lines() do
    local v = line:match("^__AUR_AUDIT__=(%S+)")
    if v then
      verdict = v
    else
      io.stderr:write(line, "\n")
    end
  end
  f:close()
  return verdict
end

local function audit_upstream(names)
  local verdicts = {}
  if #names == 0 or not audit_bin then return verdicts end
  local parts = { PY, shquote(audit_bin), "check" }
  for _, n in ipairs(names) do parts[#parts + 1] = shquote(n) end
  parts[#parts + 1] = "--ai";      parts[#parts + 1] = AI_MODE
  parts[#parts + 1] = "--fail-on"; parts[#parts + 1] = FAIL_ON
  parts[#parts + 1] = "--tokens";  parts[#parts + 1] = "2>&1"

  local f = io.popen(envprefix() .. table.concat(parts, " "), "r")
  if not f then return verdicts end
  for line in f:lines() do
    local n, v = line:match("^__AUR_AUDIT__=([^=]+)=(%S+)$")
    if n then
      verdicts[n] = v
    else
      io.stderr:write(line, "\n")
    end
  end
  f:close()
  return verdicts
end

local BLOCKING = { critical = true, high = (FAIL_ON == "high") }

-- Run aur-scan over the downloaded build directory and abort on any
-- high/critical finding. Exit status is captured through a temp file because
-- gopher-lua's io.popen cannot return it directly.
local function aur_scan_dir(pkgbase, dir)
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/omashield-scan"
  local cmd = "aur-scan scan " .. shquote(dir) .. " --fail-on high --no-color" ..
              " > " .. tmp .. ".out 2>&1; printf '%s' \"$?\" > " .. tmp .. ".rc"
  local h = io.popen(cmd)
  if h then h:close() else
    yay.log.warn("aur-scan: could not run for " .. pkgbase)
    return false
  end

  local rc = "0"
  local rf = io.open(tmp .. ".rc", "r")
  if rf then rc = rf:read("*a"); rf:close() end

  local of = io.open(tmp .. ".out", "r")
  if of then io.stdout:write(of:read("*a")); of:close() end

  return rc:match("^[1-9]") ~= nil
end

--------------------------------------------------------------- AURPreInstall
-- yay-guard verdict + aur-scan pattern review, once per package, before yay
-- shows its menus or makepkg runs anything.

yay.create_autocmd("AURPreInstall", {
  desc = "AUR security review before building (yay-guard + aur-scan)",
  callback = function(event)
    local base = event.match
    if ALLOWLIST[base] then
      yay.log.debug("omashield: in allowlist, skipping review of", base)
      return
    end

    -- Layer 1: yay-guard heuristic/metadata verdict.
    if audit_bin then
      yay.log.info("omashield: yay-guard reviewing " .. base .. "…")
      local verdict = audit(base, event.data.dir)
      if verdict == "error" then
        if STRICT then
          yay.abort("omashield: could not audit " .. base .. " (strict mode).")
        else
          yay.log.warn("omashield: could not audit " .. base .. "; continuing (fail-open).")
        end
      elseif BLOCKING[verdict] then
        yay.abort(string.format(
          "omashield: yay-guard BLOCKED %s (risk=%s). Check the report above. " ..
          "To force: OMASHIELD_OFF=1 yay -S %s", base, verdict, base))
      else
        yay.log.info(string.format("omashield: yay-guard ok (%s, risk=%s)", base, verdict))
      end
    else
      yay.log.warn("omashield: yay-guard missing — skipping for " .. base)
    end

    -- Layer 2: aur-scan static pattern review of the downloaded PKGBUILD.
    if event.data.dir then
      yay.log.info("omashield: aur-scan reviewing " .. base .. "…")
      local blocked = aur_scan_dir(base, event.data.dir)
      if blocked then
        yay.abort("omashield: aur-scan BLOCKED " .. base ..
          " — high/critical pattern in the PKGBUILD. To force: OMASHIELD_OFF=1 yay -S " .. base)
      end
    end
  end,
})

--------------------------------------------------------------- UpgradeSelect
-- On `yay -Syu`, exclude risky AUR packages (recently touched or a blocking
-- verdict) and continue with the rest, printing a final report.

yay.create_autocmd("UpgradeSelect", {
  desc = "Audit AUR upgrades: exclude the risky ones, continue with the rest",
  callback = function(event)
    local excluded = {}
    local cutoff = (RECENT_DAYS and RECENT_DAYS > 0)
      and (os.time() - RECENT_DAYS * 24 * 60 * 60) or nil

    local to_audit = {}
    for _, pkg in ipairs(event.data.upgrades) do
      if pkg.repository == "aur" and not ALLOWLIST[pkg.name] then
        if cutoff and pkg.last_modified and pkg.last_modified >= cutoff then
          excluded[pkg.name] = string.format("modified <%dd ago", RECENT_DAYS)
        else
          table.insert(to_audit, pkg.name)
        end
      end
    end

    local verdicts = audit_upstream(to_audit)
    for _, name in ipairs(to_audit) do
      local v = verdicts[name]
      if v and BLOCKING[v] then
        excluded[name] = "risk=" .. v
      elseif v == nil and audit_bin then
        yay.log.warn("omashield: could not audit " .. name .. "; continuing (fail-open).")
      end
    end

    local exclude, any = {}, false
    for name, reason in pairs(excluded) do
      if not any then
        yay.log.warn("==== omashield: packages EXCLUDED from the upgrade ====")
        any = true
      end
      table.insert(exclude, name)
      yay.log.warn(string.format(
        "  - %s (%s). To install it anyway: OMASHIELD_OFF=1 yay -S %s",
        name, reason, name))
    end
    if not any then
      yay.log.info("omashield: no AUR package in the upgrade requires exclusion.")
    end

    -- skip_menu=false: yay still shows its own exclusion menu afterwards.
    return { exclude = exclude, skip_menu = false }
  end,
})
