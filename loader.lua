local REPO = "123hoipopper13r6/Penablox-lua-loader"
local BRANCH = "main"
local DIR = "luas"
local LIST_URL = "https://api.github.com/repos/" .. REPO .. "/contents/" .. DIR .. "?ref=" .. BRANCH
local RAW_URL = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/" .. DIR .. "/"
local TOGGLE_KEY = "RightShift"
local REQUEST_GAP = 2.1
local RETRY_WAIT = 3
local MAX_TRIES = 3

local W = 480
local H = 560
local PAD = 16
local HEADER_H = 48
local TOOLBAR_H = 40
local FOOTER_H = 32
local ROW_H = 56
local ROW_GAP = 4
local LIST_Y = HEADER_H + TOOLBAR_H
local LIST_H = H - LIST_Y - FOOTER_H
local VISIBLE_ROWS = math.floor(LIST_H / (ROW_H + ROW_GAP))
local ROW_W = W - PAD * 2

local C = {
    bg = color(17, 18, 22),
    surface = color(23, 25, 31),
    raised = color(30, 33, 40),
    hairline = color(38, 41, 50),
    text = color(235, 237, 243),
    secondary = color(160, 166, 180),
    muted = color(110, 116, 132),
    accent = color(122, 140, 250),
    bad = color(232, 96, 108),
    primary_bg = color(235, 237, 243),
    primary_text = color(17, 18, 22),
}

local S = {
    open = false,
    scripts = {},
    listed = false,
    busy = false,
    loading_all = false,
    status = "idle",
    scroll = 0,
    dirty = true,
    last_request = 0,
    last_error = "",
    loaded_count = 0,
    entrance = nil,
    http_fn = request or http_request or (syn and syn.request) or client.request,
    compile_fn = loadstring,
}

if type(S.compile_fn) ~= "function" and type(getgenv) == "function" then
    local genv = getgenv()
    if type(genv) == "table" and type(genv.loadstring) == "function" then
        S.compile_fn = genv.loadstring
    end
end

local function http_get(url)
    if not S.http_fn then
        S.last_error = "no http api"
        return nil
    end
    local gap = REQUEST_GAP - (os.clock() - S.last_request)
    if gap > 0 then
        task.wait(gap)
    end
    local attempt = { n = 0 }
    while attempt.n < MAX_TRIES do
        attempt.n = attempt.n + 1
        S.last_request = os.clock()
        local ok, res = pcall(S.http_fn, {
            Url = url,
            Method = "GET",
            Headers = {
                ["User-Agent"] = "penablox-loader",
                ["Accept"] = "application/vnd.github+json",
            },
        })
        if ok and type(res) == "table" then
            if res.StatusCode == 200 and type(res.Body) == "string" then
                return res.Body
            end
            if res.StatusCode == 429 or res.StatusCode == 502 or res.StatusCode == 503 then
                S.status = "rate limited, waiting"
                S.dirty = true
                task.wait(RETRY_WAIT)
            else
                S.last_error = "http " .. tostring(res.StatusCode)
                return nil
            end
        else
            S.last_error = "request failed"
            task.wait(1)
        end
    end
    S.last_error = "rate limited"
    return nil
end

local function parse_author(source)
    for line in source:gmatch("[^\r\n]+") do
        local body = line:match("^%s*%-%-%s*(.+)$")
        if body then
            local key, value = body:match("^([%a_ ]-)%s*:%s*(.+)$")
            if key then
                local normalized = key:lower():gsub("%s+", "")
                if normalized == "credits" or normalized == "credit" or normalized == "author" then
                    local trimmed = value:match("^%s*(.-)%s*$")
                    if trimmed and #trimmed > 0 then
                        return trimmed
                    end
                end
            end
        end
    end
    return "unknown"
end

local function proxy(namespace, overrides)
    return setmetatable(overrides, { __index = namespace })
end

local function track(list, value)
    if value ~= nil then
        list[#list + 1] = value
    end
end

local function wrap_fn(record, fn)
    return function(a, b, c, d, e)
        local ok, err = pcall(fn, a, b, c, d, e)
        if not ok then
            local now = os.clock()
            if now - record.last_error_at > 3 then
                record.last_error_at = now
                client.error("[" .. record.name .. "] " .. tostring(err))
            end
        end
    end
end

local function remove_handle(handle)
    if type(handle) ~= "table" then
        return
    end
    if type(handle.remove) == "function" then
        handle:remove()
    elseif type(handle.Destroy) == "function" then
        handle:Destroy()
    elseif type(handle.disconnect) == "function" then
        handle:disconnect()
    elseif type(handle.cancel) == "function" then
        handle:cancel()
    end
end

local function destroy_widget(widget)
    if type(widget) ~= "table" then
        return
    end
    if type(widget.Destroy) == "function" then
        widget:Destroy()
    elseif type(widget.destroy) == "function" then
        widget:destroy()
    elseif type(widget.Remove) == "function" then
        widget:Remove()
    elseif type(widget.set_visible) == "function" then
        widget:set_visible(false)
    end
end

local function new_record(item)
    return {
        name = item.file,
        callbacks = {},
        handles = {},
        tasks = {},
        instances = {},
        drawings = {},
        tweens = {},
        connections = {},
        widgets = {},
        last_error_at = 0,
    }
end

local function unload_record(record)
    for _, thread in ipairs(record.tasks) do
        pcall(task.cancel, thread)
    end
    for _, entry in ipairs(record.callbacks) do
        pcall(client.unset_event_callback, entry.event, entry.fn)
    end
    for _, handle in ipairs(record.handles) do
        pcall(remove_handle, handle)
    end
    for _, connection in ipairs(record.connections) do
        pcall(connection.Disconnect, connection)
    end
    for _, anim in ipairs(record.tweens) do
        pcall(remove_handle, anim)
    end
    for _, drawing in ipairs(record.drawings) do
        pcall(drawing.Destroy, drawing)
    end
    for _, inst in ipairs(record.instances) do
        pcall(inst.Destroy, inst)
    end
    for _, widget in ipairs(record.widgets) do
        pcall(destroy_widget, widget)
    end
end

local function build_env(item, record)
    local base = getfenv()
    local env = setmetatable({}, { __index = base })
    env._G = env
    env.getgenv = function()
        return env
    end
    env.getfenv = function()
        return env
    end
    env.script = setmetatable({ Name = item.file }, { __index = base.script })

    local function register(event, fn)
        local wrapped = wrap_fn(record, fn)
        client.set_event_callback(event, wrapped)
        record.callbacks[#record.callbacks + 1] = { event = event, fn = wrapped }
        return wrapped
    end

    local function track_handle(handle)
        track(record.handles, handle)
        return handle
    end

    local function track_thread(thread)
        track(record.tasks, thread)
        return thread
    end

    env.cheat = proxy(base.cheat, {
        on = function(event, fn)
            return register(event, fn)
        end,
        register_callback = function(event, fn)
            return register(event, fn)
        end,
    })

    env.client = proxy(base.client, {
        set_event_callback = function(event, fn)
            return register(event, fn)
        end,
        register_callback = function(event, fn)
            return register(event, fn)
        end,
        on = function(event, fn)
            return track_handle(base.client.on(event, wrap_fn(record, fn)))
        end,
        delay_call = function(seconds, fn)
            return track_thread(task.delay(seconds, wrap_fn(record, fn)))
        end,
        delay_ticks = function(ticks, fn)
            return track_handle(base.events.delay_ticks(ticks, wrap_fn(record, fn)))
        end,
    })

    env.events = proxy(base.events, {
        on = function(event, fn)
            return track_handle(base.events.on(event, wrap_fn(record, fn)))
        end,
        on_tick = function(fn)
            return track_handle(base.events.on_tick(wrap_fn(record, fn)))
        end,
        every_ticks = function(interval, fn)
            return track_handle(base.events.every_ticks(interval, wrap_fn(record, fn)))
        end,
        at_tick = function(tick, fn)
            return track_handle(base.events.at_tick(tick, wrap_fn(record, fn)))
        end,
        delay_ticks = function(ticks, fn)
            return track_handle(base.events.delay_ticks(ticks, wrap_fn(record, fn)))
        end,
    })

    env.task = proxy(base.task, {
        spawn = function(fn)
            return track_thread(task.spawn(wrap_fn(record, fn)))
        end,
        delay = function(seconds, fn)
            return track_thread(task.delay(seconds, wrap_fn(record, fn)))
        end,
        defer = function(fn)
            return track_thread(task.defer(wrap_fn(record, fn)))
        end,
    })

    env.spawn = function(fn)
        return track_thread(task.spawn(wrap_fn(record, fn)))
    end
    env.delay = function(seconds, fn)
        return track_thread(task.delay(seconds, wrap_fn(record, fn)))
    end

    env.Instance = proxy(base.Instance, {
        new = function(class, parent)
            local inst = base.Instance.new(class, parent)
            track(record.instances, inst)
            return inst
        end,
    })

    env.Drawing = proxy(base.Drawing, {
        new = function(kind)
            local obj = base.Drawing.new(kind)
            track(record.drawings, obj)
            return obj
        end,
        New = function(kind)
            local obj = base.Drawing.new(kind)
            track(record.drawings, obj)
            return obj
        end,
    })

    local render_overrides = {}
    local render_creators = {
        "create_text", "create_rect", "create_line", "create_circle",
        "create_triangle", "create_quad", "create_image",
    }
    for _, key in ipairs(render_creators) do
        render_overrides[key] = function(props)
            local obj = base.render[key](props)
            track(record.drawings, obj)
            return obj
        end
    end
    env.render = proxy(base.render, render_overrides)

    local d3_overrides = {}
    local d3_creators = {
        "create", "create_box", "create_sphere",
        "create_cylinder", "create_line", "create_wireframe",
    }
    for _, key in ipairs(d3_creators) do
        d3_overrides[key] = function(a, b)
            local obj = base.render3d[key](a, b)
            track(record.drawings, obj)
            return obj
        end
    end
    env.render3d = proxy(base.render3d, d3_overrides)
    env.Drawing3D = env.render3d

    local function track_tween(target, duration, props, opts)
        local anim = base.tween.create(target, duration, props, opts)
        track(record.tweens, anim)
        return anim
    end
    env.tween = proxy(base.tween, {
        create = track_tween,
        Create = track_tween,
        New = track_tween,
    })

    env.input = proxy(base.input, {
        on_key_press = function(key, fn)
            local wrapped = wrap_fn(record, fn)
            local wanted = tostring(key):lower()
            local listener = function(key_name, input_object)
                if type(key_name) == "string" and key_name:lower() == wanted then
                    wrapped(key_name, input_object)
                end
            end
            client.set_event_callback("key_press", listener)
            record.callbacks[#record.callbacks + 1] = { event = "key_press", fn = listener }
        end,
        on_input_began = function(fn)
            return register("input_began", fn)
        end,
        on_input_ended = function(fn)
            return register("input_ended", fn)
        end,
    })

    local menu_overrides = {}
    local menu_names = { "new_tab", "new_checkbox", "new_slider", "new_combobox", "new_hotkey" }
    for _, name in ipairs(menu_names) do
        menu_overrides[name] = function(a, b, c, d, e, f, g, h, i)
            local el = base.menu[name](a, b, c, d, e, f, g, h, i)
            track(record.widgets, el)
            return el
        end
    end
    env.menu = proxy(base.menu, menu_overrides)

    local ui_overrides = {}
    local ui_names = {
        "new_checkbox", "new_slider", "new_combobox", "new_multiselect",
        "new_color_picker", "new_hotkey", "new_button", "new_label",
        "new_textbox", "new_listbox",
    }
    for _, name in ipairs(ui_names) do
        ui_overrides[name] = function(a, b, c, d, e, f, g, h, i)
            if name == "new_button" and type(d) == "function" then
                d = wrap_fn(record, d)
            end
            local el = base.ui[name](a, b, c, d, e, f, g, h, i)
            track(record.widgets, el)
            return el
        end
    end
    env.ui = proxy(base.ui, ui_overrides)

    env.chat = proxy(base.chat, {
        on_message = function(fn)
            local connection = base.chat.on_message(wrap_fn(record, fn))
            track(record.connections, connection)
            return connection
        end,
    })

    env.database = proxy(base.database, {
        read = function(key)
            return base.database.read(item.file .. ":" .. tostring(key))
        end,
        write = function(key, value)
            return base.database.write(item.file .. ":" .. tostring(key), value)
        end,
    })

    return env
end

local function load_script(item)
    if item.loaded or item.loading then
        return
    end
    if type(S.compile_fn) ~= "function" then
        S.status = "loadstring unavailable in this build"
        S.dirty = true
        notify("Loader", "loadstring is not available in this build", 4)
        return
    end
    item.loading = true
    item.failed = false
    S.dirty = true
    if not item.source then
        S.status = "fetching " .. item.file
        S.dirty = true
        local body = http_get(item.url)
        if not body then
            item.loading = false
            item.failed = true
            item.error = S.last_error
            S.status = "fetch failed, " .. S.last_error
            S.dirty = true
            return
        end
        item.source = body
        item.author = parse_author(body)
    end
    local ok, chunk, compile_error = pcall(S.compile_fn, item.source, "@" .. item.file)
    if not ok or not chunk then
        item.loading = false
        item.failed = true
        item.error = tostring(compile_error or ok)
        S.status = "compile failed, " .. item.file
        S.dirty = true
        return
    end
    local record = new_record(item)
    local env = build_env(item, record)
    if type(setfenv) == "function" then
        pcall(setfenv, chunk, env)
    end
    local ran, run_error = pcall(chunk)
    if not ran then
        unload_record(record)
        item.loading = false
        item.failed = true
        item.error = tostring(run_error)
        S.status = "runtime error, " .. item.file
        S.dirty = true
        client.error("[" .. item.file .. "] " .. tostring(run_error))
        return
    end
    item.record = record
    item.loaded = true
    item.loading = false
    item.error = nil
    S.status = "loaded " .. item.name
    S.dirty = true
end

local function unload_item(item)
    if not item.loaded then
        return
    end
    if item.record then
        unload_record(item.record)
    end
    item.record = nil
    item.loaded = false
    S.status = "unloaded " .. item.name
    S.dirty = true
    if not S.open then
        for _, other in ipairs(S.scripts) do
            if other.loaded then
                return
            end
        end
        input.lock_cursor()
    end
end

local function recount()
    S.loaded_count = 0
    for _, item in ipairs(S.scripts) do
        if item.loaded then
            S.loaded_count = S.loaded_count + 1
        end
    end
end

local function load_all()
    if S.loading_all then
        return
    end
    S.loading_all = true
    for _, item in ipairs(S.scripts) do
        if not item.loaded then
            load_script(item)
        end
    end
    S.loading_all = false
    recount()
    S.status = "ready"
    S.dirty = true
    notify("Loader", "Loaded " .. S.loaded_count .. " of " .. #S.scripts .. " scripts", 3)
end

local function unload_all()
    for _, item in ipairs(S.scripts) do
        if item.loaded then
            unload_item(item)
        end
    end
    pcall(aa.reset)
    pcall(rage.reset)
    pcall(plist.reset_all)
    pcall(chams.clear_overrides)
    pcall(sounds.reset_hitsound)
    pcall(sounds.reset_killsound)
    recount()
    S.status = "unloaded all"
    S.dirty = true
end

local function fetch_sources()
    local total = #S.scripts
    for i, item in ipairs(S.scripts) do
        if not item.source then
            S.status = "fetching " .. i .. "/" .. total
            S.dirty = true
            local body = http_get(item.url)
            if body then
                item.source = body
                item.author = parse_author(body)
                item.failed = false
            else
                item.author = "fetch failed"
                item.failed = true
            end
            S.dirty = true
        end
    end
    S.status = "ready"
    S.busy = false
    S.dirty = true
end

local function refresh()
    if S.busy then
        return
    end
    S.busy = true
    S.status = "listing scripts"
    S.dirty = true
    local body = http_get(LIST_URL)
    if not body then
        S.status = "list failed, " .. S.last_error
        S.busy = false
        S.dirty = true
        return
    end
    local entries = json.parse(body)
    if type(entries) ~= "table" or entries.message then
        S.status = "list failed, bad response"
        S.busy = false
        S.dirty = true
        return
    end
    local previous = {}
    for _, item in ipairs(S.scripts) do
        previous[item.file] = item
    end
    local found = {}
    for _, entry in ipairs(entries) do
        if entry.type == "file" and type(entry.name) == "string" and entry.name:lower():sub(-4) == ".lua" then
            local stem = entry.name:sub(1, #entry.name - 4):gsub("[_-]+", " ")
            local item = {
                file = entry.name,
                name = stem:sub(1, 1):upper() .. stem:sub(2),
                url = entry.download_url or (RAW_URL .. entry.name),
                author = "pending",
                source = nil,
                loaded = false,
                loading = false,
                failed = false,
                record = nil,
                error = nil,
            }
            local old = previous[entry.name]
            if old then
                item.source = old.source
                item.author = old.author
                item.loaded = old.loaded
                item.loading = old.loading
                item.failed = old.failed
                item.record = old.record
                item.error = old.error
            end
            found[#found + 1] = item
        end
    end
    table.sort(found, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    S.scripts = found
    S.listed = true
    S.scroll = 0
    S.status = "fetching credits"
    S.dirty = true
    fetch_sources()
end

local function make(kind, props)
    local obj = Drawing.new(kind)
    for key, value in pairs(props) do
        obj[key] = value
    end
    return obj
end

local window = make("Square", {
    Size = vector(W, H),
    Position = vector(240, 160),
    Color = C.bg,
    Rounding = 12,
    BorderColor = C.hairline,
    ClipsDescendants = true,
    Visible = false,
    ZIndex = 10,
})

local saved_pos = database.read("loader_pos")
if type(saved_pos) == "table" and type(saved_pos.x) == "number" and type(saved_pos.y) == "number" then
    window.Position = vector(saved_pos.x, saved_pos.y)
end

local header = make("Square", {
    Size = vector(W, HEADER_H),
    Position = vector(0, 0),
    Color = C.surface,
    Rounding = 12,
    BorderColor = C.hairline,
    Parent = window,
    ZIndex = 11,
})

make("Text", {
    Text = "penablox",
    Position = vector(PAD, 10),
    Color = C.text,
    Size = 14,
    Font = 0,
    Parent = header,
    ZIndex = 12,
})

make("Text", {
    Text = "lua loader",
    Position = vector(PAD, 28),
    Color = C.muted,
    Size = 11,
    Font = 0,
    Parent = header,
    ZIndex = 12,
})

local keycap = make("Square", {
    Size = vector(56, 20),
    Position = vector(W - PAD - 24 - 8 - 56, 14),
    Color = C.raised,
    Rounding = 4,
    BorderColor = C.hairline,
    Parent = header,
    ZIndex = 12,
})

make("Text", {
    Text = "RShift",
    Position = vector(W - PAD - 24 - 8 - 56 + 28, 18),
    Color = C.secondary,
    Size = 10,
    Font = 3,
    Center = true,
    Parent = header,
    ZIndex = 13,
})

local close_btn = make("Square", {
    Size = vector(24, 24),
    Position = vector(W - PAD - 24, 12),
    Color = C.surface,
    Rounding = 6,
    Parent = header,
    ZIndex = 12,
})

make("Text", {
    Text = "x",
    Position = vector(W - PAD - 12, 17),
    Color = C.muted,
    Size = 12,
    Font = 0,
    Center = true,
    Parent = header,
    ZIndex = 13,
})

local function make_button(x, w, label, primary)
    local bg = make("Square", {
        Size = vector(w, 28),
        Position = vector(x, HEADER_H + 6),
        Color = primary and C.primary_bg or C.raised,
        Rounding = 8,
        BorderColor = primary and C.primary_bg or C.hairline,
        Parent = window,
        ZIndex = 12,
    })
    make("Text", {
        Text = label,
        Position = vector(x + w / 2, HEADER_H + 14),
        Color = primary and C.primary_text or C.secondary,
        Size = 12,
        Font = 0,
        Center = true,
        Parent = window,
        ZIndex = 13,
    })
    return bg
end

local refresh_btn = make_button(PAD, 80, "Refresh", false)
local loadall_btn = make_button(PAD + 88, 88, "Load all", true)
local unloadall_btn = make_button(PAD + 184, 96, "Unload all", false)

local function make_scroll_button(x, up)
    local bg = make("Square", {
        Size = vector(28, 28),
        Position = vector(x, HEADER_H + 6),
        Color = C.raised,
        Rounding = 8,
        BorderColor = C.hairline,
        Parent = window,
        ZIndex = 12,
        Visible = false,
    })
    local cx = x + 14
    local cy = HEADER_H + 20
    local points
    if up then
        points = {
            PointA = vector(cx, cy - 4),
            PointB = vector(cx - 5, cy + 3),
            PointC = vector(cx + 5, cy + 3),
        }
    else
        points = {
            PointA = vector(cx - 5, cy - 3),
            PointB = vector(cx + 5, cy - 3),
            PointC = vector(cx, cy + 4),
        }
    end
    points.Color = C.secondary
    points.Filled = true
    points.Parent = window
    points.ZIndex = 13
    points.Visible = false
    local tri = make("Triangle", points)
    return { bg = bg, tri = tri }
end

local scroll_up = make_scroll_button(W - PAD - 64, true)
local scroll_down = make_scroll_button(W - PAD - 28, false)

local list_clip = make("Square", {
    Size = vector(ROW_W, LIST_H),
    Position = vector(PAD, LIST_Y),
    Color = C.bg,
    Parent = window,
    ClipsDescendants = true,
    ZIndex = 11,
})

local function make_row(index)
    local y = (index - 1) * (ROW_H + ROW_GAP)
    local bg = make("Square", {
        Size = vector(ROW_W, ROW_H),
        Position = vector(0, y),
        Color = C.surface,
        Rounding = 8,
        BorderColor = C.hairline,
        Parent = list_clip,
        ZIndex = 12,
        Visible = false,
    })
    local dot = make("Circle", {
        Position = vector(16, ROW_H / 2),
        Radius = 4,
        Color = C.muted,
        Filled = true,
        Parent = bg,
        ZIndex = 13,
        Visible = false,
    })
    local name_text = make("Text", {
        Text = "",
        Position = vector(32, 12),
        Color = C.text,
        Size = 13,
        Font = 0,
        Parent = bg,
        ZIndex = 13,
        Visible = false,
    })
    local author_text = make("Text", {
        Text = "",
        Position = vector(32, 32),
        Color = C.muted,
        Size = 11,
        Font = 3,
        Parent = bg,
        ZIndex = 13,
        Visible = false,
    })
    local btn = make("Square", {
        Size = vector(72, 28),
        Position = vector(ROW_W - 84, 14),
        Color = C.raised,
        Rounding = 8,
        BorderColor = C.hairline,
        Parent = bg,
        ZIndex = 13,
        Visible = false,
    })
    local btn_text = make("Text", {
        Text = "Load",
        Position = vector(ROW_W - 48, 22),
        Color = C.secondary,
        Size = 12,
        Font = 0,
        Center = true,
        Parent = bg,
        ZIndex = 14,
        Visible = false,
    })
    return {
        bg = bg,
        dot = dot,
        name = name_text,
        author = author_text,
        btn = btn,
        btn_text = btn_text,
        item = nil,
        hover = 0,
    }
end

local rows = {}
for i = 1, VISIBLE_ROWS do
    rows[#rows + 1] = make_row(i)
end

local function set_row_visible(row, visible)
    row.bg.Visible = visible
    row.dot.Visible = visible
    row.name.Visible = visible
    row.author.Visible = visible
    row.btn.Visible = visible
    row.btn_text.Visible = visible
end

local scroll_track = make("Square", {
    Size = vector(2, LIST_H - 8),
    Position = vector(W - 10, LIST_Y + 4),
    Color = C.hairline,
    Parent = window,
    ZIndex = 12,
    Visible = false,
})

local scroll_thumb = make("Square", {
    Size = vector(2, 24),
    Position = vector(W - 10, LIST_Y + 4),
    Color = C.muted,
    Rounding = 1,
    Parent = window,
    ZIndex = 13,
    Visible = false,
})

local empty_text = make("Text", {
    Text = "No scripts in luas yet",
    Position = vector(W / 2, LIST_Y + LIST_H / 2 - 16),
    Color = C.secondary,
    Size = 12,
    Font = 0,
    Center = true,
    Parent = window,
    ZIndex = 13,
    Visible = false,
})

local empty_hint = make("Text", {
    Text = "Add .lua files to the repo, then refresh",
    Position = vector(W / 2, LIST_Y + LIST_H / 2 + 4),
    Color = C.muted,
    Size = 11,
    Font = 0,
    Center = true,
    Parent = window,
    ZIndex = 13,
    Visible = false,
})

make("Square", {
    Size = vector(ROW_W, 1),
    Position = vector(PAD, H - FOOTER_H),
    Color = C.hairline,
    Parent = window,
    ZIndex = 12,
})

local status_text = make("Text", {
    Text = "idle",
    Position = vector(PAD, H - FOOTER_H + 10),
    Color = C.muted,
    Size = 11,
    Font = 0,
    Parent = window,
    ZIndex = 13,
})

local count_text = make("Text", {
    Text = "0/0 loaded",
    Position = vector(W - PAD - 80, H - FOOTER_H + 10),
    Color = C.secondary,
    Size = 11,
    Font = 3,
    Parent = window,
    ZIndex = 13,
})

local drag = window:MakeDraggable(header)

local function set_open(open)
    S.open = open
    window.Visible = open
    input.set_cursor_unlocked(open)
    if open then
        S.dirty = true
        if S.entrance then
            pcall(S.entrance.cancel, S.entrance)
        end
        local target = window.Position
        window.Position = target + vector(0, 8)
        S.entrance = tween.create(window, 0.16, { Position = target }, { style = "quad", direction = "out" })
    end
end

input.on_key_press(TOGGLE_KEY, function()
    set_open(not S.open)
end)

local uis = game:GetService("UserInputService")
uis.InputChanged:Connect(function(input_object)
    if not S.open then
        return
    end
    if input_object.InputType == Enum.UserInputType.MouseWheel then
        local max_scroll = math.max(0, #S.scripts - VISIBLE_ROWS)
        if max_scroll <= 0 then
            return
        end
        if input_object.Position.Z > 0 then
            S.scroll = math.max(0, S.scroll - 1)
        else
            S.scroll = math.min(max_scroll, S.scroll + 1)
        end
        S.dirty = true
    end
end)

client.set_event_callback("paint", function(dt)
    if not S.open then
        return
    end
    local delta = dt or 0.016
    if S.dirty then
        S.dirty = false
        recount()
        local max_scroll = math.max(0, #S.scripts - VISIBLE_ROWS)
        if S.scroll > max_scroll then
            S.scroll = max_scroll
        end
        for i = 1, VISIBLE_ROWS do
            local row = rows[i]
            local item = S.scripts[S.scroll + i]
            row.item = item
            if item then
                set_row_visible(row, true)
                row.name.Text = item.name
                local author_line = "by " .. item.author
                if item.loading then
                    author_line = "loading"
                elseif item.failed then
                    author_line = item.error or "failed"
                end
                if #author_line > 48 then
                    author_line = author_line:sub(1, 45) .. "..."
                end
                row.author.Text = author_line
                if item.loaded then
                    row.dot.Color = C.accent
                    row.btn_text.Text = "Unload"
                elseif item.failed then
                    row.dot.Color = C.bad
                    row.btn_text.Text = "Retry"
                else
                    row.dot.Color = C.muted
                    row.btn_text.Text = "Load"
                end
            else
                set_row_visible(row, false)
            end
        end
        local empty = S.listed and #S.scripts == 0
        empty_text.Visible = empty
        empty_hint.Visible = empty
        local overflow = #S.scripts > VISIBLE_ROWS
        scroll_up.bg.Visible = overflow
        scroll_up.tri.Visible = overflow
        scroll_down.bg.Visible = overflow
        scroll_down.tri.Visible = overflow
        scroll_track.Visible = overflow
        scroll_thumb.Visible = overflow
        if overflow then
            local track_h = LIST_H - 8
            local thumb_h = math.max(24, track_h * VISIBLE_ROWS / #S.scripts)
            local span = math.max(1, #S.scripts - VISIBLE_ROWS)
            scroll_thumb.Size = vector(2, thumb_h)
            scroll_thumb.Position = vector(W - 10, LIST_Y + 4 + (track_h - thumb_h) * (S.scroll / span))
        end
        status_text.Text = S.status
        local count_label = S.loaded_count .. "/" .. #S.scripts .. " loaded"
        count_text.Text = count_label
        local measured = render.measure_text(count_label, 11, 3)
        count_text.Position = vector(W - PAD - measured.X, H - FOOTER_H + 10)
    end
    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        if row.item then
            local hovered = row.bg:IsHovered()
            row.hover = tween.lerp(row.hover, hovered and 1 or 0, 16, delta)
            row.bg.Color = tween.interpolate(C.surface, C.raised, row.hover)
            if row.btn:IsClicked() then
                local item = row.item
                if item.loaded then
                    unload_item(item)
                else
                    task.spawn(load_script, item)
                end
            end
        end
    end
    if refresh_btn:IsClicked() then
        task.spawn(refresh)
    end
    if loadall_btn:IsClicked() then
        task.spawn(load_all)
    end
    if unloadall_btn:IsClicked() then
        unload_all()
    end
    if close_btn:IsClicked() then
        set_open(false)
    end
    if scroll_up.bg.Visible and scroll_up.bg:IsClicked() then
        S.scroll = math.max(0, S.scroll - 1)
        S.dirty = true
    end
    if scroll_down.bg.Visible and scroll_down.bg:IsClicked() then
        S.scroll = math.min(math.max(0, #S.scripts - VISIBLE_ROWS), S.scroll + 1)
        S.dirty = true
    end
end)

client.set_event_callback("shutdown", function()
    for _, item in ipairs(S.scripts) do
        if item.loaded and item.record then
            unload_record(item.record)
        end
    end
    local pos = window.Position
    database.write("loader_pos", { x = pos.X, y = pos.Y })
    database.flush()
    input.lock_cursor()
    if drag then
        pcall(drag.Destroy, drag)
    end
end)

notify("penablox loader", "Press RightShift to open", 4)
task.spawn(refresh)
