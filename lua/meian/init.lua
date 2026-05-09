local M = {}

local default_config = {
  on_change = nil,
  apply_initial = true,
  watcher_path = nil,
  enabled = true,
}

local config = vim.deepcopy(default_config)
local base_dir = (vim.env.XDG_RUNTIME_DIR or "/tmp") .. "/meian-mac-appearance"
local subscriber_file = nil

-- Populated by build-time substitution (e.g. the Nix flake).
local bundled_watcher_path = nil

local function ensure_servername()
  local name = vim.v.servername
  if not name or name == "" then
    name = vim.fn.serverstart()
  end
  return name
end

local function detect_appearance()
  local out = vim.fn.system({ "defaults", "read", "-g", "AppleInterfaceStyle" })
  if vim.v.shell_error == 0 and out:lower():find("dark") then
    return "dark"
  end
  return "light"
end

local function subscriber_path()
  return string.format("%s/subscribers/%d.json", base_dir, vim.fn.getpid())
end

local function register_subscriber()
  local servername = ensure_servername()
  if not servername or servername == "" then
    return nil, "could not start nvim server"
  end

  vim.fn.mkdir(base_dir .. "/subscribers", "p")

  local path = subscriber_path()
  local body = vim.json.encode({
    socket = servername,
    pid = vim.fn.getpid(),
    nvim = vim.v.progpath,
  })

  local f, err = io.open(path, "w")
  if not f then
    return nil, "could not write subscriber file: " .. (err or "?")
  end
  f:write(body)
  f:close()

  return path
end

local function unregister_subscriber()
  if subscriber_file then
    os.remove(subscriber_file)
    subscriber_file = nil
  end
end

local function spawn_watcher()
  local path = config.watcher_path
      or bundled_watcher_path
      or vim.api.nvim_get_runtime_file("bin/meian-watcher", false)[1]
  if not path or vim.fn.executable(path) ~= 1 then
    vim.notify("meian: watcher binary not found. Run `make` in the plugin directory.", vim.log.levels.WARN)
    return
  end
  vim.fn.jobstart({ path, "--base-dir", base_dir }, { detach = true })
end

function M.apply(mode)
  if mode ~= "dark" and mode ~= "light" then
    return
  end
  vim.o.background = mode
  if config.on_change then
    pcall(config.on_change, mode)
  end
end

function M.current()
  return detect_appearance()
end

function M.refresh()
  M.apply(detect_appearance())
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", default_config, opts or {})

  if not config.enabled then
    return
  end

  local _, err = register_subscriber()
  if err then
    vim.notify("meian: " .. err, vim.log.levels.WARN)
    return
  end
  subscriber_file = subscriber_path()

  spawn_watcher()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("meian", { clear = true }),
    callback = unregister_subscriber,
  })

  if config.apply_initial then
    if vim.v.vim_did_enter == 1 then
      M.apply(detect_appearance())
    else
      vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
          M.apply(detect_appearance())
        end,
      })
    end
  end

  vim.api.nvim_create_user_command("MeianApply", function(cmd)
    if cmd.args == "" then
      M.refresh()
    else
      M.apply(cmd.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "light", "dark" }
    end,
  })
end

return M
