# Remote code

Chrome Web Store → Privacy → **Are you using remote code?**, and Edge Partner
Center → Privacy → **Remote code**. Manifest V3 bans running code that isn't in
the package: remote `<script>` tags, `eval()`, or JavaScript fetched at runtime.
Fetching data (JSON, HTML to display) is not remote code.

TODO: e.g. "**No, I am not using remote code.** All JavaScript is bundled in the package. The extension calls REST APIs and receives JSON; it never loads or runs code from them."
