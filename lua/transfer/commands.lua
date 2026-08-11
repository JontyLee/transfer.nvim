local M = {}

M.recent_command = nil

local function create_autocmd()
  local augroup = vim.api.nvim_create_augroup("TransferNvim", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    pattern = { "*" },
    group = augroup,
    desc = "Clear recent command and session upload targets after changing directory",
    callback = function()
      M.recent_command = nil
      require("transfer.transfer").session_upload_targets = nil
      require("transfer.transfer").setup_external_watch()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "Clear session upload targets on exit",
    callback = function()
      require("transfer.transfer").session_upload_targets = nil
      require("transfer.transfer").stop_external_watch()
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


M.setup = function()
  create_autocmd()
  require("transfer.transfer").setup_external_watch()

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
      transfer.pick_targets(targets, { prompt = "Diff remote against", multi = false }, function(selected)
        if #selected == 0 then
          return
        end
        local picked = transfer.filter_targets(targets, selected)
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
      if not selected or #selected == 0 then
        return
      end
      transfer.session_upload_targets = selected
      local picked = transfer.filter_targets(targets, selected)

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
      transfer.pick_targets(targets, { prompt = "Upload to", multi = true, skip_upload = true }, do_upload)
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
      local picked = transfer.filter_targets(targets, selected)
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
      transfer.pick_targets(targets, { prompt = "Download from", multi = true }, do_download)
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
      local picked = transfer.filter_targets(targets, selected)
      if #picked == 0 then
        return
      end
      transfer.show_dir_diff_to_target(path, picked[1])
    end

    if #targets == 1 then
      do_dir_diff({ targets[1].name })
    else
      transfer.pick_targets(targets, { prompt = "Dir Diff against", multi = false }, do_dir_diff)
    end
  end, { nargs = "?" })

  -- TransferSelectTarget - manually pick the upload-on-save target for this session
  -- Once selected, subsequent saves skip the picker and use this selection.
  -- Calling this command again overrides the previous selection.
  vim.api.nvim_create_user_command("TransferSelectTarget", function()
    local transfer = require("transfer.transfer")
    local path = vim.fn.expand("%:p")
    local targets = transfer.all_matching_scp_paths(path, true)
    if not targets then
      vim.notify("No deployment targets found for current file", vim.log.levels.WARN, {
        title = "Transfer.nvim",
      })
      return
    end

    -- filter to upload_on_save targets only
    local to_upload = {}
    for _, t in ipairs(targets) do
      if t.deployment.upload_on_save == true then
        table.insert(to_upload, t)
      end
    end

    if #to_upload == 0 then
      vim.notify("No upload_on_save targets found", vim.log.levels.WARN, {
        title = "Transfer.nvim",
      })
      return
    end

    if #to_upload == 1 then
      transfer.session_upload_targets = { to_upload[1].name }
      vim.notify("Session upload target set to: " .. to_upload[1].name, vim.log.levels.INFO, {
        title = "Transfer.nvim",
      })
      return
    end

    -- Reset session selection so that pick_targets opens fresh
    transfer.session_upload_targets = nil
    transfer.pick_targets(to_upload, { prompt = "Select session upload target", multi = true }, function(selected)
      if not selected or #selected == 0 then
        return
      end
      transfer.session_upload_targets = selected
      vim.schedule(function()
        vim.notify("Session upload target(s) set to: " .. table.concat(selected, ", "), vim.log.levels.INFO, {
          title = "Transfer.nvim",
        })
      end)
    end)
  end, { nargs = 0 })
end

return M