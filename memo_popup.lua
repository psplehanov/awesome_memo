-- memo_popup.lua — попап со случайной активной запиской для Awesome WM.
--
-- Использование в rc.lua:
--   local memo = require("widgets.memo_popup")({ path = "~/vault/memos" })
--   awful.key({ modkey }, "m", function() memo:show() end)
--
-- Модуль не показывает ничего при старте и не встраивается в wibar.

local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local beautiful = require("beautiful")
local naughty = require("naughty")
local lfs = require("lfs")

local M = {}

local HINT = "Esc — закрыть    r — обновить    e — редактор    Space — статус"

local seeded = false

local function seed_random()
    if seeded then
        return
    end
    seeded = true
    math.randomseed(os.time() * 1000 + math.floor((os.clock() % 1) * 1000000))
end

local defaults = {
    path = nil,
    editor = nil,
    width = 480,
    padding = 12,
    font = nil,
    fonts = {
        topic = nil,
        memo = nil,
        button = nil,
        hint = nil,
    },
    max_height_ratio = 0.8,
    max_text_height = 320,
    colors = {
        fg = nil,
        bg = nil,
        muted = nil,
        border = nil,
        button = nil,
        button_fg = nil,
        correct = "#2e7d32",
        incorrect = "#c62828",
    },
}

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

--- Возвращает значение шрифта, если это непустая строка, иначе fallback.
local function font_or(value, fallback)
    if type(value) == "string" and trim(value) ~= "" then
        return value
    end
    return fallback
end

local function deep_merge(base, override)
    local result = {}
    for key, value in pairs(base) do
        if type(value) == "table" then
            result[key] = deep_merge(value, {})
        else
            result[key] = value
        end
    end
    for key, value in pairs(override or {}) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = deep_merge(result[key], value)
        else
            result[key] = value
        end
    end
    return result
end

local function expand_home(path)
    if not path then
        return nil
    end
    local home = os.getenv("HOME") or "~"
    if path == "~" then
        return home
    end
    if path:sub(1, 2) == "~/" then
        return home .. path:sub(2)
    end
    return path
end

local function basename(path)
    return (tostring(path or ""):match("([^/]+)$")) or ""
end

M.expand_home = expand_home

local function notify(text)
    if naughty and naughty.notify then
        naughty.notify({
            preset = naughty.config and naughty.config.presets and naughty.config.presets.critical,
            title = "memo_popup",
            text = text,
        })
    end
end

--- Разбивает текст на строки, убирая BOM и нормализуя CRLF.
local function to_lines(raw)
    local text = tostring(raw or ""):gsub("^\239\187\191", ""):gsub("\r\n", "\n")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Возвращает поля frontmatter, тело и признак наличия frontmatter.
local function parse_frontmatter(raw)
    local lines = to_lines(raw)
    if lines[1] ~= "---" then
        return {}, table.concat(lines, "\n"), false
    end

    local close_at
    for index = 2, #lines do
        if lines[index] == "---" then
            close_at = index
            break
        end
    end
    if not close_at then
        return {}, table.concat(lines, "\n"), false
    end

    local fields = {}
    for index = 2, close_at - 1 do
        local key, value = lines[index]:match("^([^:]+):(.*)$")
        if key then
            fields[trim(key)] = trim(value)
        end
    end

    local body_lines = {}
    for index = close_at + 1, #lines do
        body_lines[#body_lines + 1] = lines[index]
    end
    while #body_lines > 0 and body_lines[1] == "" do
        table.remove(body_lines, 1)
    end

    return fields, table.concat(body_lines, "\n"), true
end

local function parse_markup(body)
    local memo_blocks = {}
    for block in tostring(body or ""):gmatch("{memo}(.-){/memo}") do
        memo_blocks[#memo_blocks + 1] = trim(block)
    end

    local buttons = {}
    for block in tostring(body or ""):gmatch("{button}(.-){/button}") do
        local correct = block:find("%*%*", 1, false) ~= nil
        buttons[#buttons + 1] = {
            text = trim(block:gsub("%*%*", "")),
            correct = correct,
        }
    end

    local memo_text
    if #memo_blocks > 0 then
        memo_text = table.concat(memo_blocks, "\n\n")
    else
        local without_buttons = tostring(body or ""):gsub("{button}(.-){/button}", "")
        memo_text = trim(without_buttons)
    end

    return memo_text, buttons
end

--- Разбирает содержимое записки. filename нужен для fallback темы.
function M.parse_note(raw, filename)
    local fields, body = parse_frontmatter(raw)
    local memo_text, buttons = parse_markup(body)

    local topic = trim(fields.topic)
    if topic == "" then
        topic = basename(filename):gsub("%.md$", "")
    end

    return {
        status = fields.status,
        topic = topic,
        body = body,
        memo = memo_text,
        buttons = buttons,
    }
end

function M.read_note(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local raw = file:read("*a")
    file:close()
    if not raw then
        return nil, "cannot read file"
    end
    local note = M.parse_note(raw, path)
    note.path = path
    return note
end

--- Плоский список *.md файлов каталога.
function M.scan(dir)
    if not dir then
        return nil, "path is not set"
    end
    dir = expand_home(dir)

    local ok, iterator, dir_state = pcall(lfs.dir, dir)
    if not ok then
        return nil, tostring(iterator)
    end
    if type(iterator) ~= "function" then
        return nil, tostring(dir_state)
    end

    local paths = {}
    for name in iterator, dir_state do
        if name ~= "." and name ~= ".."
            and name:sub(1, 1) ~= "."
            and name:match("%.md$") then
            local path = dir .. "/" .. name
            local attributes = lfs.attributes(path)
            if attributes and attributes.mode == "file" then
                paths[#paths + 1] = path
            end
        end
    end
    table.sort(paths)
    return paths
end

--- Активные записки каталога; нечитаемые файлы пропускаются с warning.
function M.active_notes(dir)
    local paths, err = M.scan(dir)
    if not paths then
        return nil, err
    end

    local notes = {}
    for _, path in ipairs(paths) do
        local note, read_err = M.read_note(path)
        if not note then
            gears.debug.print_warning("memo_popup: skip " .. path .. ": " .. tostring(read_err))
        elseif note.status == "active" then
            notes[#notes + 1] = note
        end
    end
    return notes
end

--- Случайная записка, по возможности не текущая.
function M.pick(notes, current_path)
    if not notes or #notes == 0 then
        return nil
    end
    if #notes == 1 then
        return notes[1]
    end

    local candidates = {}
    for _, note in ipairs(notes) do
        if note.path ~= current_path then
            candidates[#candidates + 1] = note
        end
    end
    if #candidates == 0 then
        candidates = notes
    end
    return candidates[math.random(#candidates)]
end

--- Позиции строк в байтах, с сохранением исходных переводов строк.
local function line_spans(text)
    local spans = {}
    local position = 1
    while position <= #text do
        local newline = text:find("\n", position, true)
        local line_stop = newline and (newline - 1) or #text
        local content_stop = line_stop
        if content_stop >= position and text:sub(content_stop, content_stop) == "\r" then
            content_stop = content_stop - 1
        end
        spans[#spans + 1] = {
            start = position,
            stop = line_stop,
            content_stop = content_stop,
            next_position = newline and (newline + 1) or (#text + 1),
        }
        if not newline then
            break
        end
        position = newline + 1
    end
    return spans
end

--- Переключает status, меняя только эту строку frontmatter.
function M.toggle_status(path)
    local file, read_err = io.open(path, "rb")
    if not file then
        notify("Не удалось прочитать " .. tostring(path) .. ": " .. tostring(read_err))
        return nil, read_err
    end
    local raw = file:read("*a")
    file:close()

    local bom = ""
    if raw:sub(1, 3) == "\239\187\191" then
        bom = raw:sub(1, 3)
        raw = raw:sub(4)
    end

    local fields = parse_frontmatter(raw)
    local new_status = fields.status == "active" and "inactive" or "active"

    local spans = line_spans(raw)
    local first = spans[1]
    if not first or raw:sub(first.start, first.content_stop) ~= "---" then
        notify("В файле нет frontmatter: " .. tostring(path))
        return nil, "frontmatter not found"
    end

    local close_at
    for index = 2, #spans do
        if raw:sub(spans[index].start, spans[index].content_stop) == "---" then
            close_at = index
            break
        end
    end
    if not close_at then
        notify("Frontmatter не закрыт: " .. tostring(path))
        return nil, "frontmatter not closed"
    end

    local status_at
    for index = 2, close_at - 1 do
        if raw:sub(spans[index].start, spans[index].content_stop):match("^%s*status%s*:") then
            status_at = index
            break
        end
    end

    local eol = raw:sub(first.content_stop + 1, first.stop)
    if eol == "" then
        eol = "\n"
    end

    local updated
    if status_at then
        local span = spans[status_at]
        updated = raw:sub(1, span.start - 1)
            .. "status: " .. new_status
            .. raw:sub(span.content_stop + 1)
    else
        local insert_at = first.next_position
        updated = raw:sub(1, insert_at - 1)
            .. "status: " .. new_status .. eol
            .. raw:sub(insert_at)
    end

    local temp_path = path .. ".memo_tmp_" .. tostring(math.random(1, 999999999))
    local temp_file, write_err = io.open(temp_path, "wb")
    if not temp_file then
        notify("Не удалось записать " .. tostring(path) .. ": " .. tostring(write_err))
        return nil, write_err
    end

    local written, write_result = temp_file:write(bom .. updated)
    local closed, close_result = temp_file:close()
    if not written or not closed then
        os.remove(temp_path)
        notify("Не удалось записать " .. tostring(path) .. ": " .. tostring(write_result or close_result))
        return nil, write_result or close_result
    end

    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        notify("Не удалось заменить " .. tostring(path) .. ": " .. tostring(rename_err))
        return nil, rename_err
    end

    return new_status
end

local function configured(opts)
    local cfg = deep_merge(defaults, opts or {})
    cfg.path = expand_home(cfg.path)
    cfg.width = tonumber(cfg.width) or 480
    cfg.padding = tonumber(cfg.padding) or 12
    if type(cfg.fonts) ~= "table" then
        cfg.fonts = {}
    end
    cfg.font = font_or(cfg.font, beautiful.font or "sans 10")
    cfg.fonts.topic = font_or(cfg.fonts.topic, cfg.font)
    cfg.fonts.memo = font_or(cfg.fonts.memo, cfg.font)
    cfg.fonts.button = font_or(cfg.fonts.button, cfg.font)
    cfg.fonts.hint = font_or(cfg.fonts.hint, cfg.font)
    cfg.colors.fg = cfg.colors.fg or beautiful.fg_normal or "#ffffff"
    cfg.colors.bg = cfg.colors.bg or beautiful.bg_normal or "#1e1e1e"
    cfg.colors.muted = cfg.colors.muted or beautiful.fg_minimize or cfg.colors.fg
    cfg.colors.border = cfg.colors.border or beautiful.border_normal or cfg.colors.fg
    cfg.colors.button = cfg.colors.button or beautiful.bg_focus or "#3a3a3a"
    cfg.colors.button_fg = cfg.colors.button_fg or beautiful.fg_focus or cfg.colors.fg
    cfg.colors.correct = cfg.colors.correct or "#2e7d32"
    cfg.colors.incorrect = cfg.colors.incorrect or "#c62828"
    return cfg
end

local function make_answer(cfg, data, on_click)
    local label = wibox.widget {
        markup = gears.string.xml_escape(data.text or ""),
        align = "center",
        valign = "center",
        wrap = "word_char",
        widget = wibox.widget.textbox,
    }
    label.font = cfg.fonts.button

    local background = wibox.container.background(label)
    background.bg = cfg.colors.button
    background.fg = cfg.colors.button_fg
    background.shape = gears.shape.rounded_rect

    local widget = wibox.container.margin(background, 8, 8, 4, 4)
    widget:buttons(gears.table.join(awful.button({}, 1, on_click)))

    return {
        widget = widget,
        background = background,
        data = data,
    }
end

local function build_ui(cfg)
    local topic = wibox.widget.textbox()
    topic.font = cfg.fonts.topic
    topic.align = "center"
    topic.valign = "center"
    topic.ellipsize = "end"
    topic.forced_width = cfg.width - 2 * cfg.padding

    local memo = wibox.widget.textbox()
    memo.font = cfg.fonts.memo
    memo.wrap = "word_char"
    memo.valign = "top"
    memo.forced_width = cfg.width - 2 * cfg.padding

    local scroll = wibox.container.scroll.vertical(memo, nil, nil, nil, false, cfg.max_text_height)
    scroll.forced_width = cfg.width - 2 * cfg.padding

    local buttons = wibox.layout.flex.horizontal()
    buttons.spacing = 6
    buttons.forced_width = cfg.width - 2 * cfg.padding

    local hint = wibox.widget.textbox()
    hint.align = "center"
    hint.font = cfg.fonts.hint
    hint.markup = '<span foreground="' .. cfg.colors.muted .. '">'
        .. gears.string.xml_escape(HINT) .. "</span>"

    local content = wibox.layout.fixed.vertical()
    content.spacing = 15
    content:add(topic)
    content:add(scroll)
    content:add(buttons)
    content:add(hint)

    local root = wibox.container.margin(content, cfg.padding, cfg.padding, cfg.padding, cfg.padding)
    root.forced_width = cfg.width

    local popup = awful.popup {
        widget = root,
        visible = false,
        ontop = true,
        placement = awful.placement.centered,
        hide_on_right_click = false,
        maximum_width = cfg.width,
        maximum_height = 600,
        bg = cfg.colors.bg,
        border_width = 1,
        border_color = cfg.colors.border,
        shape = gears.shape.rounded_rect,
    }

    return {
        popup = popup,
        topic = topic,
        memo = memo,
        scroll = scroll,
        buttons = buttons,
        hint = hint,
    }
end

local function quote_shell(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local Instance = {}
Instance.__index = Instance

function Instance:release_grab()
    if self.grabber then
        awful.keygrabber.stop(self.grabber)
        self.grabber = nil
    end
end

function Instance:grab_keys()
    self:release_grab()
    self.grabber = awful.keygrabber.run(function(_, key, event)
        return self:handle_key(key, event)
    end)
end

function Instance:handle_key(key, event)
    if event == "release" then
        return
    end
    if key == "Escape" then
        self:hide()
    elseif key == "r" then
        self:next_note()
    elseif key == "e" then
        self:open_editor()
    elseif key == "space" or key == "Space" then
        self:toggle_status()
    end
end

function Instance:load_next()
    local notes, err = M.active_notes(self.cfg.path)
    if not notes then
        self.note = nil
        self.placeholder_text = "каталог недоступен: " .. tostring(err)
        return nil
    end
    if #notes == 0 then
        self.note = nil
        self.placeholder_text = "нет активных напоминаний"
        return nil
    end

    local picked = M.pick(notes, self.current_path)
    self.note = picked
    self.current_path = picked.path
    return picked
end

function Instance:render()
    local note = self.note
    if note then
        self.ui.topic.markup = "<b>" .. gears.string.xml_escape(note.topic or "") .. "</b>"
        self.ui.memo.markup = gears.string.xml_escape(note.memo or "")
    else
        self.ui.topic.markup = "<b>memo</b>"
        self.ui.memo.markup = gears.string.xml_escape(self.placeholder_text or "")
    end

    self.ui.buttons:reset()
    self.button_refs = {}
    if note then
        for index, data in ipairs(note.buttons or {}) do
            local ref = make_answer(self.cfg, data, function()
                self:reveal_answer(index)
            end)
            self.ui.buttons:add(ref.widget)
            self.button_refs[index] = ref
        end
    end
end

function Instance:reveal_answer(clicked)
    local has_correct = false
    for _, ref in ipairs(self.button_refs) do
        if ref.data.correct then
            has_correct = true
            break
        end
    end

    for index, ref in ipairs(self.button_refs) do
        if has_correct then
            ref.background.bg = ref.data.correct
                and self.cfg.colors.correct
                or self.cfg.colors.incorrect
        elseif index == clicked then
            ref.background.bg = self.cfg.colors.correct
        else
            ref.background.bg = self.cfg.colors.button
        end
    end
end

function Instance:next_note()
    self:load_next()
    self:render()
end

function Instance:toggle_status()
    if not self.note then
        return
    end
    local new_status = M.toggle_status(self.note.path)
    if new_status then
        self.note.status = new_status
    end
end

function Instance:present()
    local screen = awful.screen.focused()
    local workarea = screen.workarea
    local max_height = math.floor((self.cfg.max_height_ratio or 0.8) * workarea.height)

    local scroll_limit = math.max(80, max_height - 220)
    if self.cfg.max_text_height and self.cfg.max_text_height > 0 then
        scroll_limit = math.min(scroll_limit, self.cfg.max_text_height)
    end

    self.ui.popup.screen = screen
    self.ui.popup.maximum_width = self.cfg.width
    self.ui.popup.maximum_height = max_height
    self.ui.scroll.max_size = scroll_limit

    self:render()
    self.ui.popup.visible = true
    awful.placement.centered(self.ui.popup, { screen = screen, honor_workarea = true })
    self:grab_keys()
end

function Instance:show()
    self.placeholder_text = nil
    self:load_next()
    self:present()
end

function Instance:open_editor()
    local note = self.note
    if not note then
        return
    end

    local command = self.cfg.editor or rawget(_G, "editor_cmd") or "alacritty -e nvim"
    local was_visible = self.ui.popup.visible
    self:hide()

    awful.spawn.easy_async_with_shell(command .. " " .. quote_shell(note.path), function(_, _, _, exit_code)
        if exit_code and exit_code ~= 0 then
            notify("Редактор завершился с кодом " .. tostring(exit_code))
        end

        local fresh = M.read_note(note.path)
        if fresh then
            self.note = fresh
            self.current_path = note.path
        else
            self:load_next()
        end
        if was_visible then
            self:present()
        end
    end)
end

function Instance:hide()
    self.ui.popup.visible = false
    self:release_grab()
end

function M.new(opts)
    seed_random()
    local cfg = configured(opts)
    local instance = setmetatable({
        cfg = cfg,
        ui = build_ui(cfg),
        note = nil,
        current_path = nil,
        button_refs = {},
        placeholder_text = nil,
        grabber = nil,
    }, Instance)

    awesome.connect_signal("exit", function()
        instance:hide()
    end)

    return instance
end

setmetatable(M, {
    __call = function(_, opts)
        return M.new(opts)
    end,
})

return M
