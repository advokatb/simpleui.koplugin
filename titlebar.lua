-- titlebar.lua — Simple UI
-- Encapsulates all title-bar customisations for the FileManager and injected
-- fullscreen widgets (Collections, History, …).
--
-- TWO CONTEXTS
--   FM (FileManager):
--     apply(fm_self)        — called from patches.lua
--     restore(fm_self)      — undo all FM titlebar changes
--     reapply(fm_self)      — restore + apply
--
--   Injected widgets (Collections, History, coll_list, homescreen…):
--     applyToInjected(w)    — called from patchUIManagerShow
--     restoreInjected(w)    — undo changes on a specific injected widget
--
--   Both:
--     reapplyAll(fm, stack) — re-apply (or restore) every live widget
--
-- BUTTON PADDING NOTES (from KOReader TitleBar source)
--   left_button:  padding_left=button_padding(8), padding_right=2*icon_size(72)
--   right_button: padding_left=2*icon_size(72),   padding_right=button_padding(8)
--   We zero ALL paddings before placing, so overlap_offset[1] = icon left edge.

local _ = require("gettext")
local Config = require("config")
local M = {}

-- ---------------------------------------------------------------------------
-- Item catalogue
-- ---------------------------------------------------------------------------

M.ITEMS = {
    { id = "menu_button", label = function() return _("Menu")  end, ctx = "fm"  },
    { id = "up_button",   label = function() return _("Back")  end, ctx = "fm"  },
    { id = "title",       label = function() return _("Title") end, ctx = "fm",  no_side = true },
    { id = "inj_back",    label = function() return _("Menu")  end, ctx = "inj" },
    { id = "inj_right",   label = function() return _("Close") end, ctx = "inj" },
}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local SETTING_KEY = "simpleui_titlebar_custom"
local FM_CFG_KEY  = "simpleui_tb_fm_cfg"
local INJ_CFG_KEY = "simpleui_tb_inj_cfg"
local SIZE_KEY    = "simpleui_tb_size"

local function _visKey(id) return "simpleui_tb_item_" .. id end

local _VIS_DEFAULTS = {
    menu_button = true,
    up_button   = true,
    title       = true,
    inj_back    = true,
    inj_right   = false,
}

function M.isEnabled()   return G_reader_settings:nilOrTrue(SETTING_KEY) end
function M.setEnabled(v) G_reader_settings:saveSetting(SETTING_KEY, v)   end

function M.isItemVisible(id)
    local v = G_reader_settings:readSetting(_visKey(id))
    if v == nil then return _VIS_DEFAULTS[id] ~= false end
    return v == true
end
function M.setItemVisible(id, v) G_reader_settings:saveSetting(_visKey(id), v) end

-- Size helpers ---------------------------------------------------------------

local _SIZE_SCALE = { compact = 0.75, default = 1.0, large = 1.3 }

function M.getSizeKey()   return G_reader_settings:readSetting(SIZE_KEY) or "default" end
function M.setSizeKey(v)  G_reader_settings:saveSetting(SIZE_KEY, v) end
-- Reads settings once — callers should cache the result locally.
function M.getSizeScale() return _SIZE_SCALE[M.getSizeKey()] or 1.0 end

-- ---------------------------------------------------------------------------
-- Side config
-- ---------------------------------------------------------------------------

local _FM_DEFAULTS = {
    side        = { menu_button = "right", up_button = "left" },
    order_left  = { "up_button" },
    order_right = { "menu_button" },
}
local _INJ_DEFAULTS = {
    side        = { inj_back = "left", inj_right = "right" },
    order_left  = { "inj_back" },
    order_right = { "inj_right" },
}

-- Shallow merge of saved config onto defaults — no recursion needed because
-- the structure is only one level deep (side / order_left / order_right).
local function _loadCfg(key, defaults)
    local raw = G_reader_settings:readSetting(key)
    -- No saved config: return a fresh shallow copy of defaults.
    if type(raw) ~= "table" then
        local side = {}
        for k, v in pairs(defaults.side) do side[k] = v end
        return { side = side, order_left = defaults.order_left, order_right = defaults.order_right }
    end
    -- Merge: start from defaults, overlay saved values.
    local side = {}
    for k, v in pairs(defaults.side) do side[k] = v end
    if type(raw.side) == "table" then
        for k, v in pairs(raw.side) do side[k] = v end
    end
    return {
        side        = side,
        order_left  = (type(raw.order_left)  == "table") and raw.order_left  or defaults.order_left,
        order_right = (type(raw.order_right) == "table") and raw.order_right or defaults.order_right,
    }
end

function M.getFMConfig()      return _loadCfg(FM_CFG_KEY,  _FM_DEFAULTS)  end
function M.getInjConfig()     return _loadCfg(INJ_CFG_KEY, _INJ_DEFAULTS) end
function M.saveFMConfig(cfg)  G_reader_settings:saveSetting(FM_CFG_KEY,  cfg) end
function M.saveInjConfig(cfg) G_reader_settings:saveSetting(INJ_CFG_KEY, cfg) end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- x position for a button at slot (0-based) on a side.
local function _buttonX(side, slot, btn_w, pad, gap, sw)
    if side == "left" then
        return pad + slot * (btn_w + gap)
    else
        return sw - btn_w - pad - slot * (btn_w + gap)
    end
end

-- Slot map: order_right[1] → leftmost on screen (highest slot).
local function _buildSlotMap(order_left, order_right, visible_ids)
    local slots = {}
    local count_l = 0
    for _, id in ipairs(order_left) do
        if visible_ids[id] then
            slots[id] = { side = "left", slot = count_l }
            count_l = count_l + 1
        end
    end
    local right_vis = {}
    for _, id in ipairs(order_right) do
        if visible_ids[id] then right_vis[#right_vis + 1] = id end
    end
    local n = #right_vis
    for i, id in ipairs(right_vis) do
        slots[id] = { side = "right", slot = n - i }
    end
    return slots
end

-- Resize an IconButton to new_w × new_w and zero all tap-zone paddings.
-- Mutates btn.width, btn.height, and the underlying ImageWidget size, then
-- calls btn:update() so dimen and GestureRange reflect the new geometry.
-- pcall uses method-call form (pcall(f, self)) to avoid allocating a
-- closure per call — relevant since _resizeAndStrip runs on every apply().
local function _resizeAndStrip(btn, new_w)
    btn.width  = new_w
    btn.height = new_w
    if btn.image then
        btn.image.width  = new_w
        btn.image.height = new_w
        pcall(btn.image.free, btn.image)
        pcall(btn.image.init, btn.image)
    end
    btn.padding_left   = 0
    btn.padding_right  = 0
    btn.padding_bottom = 0
    btn:update()
end

-- Snapshot a button's current state into a plain table.
-- All button state is stored in one table per button (two fields on the
-- host widget: _titlebar_rb / _titlebar_lb) instead of 10+ separate fields.
-- opts.save_icon     — also save image.file (FM right button only)
-- opts.save_callback — also save callback/hold_callback
-- opts.save_dimen    — also save dimen reference (injected right button)
local function _snapBtn(btn, opts)
    local snap = {
        align   = btn.overlap_align,
        offset  = btn.overlap_offset,
        pad_l   = btn.padding_left,
        pad_r   = btn.padding_right,
        pad_bot = btn.padding_bottom,
        w       = btn.width,
        h       = btn.height,
    }
    if opts then
        if opts.save_icon     then snap.icon     = btn.image and btn.image.file end
        if opts.save_callback then snap.callback = btn.callback
                                    snap.hold_cb  = btn.hold_callback end
        if opts.save_dimen    then snap.dimen    = btn.dimen end
    end
    return snap
end

-- Restore a button from a snapshot produced by _snapBtn.
local function _restoreBtn(btn, snap)
    if not snap then return end
    if snap.icon and btn.image then
        btn.image.file = snap.icon
        pcall(btn.image.free, btn.image)
        pcall(btn.image.init, btn.image)
    end
    btn.overlap_align  = snap.align
    btn.overlap_offset = snap.offset
    btn.padding_left   = snap.pad_l
    btn.padding_right  = snap.pad_r
    btn.padding_bottom = snap.pad_bot
    if snap.w ~= nil then
        btn.width  = snap.w
        btn.height = snap.h
        if btn.image then
            btn.image.width  = snap.w
            btn.image.height = snap.h
            pcall(btn.image.free, btn.image)
            pcall(btn.image.init, btn.image)
        end
    end
    pcall(btn.update, btn)
    if snap.callback ~= nil then btn.callback      = snap.callback end
    if snap.hold_cb  ~= nil then btn.hold_callback = snap.hold_cb  end
    if snap.dimen    ~= nil then btn.dimen         = snap.dimen    end
end

-- Compute shared layout params from a TitleBar instance.
-- Called once per apply() — result used as locals, never stored.
local function _layoutParams(tb)
    local Screen  = require("device").screen
    local scale   = M.getSizeScale()
    local base_iw = (tb.right_button and tb.right_button.image and tb.right_button.image:getSize().w)
                 or (tb.left_button  and tb.left_button.image  and tb.left_button.image:getSize().w)
                 or Screen:scaleBySize(36)
    return {
        iw  = math.floor(base_iw * scale),
        pad = Screen:scaleBySize(18),
        gap = Screen:scaleBySize(4),
        sw  = Screen:getWidth(),
    }
end

-- ---------------------------------------------------------------------------
-- FM titlebar — apply / restore / reapply
-- ---------------------------------------------------------------------------

function M.apply(fm_self)
    if not M.isEnabled() then return end

    local tb = fm_self.title_bar
    if not tb then return end
    if fm_self._titlebar_patched then return end
    fm_self._titlebar_patched = true

    local UIManager = require("ui/uimanager")
    local lp        = _layoutParams(tb)
    local iw, pad, gap, sw = lp.iw, lp.pad, lp.gap, lp.sw

    -- Read all settings once up front — avoids repeated G_reader_settings hits.
    local show_menu  = M.isItemVisible("menu_button")
    local show_up    = M.isItemVisible("up_button")
    local show_title = M.isItemVisible("title")

    local cfg     = M.getFMConfig()
    local visible = {}
    if show_menu then visible["menu_button"] = true end
    if show_up   then visible["up_button"]   = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

    -- Right button ("menu_button") ------------------------------------------
    if tb.right_button then
        local rb = tb.right_button
        -- All state in one table — one field on fm_self instead of ten.
        fm_self._titlebar_rb = _snapBtn(rb, { save_icon = true, save_callback = true })

        -- Patch setRightIcon so our icon survives folder navigation.
        -- Capture show_menu now to avoid re-reading settings on every folder tap.
        local _icon_enabled = show_menu
        local orig_setRightIcon = tb.setRightIcon
        fm_self._titlebar_orig_setRightIcon = orig_setRightIcon
        tb.setRightIcon = function(tb_self, icon, ...)
            local result = orig_setRightIcon(tb_self, icon, ...)
            if icon == "plus" and _icon_enabled then
                if tb_self.right_button and tb_self.right_button.image then
                    tb_self.right_button.image.file = Config.ICON.ko_menu
                    pcall(tb_self.right_button.image.free, tb_self.right_button.image)
                    pcall(tb_self.right_button.image.init, tb_self.right_button.image)
                end
                UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
            end
            return result
        end

        if show_menu then
            if rb.image then
                rb.image.file = Config.ICON.ko_menu
                pcall(rb.image.free, rb.image)
                pcall(rb.image.init, rb.image)
            end
            placeBtn("menu_button", rb)
        else
            rb.overlap_align  = nil
            rb.overlap_offset = { sw + 100, 0 }
            rb.callback       = function() end
            rb.hold_callback  = function() end
        end
    end

    -- Left button ("up_button") ---------------------------------------------
    if tb.left_button then
        local lb = tb.left_button
        fm_self._titlebar_lb = _snapBtn(lb, { save_callback = true })

        if show_up then
            placeBtn("up_button", lb)

            local fc = fm_self.file_chooser
            if fc then
                local BD      = require("ui/bidi")
                local ICON_UP = BD.mirroredUILayout() and "chevron.right" or "chevron.left"

                fm_self._titlebar_orig_fc_genItemTable = fc.genItemTable

                -- fold_up_cb is built lazily the first time is_sub is true, then
                -- reused — avoids allocating a new closure on every folder change.
                local fold_up_cb
                local orig_genItemTable = fc.genItemTable
                fc.genItemTable = function(fc_self, dirs, files, path)
                    local item_table = orig_genItemTable(fc_self, dirs, files, path)
                    if not item_table then return item_table end
                    local is_sub  = false
                    local filtered = {}
                    for _, item in ipairs(item_table) do
                        if item.is_go_up or (item.text and item.text:find("\u{2B06}")) then
                            is_sub = true
                        else
                            filtered[#filtered + 1] = item
                        end
                    end
                    local tb2 = fm_self.title_bar
                    if tb2 and tb2.left_button then
                        local btn = tb2.left_button
                        if is_sub then
                            -- In a subfolder: show the back button.
                            btn:setIcon(ICON_UP)
                            if not fold_up_cb then
                                fold_up_cb = function() fc_self:onFolderUp() end
                            end
                            btn.callback      = fold_up_cb
                            btn.overlap_offset = { _buttonX(slot_map["up_button"].side, slot_map["up_button"].slot, iw, pad, gap, sw), 0 }
                        else
                            -- At root: hide the button by moving it off-screen.
                            btn.overlap_offset = { sw + 100, 0 }
                            btn.callback       = function() end
                            btn.hold_callback  = function() end
                        end
                        UIManager:setDirty(tb2.show_parent or fm_self, "ui", tb2.dimen)
                    end
                    return filtered
                end
            end
        else
            lb.overlap_align  = nil
            lb.overlap_offset = { sw + 100, 0 }
            lb.callback       = function() end
            lb.hold_callback  = function() end
        end
    end

    -- Title -----------------------------------------------------------------
    if tb.setTitle then
        fm_self._titlebar_orig_title_set = true
        tb:setTitle(show_title and _("Library") or "")
    end
end

function M.restore(fm_self)
    local tb = fm_self.title_bar
    if not tb then return end
    if not fm_self._titlebar_patched then return end

    if fm_self._titlebar_orig_setRightIcon then
        tb.setRightIcon = fm_self._titlebar_orig_setRightIcon
        fm_self._titlebar_orig_setRightIcon = nil
    end

    if tb.right_button then _restoreBtn(tb.right_button, fm_self._titlebar_rb) end
    fm_self._titlebar_rb = nil

    if tb.left_button then _restoreBtn(tb.left_button, fm_self._titlebar_lb) end
    fm_self._titlebar_lb = nil

    local fc = fm_self.file_chooser
    if fc and fm_self._titlebar_orig_fc_genItemTable then
        fc.genItemTable = fm_self._titlebar_orig_fc_genItemTable
    end
    fm_self._titlebar_orig_fc_genItemTable = nil

    if fm_self._titlebar_orig_title_set and tb.setTitle then
        tb:setTitle("")
        fm_self._titlebar_orig_title_set = nil
    end

    fm_self._titlebar_patched = nil
end

function M.reapply(fm_self)
    M.restore(fm_self)
    M.apply(fm_self)
end

-- ---------------------------------------------------------------------------
-- Injected widget titlebar — applyToInjected / restoreInjected
-- ---------------------------------------------------------------------------

function M.applyToInjected(widget)
    if not M.isEnabled() then return end

    local tb = widget.title_bar
    if not tb then return end
    if widget._titlebar_inj_patched then return end
    widget._titlebar_inj_patched = true

    local lp        = _layoutParams(tb)
    local iw, pad, gap, sw = lp.iw, lp.pad, lp.gap, lp.sw

    local show_back  = M.isItemVisible("inj_back")
    local show_right = M.isItemVisible("inj_right")

    local cfg     = M.getInjConfig()
    local visible = {}
    if show_back  then visible["inj_back"]  = true end
    if show_right then visible["inj_right"] = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

    -- Left button ("inj_back") ----------------------------------------------
    if tb.left_button then
        local lb = tb.left_button
        widget._titlebar_inj_lb = _snapBtn(lb)
        if show_back then
            placeBtn("inj_back", lb)
        else
            lb.overlap_align  = nil
            lb.overlap_offset = { sw + 100, 0 }
        end
    end

    -- Right button ("inj_right") --------------------------------------------
    if tb.right_button then
        local rb = tb.right_button
        widget._titlebar_inj_rb = _snapBtn(rb, { save_callback = true, save_dimen = true })
        if show_right then
            placeBtn("inj_right", rb)
        else
            -- Zero the dimen so the button occupies no space and receives no taps.
            -- Each widget gets its own Geom instance to avoid shared-mutation bugs.
            rb.dimen         = require("ui/geometry"):new{ w = 0, h = 0 }
            rb.callback      = function() end
            rb.hold_callback = function() end
        end
    end
end

function M.restoreInjected(widget)
    local tb = widget.title_bar
    if not tb then return end
    if not widget._titlebar_inj_patched then return end

    if tb.left_button  then _restoreBtn(tb.left_button,  widget._titlebar_inj_lb) end
    if tb.right_button then _restoreBtn(tb.right_button, widget._titlebar_inj_rb) end

    widget._titlebar_inj_lb      = nil
    widget._titlebar_inj_rb      = nil
    widget._titlebar_inj_patched = nil
end

-- ---------------------------------------------------------------------------
-- reapplyAll
-- ---------------------------------------------------------------------------

function M.reapplyAll(fm_self, window_stack)
    if fm_self then M.reapply(fm_self) end
    if type(window_stack) == "table" then
        for _, entry in ipairs(window_stack) do
            local w = entry.widget
            if w and w._titlebar_inj_patched then
                M.restoreInjected(w)
                M.applyToInjected(w)
            end
        end
    end
end

return M