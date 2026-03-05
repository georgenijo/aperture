# Agent Startup — Feature Mode

You are starting a new session on the Aperture project — a native iOS camera app with vintage film emulation. Follow these steps exactly and in order.

## 1. Load Context

Read these files silently:
- `CLAUDE.md` — project overview, file map, key patterns (may already be loaded)
- `film-camera-app-architecture.md` — full technical architecture and build plan
- `huji-cam-research-and-build-guide.md` — research, competitive landscape, image processing pipeline details
- Any other file relevant to your ticket

## 2. Health Check (silent)

Run `git status` — check branch and working tree. Surface results only if there are unexpected uncommitted changes. Otherwise say nothing.

## 3. Your Assignment

The issue to work on is injected at the end of this prompt — title, number, and full body are included. Do not re-fetch it.

## 4. Plan Mode

Enter plan mode (use the `EnterPlanMode` tool). While in plan mode:
- Read all files relevant to the ticket using sub-agents
- Design your implementation approach
- Write a plan covering: which ticket (issue number + name), files to change/create, approach, and any risks
- Exit plan mode for user approval

Do not write any code until the user approves the plan.

## 5. Implement

After approval, implement exactly what was planned. No scope creep — do not refactor surrounding code, add comments to unchanged code, or introduce features not in the ticket.

## 6. Verify

Run before committing:
```bash
xcodebuild -project Aperture.xcodeproj -target Aperture -sdk iphoneos -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Confirm `BUILD SUCCEEDED`. If it fails, fix the issue before proceeding.

## 7. Commit and PR

1. Stage and commit with a conventional commit message (`feat:`, `fix:`, `chore:`, etc.)
2. Push the branch: `git push -u origin <branch-name>`
3. Open a PR:
   ```bash
   gh pr create --title "<concise title>" --body "Closes #<issue-number>" --repo georgenijo/aperture
   ```
4. Report the PR URL.
