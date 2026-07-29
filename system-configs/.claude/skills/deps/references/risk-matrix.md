# Risk assessment

## Vulnerability severity → response time

| CVSS      | Class    | Typical                                                  | Action                          |
| --------- | -------- | -------------------------------------------------------- | ------------------------------- |
| 9.0-10.0  | Critical | RCE, privilege escalation, data exfiltration             | Update immediately              |
| 7.0-8.9   | High     | Auth bypass, SQL injection, XSS                           | Update within 48 hours          |
| 4.0-6.9   | Medium   | Information disclosure, DoS potential, input validation   | Schedule within 1 week          |
| 0.1-3.9   | Low      | Minor information leaks, edge-case vulnerabilities        | Next maintenance window         |

## Supply chain risk

**High risk** — single maintainer, recent maintainer change, unusual download patterns, missing
metadata, any history of embedded malware.

**Medium risk** — no release in over a year, small user base (<1000 downloads/week), typosquatting
potential, deep or complex dependency chains.

**Low risk** — well-established, actively maintained, large user base, corporate sponsorship.

High-risk packages get flagged for monitoring even when they have no open CVE — the risk is what
lands in the next release, not what's in this one.

## Before declaring done

- Every present ecosystem was detected (a missed manifest means a silent blind spot).
- Security databases were actually queried — a tool that isn't installed returns nothing, which is
  not the same as a clean scan.
- Updates applied introduced no breaking changes; the app still runs.
- Lock files updated and committed alongside the manifests.
- Test suite passes.
