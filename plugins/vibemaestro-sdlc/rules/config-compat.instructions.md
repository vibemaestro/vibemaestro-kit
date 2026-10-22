---
applyTo: ".vibemaestro/sdlc.json,**/sdlc_config.py"
description: "A config key change keeps every reader running: unknown keys warn, every key has a default, renames go through a deprecation window, breaking changes raise the schema; a new key is set only once every reader in use knows it"
---

# Config keys: older and newer readers both keep running

1. **Forward.** A reader meets keys of a newer plugin: it warns once and ignores each unknown key. A known key with a wrong value still refuses.
2. **Backward.** A new key is optional and has a default. A rename, removal or type change goes into `DEPRECATED` (`sdlc_config.py`) for a window: the old form is still read, and the warning names the new one. A key leaves the schema only once the floor reader reads its replacement.
3. **Breaking.** A change no window can carry raises `schema` (the major version) and ships its step in `MIGRATIONS` (`kb.py config migrate`). A reader refuses only a schema above its own, and its message names the update to run.
4. **Rollout.** A new key is SET in a repo's config only once every reader in use (pod image, laptops, runners) is at or above the floor (`tests/fixtures/config_compat/floor/`). Until then the code default applies.
5. Proof: `bash tests/test-config-compat.sh` feeds this repo's config and a future-key fixture to the floor reader and to the plugin's reader.
