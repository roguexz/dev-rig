# Touch ID Git Push Hook (`touchid`)

`ldx touchid` compiles a small Swift helper (`touchid_auth`) that performs a macOS **Touch ID** prompt via
`LocalAuthentication`, and installs it as a global git **pre-push** hook. Every `git push` then requires a fingerprint
before anything leaves the machine.

The helper is **biometrics-only by design**: no password fallback is offered (`localizedFallbackTitle` is emptied), and
any failure — no biometrics enrolled, timeout, or cancellation — blocks the push.

---

## How It Works

```
lib/touchid_auth.swift  --swiftc-->  $HOME/.local/bin/touchid_auth
                                          | copy
                                          v
$HOME/.config/git/hooks/git-push   <-- invoked by -->   pre-push hook
                                          ^
                          core.hookspath = $HOME/.config/git/hooks
```

- The binary is copied into the hooks directory as `git-push`, so its error lines read `git-push: …` (it derives its
  name from `argv[0]`).
- The `pre-push` hook calls the helper with a reason string like `push commits to origin`, which appears in the
  Touch ID dialog.
- Because `core.hookspath` points at `$HOME/.config/git/hooks`, the hook applies to **every** repository on the
  machine.

---

## Commands

| Command                  | Description                                                                                          |
|:-------------------------|:-----------------------------------------------------------------------------------------------------|
| `ldx touchid install`    | Compile the helper, install `git-push` + `pre-push` into `$HOME/.config/git/hooks`, set `core.hookspath`. |
| `ldx touchid uninstall`  | Remove `git-push` (and `touchid_auth` from your bin dir); restore the previous hook from `pre-push.bak`. |

### Install options

| Flag          | Description                                                              |
|:--------------|:--------------------------------------------------------------------------|
| `--dir <path>` | Bin directory for `touchid_auth` (default: `$HOME/.local/bin` or `$HOME/bin`). |

---

## Installation

```bash
ldx touchid install
```

What it does, step by step:

1. Compiles `lib/touchid_auth.swift` with `xcrun swiftc -O` into `$HOME/.local/bin/touchid_auth`
   (ad-hoc code-signed).
2. Copies the binary to `$HOME/.config/git/hooks/git-push` (executable).
3. Installs `lib/pre-push` to `$HOME/.config/git/hooks/pre-push` (executable), backing up any pre-existing hook to
   `pre-push.bak` (once).
4. Sets `git config --global core.hookspath "$HOME/.config/git/hooks"`.

## Usage

Nothing changes in your day-to-day workflow — just push as usual:

```bash
git push
# 🔒 Authentication required: Touch ID needed to push to remote...
# (Touch ID dialog: "push commits to origin")
# ✅ Authenticated. Proceeding with push...
```

You can also run the helper directly for any ad-hoc biometric confirmation:

```bash
touchid_auth "deploy to production"
```

## Behavior Notes

- **Hard block**: failed, cancelled, or unavailable biometrics block the push (exit code `1`). There is intentionally
  no password fallback.
- **Escape hatch**: `git push --no-verify` skips all hooks — use deliberately.
- The hook requires `git-push` to sit next to it; if it goes missing, pushes are blocked with a hint to rerun
  `ldx touchid install`.
- Requires a Mac with Touch ID (or another supported biometric) enrolled in System Settings.

## Uninstall

```bash
ldx touchid uninstall
```

Removes `git-push`, restores your previous `pre-push` hook from `pre-push.bak` (or removes the hook if there was no
backup), and deletes `touchid_auth` from your bin directories. `core.hookspath` is left untouched, since other hooks
may live in the same directory.

---

## Prerequisites

- Xcode Command Line Tools: `xcode-select --install`
- macOS with Touch ID enrolled
