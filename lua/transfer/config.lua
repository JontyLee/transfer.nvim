local M = {}

M.defaults = {
  -- deployment config template: can be a string, a function or a table of lines
  config_template = [[
return {
  ["server1"] = {
    host = "server1",
    mappings = {
      {
        ["local"] = "domains/example.com",
        ["remote"] = "/var/www/example.com",
      },
    },
    -- excludedPaths = {
    --   "src", -- local path relative to project root
    -- },
  },
}
]],
  close_diffview_mapping = "<leader>b", -- buffer related mapping to close diffview, set to nil to disable mapping
  upload_rsync_params = { -- a table of strings or functions
    "-rlzi",
    "--delete",
    "--checksum",
    "--exclude",
    ".git",
    "--exclude",
    ".idea",
    "--exclude",
    ".DS_Store",
    "--exclude",
    ".nvim",
    "--exclude",
    "*.pyc",
  },
  download_rsync_params = { -- a table of strings or functions
    "-rlzi",
    "--delete",
    "--checksum",
    "--exclude",
    ".git",
    "--exclude",
    ".nvim",
  },
  -- Watch for external file changes (modified outside nvim) and auto-upload
  -- to targets that have upload_on_save = true. Uses a periodic scan (find -mmin).
  watch_external_changes = false,
  watch_scan_interval_sec = 2,
  watch_max_age_sec = 4,
  -- Global excluded paths merged with each deployment's excludedPaths.
  -- Applied to single-file uploads, downloads and rsync dir transfers.
  excludedPaths = {},
  -- Suppress watcher uploads for N seconds after a git lock file (e.g.
  -- .git/index.lock) is detected, to avoid mass uploads on branch switches.
  -- 0 disables this protection.
  watch_git_pause_sec = 3,
}

M.options = {}

M.setup = function(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
