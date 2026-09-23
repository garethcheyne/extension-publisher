---
name: publish-extension
description: Check, package, version-bump and publish a Chromium extension to the Chrome Web Store and Microsoft Edge Add-ons with the extension-publisher toolkit (Publish-Extension.ps1), and read or fix its validation findings and store errors. Use when the user wants to release, ship, submit, upload or publish an extension, check whether it's ready for the stores, see its Chrome review status, or understand a publish failure.
---

# Publish an extension

`Publish-Extension.ps1` builds, zips, checks the listing against both stores' rules,
and uploads through `publish-browser-extension`. Your job is to get it to a clean
check, get the version right, and publish only when the user says so.

## Find the toolkit and the project

- **Toolkit root**: two directories above this skill's base directory (`skills/publish-extension/` → root). If it has no `Publish-Extension.ps1`, look for a clone of `extension-publisher` next to the project, or ask.
- **Project**: the extension repo holding `store/store.json`. If there's no `store/`, use the `store-listing` skill first.

Needs `pwsh` 7.2+ and Node 18+. Run from any directory with `-ProjectPath <project>`.

## 1. Check

```
pwsh <toolkit>/Publish-Extension.ps1 -ProjectPath <project>
```

Package mode builds, zips to `releases/<name>-<version>.zip` and prints findings.
It exits 0 even with errors. `-Mode Validate` exits 1 on errors but doesn't build,
so it needs an existing build. Add `-Stores chrome` or `-Stores edge` when only one
store is being published.

Deal with the findings:

| Finding | Fix |
| --- | --- |
| `store/...` still has TODOs, a missing `## <permission>` section, description too short | Write the content with the `store-listing` skill; don't paper over it with filler |
| justifies a permission the manifest no longer requests (warning) | Delete that section |
| manifest name or description too long | Shorten it in the manifest, or in `_locales/<default>/messages.json` if it's a `__MSG_` key; confirm the wording with the user |
| manifest references a file that isn't in the package | Fix the build output or `package.exclude` in store.json |
| manifest_version, version format, `webRequestBlocking` | Manifest change; explain it before editing |
| image missing or the wrong size | Tell the user the file and size; don't invent artwork |
| `privacyPolicyUrl` empty (warning) | Needed if the extension handles any user data; ask for the URL |

Re-run until there are no errors. Warnings don't block publishing, but mention them.

## 2. Version

Both stores reject a version that isn't higher than the last one uploaded, including
drafts. Find where the version comes from (the manifest, or package.json if the build
copies it) and compare it with the last release: `-Mode Status` shows Chrome's
published and in-review versions, and git tags or `releases/` show earlier builds.
If it needs a bump, propose one (patch unless the user says otherwise), apply it,
and rebuild.

## 3. Credentials

Missing IDs or secrets stop a publish with a list of what's missing. Use the
`store-setup` skill to add them. Never print or echo secret values.

Before publishing, run `pwsh <toolkit>/Test-StoreConnection.ps1 -ProjectPath <project>`.
It's read-only: it checks that both stores accept the credentials and shows Chrome's
published and in-review versions, which also tells you whether a review is still
pending and what version to beat. It can't confirm Edge's product ID; only an
upload can.

## 4. Publish (confirm first)

Uploading and submitting can't be undone from here: it replaces any pending draft and
starts a store review. **Always confirm with the user right before running it**, and
say which stores, which version, and whether it will be submitted or left as a draft.

```
pwsh <toolkit>/Publish-Extension.ps1 -ProjectPath <project> -Mode Publish
```

| Switch | When |
| --- | --- |
| `-Stores chrome,edge` | only some stores (default: those enabled in store.json) |
| `-NoSubmit` | upload drafts; the user submits from each dashboard |
| `-Staged` | Chrome holds the approved version until the user publishes it by hand |
| `-ZipPath <zip>` | publish an existing zip instead of rebuilding |
| `-SkipBuild` | zip the current build output without rebuilding |

Neither API can create a store item. If an extension has never been in a store, the
user must upload the first zip by hand in the Chrome Developer Dashboard or Edge
Partner Center, then put the new ID in store.json. After that, this script handles
every update.

If the upload fails, the text above the failure comes from the store. Common causes:
the version isn't higher, a draft or review is already pending (Chrome won't accept
a new submission while one is in review), the service account isn't added to the
Chrome publisher account, or the Edge API key has expired.

## Through CI instead

If the repo has the example pipeline (`.github/workflows/` using
`extension-publisher@v1`, or `azure-pipelines.yml`), releases are published by
pushing a `v*` tag matching the manifest version. The pipeline then waits for
approval on the `extension-stores` environment. Pushing a tag is the release, so
confirm before running `git tag v<version>` and `git push origin v<version>`.

## Afterwards

Tell the user the version, the stores, and whether it was submitted or left as a
draft, and remind them that the listing text and images still go into each dashboard
by hand whenever they change. `-Mode Status` shows Chrome's review state; Edge's is in
Partner Center.
