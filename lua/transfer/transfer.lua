local config = require("transfer.config")

local M = {}

M._saving = {}

-- reloads the buffer after a transfer
-- refreshes the neo-tree if the buffer is a neo-tree
-- @param bufnr number
-- @return void
local function reload_buffer(bufnr)
  local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
  if filetype == "neo-tree" then
    local installed, neo_tree_command = pcall(require, "neo-tree.command")
    if installed then
      neo_tree_command.execute({ action = "refresh" })
    end
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.api.nvim_command("edit!")
    end)
  end
end

-- convert the given local absolute path to a relative project root path
-- @param absolute_path string
-- @return string
local function normalize_local_path(absolute_path)
  local cwd = vim.loop.cwd()
  local found, found_end = string.find(absolute_path, cwd, 1, true)
  if found == 1 then
    absolute_path = string.sub(absolute_path, found_end + 1)
  end
  -- remove leading slash
  return string.gsub(absolute_path, "^/", "")
end

-- check if the given path matches the given pattern
-- @param path string
-- @param pattern string
-- @return boolean
local function path_matches(path, pattern)
  pattern = string.gsub(pattern, "/$", "")
  path = string.gsub(path, "/$", "")
  local s, e = string.find(path, pattern, 1, true)
  if s ~= 1 then
    return false
  end
  if e == #path then
    return true
  end
  local next_char = string.sub(path, e + 1, e + 1)
  if next_char == "/" then
    return true
  end
  return false
end

-- get the remote path for scp
-- @param deployment table
-- @param remote_file string
-- @return string
local function build_scp_path(deployment, remote_file)
  local remote_path = "scp://"
  if deployment.username then
    remote_path = remote_path .. deployment.username .. "@"
  end
  remote_path = remote_path .. deployment.host
  remote_path = remote_path .. "/" .. remote_file
  return remote_path
end

-- build command with sshpass if needed
-- @param deployment table
-- @param command table
-- @param callback function
-- @return table
local function build_command(deployment, command, callback)
  if not deployment.password then
    callback(command)
    return
  end

  if deployment.password ~= true and type(deployment.password) ~= "string" then
    vim.notify("Password must be either a `string` or `true`", vim.log.levels.ERROR)
    callback(false)
    return
  end

  if vim.fn.executable("sshpass") ~= 1 then
    vim.notify("Password-based authentication requires `sshpass`", vim.log.levels.ERROR)
    callback(false)
    return
  end

  -- @param password string
  local function _build(password)
    local _command = { "sshpass", "-p", password }
    vim.list_extend(_command, command)
    callback(_command)
  end

  local function _prompt()
    vim.ui.input({ prompt = "Password for " .. deployment.host }, function(input)
      if not input or input == "" then
        vim.schedule(function()
          vim.notify("No password was entered, cancelling", vim.log.levels.ERROR)
          callback(false)
        end)
      else
        _build(input)
      end
    end)
  end

  if type(deployment.password) == "string" then
    _build(deployment.password)
  else
    vim.defer_fn(_prompt, 500) -- defer to ensure input gets focus
  end
end

-- get the excluded paths for the given directory
-- @param deployment table
-- @param dir string
-- @return table
function M.excluded_paths_for_dir(deployment, dir)
  local excludedPaths = {}
  if deployment and deployment.excludedPaths and #deployment.excludedPaths > 0 then
    -- remove cwd from local file path
    local local_path = normalize_local_path(dir)
    for _, excluded in pairs(deployment.excludedPaths) do
      excluded = string.gsub(excluded, "^/", "")
      if path_matches(excluded, local_path) then
        local s, e = string.find(excluded, local_path, 1, true)
        if s then
          excluded = string.sub(excluded, e + 1)
          excluded = string.gsub(excluded, "^/", "")
          table.insert(excludedPaths, excluded)
        end
      elseif not excluded:find("/") and excluded:find("*") then
        -- pattern
        table.insert(excludedPaths, excluded)
      end
    end
  end
  return excludedPaths
end

-- Collect all matching targets for a local path
-- @param local_path string
-- @param quiet? boolean
-- @return {name, scp_path, rsync_path, deployment}[] | nil
function M.all_matching_scp_paths(local_path, quiet)
  local cwd = vim.loop.cwd()
  local config_file = cwd .. "/.nvim/deployment.lua"
  if vim.fn.filereadable(config_file) ~= 1 then
    if not quiet then
      vim.notify(
        "No deployment config found in \n" .. config_file .. "\n\nRun `:TransferInit` to create it",
        vim.log.levels.WARN,
        { title = "Transfer.nvim", icon = " ", timeout = 4000 }
      )
    end
    return nil
  end
  local deployment_conf = dofile(config_file)
  local_path = normalize_local_path(local_path)

  local results = {}
  for name, deployment in pairs(deployment_conf) do
    local skip = false
    if deployment.excludedPaths ~= nil then
      for _, excluded in pairs(deployment.excludedPaths) do
        excluded = string.gsub(excluded, "^/", "")
        if path_matches(local_path, excluded) then
          skip = true
        end
      end
    end
    if not skip then
      for _, mapping in pairs(deployment.mappings) do
        local mapped = mapping["local"]
        local remote_file = nil
        if mapped == nil or mapped == "" or mapped == "/" or mapped == "." then
          if mapping["remote"] == nil or mapping["remote"] == "" or mapping["remote"] == "/" then
            remote_file = local_path
          else
            remote_file = mapping["remote"]
            if remote_file:sub(-1) ~= "/" and local_path ~= "" then
              remote_file = remote_file .. "/"
            end
            remote_file = remote_file .. local_path
          end
          local scp = build_scp_path(deployment, remote_file)
          table.insert(results, { name = name, scp_path = scp, deployment = deployment })
          break
        else
          if path_matches(local_path, mapped) then
            if local_path:sub(-1) == "/" and mapped:sub(-1) ~= "/" then
              mapped = mapped .. "/"
            end
            if local_path == mapped then
              remote_file = mapping["remote"]
            else
              remote_file = mapping["remote"] .. string.sub(local_path, #mapped + 1)
            end
            if local_path:sub(-1) == "/" and remote_file:sub(-1) ~= "/" then
              remote_file = remote_file .. "/"
            elseif local_path:sub(-1) ~= "/" and remote_file:sub(-1) == "/" then
              remote_file = remote_file:sub(1, #remote_file - 1)
            end
          end
        end
        if remote_file ~= nil then
          local scp = build_scp_path(deployment, remote_file)
          table.insert(results, { name = name, scp_path = scp, deployment = deployment })
          break
        end
      end
    end
  end
  if #results == 0 then
    if not quiet then
      vim.notify("File '" .. local_path .. "'\nis not mapped in deployment config", vim.log.levels.ERROR, {
        title = "No mappings found", icon = " ", timeout = 4000,
      })
    end
    return nil
  end
  return results
end

-- get the remote path for scp
-- @param local_path string
-- @param quiet? boolean
-- @return string, table
function M.remote_scp_path(local_path, quiet)
  local cwd = vim.loop.cwd()
  local config_file = cwd .. "/.nvim/deployment.lua"
  if vim.fn.filereadable(config_file) ~= 1 then
    if not quiet then
      vim.notify(
        "No deployment config found in \n" .. config_file .. "\n\nRun `:TransferInit` to create it",
        vim.log.levels.WARN,
        {
          title = "Transfer.nvim",
          icon = " ",
          timeout = 4000,
        }
      )
    end
    return nil, nil
  end
  local deployment_conf = dofile(config_file)
  -- remove cwd from local file path
  local_path = normalize_local_path(local_path)

  local skip_reason
  for name, deployment in pairs(deployment_conf) do
    local skip = false
    if deployment.excludedPaths ~= nil then
      for _, excluded in pairs(deployment.excludedPaths) do
        excluded = string.gsub(excluded, "^/", "")
        if path_matches(local_path, excluded) then
          skip_reason = "File is excluded from deployment\non " .. name .. " by rule: " .. excluded
          skip = true
        end
      end
    end
    if not skip then
      for _, mapping in pairs(deployment.mappings) do
        -- handle mappings like nil, "" or "/" as same thing
        local mapped = mapping["local"]
        local remote_file = nil
        if mapped == nil or mapped == "" or mapped == "/" or mapped == "." then
          if mapping["remote"] == nil or mapping["remote"] == "" or mapping["remote"] == "/" then
            remote_file = local_path
          else
            remote_file = mapping["remote"]
            if remote_file:sub(-1) ~= "/" and local_path ~= "" then
              remote_file = remote_file .. "/"
            end
            remote_file = remote_file .. local_path
          end
          return build_scp_path(deployment, remote_file), deployment
        else
          if path_matches(local_path, mapped) then
            if local_path:sub(-1) == "/" and mapped:sub(-1) ~= "/" then
              -- if local_path ends with a slash, and mapped does not, add it
              mapped = mapped .. "/"
            end
            if local_path == mapped then
              remote_file = mapping["remote"]
            else
              remote_file = mapping["remote"] .. string.sub(local_path, #mapped + 1)
            end
            -- align trailing slashes with input
            if local_path:sub(-1) == "/" and remote_file:sub(-1) ~= "/" then
              remote_file = remote_file .. "/"
            elseif local_path:sub(-1) ~= "/" and remote_file:sub(-1) == "/" then
              remote_file = remote_file:sub(1, #remote_file - 1)
            end
          end
        end
        if remote_file ~= nil then
          return build_scp_path(deployment, remote_file), deployment
        end
      end
    end
  end
  if skip_reason == nil then
    skip_reason = "File '" .. local_path .. "'\nis not mapped in deployment config"
  end
  if not quiet then
    vim.notify(skip_reason, vim.log.levels.ERROR, {
      title = "No mappings found",
      icon = " ",
      timeout = 4000,
    })
  end
  return nil, nil
end

-- get the remote path for rsync
-- @param local_path string
-- @return string
function M.remote_rsync_path(local_path)
  local remote_path, deployment = M.remote_scp_path(local_path)
  if remote_path == nil then
    return
  end
  -- remove scp:// prefix from path
  remote_path = remote_path:gsub("^scp://", "")
  -- replace only the first occurrence of / with :
  remote_path = remote_path:gsub("/", ":", 1)
  return remote_path, deployment
end

-- upload the given file on BufWritePost event
-- Upload to ALL matching targets that have upload_on_save = true
-- @param local_path string
-- @return void
function M.upload_on_save(local_path)
  if M._saving[local_path] then
    return
  end
  M._saving[local_path] = true

  local function _finished()
    M._saving[local_path] = nil
  end

  local function _upload()
    local targets = M.all_matching_scp_paths(local_path, true)
    if not targets then
      _finished()
      return
    end
    -- filter targets with upload_on_save = true
    local to_upload = {}
    for _, t in ipairs(targets) do
      if t.deployment.upload_on_save == true then
        table.insert(to_upload, t)
      end
    end
    if #to_upload == 0 then
      _finished()
      return
    end
    -- upload to each target sequentially
    local function next_upload(idx)
      if idx > #to_upload then
        _finished()
        return
      end
      M.upload_file_to_target(local_path, to_upload[idx], function()
        vim.schedule(function()
          next_upload(idx + 1)
        end)
      end)
    end
    next_upload(1)
  end

  local ok, result = pcall(_upload)
  if not ok then
    _finished()
    vim.schedule(function()
      vim.notify("Error uploading file\n" .. tostring(result), vim.log.levels.ERROR)
    end)
  end
end

-- upload the given file to the first matching target
-- @param local_path string
-- @param callback? function
-- @return void
-- core scp upload notification and job logic
-- @param local_path string (absolute)
-- @param remote_path string
-- @param deployment table
-- @param callback? function
local function do_scp_upload_body(local_path, remote_path, deployment, callback)
  build_command(deployment, { "scp", local_path, remote_path }, function(command)
    if not command then
      if callback then
        vim.schedule(callback)
      end
      return
    end

    local local_short = vim.fn.fnamemodify(local_path, ":~"):gsub(".*/", "")
    local notification = vim.notify(local_short, vim.log.levels.INFO, {
      title = "Uploading file...",
      timeout = 0,
      icon = "󱕌 ",
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_exit = function(_, code, _)
        if callback then
          vim.schedule(callback)
        end

        if code == 0 then
          vim.notify(remote_path, vim.log.levels.INFO, {
            id = notification_id,
            title = "File uploaded",
            icon = "",
            timeout = 3000,
            replace = notification_id,
          })
        else
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            title = "Error uploading file",
            timeout = 4000,
            replace = notification_id,
            icon = " ",
          })
        end
      end,
    })
  end)
end

-- upload the given file to the first matching target
-- @param local_path string
-- @param callback? function
-- @return void
function M.upload_file(local_path, callback)
  if local_path == nil then
    local_path = vim.fn.expand("%:p")
  else
    local_path = vim.fn.fnamemodify(local_path, ":p")
  end
  local remote_path, deployment = M.remote_scp_path(local_path)
  if remote_path == nil then
    if callback then
      callback()
    end
    return
  end
  do_scp_upload_body(local_path, remote_path, deployment, callback)
end

--- @param local_path string
--- @param target {name: string, scp_path: string, deployment: table}
--- @param callback? function
function M.upload_file_to_target(local_path, target, callback)
  if local_path == nil then
    local_path = vim.fn.expand("%:p")
  else
    local_path = vim.fn.fnamemodify(local_path, ":p")
  end
  do_scp_upload_body(local_path, target.scp_path, target.deployment, callback)
end

-- core scp download notification and job logic
-- @param local_path string (absolute)
-- @param remote_path string
-- @param deployment table
-- @param callback? function
local function do_scp_download_body(local_path, remote_path, deployment, callback)
  build_command(deployment, { "scp", remote_path, local_path }, function(command)
    if not command then
      if callback then
        vim.schedule(callback)
      end
      return
    end

    local local_short = vim.fn.fnamemodify(local_path, ":~"):gsub(".*/", "")
    local notification = vim.notify(local_short, vim.log.levels.INFO, {
      title = "Downloading file...",
      timeout = 0,
      icon = "󱕉 ",
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_exit = function(_, code, _)
        if callback then
          vim.schedule(callback)
        end

        if code == 0 then
          vim.notify(remote_path, vim.log.levels.INFO, {
            id = notification_id,
            title = "Remote file downloaded",
            icon = "",
            timeout = 1000,
            replace = notification_id,
          })
          -- reload buffer for the downloaded file
          local bufnr = vim.fn.bufnr(local_path)
          if bufnr ~= -1 then
            reload_buffer(bufnr)
          end
        else
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            title = "Error downloading file",
            icon = " ",
            timeout = 4000,
            replace = notification_id,
          })
        end
      end,
    })
  end)
end

--- Download file from a specific target (pre-resolved from all_matching_scp_paths)
--- @param local_path string
--- @param target {name: string, scp_path: string, deployment: table}
--- @param callback? function
function M.download_file_from_target(local_path, target, callback)
  if local_path == nil then
    local_path = vim.fn.expand("%:p")
  else
    local_path = vim.fn.fnamemodify(local_path, ":p")
  end
  do_scp_download_body(local_path, target.scp_path, target.deployment, callback)
end

-- Replace local file with remote copy
-- @param local_path string|nil
function M.download_file(local_path, callback)
  if local_path == nil then
    local_path = vim.fn.expand("%:p")
  else
    local_path = vim.fn.fnamemodify(local_path, ":p")
  end
  local remote_path, deployment = M.remote_scp_path(local_path)
  if remote_path == nil then
    if callback then
      callback()
    end
    return
  end
  do_scp_download_body(local_path, remote_path, deployment, callback)
end

-- Some rsync params can be functions
local function expand_variables(rsync_params)
  local new_params = {}
  -- if param is a function, call it, otherwise just add it
  for _, param in pairs(rsync_params) do
    if type(param) == "function" then
      local result = param()
      if type(result) == "table" then
        vim.list_extend(new_params, result)
      else
        if result ~= nil and result ~= "" then
          table.insert(new_params, result)
        end
      end
    else
      table.insert(new_params, param)
    end
  end
  return new_params
end

--- Convert an scp_path (e.g. "scp://user@host/path") to rsync path ("user@host:/path")
--- @param scp_path string
--- @return string
local function scp_path_to_rsync(scp_path)
  local rsync = scp_path:gsub("^scp://", "")
  rsync = rsync:gsub("/", ":", 1)
  return rsync
end

-- Sync local and remote directory
-- @param dir string
-- @param upload boolean
function M.sync_dir(dir, upload)
  local remote_path, deployment = M.remote_rsync_path(dir)
  if remote_path == nil then
    return
  end

  local excluded = M.excluded_paths_for_dir(deployment, dir)

  local cmd = { "rsync" }
  if upload then
    vim.list_extend(cmd, expand_variables(config.options.upload_rsync_params))
    for _, path in pairs(excluded) do
      vim.list_extend(cmd, { "--exclude", path })
    end
    vim.list_extend(cmd, { dir .. "/", remote_path .. "/" })
  else
    for _, path in pairs(excluded) do
      vim.list_extend(cmd, { "--exclude", path })
    end
    vim.list_extend(cmd, expand_variables(config.options.download_rsync_params))
    vim.list_extend(cmd, { remote_path .. "/", dir .. "/" })
  end

  build_command(deployment, cmd, function(command)
    if not command then
      return
    end

    local notification = vim.notify("rsync: " .. remote_path, vim.log.levels.INFO, {
      title = "Sync started...",
      icon = " ",
      timeout = 5000,
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local output = {}
    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_stdout = function(_, data, _)
        for _, line in pairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end,
      on_exit = function(_, code, _)
        if code ~= 0 then
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            timeout = 10000,
            title = "Error running rsync",
            icon = " ",
            replace = notification_id,
          })
          return
        end

        if not upload then
          local filetype = vim.api.nvim_buf_get_option(0, "filetype")
          if filetype == "neo-tree" then
            reload_buffer(0)
          end
          -- reload all buffers in the synced directory
          local buffers = vim.api.nvim_list_bufs()
          for _, bufnr in pairs(buffers) do
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname ~= "" and bufname:find(dir, 1, true) then
              reload_buffer(bufnr)
            end
          end
        end

        if #output == 0 then
          output = { "No differences found" }
        end
        vim.notify(table.concat(output, "\n"), vim.log.levels.INFO, {
          id = notification_id,
          timeout = 3000,
          title = "Sync completed",
          icon = " ",
          replace = notification_id,
        })
      end,
    })
  end)
end

--- Sync directory with a specific target (pre-resolved from all_matching_scp_paths)
--- @param dir string
--- @param upload boolean
--- @param target {name: string, scp_path: string, deployment: table}
--- @param callback? function
function M.sync_dir_to_target(dir, upload, target, callback)
  local rsync_path = scp_path_to_rsync(target.scp_path)
  local deployment = target.deployment
  local excluded = M.excluded_paths_for_dir(deployment, dir)

  local cmd = { "rsync" }
  if upload then
    vim.list_extend(cmd, expand_variables(config.options.upload_rsync_params))
    for _, path in pairs(excluded) do
      vim.list_extend(cmd, { "--exclude", path })
    end
    vim.list_extend(cmd, { dir .. "/", rsync_path .. "/" })
  else
    for _, path in pairs(excluded) do
      vim.list_extend(cmd, { "--exclude", path })
    end
    vim.list_extend(cmd, expand_variables(config.options.download_rsync_params))
    vim.list_extend(cmd, { rsync_path .. "/", dir .. "/" })
  end

  build_command(deployment, cmd, function(command)
    if not command then
      if callback then
        vim.schedule(callback)
      end
      return
    end

    local notification = vim.notify("rsync: " .. rsync_path, vim.log.levels.INFO, {
      title = "Sync started...",
      icon = " ",
      timeout = 5000,
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local output = {}
    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_stdout = function(_, data, _)
        for _, line in pairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end,
      on_exit = function(_, code, _)
        if callback then
          vim.schedule(callback)
        end

        if code ~= 0 then
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            timeout = 10000,
            title = "Error running rsync",
            icon = " ",
            replace = notification_id,
          })
          return
        end

        if not upload then
          local filetype = vim.api.nvim_buf_get_option(0, "filetype")
          if filetype == "neo-tree" then
            reload_buffer(0)
          end
          local buffers = vim.api.nvim_list_bufs()
          for _, bufnr in pairs(buffers) do
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname ~= "" and bufname:find(dir, 1, true) then
              reload_buffer(bufnr)
            end
          end
        end

        if #output == 0 then
          output = { "No differences found" }
        end
        vim.notify(table.concat(output, "\n"), vim.log.levels.INFO, {
          id = notification_id,
          timeout = 3000,
          title = "Sync completed",
          icon = " ",
          replace = notification_id,
        })
      end,
    })
  end)
end

function M.show_dir_diff(dir)
  local remote_path, deployment = M.remote_rsync_path(dir)
  if remote_path == nil then
    return
  end

  local excluded = M.excluded_paths_for_dir(deployment, dir)
  local cmd = { "rsync", "-rlzi", "--dry-run", "--checksum", "--delete", "--out-format=%n" }
  for _, path in pairs(excluded) do
    vim.list_extend(cmd, { "--exclude", path })
  end

  if config.options.upload_rsync_params ~= nil then
    for i, v in ipairs(config.options.upload_rsync_params) do
      if v == "--exclude" then
        if i + 1 > #config.options.upload_rsync_params then
          break
        end
        vim.list_extend(cmd, { v, config.options.upload_rsync_params[i + 1] })
      end
    end
  end
  vim.list_extend(cmd, { dir .. "/", remote_path .. "/" })

  local lines = { " " .. table.concat(cmd, " "), normalize_local_path(dir), remote_path, "------" }

  build_command(deployment, cmd, function(command)
    if not command then
      return
    end

    local notification = vim.notify("rsync -rlzi --dry-run --checksum --delete", vim.log.levels.INFO, {
      title = "Diff started...",
      icon = " ",
      timeout = 3500,
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local output = {}
    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_stdout = function(_, data, _)
        for _, line in pairs(data) do
          if line ~= "" then
            line = line:gsub("^deleting ", " ")
            table.insert(output, line)
          end
        end
      end,
      on_exit = function(_, code, _)
        if code ~= 0 then
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            timeout = 10000,
            title = "Error running rsync",
            icon = " ",
            replace = notification_id,
          })
          return
        end
        if #output == 0 then
          table.insert(lines, " No differences found")
        else
          vim.list_extend(lines, output)
        end
        -- show quickfix list
        vim.fn.setqflist({}, "r", { title = "Diff: " .. dir, lines = lines })
        vim.api.nvim_command("copen")
      end,
    })
  end)
end

--- Show dir diff against a specific target (pre-resolved from all_matching_scp_paths)
--- @param dir string
--- @param target {name: string, scp_path: string, deployment: table}
function M.show_dir_diff_to_target(dir, target)
  local rsync_path = scp_path_to_rsync(target.scp_path)
  local deployment = target.deployment
  local excluded = M.excluded_paths_for_dir(deployment, dir)
  local cmd = { "rsync", "-rlzi", "--dry-run", "--checksum", "--delete", "--out-format=%n" }
  for _, path in pairs(excluded) do
    vim.list_extend(cmd, { "--exclude", path })
  end

  if config.options.upload_rsync_params ~= nil then
    for i, v in ipairs(config.options.upload_rsync_params) do
      if v == "--exclude" then
        if i + 1 > #config.options.upload_rsync_params then
          break
        end
        vim.list_extend(cmd, { v, config.options.upload_rsync_params[i + 1] })
      end
    end
  end
  vim.list_extend(cmd, { dir .. "/", rsync_path .. "/" })

  local lines = { " " .. table.concat(cmd, " "), normalize_local_path(dir), rsync_path, "------" }

  build_command(deployment, cmd, function(command)
    if not command then
      return
    end

    local notification = vim.notify("rsync -rlzi --dry-run --checksum --delete", vim.log.levels.INFO, {
      title = "Diff started...",
      icon = " ",
      timeout = 3500,
    })
    local notification_id
    if type(notification) == "table" and notification.id then
      notification_id = notification.id
    elseif type(notification) == "number" then
      notification_id = notification
    end

    local output = {}
    local stderr = {}
    vim.fn.jobstart(command, {
      on_stderr = function(_, data, _)
        if data == nil or #data == 0 then
          return
        end
        vim.list_extend(stderr, data)
      end,
      on_stdout = function(_, data, _)
        for _, line in pairs(data) do
          if line ~= "" then
            line = line:gsub("^deleting ", " ")
            table.insert(output, line)
          end
        end
      end,
      on_exit = function(_, code, _)
        if code ~= 0 then
          vim.notify(table.concat(stderr, "\n"), vim.log.levels.ERROR, {
            id = notification_id,
            timeout = 10000,
            title = "Error running rsync",
            icon = " ",
            replace = notification_id,
          })
          return
        end
        if #output == 0 then
          table.insert(lines, " No differences found")
        else
          vim.list_extend(lines, output)
        end
        -- show quickfix list
        vim.fn.setqflist({}, "r", { title = "Diff: " .. dir, lines = lines })
        vim.api.nvim_command("copen")
      end,
    })
  end)
end

return M
