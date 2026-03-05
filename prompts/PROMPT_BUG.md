# Agent Startup — Bug Fix Mode

You are starting a new session on the Aperture project in bug-fix mode. Follow these steps exactly and in order.

## 1. Load Context

Read these files silently:
- `CLAUDE.md` — project overview, file map, key patterns (may already be loaded)
- `film-camera-app-architecture.md` — technical architecture

## 2. Health Check (silent)

Run the following in the background:
- `git status` — check branch and working tree
- `xcodebuild -project Aperture.xcodeproj -target Aperture -sdk iphoneos -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5` — verify project builds

Only surface results if: build fails, or there are unexpected uncommitted changes. Otherwise say nothing about health checks.

## 3. Pick the Next Bug

Run:
```bash
gh issue list --label "bug" --state open --json number,title,labels --repo georgenijo/aperture
```

From the results, pick the open issue with the highest priority label (p1 > p2 > p3). If no issues carry a priority label, pick the most recently updated open bug. If no bugs exist, stop and report "no open bug issues found."

Then run:
```bash
gh issue view <number> --json title,body --repo georgenijo/aperture
```

## 4. Create Branch

```bash
git checkout -b fix/<number>-<short-slug>
```

## 5. Present Your Plan

Tell me:
- Which bug you're fixing (issue number + name, one-line description)
- Your investigation and fix plan: root cause hypothesis, files to change, approach

Then ask: **"Confirm to proceed?"**

Do not write any code until I confirm.

## 6. Implement

After confirmation, implement the fix. Stay focused — fix the bug, nothing else.

## 7. Verify

Run before committing:
```bash
xcodebuild -project Aperture.xcodeproj -target Aperture -sdk iphoneos -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Confirm `BUILD SUCCEEDED`. If it fails, fix the issue before proceeding.

## 8. Commit and PR

1. Stage and commit with a conventional commit message (`fix: <description>`)
2. Push the branch: `git push -u origin fix/<number>-<short-slug>`
3. Open a PR:
   ```bash
   gh pr create --title "fix: <concise description>" --body "Closes #<issue-number>" --repo georgenijo/aperture
   ```
4. Report the PR URL.
