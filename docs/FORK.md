# Custom fork builds

The `xue-ding-e/XenTerm` fork maintains additional connection and automation
features on top of [ixbaicn/XenTerm](https://github.com/ixbaicn/XenTerm).
Install custom builds only from this fork's
[releases](https://github.com/xue-ding-e/XenTerm/releases) or from a workflow
artifact that names the exact commit you intend to use. An upstream binary
may lack these additions; replacing the executable can remove those features.
Back up the configuration before switching versions, and do not run two builds
against the same profile when testing a migration.

## Release safeguards

- A normal branch push in a fork never builds or replaces the rolling beta release
- Explicit `workflow_dispatch` can build a beta, and a `v*` tag can build a versioned release
- Versioned releases from forks are prereleases and never marked as the latest stable version
- AUR publication is restricted to stable upstream releases or an upstream-only manual dispatch
- Rolling beta replacement removes only the `beta` release; other preview releases are retained

The current GPUI source has no in-app updater implementation. If one is
introduced later, fork builds must use an explicit fork update channel or leave
automatic updates disabled. They must never silently replace a custom build
with the upstream release.

These safeguards are repository workflow rules. They do not change account
permissions, repository secrets, or any production installation.
