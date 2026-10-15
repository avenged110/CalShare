# CalShare — Background Service Plan (staged, not started)

Status: **investigation complete, nothing implemented.** Written 2026-10-11 against build 25
(1.0.0). This is the follow-up to PLAN.md §2's "Considered and deferred: a separate launchd
agent". No data migration is needed: the current data is disposable, so the user runs
Settings › Testing › Reset for Testing on the old build and sets the new build up from scratch.

## 1. Where things stand today (facts this plan depends on)

- One process. `AppModel` (CalShare/20.00) owns `let supervisor = Supervisor()` and calls it
  directly. `CalShareCore` is already process-agnostic. The only process-coupled pieces are
  `Supervisor.Options.manageProcessActivity`, `Logger.bootstrap`, and `onUpdate`.
- The app calls this Supervisor surface (it becomes the IPC protocol): `start`, `stop`,
  `snapshot`, `onUpdate`, `perform(FixAction)`, `updateConfiguration(closure)`,
  `createAccount`, `setPassword`, `deleteAccount`, `checkPassword`, `profileData`,
  `enrollmentURL`, `authorityCertificate`, `checkTrustNow`, `recheckTrust`, `restore`,
  `deleteBackup`, `export(to:)`, `eraseAllData`. (`setDisplayName` and `verifyPassword` are
  public too, but nothing in the app calls them.)
- Signing: **ad hoc** (`Signature=adhoc`, no `DEVELOPMENT_TEAM`), sandboxed, Hardened Runtime.
  Entitlements: incoming and outgoing network, Downloads read/write, user-selected files
  read/write. `REGISTER_APP_GROUPS = YES` is set, but no group is used.
- Private keys are **files** under `Certificates/` and get loaded into an in-memory
  `SecIdentity` (Certificates.swift:188). Nothing goes in the keychain, so moving data to
  another process needs no keychain access group. (This is the biggest simplifier.)
- Data lives in the app's container: `~/Library/Containers/app.CalShare/Data/Library/Application Support/`.
- In the app process today (each needs a new home): ProblemNotifier (UNUserNotificationCenter),
  the debug-logging toggle (app UserDefaults, read by `Logger`'s `isEnabled`),
  `SMAppService.mainApp` (Open at Login), trust (`SecTrustSettingsSetTrustSettings`, which
  needs UI auth), writing profiles to Downloads, the export folder panel, and the menu bar item.

## 2. Target architecture

```
CalShare.app  (sandboxed UI, LSUIElement off; can be quit anytime)
 ├─ Contents/MacOS/CalShare                       dashboard, setup assistant, menu bar item
 ├─ Contents/Library/LaunchAgents/app.CalShare.Agent.plist
 └─ Contents/Library/LoginItems/CalShare Agent.app   (sandboxed, LSUIElement, no SwiftUI)
       └─ runs Supervisor + HTTPServer + Bonjour + backups + ProblemNotifier
          vends XPC Mach service "app.CalShare.Agent.xpc" (exact name: see Spike 1)
```

- **Registration:** `SMAppService.agent(plistName: "app.CalShare.Agent.plist")`. This is a
  per-user LaunchAgent (gui/<uid> domain). It is **not** privileged: no admin password and no
  daemon. It appears in System Settings › General › Login Items & Extensions › "Allow in the
  Background", and macOS posts a "Background Items Added" notification when it's registered.
- **launchd plist:** `Label`, `BundleProgram = Contents/Library/LoginItems/CalShare Agent.app/Contents/MacOS/CalShare Agent`,
  `MachServices = { <name> = true }`, `RunAtLoad = true`,
  `KeepAlive = { SuccessfulExit = false }` (crash → relaunch; a deliberate `exit(0)` stays
  down until the next login or registration), `ProcessType = Standard`,
  `AssociatedBundleIdentifiers = app.CalShare` (so Login Items shows CalShare's name and icon).
- **The agent is a helper .app bundle, not a bare executable.** It needs its own Info.plist
  (NSLocalNetworkUsageDescription, NSBonjourServices) for Local Network privacy, and a bundle to
  post notifications. Set `CFBundleDisplayName = CalShare` and use the same icon.
- **Data ownership:** the agent alone owns all data, in its own container
  (`~/Library/Containers/app.CalShare.Agent/…`). The app touches **no** server files. That
  means no app group container, no shared SQLite, and no locking between processes.
- **Transport:** `NSXPCConnection` with a two-way `@objc` protocol. To avoid NSSecureCoding
  boilerplate, every payload is `Data` (JSON via Codable). Calls are async with a reply block.
  Push: the agent calls `snapshotChanged()` on the app's exported object, replacing
  `onUpdate`. The 5-second poll stays as a fallback.
- **Version skew:** after an app update, the old agent binary is still running. The app does
  a `hello(version: build)` handshake on every connect. If the build doesn't match, the app
  sends `relaunch`, the agent exits non-zero, and launchd starts the new binary. The protocol
  also carries a `protocolVersion` int.

## 3. Work breakdown (ordered; each step builds and runs)

1. **Spikes first (≈½ day, throwaway).** Settle these before touching CalShare:
   - **S1 Mach lookup from a sandboxed, ad hoc signed app.** Option A (preferred):
     `com.apple.security.temporary-exception.mach-lookup.global-name = [<name>]` on the app,
     with the agent sandboxed and registering the name through its plist. Option B: a
     team-less app group (`group.app.CalShare`) with the service named `group.app.CalShare.agent`.
     Check whether Sequoia's group-container prompt fires when no container is touched.
   - **S2 BTM with ad hoc signing:** does rebuilding (new cdhash) re-post "Background Items
     Added", reset the Allow toggle, or orphan the old entry? Record the exact behavior.
   - **S3 Local Network prompt** from the agent: who is it attributed to, and does it appear
     at all for a listener plus the LAN self-probe?
   - **S4 Trashed app:** with the app in Trash (Trash not emptied) and then deleted, does the
     agent still launch at the next login? Does the Login Items entry linger?
2. **Codable snapshot.** Make `SupervisorSnapshot` and its members Codable: ComponentHealth,
   ActivityEvent (its `let id = UUID()` must be encoded), CollectionSummary, AccountSummary,
   BackupRecord, RequestLogEntry, NetworkSnapshot, StoreStatistics, HealthState, FixAction.
   ServerConfiguration, ClientRecord and CollectionKind already conform. Add a round-trip test.
3. **Protocol in CalShareCore** (`AgentProtocol.swift`): `ServerRequest`/`ServerResponse`
   Codable enums that cover §1's surface. Replace `updateConfiguration(closure)` with
   `setConfiguration(ServerConfiguration)`, sent whole and last-writer-wins (one UI, so that's
   fine). `export` becomes `exportFiles() -> [(name, Data)]`, and the app writes them to the
   folder it picked, so no sandbox extension has to cross processes. Move the debug-logging
   flag into ServerConfiguration so the agent can read it.
4. **Agent target** (`CalShareAgent/`, ~150 lines): `main.swift` with NSApplication in
   `.prohibited` policy (or a plain `dispatchMain`, if notifications work without an
   NSApplication; check this), `Logger.bootstrap(fileName: "CalShare Agent.log")`,
   `Supervisor().start()`, an NSXPCListener(machServiceName:) delegate, and ProblemNotifier
   moved here as-is. Notification taps open `calshare://overview` with
   `NSWorkspace.open`, which launches or brings up the app. Entitlements: the app's network
   ones minus Downloads and user-selected files. Copy Phase in the app target: embed it in
   `Contents/Library/LoginItems` and the plist in `Contents/Library/LaunchAgents`.
5. **`ServerClient` in the app**: owns the NSXPCConnection, reconnects on
   invalidation/interruption, and exposes the same method names AppModel uses now, as
   `async`. `AppModel.supervisor` becomes `server: ServerClient`. Most call sites only gain an
   `await`. Add `connectionState: .connected | .notRunning | .disabledInSettings | .requiresApproval | .versionMismatch`.
6. **Service lifecycle UI** (§4): the setup assistant step, the Overview card, Settings, and
   Uninstall.
7. **Menu bar:** keep the MenuBarExtra in the **app**, never in the agent, so no UI code runs
   in the server. When the dashboard closes, switch to `.accessory` activation policy so the app
   is menu-bar-only. Replace "Open at Login" with "Show in menu bar at login"
   (`SMAppService.mainApp`, launched hidden). That setting no longer has anything to do with
   syncing.
8. **Remove** in-app `supervisor.start/stop` and `applicationWillTerminate` stopping the server,
   and change "Quit CalShare (Stops Syncing)" to "Quit CalShare". Reset for Testing becomes:
   XPC `eraseAllData` → `unregister()` → app prefs → quit.
9. **Tests:** existing `swift test` stays valid, since Supervisor is unchanged. Add protocol
   round-trip tests and an in-process `NSXPCListener.anonymous()` test that drives
   ServerClient end to end. Update `Scripts/smoke.sh` to quit the app and confirm the server
   still answers.
10. **Docs:** README (install, background item, uninstall), PLAN.md §2, Credits unchanged,
    COPYING in the new target folder (see `_Shared/Licensing/README.md`), and headers on new files.

Rough size: +600 to 900 lines and roughly 150 lines changed in AppModel and its views. That's
about 2 to 4 focused sessions after the spikes. Most of the risk is in S1 and S2, not the code.

## 4. User-facing changes

- **Setup assistant** gains a first step, "Turn on CalShare in the background", which calls
  `register()`. If the user has switched it off in Login Items, it shows "Open Login Items" via
  `SMAppService.openSystemSettingsLoginItems()`.
- **Overview** gains a "Background Service" card (running / turned off in System Settings / not
  responding) with a Fix button.
- **Quitting the app no longer stops syncing.** The menu bar icon is optional and only
  reflects status while the app is running.
- **Notifications** come from the agent. They still read "CalShare", but they need their own
  one-time permission.
- **Settings › General:** "Run in the background" (mirrors the BTM status), "Show in menu bar
  at login", and Keep Awake (unchanged, now applied by the agent).
- **Uninstall CalShare…** (Settings › Testing → its own section):
  1. Confirm, and offer to export first.
  2. XPC `eraseAllData`, then the agent exits.
  3. `SMAppService.agent.unregister()`. The Login Items entry goes away.
  4. Remove the CA's trust and the certificate from the login keychain
     (`SecTrustSettingsRemoveTrustSettings` and `SecItemDelete`; macOS asks for the password).
  5. Explain that the setup profiles must be removed by hand in System Settings › General ›
     Device Management on this Mac and on each iPhone or iPad. A sandboxed app can't remove
     them, and devices with a profile will show sync errors.
  6. Remove the app's own prefs and leftover profiles, reveal CalShare.app in Finder with
     "Move to Trash", and quit. A sandboxed app can't trash itself in /Applications.
- **Safety net for drag-to-Trash without uninstalling:** when the agent starts, if its bundle
  path is under `/.Trash/` or the main app bundle is missing, it logs that and calls `exit(0)`,
  which `SuccessfulExit = false` leaves down. S4 confirms whether this is needed.

## 5. What does not change

macOS does not sync while the Mac is asleep or logged out. A LaunchAgent starts at **login**,
not at boot. Ports, TLS, Bonjour, the DAV implementation, the database, backups and the trust
model all stay the same. A LaunchDaemon, which would run before login, was rejected: it needs
admin approval and runs as root outside the per-user sandbox. With FileVault, nothing runs
before login anyway.
