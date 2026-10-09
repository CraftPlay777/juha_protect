-- juha_protect | Juha (CraftPlay777)
-- named protected areas + saving/restoring of structures (.jp), all through /protect

-- ============================================================
-- TRANSLATIONS
-- Source language: English. Translations live in locale/*.tr
-- (Spanish: es, French: fr). The wrapper turns every argument into a
-- string so numbers can be passed straight to S().
-- ============================================================

local S0 = minetest.get_translator("juha_protect")
local unpack = unpack or table.unpack

local function S(str, ...)
    local n = select("#", ...)
    local args = {...}
    for i = 1, n do args[i] = tostring(args[i]) end
    return S0(str, unpack(args, 1, n))
end

-- plain English text (no escape sequences), for log lines and internal errors
local function plain(s)
    s = tostring(s)
    if minetest.get_translated_string then
        return minetest.get_translated_string("en", s)
    end
    return s
end

if not minetest.registered_privileges or not minetest.registered_privileges["protect"] then
    minetest.register_privilege("protect", {
        description = S("Can manage protected areas / no-PvP zones"),
        give_to_singleplayer = false,
    })
end

local storage = minetest.get_mod_storage()
local zones = minetest.deserialize(storage:get_string("zones")) or {}
-- zones[name] = { min = vector, max = vector }

-- structures saved with /protect save are written as real <name>.jp files
-- inside a "protect/" folder in the world
-- (like worldedit does with its .we files, but tidier in its own folder)
-- in JSON format (not Lua's native serialization, which breaks with big
-- structures because deserialize compiles the text as Lua code)
local worldpath = minetest.get_worldpath()
local protect_dir = worldpath .. "/protect"
minetest.mkdir(protect_dir)

local function safe_filename(name)
    return (name:gsub("[^%w_%-]", "_"))
end

local function save_path(name)
    return protect_dir .. "/" .. safe_filename(name) .. ".jp"
end

-- GLOBAL registry of everything any player places anywhere on the map
-- (not only inside zones) -- allows normal protection and clean with "range"
local placed_blocks = minetest.deserialize(storage:get_string("placed_blocks")) or {}

-- pending state per player, separated by flow
local pending_pos1, pending_pos2 = {}, {}         -- "create new area" flow
local edit_name, edit_pos1 = {}, {}               -- "/protect edit" flow
local save_name, save_pos1 = {}, {}               -- "/protect save" flow

local function save_zones()
    storage:set_string("zones", minetest.serialize(zones))
end

local function save_placed_blocks()
    storage:set_string("placed_blocks", minetest.serialize(placed_blocks))
end

local function has_bypass(name)
    return minetest.check_player_privs(name, {protect = true})
end

local function find_zone(pos)
    for zname, z in pairs(zones) do
        if pos.x >= z.min.x and pos.x <= z.max.x
            and pos.y >= z.min.y and pos.y <= z.max.y
            and pos.z >= z.min.z and pos.z <= z.max.z then
            return zname, z
        end
    end
    return nil
end

local function corners(p1, p2)
    return vector.new(math.min(p1.x, p2.x), math.min(p1.y, p2.y), math.min(p1.z, p2.z)),
        vector.new(math.max(p1.x, p2.x), math.max(p1.y, p2.y), math.max(p1.z, p2.z))
end

-- ============================================================
-- PROTECTION: original terrain cannot be broken,
-- what the player places afterwards can be broken freely
-- ============================================================

local old_node_dig = minetest.node_dig
function minetest.node_dig(pos, node, digger)
    local pname = digger and digger:get_player_name() or ""
    local zname = find_zone(pos)
    if zname and not has_bypass(pname) then
        local hash = minetest.hash_node_position(vector.round(pos))
        if not placed_blocks[hash] then
            minetest.record_protection_violation(pos, pname)
            return
        end
    end
    return old_node_dig(pos, node, digger)
end

minetest.register_on_placenode(function(pos, newnode, placer)
    local hash = minetest.hash_node_position(vector.round(pos))
    placed_blocks[hash] = true
    save_placed_blocks()
end)

-- ============================================================
-- CLEANING and LOCKING
-- ============================================================

local function clean_box(minp, maxp)
    local count = 0
    for hash in pairs(placed_blocks) do
        local bpos = minetest.get_position_from_hash(hash)
        if bpos.x >= minp.x and bpos.x <= maxp.x
            and bpos.y >= minp.y and bpos.y <= maxp.y
            and bpos.z >= minp.z and bpos.z <= maxp.z then
            minetest.set_node(bpos, {name = "air"})
            placed_blocks[hash] = nil
            count = count + 1
        end
    end
    return count
end

-- "locks" a zone: removes from the global "placed by a player" registry
-- everything that is there right now
local function lock_zone(minp, maxp)
    local count = 0
    for hash in pairs(placed_blocks) do
        local bpos = minetest.get_position_from_hash(hash)
        if bpos.x >= minp.x and bpos.x <= maxp.x
            and bpos.y >= minp.y and bpos.y <= maxp.y
            and bpos.z >= minp.z and bpos.z <= maxp.z then
            placed_blocks[hash] = nil
            count = count + 1
        end
    end
    if count > 0 then
        save_placed_blocks()
    end
    return count
end

-- ============================================================
-- METADATA CAPTURE/RESTORE, USERDATA-PROOF
-- meta:to_table()/from_table() handle the inventory with real ItemStacks
-- (userdata), which CANNOT be saved as JSON -- so everything is converted
-- to itemstrings (text) by hand
-- ============================================================

-- can it be written/read as JSON without losing anything? (binary strings break JSON)
local function json_safe(v)
    local ok, s = pcall(minetest.write_json, v)
    if not ok or not s then return false end
    local ok2, back = pcall(minetest.parse_json, s)
    return ok2 and back ~= nil
end

-- returns the metadata, or nil if there is none; if there is some but it
-- CANNOT be saved as JSON returns nil, true (so a warning is shown instead
-- of breaking the file)
local function capture_meta(pos)
    local meta = minetest.get_meta(pos)
    local fields = meta:to_table().fields or {}

    local inv = meta:get_inventory()
    local lists = {}
    local has_inventory = false
    for listname, list in pairs(inv:get_lists()) do
        has_inventory = true
        local items = {}
        for i, stack in ipairs(list) do
            items[i] = stack:to_string()
        end
        lists[listname] = items
    end

    if not has_inventory and next(fields) == nil then
        return nil
    end

    local result = {fields = fields, inventory = lists}
    if not json_safe(result) then
        return nil, true
    end
    return result
end

local function restore_meta(pos, data)
    if not data then return end
    local meta = minetest.get_meta(pos)

    if data.fields then
        for k, v in pairs(data.fields) do
            meta:set_string(k, v)
        end
    end

    if data.inventory then
        local inv = meta:get_inventory()
        for listname, items in pairs(data.inventory) do
            local stacks = {}
            for i, itemstring in ipairs(items) do
                stacks[i] = ItemStack(itemstring)
            end
            if inv:get_size(listname) ~= #stacks then
                inv:set_size(listname, #stacks)
            end
            inv:set_list(listname, stacks)
        end
    end
end

-- ============================================================
-- SAVE / LOAD STRUCTURES (blocks + metadata + entities)
--
-- Safety layers:
--  1. Before reading/writing each batch the map is FORCE-LOADED
--     (emerge_area). Previously, blocks far from the player came out as
--     "ignore", were silently skipped and the .jp ended up with half an
--     island. Now, if anything is left unloaded, the save is ABORTED.
--  2. The .jp is verified in memory (it can be read back, same number of
--     nodes, same checksum), the previous one is copied to <name>.jp.bak,
--     the new one is written atomically and compared byte by byte with what
--     ended up on disk. A good file is never overwritten with a bad one.
--  3. When loading, the WHOLE file is validated (structure, bounds, number
--     of nodes, checksum) BEFORE touching the map. If the .jp is damaged
--     the .bak is used and a warning is shown.
--  4. Loading uses VoxelManip in batches: each batch is emptied and filled
--     in a single write (a batch is never left half-empty), and it is much
--     faster than set_node node by node.
--  5. Only one heavy operation at a time (avoids saving and loading on top
--     of each other).
-- ============================================================

local FORMAT_VERSION = 2
local MAX_CHUNK_NODES = 250000   -- max positions per batch (controls RAM and lag)
local EMERGE_TRIES = 3
local EMERGE_TIMEOUT = 60        -- seconds waiting for the engine to load a batch
local CHK_MOD = 2147483629
local MISSING = "missing"

-- ---------- only one heavy operation at a time ----------

local current_job = nil

-- kind is "save" or "load" (internal); the label shown to players is translated
local function job_label(kind)
    if kind == "save" then return S("saving") end
    return S("loading")
end

local function begin_job(kind, sname, pname)
    if current_job then
        return false, S("An operation is already running: @1 '@2' (by @3). Wait for it to finish.",
            job_label(current_job.kind), current_job.name, current_job.owner)
    end
    current_job = {kind = kind, name = sname, owner = pname}
    return true, current_job
end

-- only releases if the job is still the same one (calling it twice does not clobber a new one)
local function end_job(job)
    if current_job == job then
        current_job = nil
    end
end

minetest.register_on_shutdown(function()
    if current_job then
        minetest.log("warning", "[juha_protect] the server shut down during a " .. current_job.kind ..
            " of '" .. current_job.name .. "'. If it was a load, repeat /protect load " .. current_job.name)
    end
end)

-- ---------- files ----------

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- atomic write: if the engine has safe_file_write it uses it (writes to a
-- temp file and renames); otherwise a normal write checking for errors
local function write_file_atomic(path, content)
    if minetest.safe_file_write then
        if not minetest.safe_file_write(path, content) then
            error("could not write " .. path)
        end
        return
    end
    local f, ferr = io.open(path, "wb")
    if not f then
        error("could not open " .. path .. " for writing: " .. tostring(ferr))
    end
    local okw, werr = f:write(content)
    local okc = f:close()
    if not okw or not okc then
        error("failed writing " .. path .. ": " .. tostring(werr))
    end
end

-- ---------- deleting saves ----------
-- In Luanti's secure environment mods CANNOT delete files (os.remove does not
-- exist). Order of attempts: os.remove -> os.remove from the insecure
-- environment (if the mod is in secure.trusted_mods) -> leave the file EMPTY.
-- An empty .jp counts as "does not exist" across the whole mod (load, check,
-- listings).

local insecure_os
do
    local ok, ie = pcall(function()
        return minetest.request_insecure_environment and minetest.request_insecure_environment()
    end)
    if ok and ie then insecure_os = ie.os end
end

-- size in bytes, or nil if it does not exist (without reading the whole file)
local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- tries to really delete; true only if the file no longer exists
local function try_real_delete(path)
    local rm = (os and os.remove) or (insecure_os and insecure_os.remove)
    if rm then
        pcall(rm, path)
        if file_size(path) == nil then return true end
    end
    -- recursive minetest.rmdir: depending on the engine it also deletes single files
    if minetest.rmdir then
        pcall(minetest.rmdir, path, true)
        if file_size(path) == nil then return true end
    end
    return false
end

-- assumes the file exists and has content
-- returns true, "deleted" | true, "emptied" | false, error
local function delete_file(path)
    if try_real_delete(path) then return true, "deleted" end
    local okw, err = pcall(write_file_atomic, path, "")
    if not okw then return false, tostring(err) end
    if read_file(path) ~= "" then
        return false, "could not empty " .. path
    end
    return true, "emptied"
end

local function file_has_content(path)
    local size = file_size(path)
    return size ~= nil and size > 0
end

-- cleans up the .jp / .bak files left EMPTY by earlier deletions
-- (if the engine now allows deleting them they vanish from disk; if not, nothing happens)
local function sweep_empty_files()
    local removed = 0
    for _, f in ipairs(minetest.get_dir_list(protect_dir, false) or {}) do
        if f:match("%.jp$") or f:match("%.jp%.bak$") then
            local p = protect_dir .. "/" .. f
            if file_size(p) == 0 and try_real_delete(p) then
                removed = removed + 1
            end
        end
    end
    return removed
end
pcall(sweep_empty_files)

-- deletes the save and its backup (otherwise loading would "resurrect" it from the .bak)
-- returns existed, mode ("deleted"/"emptied"), error
local function delete_save(sname)
    local path = save_path(sname)
    local existed, mode = false, nil
    for _, p in ipairs({path, path .. ".bak"}) do
        if file_has_content(p) then
            existed = true
            local ok, how = delete_file(p)
            if not ok then return existed, mode, how end
            if how == "emptied" or not mode then mode = how end
        end
    end
    return existed, mode
end

-- names of all existing saves (sorted)
local function list_saved_names()
    local seen, names = {}, {}
    for _, f in ipairs(minetest.get_dir_list(protect_dir, false) or {}) do
        local base = f:match("^(.+)%.jp$") or f:match("^(.+)%.jp%.bak$")
        if base and not seen[base] and (file_has_content(protect_dir .. "/" .. base .. ".jp")
                or file_has_content(protect_dir .. "/" .. base .. ".jp.bak")) then
            seen[base] = true
            names[#names + 1] = base
        end
    end
    table.sort(names)
    return names
end

-- ---------- snapshot validation ----------

local name_hashes = {}
local function hash_name(name)
    local h = name_hashes[name]
    if not h then
        h = 7
        for i = 1, #name do
            h = (h * 31 + name:byte(i)) % CHK_MOD
        end
        name_hashes[name] = h
    end
    return h
end

local function checksum_nodes(nodes)
    local h = 17
    for i = 1, #nodes do
        local n = nodes[i]
        h = (h * 31 + n.ox) % CHK_MOD
        h = (h * 31 + n.oy) % CHK_MOD
        h = (h * 31 + n.oz) % CHK_MOD
        h = (h * 31 + (n.param2 or 0)) % CHK_MOD
        h = (h * 31 + hash_name(n.name)) % CHK_MOD
    end
    return h
end

local function is_int(v)
    return type(v) == "number" and v == math.floor(v)
end

local function normalize_snapshot(data)
    -- minetest.write_json writes "null" for empty Lua tables and parse_json
    -- returns it as nil: a zone without entities comes back with entities = nil
    -- (this also covers old .jp files from before entity support)
    if type(data) == "table" then
        data.nodes = data.nodes or {}
        data.entities = data.entities or {}
    end
    return data
end

-- returns true | false, reason | true, nil, warning
local function verify_snapshot(data)
    if type(data) ~= "table" then return false, S("invalid content") end
    local mn, mx = data.min, data.max
    if type(mn) ~= "table" or type(mx) ~= "table" then
        return false, S("the zone bounds (min/max) are missing")
    end
    for _, a in ipairs({"x", "y", "z"}) do
        if not is_int(mn[a]) or not is_int(mx[a]) then
            return false, S("invalid bounds")
        end
        if mn[a] > mx[a] then return false, S("inverted bounds") end
    end
    if type(data.nodes) ~= "table" or type(data.entities) ~= "table" then
        return false, S("the node/entity lists are missing")
    end
    if data.version ~= nil and (not is_int(data.version) or data.version > FORMAT_VERSION) then
        return false, S("file from a newer version of the mod (@1)", tostring(data.version))
    end

    local wx, wy, wz = mx.x - mn.x + 1, mx.y - mn.y + 1, mx.z - mn.z + 1
    local nodes = data.nodes
    for i = 1, #nodes do
        local n = nodes[i]
        if type(n) ~= "table" or type(n.name) ~= "string" or n.name == ""
            or not is_int(n.ox) or not is_int(n.oy) or not is_int(n.oz)
            or n.ox < 0 or n.ox >= wx or n.oy < 0 or n.oy >= wy or n.oz < 0 or n.oz >= wz then
            return false, S("node #@1 is damaged or out of bounds", i)
        end
    end

    if data.version then
        if data.node_count ~= #nodes then
            return false, S("nodes are missing: the file declares @1 and contains @2",
                tostring(data.node_count), #nodes)
        end
        if data.entity_count ~= #data.entities then
            return false, S("entities are missing: the file declares @1 and contains @2",
                tostring(data.entity_count), #data.entities)
        end
        if data.checksum ~= checksum_nodes(nodes) then
            return false, S("the checksum does not match (damaged or truncated file)")
        end
        return true
    end
    return true, nil, S("old format file (no checksum): it cannot be guaranteed to be complete")
end

-- ---------- batches: columns aligned to the mapblock grid ----------

local function chunk_side(wy)
    local side = math.floor(math.sqrt(MAX_CHUNK_NODES / math.max(wy, 1)) / 16) * 16
    return math.max(16, math.min(64, side))
end

local function build_chunks(minp, maxp)
    local side = chunk_side(maxp.y - minp.y + 1)
    local chunks = {}
    for gx = math.floor(minp.x / side), math.floor(maxp.x / side) do
        for gz = math.floor(minp.z / side), math.floor(maxp.z / side) do
            chunks[#chunks + 1] = {
                gx = gx, gz = gz,
                min = {x = math.max(minp.x, gx * side), y = minp.y, z = math.max(minp.z, gz * side)},
                max = {x = math.min(maxp.x, gx * side + side - 1), y = maxp.y,
                       z = math.min(maxp.z, gz * side + side - 1)},
            }
        end
    end
    return chunks, side
end

-- forces the engine to load (or generate) that part of the map and reports when it is ready
local function emerge_chunk(cmin, cmax, tries, cont)
    if not minetest.emerge_area then
        minetest.load_area(cmin, cmax)
        return cont(true)
    end

    local finished, failed = false, false
    local function finish(ok, why)
        if finished then return end
        finished = true
        if ok then return cont(true) end
        if tries > 1 then
            minetest.log("warning", "[juha_protect] retrying to load the map (" .. plain(why) .. ")")
            return minetest.after(1, function() emerge_chunk(cmin, cmax, tries - 1, cont) end)
        end
        cont(false, why)
    end

    minetest.emerge_area(cmin, cmax, function(blockpos, action, remaining)
        if action == minetest.EMERGE_CANCELLED or action == minetest.EMERGE_ERRORED then
            failed = true
        end
        if remaining == 0 then
            if failed then
                finish(false, S("the engine could not load that part of the map"))
            else
                finish(true)
            end
        end
    end)
    minetest.after(EMERGE_TIMEOUT, function()
        finish(false, S("timed out waiting for the map to load"))
    end)
end

-- walks the batches one by one (load map -> process -> next server step)
local function process_chunks(chunks, chunk_fn, on_progress, on_done, on_error)
    local total = #chunks
    local i = 0

    local function fail(msg)
        local ok, e = pcall(on_error, msg)
        if not ok then
            minetest.log("error", "[juha_protect] on_error failed: " .. tostring(e))
        end
    end

    local function nextchunk()
        i = i + 1
        if i > total then
            local ok, err = pcall(on_done)
            if not ok then fail(S("error while finishing: @1", tostring(err))) end
            return
        end
        local c = chunks[i]
        emerge_chunk(c.min, c.max, EMERGE_TRIES, function(ok, why)
            if not ok then
                return fail(S("batch @1/@2: @3", i, total, tostring(why)))
            end
            local ok2, err2 = pcall(chunk_fn, c)
            if not ok2 then
                minetest.log("error", "[juha_protect] failure in batch " .. i .. "/" .. total .. ": " .. tostring(err2))
                return fail(S("batch @1/@2: @3", i, total, tostring(err2)))
            end
            if on_progress then pcall(on_progress, i, total) end
            minetest.after(0, nextchunk)
        end)
    end

    nextchunk()
end

-- ---------- SAVE ----------

local function capture_entities(minp, maxp)
    local entities = {}
    local skipped = 0
    for _, obj in ipairs(minetest.get_objects_in_area(minp, maxp) or {}) do
        local ok_e, err_e = pcall(function()
            if obj and obj.is_player and not obj:is_player() then
                local ent = obj:get_luaentity()
                if ent and obj.get_staticdata then
                    local p = obj:get_pos()
                    local e = {
                        ox = p.x - minp.x, oy = p.y - minp.y, oz = p.z - minp.z,
                        name = ent.name, staticdata = obj:get_staticdata(),
                    }
                    -- binary staticdata does not fit in JSON: that entity is skipped
                    -- instead of breaking the whole file
                    if json_safe(e) then
                        table.insert(entities, e)
                    else
                        error("staticdata cannot be saved as JSON (" .. tostring(ent.name) .. ")")
                    end
                end
            end
        end)
        if not ok_e then
            skipped = skipped + 1
            minetest.log("warning", "[juha_protect] skipped an odd entity while saving: " .. tostring(err_e))
        end
    end
    return entities, skipped
end

-- on_done(holder, stats) with holder.snapshot = data ready to be written
local function capture_zone_async(minp, maxp, on_done, on_error, on_progress)
    minp = {x = minp.x, y = minp.y, z = minp.z}
    maxp = {x = maxp.x, y = maxp.y, z = maxp.z}
    local chunks = build_chunks(minp, maxp)

    local nodes, n_nodes = {}, 0
    local ignored, meta_skipped = 0, 0
    local data_buf, p2_buf = {}, {}
    local id_names = {}
    local c_air, c_ignore, c_unknown = minetest.CONTENT_AIR, minetest.CONTENT_IGNORE, minetest.CONTENT_UNKNOWN

    local function chunk_fn(c)
        local cmin, cmax = c.min, c.max
        local vm = minetest.get_voxel_manip()
        local emin, emax = vm:read_from_map(cmin, cmax)
        local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
        local data = vm:get_data(data_buf)
        local p2 = vm:get_param2_data(p2_buf)

        -- which positions have metadata (chests, signs...), all at once
        local with_meta, meta_known = {}, false
        local okm, plist = pcall(minetest.find_nodes_with_meta, cmin, cmax)
        if okm and type(plist) == "table" then
            meta_known = true
            for _, p in ipairs(plist) do
                with_meta[area:indexp(p)] = true
            end
        end

        for z = cmin.z, cmax.z do
            for y = cmin.y, cmax.y do
                local vi = area:index(cmin.x, y, z)
                for x = cmin.x, cmax.x do
                    local cid = data[vi]
                    if cid == c_ignore then
                        ignored = ignored + 1
                    elseif cid ~= c_air then
                        local name = id_names[cid]
                        if not name then
                            name = minetest.get_name_from_content_id(cid)
                            id_names[cid] = name
                        end
                        if cid == c_unknown then
                            name = minetest.get_node({x = x, y = y, z = z}).name
                        end
                        local meta
                        if with_meta[vi] or not meta_known then
                            local bad
                            meta, bad = capture_meta({x = x, y = y, z = z})
                            if bad then meta_skipped = meta_skipped + 1 end
                        end
                        n_nodes = n_nodes + 1
                        nodes[n_nodes] = {
                            ox = x - minp.x, oy = y - minp.y, oz = z - minp.z,
                            name = name, param2 = p2[vi], meta = meta,
                        }
                    end
                    vi = vi + 1
                end
            end
        end
    end

    process_chunks(chunks, chunk_fn, on_progress, function()
        if ignored > 0 then
            return on_error(S("@1 positions inside the zone were not loaded. Nothing was written so as not to leave an incomplete file", ignored))
        end
        local entities, ent_skipped = capture_entities(minp, maxp)
        local holder = {snapshot = {
            version = FORMAT_VERSION,
            min = minp, max = maxp,
            nodes = nodes, entities = entities,
            node_count = #nodes, entity_count = #entities,
            checksum = checksum_nodes(nodes),
        }}
        nodes = nil  -- so no second reference is left taking up RAM
        on_done(holder, {meta_skipped = meta_skipped, ent_skipped = ent_skipped})
    end, on_error)
end

-- safe write. The good file is never deleted or half-overwritten:
--  1) EVERYTHING is serialized and verified in memory (count + checksum)
--  2) the previous save (if valid) is copied to <name>.jp.bak
--  3) the new file is written atomically (safe_file_write)
--  4) it is read back from disk and compared byte by byte
-- (Luanti's secure environment has no os.rename / os.remove, which is why
-- no temp file of our own is used)
local function write_save_file(name, holder)
    local path = save_path(name)
    local bak = path .. ".bak"
    local info = {backup = false}

    local ok, result = pcall(function()
        local snapshot = holder.snapshot
        holder.snapshot = nil
        if not snapshot then error("there is no data to save") end
        info.nodes, info.entities = snapshot.node_count, snapshot.entity_count

        local serialized, jerr = minetest.write_json(snapshot)
        snapshot = nil
        collectgarbage()
        if not serialized or serialized == "" then
            error("could not convert to JSON: " .. tostring(jerr))
        end
        info.bytes = #serialized

        -- 1) the serialized text is read back and count + checksum are checked
        if minetest.settings:get_bool("juha_protect_verify_parse", true) then
            local parsed = normalize_snapshot(minetest.parse_json(serialized))
            local good, why = verify_snapshot(parsed)
            if not good then
                error("the pre-write verification failed: " .. plain(why))
            end
            parsed = nil
            collectgarbage()
        end

        -- 2) backup of the previous save, only if that one is healthy
        --    (so an old damaged file never overwrites a good .bak)
        local old = read_file(path)
        if old and old ~= "" then
            local old_data = minetest.parse_json(old)
            if type(old_data) == "table" then
                normalize_snapshot(old_data)
                if verify_snapshot(old_data) then
                    write_file_atomic(bak, old)
                    info.backup = true
                end
            end
            old, old_data = nil, nil
            collectgarbage()
        end

        -- 3) atomic write of the new file
        write_file_atomic(path, serialized)

        -- 4) check what really ended up on disk
        if read_file(path) ~= serialized then
            local prev = info.backup and read_file(bak) or nil
            if prev and prev ~= "" then
                pcall(write_file_atomic, path, prev)
            end
            error("what was written to disk does not match what was expected (disk full?)")
        end
    end)

    if not ok then
        minetest.log("error", "[juha_protect] write_save_file failed: " .. tostring(result))
        return false, result, path, info
    end
    return true, nil, path, info
end

-- ---------- LOAD ----------

local function load_snapshot_file(path)
    local content = read_file(path)
    if not content then return nil, MISSING end
    if content == "" then return nil, MISSING end  -- empty = deleted (see delete_file)
    local data = minetest.parse_json(content)
    content = nil
    if type(data) ~= "table" then
        return nil, S("could not be read (truncated or corrupt)")
    end
    normalize_snapshot(data)
    local ok, why, warn = verify_snapshot(data)
    if not ok then return nil, why end
    return data, nil, warn
end

-- ok:    snapshot, path_used, note (if the .bak was used), warning
-- error: nil, message
local function read_save_file(name)
    local path = save_path(name)
    local bak = path .. ".bak"

    local snap, err, warn = load_snapshot_file(path)
    if snap then return snap, path, nil, warn end

    local bsnap, berr, bwarn = load_snapshot_file(bak)
    if bsnap then
        local why
        if err == MISSING then
            why = S("the main file was not found")
        else
            why = S("the main file is damaged: @1", tostring(err))
        end
        return bsnap, bak, S("@1 -> using the .bak backup (previous version)", why), bwarn
    end

    if err == MISSING and berr == MISSING then
        return nil, S("The file does not exist at: @1", path)
    end
    local main_why = (err == MISSING) and S("it does not exist") or err
    local bak_why = (berr == MISSING) and S("it does not exist") or berr
    return nil, S("The save '@1' is damaged (@2) and the backup is unusable (@3). The map was not touched",
        name, main_why, bak_why)
end

-- each batch: removes old metadata, empties and fills in ONE single write
local function restore_zone_async(snapshot, on_done, on_error, on_progress)
    local minp = {x = snapshot.min.x, y = snapshot.min.y, z = snapshot.min.z}
    local maxp = {x = snapshot.max.x, y = snapshot.max.y, z = snapshot.max.z}
    local chunks, side = build_chunks(minp, maxp)

    -- distributes the nodes per batch
    local buckets = {}
    local nodes = snapshot.nodes
    for i = 1, #nodes do
        local n = nodes[i]
        local key = math.floor((minp.x + n.ox) / side) * 65536 + math.floor((minp.z + n.oz) / side)
        local b = buckets[key]
        if not b then
            b = {}
            buckets[key] = b
        end
        b[#b + 1] = n
    end

    local stats = {unknown = 0, meta_fail = 0, ent_skipped = 0}
    local cid_cache = {}
    local data_buf, p2_buf = {}, {}
    local c_air = minetest.CONTENT_AIR

    local function resolve(name)
        local r = cid_cache[name]
        if r == nil then
            local real = name
            if not minetest.registered_nodes[real] then
                local al = minetest.registered_aliases and minetest.registered_aliases[real]
                if al and minetest.registered_nodes[al] then real = al else real = nil end
            end
            if real then
                r = {cid = minetest.get_content_id(real), def = minetest.registered_nodes[real]}
            else
                r = false
            end
            cid_cache[name] = r
        end
        return r
    end

    local function chunk_fn(c)
        local cmin, cmax = c.min, c.max
        local list = buckets[c.gx * 65536 + c.gz] or {}
        buckets[c.gx * 65536 + c.gz] = nil

        local vm = minetest.get_voxel_manip()
        local emin, emax = vm:read_from_map(cmin, cmax)
        local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
        local data = vm:get_data(data_buf)
        local p2 = vm:get_param2_data(p2_buf)

        -- 1) VoxelManip does not delete the metadata of what it replaces: clean it separately
        local okm, plist = pcall(minetest.find_nodes_with_meta, cmin, cmax)
        if okm and type(plist) == "table" then
            for _, p in ipairs(plist) do
                pcall(function() minetest.get_meta(p):from_table({}) end)
            end
        end

        -- 2) empty the batch (only inside the zone)
        for z = cmin.z, cmax.z do
            for y = cmin.y, cmax.y do
                local vi = area:index(cmin.x, y, z)
                for _ = cmin.x, cmax.x do
                    data[vi] = c_air
                    p2[vi] = 0
                    vi = vi + 1
                end
            end
        end

        -- 3) place the nodes from the file
        local post, fallback = {}, {}
        for k = 1, #list do
            local n = list[k]
            local x, y, z = minp.x + n.ox, minp.y + n.oy, minp.z + n.oz
            local r = resolve(n.name)
            if r then
                local vi = area:index(x, y, z)
                data[vi] = r.cid
                p2[vi] = n.param2 or 0
                if n.meta or (r.def and r.def.on_construct) then
                    post[#post + 1] = {x = x, y = y, z = z, n = n, def = r.def}
                end
            else
                fallback[#fallback + 1] = {x = x, y = y, z = z, n = n}
            end
        end

        -- 4) a single write to the map for the whole batch
        vm:set_data(data)
        vm:set_param2_data(p2)
        vm:write_to_map(true)
        pcall(function() vm:update_liquids() end)

        -- 5) nodes from mods that are not installed: set_node keeps the name
        for _, f in ipairs(fallback) do
            stats.unknown = stats.unknown + 1
            pcall(minetest.set_node, {x = f.x, y = f.y, z = f.z},
                {name = f.n.name, param2 = f.n.param2 or 0})
        end

        -- 6) what set_node did and VoxelManip does not: on_construct + metadata
        for _, p in ipairs(post) do
            local pos = {x = p.x, y = p.y, z = p.z}
            if p.def and p.def.on_construct then
                pcall(p.def.on_construct, pos)
            end
            if p.n.meta then
                local okr = pcall(restore_meta, pos, p.n.meta)
                if not okr then stats.meta_fail = stats.meta_fail + 1 end
            end
        end
    end

    process_chunks(chunks, chunk_fn, on_progress, function()
        for _, obj in ipairs(minetest.get_objects_in_area(minp, maxp) or {}) do
            local ok_e, err_e = pcall(function()
                if obj and obj.is_player and not obj:is_player() then
                    obj:remove()
                end
            end)
            if not ok_e then
                minetest.log("warning", "[juha_protect] could not remove an old entity: " .. tostring(err_e))
            end
        end

        for _, e in ipairs(snapshot.entities) do
            local ok4, err4 = pcall(function()
                local pos = {x = minp.x + e.ox, y = minp.y + e.oy, z = minp.z + e.oz}
                minetest.add_entity(pos, e.name, e.staticdata)
            end)
            if not ok4 then
                stats.ent_skipped = stats.ent_skipped + 1
                minetest.log("warning", "[juha_protect] could not recreate an entity (" ..
                    tostring(e.name) .. "): " .. tostring(err4))
            end
        end
        on_done(stats)
    end, on_error)
end

-- ============================================================
-- COMMAND HELPERS
-- ============================================================

-- mass deletions ("all") ask for the same command to be repeated within 30 seconds
local pending_delete = {}
local function needs_confirmation(pname, what)
    local p = pending_delete[pname]
    local now = os.time()
    if p and p.what == what and now - p.t <= 30 then
        pending_delete[pname] = nil
        return false
    end
    pending_delete[pname] = {what = what, t = now}
    return true
end

local function remove_zone(zname)
    zones[zname] = nil
    -- if someone was editing it, that edit is cancelled
    for pn, en in pairs(edit_name) do
        if en == zname then
            edit_name[pn] = nil
            edit_pos1[pn] = nil
        end
    end
end

local EMPTIED_NOTE = " " .. S("(this Luanti does not let mods delete files: they were left empty, the mod hides them and treats them as nonexistent; they are removed from disk by themselves if that becomes possible later, or manually from the protect/ folder of the world)")

-- reports progress in chat at most every ~5 seconds
-- kind is "save" or "load"
local function make_progress(pname, kind, sname)
    local last = minetest.get_us_time()
    return function(i, total)
        local now = minetest.get_us_time()
        if i < total and now - last < 5000000 then return end
        last = now
        local pct = math.floor(i * 100 / total)
        if kind == "save" then
            minetest.chat_send_player(pname, S("Saving '@1': @2% (batch @3/@4)", sname, pct, i, total))
        else
            minetest.chat_send_player(pname, S("Loading '@1': @2% (batch @3/@4)", sname, pct, i, total))
        end
    end
end

local function size_text(minp, maxp)
    return (maxp.x - minp.x + 1) .. "x" .. (maxp.y - minp.y + 1) .. "x" .. (maxp.z - minp.z + 1)
end

-- ============================================================
-- SINGLE COMMAND
-- ============================================================

minetest.register_chatcommand("protect", {
    privs = {protect = true},
    params = "pos1 | pos2 | <name> | edit <name>|pos1|pos2|inzone <name> | save <name>|pos1|pos2|up <name> | load <name> | check <name> | delete <name>|all | delete save <name>|all | clean <name>|all [range <number>] | list [save]",
    description = S("Manage protected areas and save/restore structures"),
    func = function(name, param)
        local args = {}
        for w in param:gmatch("%S+") do table.insert(args, w) end
        local sub = args[1]

        if not sub then
            return false, S("Usage: /protect pos1 | pos2 | <name> | edit ... | save ... | load <name> | check <name> | delete ... | clean ... | list")
        end

        -- ---------- pos1 / pos2 (create new area) ----------
        if sub == "pos1" then
            local player = minetest.get_player_by_name(name)
            if not player then return false end
            pending_pos1[name] = vector.round(player:get_pos())
            return true, S("Corner 1 set at @1", minetest.pos_to_string(pending_pos1[name]))

        elseif sub == "pos2" then
            local player = minetest.get_player_by_name(name)
            if not player then return false end
            pending_pos2[name] = vector.round(player:get_pos())
            return true, S("Corner 2 set at @1. Use /protect <name> to save",
                minetest.pos_to_string(pending_pos2[name]))

        -- ---------- list ----------
        elseif sub == "list" and args[2] == "save" then
            local names = list_saved_names()
            if #names == 0 then
                return true, S("There are no saved zones")
            end
            local out = {}
            for _, n in ipairs(names) do
                local size = file_size(save_path(n)) or 0
                if size == 0 then
                    out[#out + 1] = S("@1 (backup .bak only)", n)
                else
                    out[#out + 1] = S("@1 (@2 KB)", n, math.floor(size / 1024))
                end
            end
            return true, S("Saves (@1): @2", #names, table.concat(out, ", "))

        elseif sub == "list" then
            local names = {}
            for zname in pairs(zones) do table.insert(names, zname) end
            table.sort(names)
            if #names == 0 then
                return true, S("There are no protected areas")
            end

            local items = {}
            for _, zname in ipairs(names) do
                table.insert(items, minetest.formspec_escape(zname))
            end

            local spec = "size[6,7]" ..
                "label[2,0.2;" .. minetest.formspec_escape(S("Protected areas")) .. "]" ..
                "textlist[0.3,0.7;5.4,5.5;protect_list;" .. table.concat(items, ",") .. ";1;false]" ..
                "button_exit[2,6.4;2,0.7;close;" .. minetest.formspec_escape(S("Close")) .. "]"
            minetest.show_formspec(name, "juha_protect:list", spec)
            return true

        -- ---------- clean ----------
        elseif sub == "clean" then
            local target = args[2]
            if not target then
                return false, S("Usage: /protect clean <name>|all [range <number>]")
            end

            local range = nil
            if args[3] == "range" then
                range = tonumber(args[4])
                if not range then
                    return false, S("Usage: /protect clean @1 range <number>", target)
                end
            end

            local targets = {}
            if target == "all" then
                for zname, z in pairs(zones) do
                    table.insert(targets, {name = zname, zone = z})
                end
                if #targets == 0 then
                    return true, S("There are no protected areas to clean")
                end
            else
                local z = zones[target]
                if not z then
                    return false, S("No area named '@1' exists", target)
                end
                table.insert(targets, {name = target, zone = z})
            end

            local total = 0
            for _, t in ipairs(targets) do
                local z = t.zone
                local minp, maxp = z.min, z.max
                if range then
                    minp = vector.new(minp.x - range, minp.y - range, minp.z - range)
                    maxp = vector.new(maxp.x + range, maxp.y + range, maxp.z + range)
                end
                total = total + clean_box(minp, maxp)
            end
            save_placed_blocks()

            local range_txt = range and (" " .. S("(range @1 blocks around)", range)) or ""
            if target == "all" then
                return true, S("Full cleanup: @1 blocks removed in @2 area(s)@3", total, #targets, range_txt)
            end
            return true, S("Area '@1' cleaned: @2 blocks removed@3", target, total, range_txt)

        -- ---------- edit <name> | edit pos1 | edit pos2 | edit inzone <name> ----------
        elseif sub == "edit" then
            local target = args[2]
            local player = minetest.get_player_by_name(name)

            if target == "inzone" then
                local zname = args[3]
                if not zname then
                    return false, S("Usage: /protect edit inzone <name>")
                end
                local z = zones[zname]
                if not z then
                    return false, S("No area named '@1' exists", zname)
                end
                local locked = lock_zone(z.min, z.max)
                return true, S("Area '@1' locked again using its saved bounds (@2 blocks locked again)", zname, locked)

            elseif target == "pos1" then
                if not edit_name[name] then
                    return false, S("First use /protect edit <name>")
                end
                if not player then return false end
                edit_pos1[name] = vector.round(player:get_pos())
                return true, S("Corner 1 set at @1", minetest.pos_to_string(edit_pos1[name]))

            elseif target == "pos2" then
                if not edit_name[name] then
                    return false, S("First use /protect edit <name>")
                end
                if not edit_pos1[name] then
                    return false, S("Set /protect edit pos1 first")
                end
                if not player then return false end
                local minp, maxp = corners(edit_pos1[name], vector.round(player:get_pos()))
                local zname = edit_name[name]
                zones[zname] = {min = minp, max = maxp}
                save_zones()
                local locked = lock_zone(minp, maxp)
                edit_name[name] = nil
                edit_pos1[name] = nil
                return true, S("Area '@1' edited and saved (@2 blocks locked again)", zname, locked)

            else
                if not target then
                    return false, S("Usage: /protect edit <name> | edit inzone <name> | edit pos1 | edit pos2")
                end
                if not zones[target] then
                    return false, S("No area named '@1' exists", target)
                end
                edit_name[name] = target
                edit_pos1[name] = nil
                return true, S("Editing '@1'. Set /protect edit pos1 and then /protect edit pos2", target)
            end

        -- ---------- save <name> | save pos1 | save pos2 | save up <name> ----------
        elseif sub == "save" then
            local target = args[2]
            local player = minetest.get_player_by_name(name)

            -- returns ok, message (ok=false if another operation is already running)
            local function do_capture_and_save(sname, minp, maxp)
                local okj, job = begin_job("save", sname, name)
                if not okj then return false, job end

                capture_zone_async(minp, maxp, function(holder, st)
                    local ok, err, path, info = write_save_file(sname, holder)
                    end_job(job)
                    if ok then
                        local msg = S("Zone '@1' saved and verified at: @2 (@3 nodes, @4 entities, @5 KB)",
                            sname, path, info.nodes, info.entities, math.floor(info.bytes / 1024))
                        if info.backup then
                            msg = msg .. ". " .. S("The previous save was kept as .bak")
                        end
                        minetest.chat_send_player(name, msg)
                        if st.meta_skipped > 0 then
                            minetest.chat_send_player(name, S("Warning: @1 node(s) had metadata that cannot be saved; they were saved without it",
                                st.meta_skipped))
                        end
                        if st.ent_skipped > 0 then
                            minetest.chat_send_player(name, S("Warning: @1 entity(ies) could not be saved (see debug.txt)",
                                st.ent_skipped))
                        end
                    else
                        minetest.chat_send_player(name, S("Error writing the file (@1): @2. If there was already a save, it is intact",
                            tostring(path), tostring(err)))
                    end
                end, function(err)
                    end_job(job)
                    minetest.chat_send_player(name, S("Error saving '@1': @2. If there was already a save, it is intact (check debug.txt for more detail)",
                        sname, tostring(err)))
                end, make_progress(name, "save", sname))

                return true, S("Saving '@1' (@2)... I will tell you in chat about the progress and when it finishes",
                    sname, size_text(minp, maxp))
            end

            if target == "up" then
                local zname = args[3]
                if not zname then
                    return false, S("Usage: /protect save up <name>")
                end
                local z = zones[zname]
                if not z then
                    return false, S("No protected area named '@1' exists", zname)
                end
                return do_capture_and_save(zname, z.min, z.max)

            elseif target == "pos1" then
                if not save_name[name] then
                    return false, S("First use /protect save <name>")
                end
                if not player then return false end
                save_pos1[name] = vector.round(player:get_pos())
                return true, S("Corner 1 set at @1", minetest.pos_to_string(save_pos1[name]))

            elseif target == "pos2" then
                if not save_name[name] then
                    return false, S("First use /protect save <name>")
                end
                if not save_pos1[name] then
                    return false, S("Set /protect save pos1 first")
                end
                if not player then return false end
                local minp, maxp = corners(save_pos1[name], vector.round(player:get_pos()))
                local sname = save_name[name]

                local okc, msg = do_capture_and_save(sname, minp, maxp)
                if okc then
                    -- only now is the selection cleared (if another operation was running it is kept)
                    save_name[name] = nil
                    save_pos1[name] = nil
                end
                return okc, msg

            else
                if not target then
                    return false, S("Usage: /protect save <name> | save pos1 | save pos2 | save up <name>")
                end
                save_name[name] = target
                save_pos1[name] = nil
                return true, S("Saving '@1'. Set /protect save pos1 and then /protect save pos2", target)
            end

        -- ---------- load <name> ----------
        elseif sub == "load" then
            local target = args[2]
            if not target then
                return false, S("Usage: /protect load <name>")
            end
            -- the WHOLE file is validated before touching the map
            local snap, path, note, warn = read_save_file(target)
            if not snap then
                return false, path  -- in this case "path" holds the error message
            end

            local okj, job = begin_job("load", target, name)
            if not okj then return false, job end

            if note then minetest.chat_send_player(name, S("Warning: @1", note)) end
            if warn then minetest.chat_send_player(name, S("Warning: @1", warn)) end

            restore_zone_async(snap, function(st)
                end_job(job)
                local extra = {}
                if st.unknown > 0 then
                    table.insert(extra, S("@1 node(s) from mods that are not installed", st.unknown))
                end
                if st.meta_fail > 0 then
                    table.insert(extra, S("@1 metadata could not be restored", st.meta_fail))
                end
                if st.ent_skipped > 0 then
                    table.insert(extra, S("@1 entity(ies) could not be recreated", st.ent_skipped))
                end
                local txt = ""
                if #extra > 0 then
                    txt = " " .. S("(@1, see debug.txt)", table.concat(extra, ", "))
                end
                minetest.chat_send_player(name, S("Zone '@1' fully reloaded at its original position@2", target, txt))
            end, function(err)
                end_job(job)
                minetest.chat_send_player(name, S("Error loading '@1': @2. The batches already restored are complete; repeat /protect load @3 (check debug.txt for more detail)",
                    target, tostring(err), target))
            end, make_progress(name, "load", target))

            return true, S("Loading '@1' (@2, @3 nodes)... I will tell you in chat about the progress and when it finishes",
                target, size_text(snap.min, snap.max), #snap.nodes)

        -- ---------- check <name> (verifies the file without touching the map) ----------
        elseif sub == "check" then
            local target = args[2]
            if not target then
                return false, S("Usage: /protect check <name>")
            end
            local snap, path, note, warn = read_save_file(target)
            if not snap then
                return false, path
            end
            local msg = S("'@1' is OK: @2 nodes, @3 entities, zone of @4 (@5)",
                target, #snap.nodes, #snap.entities, size_text(snap.min, snap.max), path)
            if note then msg = msg .. ". " .. note end
            if warn then msg = msg .. ". " .. S("Warning: @1", warn) end
            return true, msg

        -- ---------- delete save <name>|all  /  delete <name>|all ----------
        elseif sub == "delete" then
            local target = args[2]
            if not target then
                return false, S("Usage: /protect delete <name>|all  (removes the protection)  |  /protect delete save <name>|all  (deletes the .jp save)")
            end

            -- ----- saves (.jp): the map is NOT touched -----
            if target == "save" then
                local sname = args[3]
                if not sname then
                    return false, S("Usage: /protect delete save <name>|all")
                end
                if current_job then
                    return false, S("An operation is in progress (@1 '@2'). Wait for it to finish before deleting saves",
                        job_label(current_job.kind), current_job.name)
                end

                if sname == "all" then
                    local names = list_saved_names()
                    if #names == 0 then
                        return true, S("There are no saved zones")
                    end
                    if needs_confirmation(name, "save all") then
                        return true, S("This permanently deletes @1 save(s): @2. The map is NOT touched. Repeat /protect delete save all within the next 30 seconds to confirm",
                            #names, table.concat(names, ", "))
                    end
                    local done, emptied, failed = 0, false, {}
                    for _, n in ipairs(names) do
                        local existed, mode, err = delete_save(n)
                        if err then
                            failed[#failed + 1] = n .. " (" .. tostring(err) .. ")"
                        elseif existed then
                            done = done + 1
                            if mode == "emptied" then emptied = true end
                        end
                    end
                    local msg = S("@1 save(s) deleted. The map was not touched", done)
                    if #failed > 0 then
                        msg = msg .. ". " .. S("Could not delete: @1", table.concat(failed, ", "))
                    end
                    if emptied then msg = msg .. EMPTIED_NOTE end
                    return #failed == 0, msg
                end

                local existed, mode, err = delete_save(sname)
                if err then
                    return false, S("Could not delete the save '@1': @2", sname, tostring(err))
                end
                if not existed then
                    return false, S("No save named '@1' exists", sname)
                end
                local msg = S("Save '@1' deleted (including its .bak). The zone on the map stays as it was", sname)
                if mode == "emptied" then msg = msg .. EMPTIED_NOTE end
                return true, msg
            end

            -- ----- protections: protection is removed, the map and the saves are not touched -----
            if target == "all" then
                local names = {}
                for zname in pairs(zones) do names[#names + 1] = zname end
                table.sort(names)
                if #names == 0 then
                    return true, S("There are no protected areas")
                end
                if needs_confirmation(name, "zones all") then
                    return true, S("This removes the protection of @1 area(s): @2. Blocks and saves are not touched. Repeat /protect delete all within the next 30 seconds to confirm",
                        #names, table.concat(names, ", "))
                end
                for _, zname in ipairs(names) do remove_zone(zname) end
                save_zones()
                return true, S("Protection removed from @1 area(s)", #names)
            end

            if not zones[target] then
                return false, S("No area named '@1' exists", target)
            end
            remove_zone(target)
            save_zones()
            return true, S("Protection of '@1' removed. Blocks and the save (if any) stay as they are", target)

        -- ---------- <name> (create new area) ----------
        else
            local zname = sub
            local p1, p2 = pending_pos1[name], pending_pos2[name]
            if not p1 or not p2 then
                return false, S("Set both corners first with /protect pos1 and /protect pos2")
            end
            local minp, maxp = corners(p1, p2)
            zones[zname] = {min = minp, max = maxp}
            save_zones()
            local locked = lock_zone(minp, maxp)
            pending_pos1[name] = nil
            pending_pos2[name] = nil
            return true, S("Area '@1' saved and protected (@2 blocks locked)", zname, locked)
        end
    end
})
