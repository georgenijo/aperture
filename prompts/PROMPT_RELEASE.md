# Agent Startup — Release Mode

You are starting a release session for the Aperture project. Work autonomously through every step. Only stop to confirm the final release action before pushing the tag.

## 1. Load Context

Read silently:
- `Aperture.xcodeproj/project.pbxproj` — current MARKETING_VERSION and CURRENT_PROJECT_VERSION
- `CLAUDE.md` — project overview

## 2. Assess Current State

Run:
- `git status` — must be on `main` with a clean working tree. If not, stop and report.
- `git fetch origin && git log origin/main --oneline -5` — confirm local main is up to date with remote.

## 3. Determine Version Bump

Run:
- `git tag --sort=-version:refname | head -5` — find the last release tag
- `git log {last_tag}..HEAD --oneline` — all commits since that tag
- `git diff {last_tag}..HEAD --stat` — files changed

Analyse the commits using these rules (in priority order):
- Any commit with `feat!:`, `BREAKING CHANGE`, or a major architectural change → **major bump**
- Any commit with `feat:` → **minor bump**
- Only `fix:`, `chore:`, `docs:`, `refactor:`, `test:` → **patch bump**

Determine the new version by applying the bump to the current MARKETING_VERSION.

## 4. Summarise and Confirm

Present a concise release summary:
- Current version → New version (and why: major/minor/patch)
- Bullet list of what's included (one line per meaningful commit, skip chores/docs)
- Ask: **"Ready to release v{new_version}? Confirm to proceed."**

Stop and wait for confirmation.

## 5. Execute Release

On confirmation, run these steps in order:

1. Update `MARKETING_VERSION` in `Aperture.xcodeproj/project.pbxproj` (both Debug and Release configs)
2. Increment `CURRENT_PROJECT_VERSION` by 1
3. Commit: `git add Aperture.xcodeproj/project.pbxproj && git commit -m "chore: bump version to {new_version}"`
4. Push: `git push origin main`
5. Tag: `git tag v{new_version}`
6. Push tag: `git push origin v{new_version}`
7. Create a GitHub release:
   ```bash
   gh release create v{new_version} --repo georgenijo/aperture --title "v{new_version}" --notes "$(cat <<'EOF'
   ## What's New
   - bullet per `feat:` commit (human-readable)

   ## Fixes
   - bullet per `fix:` commit (omit section if none)

   ## Full Changelog
   https://github.com/georgenijo/aperture/compare/v{previous_version}...v{new_version}
   EOF
   )"
   ```
   Write the notes from the commit list — use clear, user-facing language. Omit empty sections. Skip `chore:`, `docs:`, `test:` commits.

## 6. Hand Off

Tell the user:
- Tag pushed, release created
- Link to the release page
