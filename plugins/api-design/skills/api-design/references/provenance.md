# Sources and license

- Author: Sergey Konstantinov.
- Book: [The API](https://twirl.github.io/The-API-Book/) ([Russian edition](https://twirl.github.io/The-API-Book/index.ru.html)).
- Official skill source: [twirl/APIDev.rules](https://github.com/twirl/APIDev.rules/tree/02eaa4791910bee15fed7405b9d4af59115b7d47/dist/skills/api-development).
- Pinned upstream revision: `02eaa4791910bee15fed7405b9d4af59115b7d47`.
- Imported files: `SKILL.md` and six reference files from `dist/skills/api-development/`.
- Adaptations: rename the skill to `api-design`, add this provenance and an explicit UI-reference loading rule, and package it for Claude Code and Codex. The guidance references retain the upstream text except two generic export URL examples renamed from users to accounts to avoid a home-path false positive in the repository leak gate.
- Upstream skills are dual MIT/BSD-3-Clause; this package selects MIT. Preserve `../../LICENSE` when redistributing this skill outside its plugin (place a copy beside the standalone skill).
- The book itself is CC BY-NC 4.0. It is linked, not bundled or relicensed. The MIT permission applies to the official skill material, not the book.

Treat the guidance as design heuristics, not proof of security or protocol compliance. Validate normative behavior against the applicable specifications. Never claim the author endorsed this adaptation.
