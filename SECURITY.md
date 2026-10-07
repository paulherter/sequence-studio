# Security policy

Sequence Studio is alpha software. Only the latest release and the `main` branch receive fixes.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting instead:
**Security > Report a vulnerability** on this repository (a private security advisory).

Include what you found, the app version or commit, a minimal way to reproduce it (a small crafted file is fine;
do not attach copyrighted footage) and what you think the impact is.

You can expect an acknowledgement within a week. This is a volunteer project, so fix times vary; we will tell you
what we plan and credit you in the release notes if you wish.

## In scope

- Memory safety or crashes triggered by crafted media, project (`.sqproj`), preset or import files
- Reading or writing files outside what the user chose
- The release DMG and its build scripts

## Out of scope

- Bugs without a security impact (open a normal issue)
- Vulnerabilities in third-party libraries that are not reachable from Sequence Studio (report those upstream)
