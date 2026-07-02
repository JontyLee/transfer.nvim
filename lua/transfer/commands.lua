local M = {}

M.recent_command = nil

local function create_autocmd()
  local augroup = vim.api.nvim_create_augroup("TransferNvim", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    pattern = { "*" },
    group = augroup,
    desc = "Clear recent command after changing directory",
    callback = function()
      M.recent_command = nil
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    desc = "Upload on Save",
    callback = function(args)
      require("transfer.transfer").upload_on_save(args.file)
    end,
  })
end

--- Check if snacks.nvim is available for the picker
--- @return boolean
local function has_snacks()
  local ok, _ = pcall(require, "snacks")
  return ok
end

--- Show a picker for user to select target(s), with an "All" option.
--- When `multi = true`, multiple selections are allowed (for upload/download).
--- When `multi = false`, only one target can be selected (for diff).
--- @param targets table {name, ...}[]
--- @param opts {prompt: string, multi: boolean}
--- @param cb fun(selected_names: string[])
local function pick_targets(targets, opts, cb)
  local names = vim.tbl_map(function(t)
    return t.name
  end, targets)
  table.insert(names, 1, "All")

  local function do_select(choices)
    local selected = {}
    for _, choice in ipairs(choices) do
      if choice == "All" then
        -- return all target names
        cb(vim.tbl_map(function(t)
          return t.name
        end, targets))
        return
      end
      table.insert(selected, choice)
    end
    cb(selected)
  end

  if has_snacks() then
    local Snacks = require("snacks")
    Snacks.picker.select(names, {
      prompt = opts.prompt or "Select target",
      multi = opts.multi ~= false,
    }, function(choice)
      if not choice then
        return
      end
      if type(choice) == "string" then
        do_select({ choice })
      else
        do_select(choice)
      end
    end)
  else
    vim.ui.select(names, {
      prompt = opts.prompt or "Select target",
      -- multi-select via vim.ui.select isn't standard, but some backends support it
    }, function(choice)
      if not choice then
        return
      end
      do_select({ choice })
    end)
  end
end

--- Get targets filtered by selected names
--- @param targets table
--- @param selected_names string[]
--- @return table
local function filter_targets(targets, selected_names)
  local name_set = {}
  for _, name in ipairs(selected_names) do
    name_set[name] = true
  end
  local result = {}
  for _, t in ipairs(targets) do
    if name_set[t.name] then
      table.insert(result, t)
    end
  end
  return result
end

M.setup = function()
  create_autocmd()

  -- TransferInit - create a config file and open it. Just edit if it already exists
  vim.api.nvim_create_user_command("TransferInit", function()
    local config = require("transfer.config")
    local template = config.options.config_template
    if type(template) == "function" then
      template = template()
    end
    if type(template) == "string" then
      template = vim.fn.split(template, "\n")
    end
    local path = vim.loop.cwd() .. "/.nvim"
    if vim.fn.isdirectory(path) == 0 then
      vim.fn.mkdir(path)
    end
    path = path .. "/deployment.lua"
    if vim.fn.filereadable(path) == 0 then
      vim.fn.writefile(template, path)
    end
    vim.cmd("edit " .. path)
  end, { nargs = 0 })

  -- TransferRepeat - repeat the last transfer command
  vim.api.nvim_create_user_command("TransferRepeat", function()
    if M.recent_command == nil then
      vim.notify("No recent transfer command to repeat", vim.log.levels.WARN, {
        title = "Transfer.nvim",
        icon = "",
      })
      return
    end
    vim.cmd(M.recent_command)
  end, { nargs = 0 })

  -- DiffRemote - open a diff view with the remote file
  vim.api.nvim_create_user_command("DiffRemote", function(opts)
    local local_path
    if opts ~= nil and opts.args then
      local_path = opts.args
    end
    if local_path == nil or local_path == "" then
      local_path = vim.fn.expand("%:p")
    end

    local transfer = require("transfer.transfer")
    local targets = transfer.all_matching_scp_paths(local_path)
    if not targets then
      return
    end

    local function do_diff(target)
      local config = require("transfer.config")
      local orig_win = vim.api.nvim_get_current_win()

      if config.options.close_diffview_mapping ~= nil then
        vim.api.nvim_create_autocmd("BufEnter", {
          pattern = { target.scp_path },
          desc = "Add mapping to close diffview",
          once = true,
          callback = function()
            vim.keymap.set("n", config.options.close_diffview_mapping, function()
              if vim.api.nvim_win_is_valid(orig_win) then
                vim.api.nvim_win_call(orig_win, function()
                  vim.cmd("diffoff")
                end)
              end
              vim.cmd("diffoff")
              vim.cmd("bd!")
            end, { buffer = true, desc = "Close Diffview" })
          end,
        })
      end
      vim.api.nvim_command("silent! diffsplit " .. target.scp_path)
    end

    if #targets == 1 then
      do_diff(targets[1])
    else
      pick_targets(targets, { prompt = "Diff remote against", multi = false }, function(selected)
        if #selected == 0 then
          return
        end
        local picked = filter_targets(targets, selected)
        if #picked > 0 then
          do_diff(picked[1])
        end
      end)
    end
  end, { nargs = "?" })

  -- TransferUpload - upload the given file or directory
  vim.api.nvim_create_user_command("TransferUpload", function(opts)
    local path
    if opts ~= nil and opts.args then
      path = opts.args
    end
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    M.recent_command = "TransferUpload " .. path

    local transfer = require("transfer.transfer")
    local is_dir = vim.fn.isdirectory(path) == 1
    local targets

    if is_dir then
      -- For dir sync, find all matching targets via the first mapped file pattern
      -- all_matching_scp_paths works on normalized paths, so we can use the dir path
      targets = transfer.all_matching_scp_paths(path, true)
    else
      targets = transfer.all_matching_scp_paths(path)
    end
    if not targets then
      return
    end

    local function do_upload(selected)
      local picked = filter_targets(targets, selected)

      if #picked == 0 then
        return
      end

      local function next_upload(idx)
        if idx > #picked then
          return
        end
        local t = picked[idx]
        if is_dir then
          transfer.sync_dir_to_target(path, true, t, function()
            vim.schedule(function()
              next_upload(idx + 1)
            end)
          end)
        else
          transfer.upload_file_to_target(path, t, function()
            vim.schedule(function()
              next_upload(idx + 1)
            end)
          end)
        end
      end

      next_upload(1)
    end

    if #targets == 1 then
      do_upload({ targets[1].name })
    else
      pick_targets(targets, { prompt = "Upload to", multi = true }, do_upload)
    end
  end, { nargs = "?" })

  -- TransferDownload - download the given file or directory
  vim.api.nvim_create_user_command("TransferDownload", function(opts)
    local path
    if opts ~= nil and opts.args then
      path = opts.args
    end
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    M.recent_command = "TransferDownload " .. path

    local transfer = require("transfer.transfer")
    local targets = transfer.all_matching_scp_paths(path)
    if not targets then
      return
    end

    local function do_download(selected)
      local picked = filter_targets(targets, selected)
      if #picked == 0 then
        return
      end
      local function next_download(idx)
        if idx > #picked then
          return
        end
        local t = picked[idx]
        transfer.download_file_from_target(path, t, function()
          vim.schedule(function()
            next_download(idx + 1)
          end)
        end)
      end
      next_download(1)
    end

    if #targets == 1 then
      do_download({ targets[1].name })
    else
      pick_targets(targets, { prompt = "Download from", multi = true }, do_download)
    end
  end, { nargs = "?" })

  -- TransferDirDiff - show changed files between local and remote directory
  vim.api.nvim_create_user_command("TransferDirDiff", function(opts)
    local path
    if opts ~= nil and opts.args then
      path = opts.args
    end
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    M.recent_command = "TransferDirDiff " .. path

    local transfer = require("transfer.transfer")
    -- DirDiff only makes sense against one target
    local targets = transfer.all_matching_scp_paths(path, true)
    if not targets then
      return
    end

    local function do_dir_diff(selected)
      local picked = filter_targets(targets, selected)
      if #picked == 0 then
        return
      end
      transfer.show_dir_diff_to_target(path, picked[1])
    end

    if #targets == 1 then
      do_dir_diff({ targets[1].name })
    else
      pick_targets(targets, { prompt = "Dir Diff against", multi = false }, do_dir_diff)
    end
  end, { nargs = "?" })
end

return M