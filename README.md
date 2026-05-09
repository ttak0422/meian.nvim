<h1 align="center">
    meian.nvim
</h1>

<p align="center">
  Reflect macOS Light / Dark Mode changes into running Neovim instances in real time.
</p>

## Overview

`meian.nvim` ships with a small Swift watcher that subscribes to the system's `AppleInterfaceThemeChangedNotification`.
When the appearance changes, the watcher pushes the new mode (`light` or `dark`) into every running Neovim by calling `nvim --server <socket> --remote-send`,
which invokes `require('meian').apply(<mode>)` inside each instance.

A single watcher process is shared across all Neovim instances via `flock(2)` on a lock file.

## Requirements

- macOS
- Neovim 0.10+

## Install

```nix
{
  inputs.meian-nvim.url = "github:ttak0422/meian.nvim";

  # ...
  programs.neovim.plugins = [
    {
      plugin = inputs.meian-nvim.packages.${pkgs.system}.default;
      type = "lua";
      config = ''
        require("meian").setup({
          on_change = function(mode)
            vim.cmd.colorscheme(mode == "dark" and "habamax" or "default")
          end,
        })
      '';
    }
  ];
}
```

## Configuration

```lua
require("meian").setup({
  -- Apply the current mode immediately on startup. (default: true)
  apply_initial = true,

  -- Called after every mode switch. Set the colorscheme here.
  on_change = function(mode) -- "light" | "dark"
    vim.cmd.colorscheme(mode == "dark" and "habamax" or "default")
  end,

  -- Disable the plugin (also disabled automatically on non-macOS).
  enabled = true,
})
```

`vim.o.background` is set automatically before `on_change` is called, so themes that consult `&background` will already see the new value.

## API

| function                       | description                                              |
| ------------------------------ | -------------------------------------------------------- |
| `require('meian').apply(mode)` | Apply `"light"` or `"dark"` (called by the watcher).     |
| `require('meian').refresh()`   | Read the current system appearance and apply it.         |
| `require('meian').current()`   | Return `"light"` or `"dark"` for the current OS setting. |

User commands:

- `:MeianApply` — re-detect the system mode and apply.
- `:MeianApply light` / `:MeianApply dark` — apply explicitly.

## How it works

```
                                    ┌───────────────────────┐
  AppleInterfaceThemeChanged ─────▶ │   meian-watcher       │
                                    │   (singleton, flock)  │
                                    └──────────┬────────────┘
                                               │
                               reads <base-dir>/subscribers/*.json
                                               │
            ┌──────────────────────────────────┼──────────────────────────────────┐
            │                                  │                                  │
            ▼                                  ▼                                  ▼
   nvim --server $sock1 ...            nvim --server $sock2 ...            nvim --server $sockN ...
```

- Each Neovim writes `subscribers/<pid>.json` containing its `v:servername` and `v:progpath`, and removes it on `VimLeavePre`.
- The watcher acquires a non-blocking `flock` on `watch.lock`. 
  A second watcher started by another Neovim sees the lock as taken and exits immediately, leaving exactly one watcher running.
- If `nvim --remote-send` fails for a subscriber (e.g. Neovim crashed without cleanup),
  the watcher removes the stale subscriber file.
- The watcher exits after 60s without any subscribers, so it does not
  linger when no Neovim is running.

The base directory is `$XDG_RUNTIME_DIR/meian-mac-appearance` when set,
otherwise `/tmp/meian-mac-appearance`:

```
<base-dir>/
├── watch.lock                  # singleton lock, holds watcher PID
└── subscribers/
    ├── 12345.json              # { "socket": ..., "pid": ..., "nvim": ... }
    └── 67890.json
```
