# Security Policy

## Reporting a vulnerability

Please don't report security problems in public issues.

Report them privately through [GitHub's private vulnerability reporting](https://github.com/JoshuaHolme/HolmeTheater/security/advisories/new),
or by email to [support@holme.tech](mailto:support@holme.tech) with "Security" in the subject. Include what you found,
how to reproduce it, and what an attacker could do with it.

You'll get a reply within a week. Once a fix is released, you'll be credited in the release notes unless you'd rather
not be.

## Supported versions

Fixes go into the latest release on the App Store and the `main` branch.

## Scope

In scope: this app's code, such as how it stores and sends your access token, what it sends to which hosts, how it
handles downloaded files, and how it parses data from the server.

Out of scope: vulnerabilities in Jellyfin Server or in [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift).
Please report those to the [Jellyfin project](https://github.com/jellyfin/jellyfin/security).

For how the app handles connections and tokens, see [Security notes](README.md#security-notes) in the README.
