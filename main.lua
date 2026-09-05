-- quickchat: save custom chat messages, fire them off with a hotkey or
-- automatically on an in-game event (goal, demo, save, etc), instead of
-- typing them out in game every time.
--
-- uses hebnix.chat.send(channel, message), which taps whatever key you've
-- actually got that channel bound to, types the message, and hits enter.
-- works while playing, since sending chat isn't a competitive advantage.

local plugin = {}

local CHANNELS = { "global", "team", "party" }

local TRIGGERS = {
    "off",
    "goal for your team",
    "goal against your team",
    "you score an own goal",
    "you demo someone",
    "you get demoed",
    "you hit the crossbar",
    "a teammate hits the crossbar",
    "an opponent hits the crossbar",
    "you get an assist",
    "you make a save",
    "match ends",
}

local chats = {}          -- { {id=, channel=, text=, bind=, trigger=, count=, progress=}, ... }
local next_id = 1
local capture_index = nil -- index into chats currently capturing a bind
local held_binds = {}     -- index -> was it down last tick (edge detection)

-- local player identity, resolved once per match by matching Launch.log's
-- username against the players list. no direct "this is you" field exists
-- on StatsAPI player/event payloads.
local log_key = nil
local local_username = nil
local my_shortcut = nil
local my_team_num = nil

-- per-team score snapshot from the last UpdateState, used to work out which
-- team a goal actually benefited (own goals still count for the other team).
local team_scores = {}
local pending_goal = nil -- {scorer_shortcut=, scorer_team=, pre_scores=, ts=}

-- persistence

local function save_chats()
    hebnix.set("chats", hebnix.json_encode(chats))
end

local function load_chats()
    local raw = hebnix.get_string("chats", "[]")
    local ok, decoded = pcall(hebnix.json_decode, raw)
    chats = (ok and type(decoded) == "table") and decoded or {}

    -- backfill ids for entries saved before "id" existed
    local needs_save = false
    for _, chat in ipairs(chats) do
        if chat.id == nil then
            chat.id = next_id
            next_id = next_id + 1
            needs_save = true
        elseif chat.id >= next_id then
            next_id = chat.id + 1
        end
    end
    if needs_save then
        save_chats()
    end
end

-- firing

-- fires a chat once its trigger has happened chat.count times, then resets
-- the count so it keeps firing every Nth occurrence (count defaults to 1,
-- i.e. every time).
local function fire_chats_for(trigger)
    local changed = false
    for _, chat in ipairs(chats) do
        if chat.trigger == trigger then
            local need = math.max(1, chat.count or 1)
            chat.progress = (chat.progress or 0) + 1
            changed = true
            if chat.progress >= need then
                chat.progress = 0
                hebnix.chat.send(chat.channel, chat.text)
            end
        end
    end
    if changed then
        save_chats()
    end
end

-- local player resolution

local function resolve_local_player(update_state)
    if my_shortcut ~= nil or local_username == nil then
        return
    end
    for _, p in ipairs(update_state.Players or {}) do
        if p.Name == local_username then
            my_shortcut = p.Shortcut
            my_team_num = p.TeamNum
            break
        end
    end
end

-- goal handling: GoalScored fires immediately, but doesn't say which team's
-- score it actually counted for (an own goal counts for the other team) so
-- the resolution waits for the next UpdateState and diffs team scores.

local function resolve_pending_goal(benefiting_team)
    local goal = pending_goal
    pending_goal = nil
    if goal == nil then
        return
    end
    if my_team_num ~= nil then
        if benefiting_team == my_team_num then
            fire_chats_for("goal for your team")
        else
            fire_chats_for("goal against your team")
        end
    end
    if my_shortcut ~= nil and goal.scorer_shortcut == my_shortcut and goal.scorer_team ~= benefiting_team then
        fire_chats_for("you score an own goal")
    end
end

local function update_team_scores(update_state)
    local game = update_state.Game or {}
    local new_scores = {}
    for _, t in ipairs(game.Teams or {}) do
        new_scores[t.TeamNum] = t.Score
    end

    if pending_goal then
        for team_num, score in pairs(new_scores) do
            local prev = pending_goal.pre_scores[team_num] or 0
            if score > prev then
                resolve_pending_goal(team_num)
                break
            end
        end
        -- drop it if we somehow never see the score change land
        if pending_goal and hebnix.monotonic_seconds() - pending_goal.ts > 5 then
            pending_goal = nil
        end
    end

    team_scores = new_scores
end

local function handle_goal_scored(d)
    local scorer = d.Scorer or {}
    pending_goal = {
        scorer_shortcut = scorer.Shortcut,
        scorer_team = scorer.TeamNum,
        pre_scores = team_scores,
        ts = hebnix.monotonic_seconds(),
    }
end

local function handle_crossbar_hit(d)
    local hitter = d.BallLastTouch and d.BallLastTouch.Player
    if not hitter or my_shortcut == nil then
        return
    end
    if hitter.Shortcut == my_shortcut then
        fire_chats_for("you hit the crossbar")
    elseif hitter.TeamNum == my_team_num then
        fire_chats_for("a teammate hits the crossbar")
    else
        fire_chats_for("an opponent hits the crossbar")
    end
end

local function handle_statfeed(d)
    if my_shortcut == nil then
        return
    end
    local main_shortcut = d.MainTarget and d.MainTarget.Shortcut
    local secondary_shortcut = d.SecondaryTarget and d.SecondaryTarget.Shortcut

    if d.EventName == "Demolish" then
        if main_shortcut == my_shortcut then
            fire_chats_for("you demo someone")
        elseif secondary_shortcut == my_shortcut then
            fire_chats_for("you get demoed")
        end
    elseif d.EventName == "Assist" and main_shortcut == my_shortcut then
        fire_chats_for("you get an assist")
    elseif d.EventName == "Save" and main_shortcut == my_shortcut then
        fire_chats_for("you make a save")
    end
end

-- lifecycle

function plugin.on_load()
    load_chats()
    log_key = hebnix.parse_launch_log_async(false)
    hebnix.log("QuickChat loaded, " .. #chats .. " saved message(s)")
end

function plugin.on_game_event(event_type, event)
    local d = event.data or {}

    if event_type == "UpdateState" then
        resolve_local_player(d)
        update_team_scores(d)
    elseif event_type == "GoalScored" then
        handle_goal_scored(d)
    elseif event_type == "CrossbarHit" then
        handle_crossbar_hit(d)
    elseif event_type == "StatfeedEvent" then
        -- swap this log line out once you've confirmed the real EventName
        -- strings your account's matches send for assists/saves.
        hebnix.log("Statfeed: " .. tostring(d.EventName) .. " (main=" .. tostring((d.MainTarget or {}).Name) .. ")")
        handle_statfeed(d)
    elseif event_type == "MatchEnded" then
        fire_chats_for("match ends")
    elseif event_type == "GameLeft" or event_type == "MatchDestroyed" then
        my_shortcut = nil
        my_team_num = nil
        team_scores = {}
        pending_goal = nil
        for _, chat in ipairs(chats) do
            chat.progress = 0
        end
        save_chats()
    end
end

function plugin.on_tick()
    -- resolve local player's username once, from Launch.log
    if local_username == nil and log_key then
        local res = hebnix.launch_log_result(log_key)
        if res ~= nil and res ~= "pending" then
            local_username = (res.session or {}).username
            log_key = nil
        end
    end

    -- poll an in-flight bind capture
    if capture_index ~= nil then
        local status, bind = hebnix.capture_bind_result()
        if status == "done" then
            chats[capture_index].bind = bind
            save_chats()
            -- the key just used to capture this bind is often still
            -- physically held down for a tick or two after capture
            -- completes; mark it as already-held so the fire-on-press loop
            -- below doesn't treat that as a fresh press and try to send
            -- immediately (usually while focus is still on Hebnix's own
            -- settings window, not Rocket League, which hebnix.chat.send
            -- rejects outright and crashes the whole plugin on).
            held_binds[capture_index] = true
            capture_index = nil
        elseif status == "timeout" then
            capture_index = nil
        end
        return
    end

    -- fire any chat whose bind is freshly pressed. only while connected to
    -- RL, so this can't fire into some other focused app.
    if not hebnix.rl_connected() then
        held_binds = {}
        return
    end
    for i, chat in ipairs(chats) do
        local bind = chat.bind
        if bind and bind ~= "" then
            local down = hebnix.is_bind_pressed(bind)
            if down and not held_binds[i] then
                hebnix.chat.send(chat.channel, chat.text)
            end
            held_binds[i] = down
        end
    end
end

function plugin.on_settings(ui)
    ui.heading("Quick Chat")
    ui.label("Save a message, give it a hotkey and/or an in-game trigger.")
    ui.space(6)

    if #chats == 0 then
        ui.label("No saved messages yet.")
    end
    for i, chat in ipairs(chats) do
        ui.horizontal(function()
            ui.label("[" .. chat.channel .. "]")
            ui.label(chat.text)
            ui.label("bind: " .. (chat.bind and chat.bind ~= "" and chat.bind or "none"))
            if capture_index == i then
                ui.colored_label("#d35400", "press a key...")
            elseif ui.button("Set bind") then
                capture_index = i
                hebnix.capture_bind_async(10)
            end
            if ui.button("Remove") then
                table.remove(chats, i)
                save_chats()
            end
        end)
        ui.horizontal(function()
            local trigger_key = "trigger_" .. chat.id
            local wanted = chat.trigger or "off"
            if hebnix.get_string(trigger_key, "") ~= wanted then
                hebnix.set(trigger_key, wanted)
            end
            local trigger = ui.combo_box(trigger_key, "On event", TRIGGERS)
            if trigger ~= wanted then
                chat.trigger = trigger
                save_chats()
            end

            if trigger ~= "off" then
                local count_key = "count_" .. chat.id
                local wanted_count = chat.count or 1
                if hebnix.get_number(count_key, 0) ~= wanted_count then
                    hebnix.set(count_key, wanted_count)
                end
                local count = math.floor(ui.slider(count_key, "fire after", 1, 20, wanted_count) + 0.5)
                if count ~= wanted_count then
                    chat.count = count
                    save_chats()
                end
                ui.label("occurrence(s)  (" .. (chat.progress or 0) .. "/" .. count .. " so far)")
            end
        end)
        ui.space(4)
    end
    ui.space(6)

    ui.heading("Add message")
    local channel = ui.combo_box("new_channel", "Channel", CHANNELS)
    local text = ui.text_input("new_text", "type your message")
    if ui.button("Add") and text ~= "" then
        table.insert(chats, {
            id = next_id, channel = channel, text = text, bind = "",
            trigger = "off", count = 1, progress = 0,
        })
        next_id = next_id + 1
        save_chats()
        hebnix.set("new_text", "")
    end

    ui.space(6)
    ui.label("Local player: " .. tostring(local_username or "resolving...")
        .. (my_shortcut and (", team " .. tostring(my_team_num)) or ""))
end

return plugin
