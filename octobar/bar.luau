--!nonstrict
-- Bar [[widget]] entry: glyph + open-PR count, plus a bell with the unseen
-- activity count and the commits tracked branches are behind, fed entirely by
-- the fetch service through shared state. A failed fetch adds a red "!" next
-- to the count. The bell is red for change requests or CI failures, tertiary
-- for review requests. The tooltip summarizes all of it.
-- Clicking anywhere on the capsule toggles the panel —
-- which is why the tree deliberately contains no inline ui.button (inline
-- controls would consume their own clicks).

local PANEL_ID = "sn4pe/octobar:panel"

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"
local activity = noctalia.state.get("activity") or {}
local branches = noctalia.state.get("branches") or {}

local function countText()
  if counts ~= nil then
    return tostring(counts.total)
  end
  if fetchStatus == "error" then
    return "!"
  end
  return "…"
end

local MAX_TOOLTIP_ACTIVITY = 5

local function tooltipLines()
  local tr = noctalia.tr
  local lines = {}
  if fetchStatus == "error" then
    table.insert(lines, tr("bar.error"))
  end
  if counts ~= nil then
    local parts = {}
    for _, key in ipairs({ "requested", "changes_requested", "failing", "approved" }) do
      if (counts[key] or 0) > 0 then
        table.insert(parts, tr("bar." .. key, { count = counts[key] }))
      end
    end
    local summary = tr("bar.prs", { count = counts.total })
    table.insert(lines, #parts > 0 and `{summary}: {table.concat(parts, ", ")}` or summary)
  end
  for i, entry in ipairs(activity) do
    if i > MAX_TOOLTIP_ACTIVITY then
      table.insert(lines, tr("panel.more_rows", { count = #activity - MAX_TOOLTIP_ACTIVITY }))
      break
    end
    table.insert(lines, `{entry.repo}#{entry.number}: ` .. tr("activity." .. entry.kind, { actor = entry.actor }))
  end
  for _, b in ipairs(branches) do
    if b.behind > 0 then
      table.insert(lines, tr("develop.line", { repo = b.repo, branch = b.branch, count = b.behind }))
    end
  end
  return lines
end

local function render()
  local behind = 0
  for _, b in ipairs(branches) do
    if b.behind > 0 then
      behind += b.behind
    end
  end

  local hideWhenZero = noctalia.getConfig("hide_when_zero") == true
  if hideWhenZero and fetchStatus == "ok" and counts ~= nil and counts.total == 0 and #activity == 0 and behind == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "git-pull-request"
  end
  local isVertical = barWidget.isVertical()
  local container = isVertical and ui.column or ui.row
  local layout = { gap = 4, align = "center" }
  if isVertical then
    layout.paddingV = 4
  else
    layout.paddingH = 4
  end
  local children = {
    ui.glyph({ name = glyph, size = 16, color = "on_surface" }),
    ui.label({ text = countText(), color = "on_surface" }),
  }
  if fetchStatus == "error" and counts ~= nil then
    table.insert(children, ui.label({ text = "!", fontWeight = "bold", color = "error" }))
  end
  if #activity > 0 then
    local bellColor = "primary"
    for _, entry in ipairs(activity) do
      if entry.kind == "changes" or entry.kind == "ci_failed" then
        bellColor = "error"
        break
      elseif entry.kind == "review_requested" then
        bellColor = "tertiary"
      end
    end
    table.insert(children, ui.glyph({ name = "bell", size = 16, color = bellColor }))
    table.insert(children, ui.label({ text = tostring(#activity), color = bellColor }))
  end
  if behind > 0 then
    table.insert(children, ui.glyph({ name = "git-branch", size = 16, color = "on_surface" }))
    table.insert(children, ui.label({ text = "+" .. tostring(behind), color = "on_surface" }))
  end
  barWidget.render(container(layout, children))
  barWidget.setTooltip(table.concat(tooltipLines(), "\n"))
end

-- fetch_status is published last by the service, so one watcher on it sees a
-- consistent prs/counts snapshot; the counts watcher covers same-status updates.
noctalia.state.watch("counts", function(value)
  counts = value
  render()
end)

noctalia.state.watch("activity", function(value)
  activity = value or {}
  render()
end)

noctalia.state.watch("branches", function(value)
  branches = value or {}
  render()
end)

noctalia.state.watch("fetch_status", function(value)
  fetchStatus = value
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
