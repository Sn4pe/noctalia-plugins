--!nonstrict
-- Bar [[widget]] entry: commits the tracked local branches are behind GitHub.
-- Hidden while every branch is up to date. Click opens the compare view of
-- the branch furthest behind.

local branches = noctalia.state.get("branches") or {}

local function render()
  local total = 0
  local worst = nil
  local lines = {}
  for _, b in ipairs(branches) do
    if b.behind > 0 then
      total += b.behind
      table.insert(lines, noctalia.tr("develop.line", { repo = b.repo, branch = b.branch, count = b.behind }))
      if worst == nil or b.behind > worst.behind then
        worst = b
      end
    end
  end
  if total == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setGlyph("git-branch")
  barWidget.setText("+" .. tostring(total))
  barWidget.setTooltip(table.concat(lines, "\n"))
end

noctalia.state.watch("branches", function(value)
  branches = value or {}
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  local worst = nil
  for _, b in ipairs(branches) do
    if b.behind > 0 and (worst == nil or b.behind > worst.behind) then
      worst = b
    end
  end
  if worst then
    noctalia.runAsync({ "xdg-open", worst.url })
  end
end
