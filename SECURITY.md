# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately by emailing
[security@pinprick.rs](mailto:security@pinprick.rs) or using
[GitHub's private vulnerability reporting](https://github.com/starhaven-io/pinprick-action/security/advisories/new).
Do not open a public issue for an undisclosed vulnerability.

Include the affected component, version, or commit; reproduction steps; potential
impact; and any suggested mitigation. We will acknowledge the report,
investigate it, and coordinate disclosure with you.

This action is a thin wrapper that installs and runs the separate pinprick
engine. Report vulnerabilities in pinprick's audit detection to the
[pinprick project](https://github.com/starhaven-io/pinprick/security/advisories/new);
issues in the wrapper itself (the checksum-verified install, exit-code mapping,
or SARIF upload) belong here.

## Supported versions

Only the latest released version of pinprick-action is supported with security fixes.
