
# GitLab Portfolio Management Dashboard — README

> A single HTML report that turns your GitLab data into portfolio‑level insights for engineers, managers, and auditors.

---

## 1) What this is

This project ships a **PowerShell report generator** and a **responsive HTML dashboard template**. The script queries your GitLab instance, populates the template, and writes a self‑contained `output.html` that you can open in any browser. The dashboard renders charts with **Chart.js** and shows metrics for delivery, adoption, security, and maintainability.

**Output files**
- `output.html` — the generated report (open in your browser).
- `gitlab-report-template.html` — the template the script fills with data.
- `README.md` — this document.

---

## 2) Who this serves

- **New engineers (fresh grads):** exact definitions, concrete tasks that move the score.
- **Non‑technical managers:** trend lines, traffic‑light summaries, actions that protect delivery.
- **Auditors:** data lineage, formulas, endpoints, and reproducibility notes.

---

## 3) Quick start

> You need: PowerShell 7+, network access to your GitLab, and an access token with at least `read_api` scope (or `api` if your instance requires it to read certain endpoints like security findings).

1. **Create a Personal Access Token (PAT)**
   - Scope: start with `read_api`. Use `api` only if your instance requires it for the endpoints you read.
   - Keep the token secret. Set it through an environment variable or your CI/CD secrets.

2. **Set environment variables (recommended)**
   ```powershell
   $env:GITLAB_BASE_URL   = "https://gitlab.example.com"   # or https://gitlab.com
   $env:GITLAB_GROUP_ID   = "12345"                        # numeric group ID or full path
   $env:GITLAB_TOKEN      = "<your-token>"
   $env:GITLAB_DAYS_BACK  = "360"                          # analysis window
   $env:REPORT_TEMPLATE   = ".\gitlab-report-template.html"
   $env:REPORT_OUTFILE    = ".\output.html"
   ```

3. **Run the generator script**
   ```powershell
   pwsh .\gitlab-report-template-exec.ps1
   ```
   > If your script exposes parameters, pass them accordingly (for example `-BaseUrl`, `-GroupId`, `-AccessToken`, `-DaysBack`, `-TemplatePath`, `-OutFile`). Use environment variables when in doubt.

4. **Open the report**
   - Double‑click `output.html` or serve it as a static file behind your internal portal.

> Tip: Schedule the script in GitLab CI, a Windows Task Scheduler job, or a cron‑like runner and publish `output.html` daily.

---

## 4) What the dashboard shows (and how to read it)

The header shows the **report date**, the **analysis window** in days, the **execution time**, and the **number of projects assessed**.

### KPI tiles (top row)

- **Portfolio footprint** — count of projects in scope.
- **Active delivery** — number of projects with recent activity (≤ 30 days). “Activity” includes commits, issues, or merge requests updates.
- **Adoption strength** — percentage of projects operating at **Medium** or **High** adoption based on a 0–100 score (see “Adoption score” below).
- **Delivery reliability** — average CI/CD pipeline pass rate across tracked projects.
- **Security exposure** — total **Critical** vulnerabilities across the portfolio (from SAST/Dependency Scanning, etc.).
- **Maintainability index** — average maintainability benchmark derived from complexity, duplication, and technical‑debt signals.

> Click into **Project Health** table rows to see per‑project overlays with last activity, open issues, pipeline success, contributors, and recommended next steps.

### Charts (middle row)

- **Adoption distribution** — how many projects sit in Very‑Low / Low / Medium / High bands.
- **Activity timeline** — trend by week or month.
- **Pipeline success rates** — reliability across projects.
- **Contribution distribution** — contributor concentration (detect single‑developer projects).

### Executive Insights

- Delivery, Security, Adoption, and Collaboration highlights with “Quick Wins”. Use this for weekly leadership briefings.

---

## 5) KPI definitions, formulas, and data lineage

This section spells out exactly what we count and why. It also lists the GitLab API endpoints commonly used to derive the numbers. If your instance uses GraphQL or mirror endpoints, adapt accordingly.

> **Scope:** All projects returned for the configured group (or namespace) within the analysis window (`DAYS_BACK`).

### 5.1 Portfolio footprint
- **Definition:** Number of projects assessed during this run.
- **How:** Count projects collected for the target group.
- **Endpoints:** `GET /groups/:id/projects` (REST) or GraphQL `group { projects { ... } }`.
- **Notes:** Use pagination. Respect archived filters if you exclude them.

### 5.2 Active delivery
- **Definition:** Projects with commits, issues, or MRs updated in the last **30 days**.
- **How:** For each project, evaluate `last_activity_at` or combine events (commits, issue updates, MR updates). Mark **active** if within threshold (30 days by default).
- **Endpoints:** 
  - Projects metadata: `GET /projects/:id` (field `last_activity_at`).
  - Issues: `GET /projects/:id/issues?updated_after=...`
  - Merge requests: `GET /projects/:id/merge_requests?updated_after=...`
  - Commits: `GET /projects/:id/repository/commits?since=...`

### 5.3 Adoption score (0–100) and **Adoption strength**
- **Definition:** A composite score that reflects GitLab utilization. The dashboard classifies scores into bands:
  - **High:** 80–100
  - **Medium:** 60–79
  - **Low:** 40–59
  - **Very Low:** 0–39
- **Suggested inputs:** activity recency, number of contributors, CI success rate, and MR throughput/reviews.
- **Adoption strength KPI:** Share of projects with **Medium** or **High** adoption.

> The scoring weights can be tailored in your script to match team policy. Keep the thresholds stable for quarter‑over‑quarter comparability.

### 5.4 Delivery reliability (mean pipeline pass rate)
- **Definition:** Average percentage of pipelines in the analysis window whose **status == success**.
- **How:** For each project, count `successful_pipelines / total_pipelines` in window; average across projects running pipelines.
- **Endpoints:** `GET /projects/:id/pipelines?updated_after=...` then inspect `status`.

### 5.5 Security exposure (Critical vulnerabilities)
- **Definition:** Count of **Critical** severity vulnerabilities across in‑scope projects.
- **How:** Read vulnerability findings from security scans (SAST, Dependency Scanning, Container Scanning, etc.). Filter by severity = `critical`. Sum across projects.
- **Endpoints:** Prefer **GraphQL** `vulnerabilities` for stability. REST alternatives include:
  - `GET /projects/:id/vulnerability_findings`
  - `GET /projects/:id/vulnerabilities` (varies by GitLab version; Ultimate tier)
- **Permissions:** Requires sufficient permissions and a tier that exposes vulnerabilities.

### 5.6 Maintainability index (portfolio)
- **Definition:** An aggregate maintainability indicator derived from Code Quality findings (complexity, duplication, smells) or an internal maintainability formula normalized to 0–100.
- **How (one approach):** Convert Code Quality severities to points (e.g., Blocker/High/Medium/Low), calculate per‑project score, then average.
- **Endpoints / artifacts:** CI job artifacts that produce **Code Quality** reports; or project‑level metrics if you export them.

### 5.7 Project Health table columns (per project)
- **Health Score:** the same 0–100 composite used for “Adoption score”.
- **Adoption Level:** categorical band (Very‑Low, Low, Medium, High) mapped from Health Score.
- **Last Activity:** days since latest activity.
- **Open Issues:** current open issue count.
- **Pipeline Success:** pass‑rate percentage for the window.
- **Contributors:** number of unique authors (commits) or project members contributing in the window.

> **Auditors:** retain the raw JSON snapshots you fetch per project. Keep a run manifest with the exact URL, params, page counts, and timestamps for each call. That creates a defensible trail.

---

## 6) How to improve the scores (for teams)

These moves work in any stack and raise the portfolio score fast:

1. **Turn on CI for all projects.** Add a minimal `.gitlab-ci.yml` with a lint step that must pass. 
2. **Fix flaky pipelines.** Triage the top failed job and reduce the fail ratio week over week.
3. **Enable SAST + Dependency Scanning.** Start with default templates. Remediate or dismiss with reason.
4. **Review more, faster.** Enforce MR approvals. Set an SLA for review latency (e.g., <48h).
5. **Broaden contribution.** Avoid single‑maintainer repos. Pair up on stuck MRs.

---

## 7) Data collection details (endpoints, scopes, and pagination)

> The table below maps major metrics to common GitLab API calls. Adjust for GraphQL if you prefer it or if REST is deprecated for a domain (for example, vulnerabilities).

| Metric | Primary endpoints | Notes |
|---|---|---|
| Projects in scope | `GET /groups/:id/projects` | Use pagination. Exclude archived if needed. |
| Last activity | `GET /projects/:id` | Field `last_activity_at`; sortable under groups/projects list. |
| Issues | `GET /projects/:id/issues?state=opened&updated_after=...` | Use `issues_statistics` for totals if preferred. |
| Merge requests | `GET /projects/:id/merge_requests?state=opened&updated_after=...` | Consider `merged_after` when computing throughput. |
| Pipelines | `GET /projects/:id/pipelines?updated_after=...` then `GET /projects/:id/pipelines/:pipeline_id` | Inspect `status` for success rate. |
| Contributors | `GET /projects/:id/repository/contributors` | The count does not include merge commits. |
| Vulnerabilities | GraphQL `vulnerabilities`; or `vulnerability_findings` / `vulnerabilities` | Requires permissions and tier that exposes data. |
| Code Quality | CI artifact `gl-code-quality-report.json` | Produced by your code quality job in CI. |

**Authentication**
- Use a **Personal Access Token** with `Authorization: Bearer <token>` (or legacy `Private-Token` header).
- Scope: `read_api` is usually enough for read‑only access. Some endpoints or self‑managed policies may require `api`.

**Pagination**
- Respect `page` and `per_page` params (REST). Loop until headers no longer include `x-next-page`.

**Rate limits**
- GitLab.com and self‑managed instances enforce rate limits. Batch and back‑off. Prefer GraphQL when it reduces call volume.

---

## 8) Reproducibility and audit notes

- **Run manifest:** Stamp each run with start/end timestamps, base URL, group ID, window, and script version. 
- **Immutable artifacts:** Archive the raw JSON pages you fetched for issues, MRs, pipelines, vulnerabilities.
- **Deterministic scoring:** Keep scoring rules in one function and version them. Never change thresholds mid‑quarter without a documented migration note.
- **Rounding:** Round percentages at the last step to avoid drift (e.g., keep two decimals internally; display one).

---

## 9) Operating the generator

### 9.1 CI schedule (example)

```yaml
# .gitlab-ci.yml (example)
stages: [report]

report:gitlab-portfolio
  stage: report
  image: mcr.microsoft.com/powershell:latest
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'
  script:
    - pwsh ./gitlab-report-template-exec.ps1
  artifacts:
    when: always
    paths: [output.html]
    expire_in: 30 days
```

- Store tokens as **masked CI variables**.
- Publish `output.html` with Pages, a static bucket, or behind an internal portal.

### 9.2 Local troubleshooting

- **401/403:** token lacks scope or project access; verify membership and token scopes.
- **429:** you hit rate limits; add sleeps, reduce `per_page`, or schedule off‑peak.
- **Empty tiles:** no data in window; increase `DAYS_BACK` or check permission to private projects.
- **Broken charts:** verify `Chart.js` is reachable and the template was filled correctly.

---

## 10) Governance and security

- Store tokens in secret stores, not in scripts or repo files.
- Limit PATs to `read_api` for read‑only jobs; rotate regularly.
- Restrict who can publish the HTML externally; the report can contain sensitive stats.
- Record **who ran** the job and **what version** produced the report.

---

## 11) Glossary (plain‑English)

- **Project footprint:** number of projects you track this run.
- **Active delivery:** project had activity in the last 30 days.
- **Adoption score:** 0–100 roll‑up of GitLab usage (activity, contributors, CI, reviews). High ≥ 80.
- **Pipeline success:** share of successful pipelines out of all pipelines in window.
- **Critical vulnerability:** security finding rated *Critical* by the scanner.
- **Maintainability:** a proxy for how easy code is to work with; derived from code quality signals.

---

## 12) Change the scoring

You can tailor weights to match your standards. A simple, effective baseline:

```
Score = 0.35 * PipelinePassRate
      + 0.25 * ActivityRecencyIndex
      + 0.20 * ContributorsIndex
      + 0.20 * MRThroughputIndex
```

- Keep the four bands (Very‑Low/Low/Medium/High) unchanged to retain comparability.
- Document any change in a `SCORING.md` and reference it in audit notes.

---

## 13) Legal, licensing, and attribution

- GitLab, GitLab logo, and GitLab terms apply to API usage. Respect your license tier.
- Chart.js is MIT‑licensed. Follow its license terms in your distribution.

---

## 14) References

> These links point to the exact GitLab documentation sections you will use to implement or audit the metrics.

- GitLab REST **Groups** API — list projects in a group: https://docs.gitlab.com/api/groups/
- GitLab **Projects** API — metadata and `last_activity_at`: https://docs.gitlab.com/api/projects/
- GitLab **Pipelines** API — list pipelines and statuses: https://docs.gitlab.com/api/pipelines/
- GitLab **Issues** API: https://docs.gitlab.com/api/issues/
- GitLab **Merge requests** API: https://docs.gitlab.com/api/merge_requests/
- GitLab **Issues statistics** API: https://docs.gitlab.com/api/issues_statistics/
- GitLab **Repository contributors** API: https://docs.gitlab.com/api/repositories/
- GitLab **Vulnerability Findings** (REST, deprecated) and GraphQL recommendations: https://docs.gitlab.com/api/vulnerability_findings/
- GitLab **Project vulnerabilities** API (Ultimate): https://docs.gitlab.com/api/project_vulnerabilities/
- GitLab **Code Quality** docs and report format: https://docs.gitlab.com/ci/testing/code_quality/
- Personal Access Tokens — scopes and usage: https://docs.gitlab.com/user/profile/personal_access_tokens/
- GitLab **Rate limits** (overview and GitLab.com specifics): https://docs.gitlab.com/security/rate_limits/ and https://docs.gitlab.com/api/rest/
- Chart.js documentation: https://www.chartjs.org/docs/

---

## 15) Version

- README version: 1.0
- Template version: see the comment header inside `gitlab-report-template.html`
- Script version: see the header in `gitlab-report-template-exec.ps1`

---

### Final word

Keep it simple. Ship the daily HTML. Fix what the tiles highlight. When the numbers move, culture changes.
