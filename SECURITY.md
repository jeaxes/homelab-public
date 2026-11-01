# Security policy

Please report security issues privately through GitHub private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for security problems.

Never include live credentials, `.env` contents or private keys in a report.

## Container dependencies

The source cleanup does not certify the bundled container images as vulnerability-free. The November 1, 2026 dependency scan reported HIGH and CRITICAL advisories in several referenced images, including IT Tools and Gitea, and HIGH advisories in Homepage, cAdvisor and Docker Socket Proxy. These are package advisory matches; reachability and impact depend on deployment configuration. A failed registry download is an incomplete scan, not a clean result.

The `Container security` workflow discovers every literal image reference in the Compose files and scans OS and application packages on pull requests, pushes to main and weekly. It fails for HIGH or CRITICAL findings, including those without an available fix. Registry or scanner failures also fail the job. It uses public images without deployment credentials or `.env` files. No findings are silently suppressed. Configure the workflow as a required check in the repository rules before relying on it as a merge gate.

Expect the check to fail while the recorded dependency findings remain. Review upstream fixes, update to a verified image reference, inspect compatibility changes and rerun the scan before deploying. Pinning a digest prevents unexpected changes; it does not remove vulnerabilities already in that image. A passing dependency scan covers its advisory database and scanned packages, and is not proof of complete runtime security.
