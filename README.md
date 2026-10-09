# Juha Protect (`juha_protect`)

Named protected areas for Luanti (Minetest), plus saving and restoring whole
structures (islands, builds...) as verified `.jp` files. Everything is done
through a single command: `/protect`.

- **Protects the original terrain** inside an area: it cannot be dug.
- **Blocks placed by players afterwards stay breakable**, so people can still build and play inside the zone.
- **Save / load** a zone (nodes, metadata, inventories and entities) with several safety layers against incomplete or corrupt files.

Author: Juha (CraftPlay777) · License: MIT (see `LICENSE`)

## Languages

The mod's default language is **English**. Translations are included for
**Spanish (es)** and **French (fr)**; Luanti picks the one that matches the
player's language setting. Translation files are in `locale/`
(`template.txt` is the template for new languages).

## Privilege

| Privilege | What it does |
|-----------|--------------|
| `protect` | Lets a player use `/protect` and bypasses the protection inside areas. |

```
/grant <player> protect
```

## Commands

Create and manage areas:

| Command | Description |
|---------|-------------|
| `/protect pos1` / `/protect pos2` | Mark the two corners (your current position). |
| `/protect <name>` | Create the protected area with the marked corners. |
| `/protect edit <name>` then `edit pos1` + `edit pos2` | Change the bounds of an existing area. |
| `/protect edit inzone <name>` | Lock the area again using its saved bounds. |
| `/protect list` | Show the protected areas. |
| `/protect delete <name>` | Remove the protection of an area (blocks and saves are not touched). |
| `/protect delete all` | Remove every protection (asks you to repeat the command within 30 s). |
| `/protect clean <name>\|all [range <n>]` | Remove the blocks players placed in an area (optionally `n` blocks around it). |

Save and restore structures:

| Command | Description |
|---------|-------------|
| `/protect save <name>` then `save pos1` + `save pos2` | Save the selected region as `<name>`. |
| `/protect save up <name>` | Save (update) using the bounds of the protected area `<name>`. |
| `/protect load <name>` | Restore the saved structure at its original position. |
| `/protect check <name>` | Verify a saved file without touching the map. |
| `/protect list save` | List the saved structures. |
| `/protect delete save <name>\|all` | Delete saved files (the map is not touched; `all` asks for confirmation). |

## How saving works

Saves are written to `<world>/protect/<name>.jp` (JSON). To avoid incomplete
or corrupt files:

1. The map is force-loaded in batches before reading it; if any position is still unloaded, the save is **aborted**.
2. The data is verified in memory (node count + checksum) before writing.
3. The previous save is kept as `<name>.jp.bak`, and the new file is written atomically and compared with what ended up on disk.
4. Loading validates the **whole** file before touching the map; if the `.jp` is damaged, the `.bak` is used.
5. Loading uses VoxelManip in batches (each batch is cleared and filled in one write).
6. Only one heavy operation (save or load) can run at a time.

Optional setting (`minetest.conf`):

```
juha_protect_verify_parse = true   # re-parse and verify the serialized data before writing (default: true)
```

## Notes

- Luanti's secure environment does not let mods delete files. If the mod
  cannot really delete a `.jp`/`.bak`, it leaves the file **empty** and treats
  it as nonexistent. Real deletion is attempted when the engine or the
  `secure.trusted_mods` setting allows it.
- The mod wraps `minetest.node_dig` to protect the terrain; keep this in mind
  if you also use other mods that override it.
- Nodes from mods that are not installed are restored by name, so they come
  back as soon as that mod is enabled.
- Always keep backups of your world before big load operations.

## License

MIT, Copyright (c) 2026 Juha (CraftPlay777). See `LICENSE`.
