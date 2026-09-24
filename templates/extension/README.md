# {{displayName}}

{{description}}

A Manifest V3 extension for Chrome and Edge, built with Vite, React, TypeScript, Tailwind CSS and [shadcn/ui](https://ui.shadcn.com). Created with [extension-publisher](https://github.com/garethcheyne/extension-publisher)'s `New-Extension.ps1`.

## Develop

```powershell
npm install
npm run dev
```

Open `chrome://extensions` (or `edge://extensions`), turn on **Developer mode**, choose **Load unpacked** and pick `dist/`. While `npm run dev` runs, changes reload by themselves. Click the toolbar icon to open the side panel.

| Path | What it is |
| --- | --- |
| `manifest.json` | The extension manifest. Entries point at source files; the build rewrites them for `dist/`. |
| `src/sidepanel/` | The side panel: `App.tsx` is the UI. |
| `src/background/service-worker.ts` | The service worker. |
| `src/components/ui/` | shadcn/ui components. Add more with `npx shadcn@latest add <name>`. |
| `src/lib/use-storage.ts` | `useState` backed by `chrome.storage.local`. |
| `public/icons/` | Toolbar and extensions-page icons. Replace the placeholders. |
| `store/` | Store listing, privacy answers and IDs. See `store/README.md`. |

To add a popup, options page or content script, add it to `manifest.json` pointing at a source file (`.html` or `.ts`); the build picks it up.

## Release

1. Bump `version` in `manifest.json` (and `package.json` to match).
2. `npm run store` builds, zips into `releases/` and checks against both stores' rules.
3. `npm run store:publish` uploads and submits to both stores.

The first version is uploaded by hand. See "First release of a new extension" in the extension-publisher README.
