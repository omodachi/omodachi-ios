# Security policy

## Reporting a vulnerability

Please report it privately, in either of two ways:

- **GitHub.** On this repository's **Security** tab, press **Report a
  vulnerability**
  (<https://github.com/omodachi/omodachi-ios/security/advisories/new>). That
  opens a private security advisory which only you and the maintainer can see.
- **Email** <security@omodachi.app>.

Please do not put the details in a public issue, pull request or discussion.

Reports are read by the maintainer, Leo Zhang. There is no bug bounty.

## What to include

- The **Version** and **Build** lines from the app's Settings (for a build
  made with `scripts/build.sh`, the Build line names its commit), or the
  commit you looked at; and the iOS or iPadOS version.
- What an attacker needs (the same network, a paired computer, the unlocked
  device, ...) and what they get.
- Steps to reproduce it or a proof of concept, and what you expected instead.

## Scope

This repository: the iPhone and iPad app, including the vendored components it
builds in (`Vendor/`, listed in `docs/THIRD-PARTY.md`). The README's
[Security model](README.md#security-model) says what the app keeps on the
device and what it can ask a computer to do.

The other parts of Omodachi take reports the same two ways. Use the repository
the problem is in; if you are not sure which, email.

| Repository | What it is |
| --- | --- |
| [`omodachi-core`](https://github.com/omodachi/omodachi-core/security) | the host daemon the app talks to, and its installer |
| [`omodachi-plugin`](https://github.com/omodachi/omodachi-plugin/security) | the Omarchy plugin: the bar icon, the panel and the Install button's bootstrap |
| [`omodachi-sunshine`](https://github.com/omodachi/omodachi-sunshine/security) | the Sunshine fork that streams the remote screen |
