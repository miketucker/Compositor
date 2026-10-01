# Writing a Compositor plugin

A plugin adds brushes and dither patterns to the Brush tool. It's a folder whose name ends in `.compositorplugin`. The folder holds:

- a manifest, `plugin.json`;
- optionally a JavaScript file;
- any pictures the manifest names.

The Finder and Files show the folder as a single item. Compositor ships one, the Dither Brush, in `Plugins/Dither Brush.compositorplugin`, and it is the example to copy.

## Installing

There are two ways to install a plugin:

- In **Plugins…** (in the Edit menu on the Mac, or the File menu on iPad), choose **Install Plugin…** and pick the folder.
- Copy the folder into the Plugins folder and choose **Reload**. Compositor also reloads by itself when it comes back to the front.
  - On the Mac: the folder **Show Plugins Folder** opens, in Compositor's Application Support.
  - On iPad: Files › On My iPad › Compositor › Plugins.

The same window lists every plugin, turns each one off or on, removes added ones, and shows why a plugin didn't load.

## plugin.json

```json
{
  "id": "com.example.stipple",
  "name": "Stipple",
  "version": "1.0",
  "apiVersion": 1,
  "author": "Example",
  "description": "One line about what it adds.",
  "main": "main.js",
  "contributes": {
    "patterns": [
      { "id": "checker", "name": "Checker", "matrix": [[0, 1], [1, 0]] },
      { "id": "noise", "name": "Noise", "image": "patterns/noise.png" }
    ],
    "brushes": [
      {
        "id": "stipple", "name": "Stipple", "symbol": "circle.dotted", "ink": "pattern",
        "options": [
          { "id": "pattern", "type": "pattern", "title": "Pattern", "default": "checker", "compact": true },
          { "id": "density", "type": "slider", "title": "Density", "min": 0, "max": 100, "default": 50, "unit": "%" },
          { "id": "colors", "type": "choice", "title": "Colors", "default": "foreground",
            "choices": [{ "id": "foreground", "title": "Foreground" },
                        { "id": "foregroundToBackground", "title": "Foreground → Background" }] },
          { "id": "pressureDensity", "type": "toggle", "title": "Press Harder for Denser", "default": true, "pressure": true }
        ]
      }
    ]
  }
}
```

**Top-level fields**
- `id`: letters, digits, dots and dashes. It must be unique among installed plugins.
- `apiVersion`: must be `1`.
- `main`: optional. Every path must stay inside the folder; `..` and links that lead out of it are refused.

**Patterns** are ordered dithering matrices, as Aseprite's are, up to 64 × 64. A `matrix` gives the order its cells turn on as whole numbers, lowest first. A cell is painted once the brush's density reaches `(n + 1) / (largest + 2)`, so nothing is painted at density 0 and everything at 1. An `image` is a grayscale picture of the same thing in which brighter pixels turn on first. Patterns from every plugin appear in every pattern menu.

**Brushes** appear in the Brush tool's brush menu, next to its own Round brush.
- `ink: "pattern"` is the only ink so far. It paints crisp pixels in a pattern locked to the document's pixel grid, so strokes interlock wherever they overlap and on any layer.
- `symbol` is an SF Symbol, used in the menu and the tool rail.
- Size, Opacity, Smoothing, Paint/Erase and the colors are the Brush's own. A plugin brush adds its options after them.

**Options**
- `slider` (`min`, `max`, `unit`), `toggle`, `choice` (`choices`) and `pattern` (a menu of every pattern).
- `default` sets the starting value. A pattern default may name the plugin's own pattern without the plugin id, or another plugin's as `plugin.id/pattern`.
- `help` is the tooltip.
- `compact: true` also puts the option in Full Screen Canvas's tool bar.
- `pressure: true` groups the option under the bar's Pressure button.
- Values are remembered between launches.

## main.js

The script runs once, as the plugin loads, in JavaScriptCore. It can reach two things:

- `compositor.registerPattern({ id, name, matrix })` adds a pattern worked out in code.
- `compositor.registerBrush(id, { ink(options), dab(input, options) })` gives a brush declared in plugin.json its behavior.
  - `ink` returns `{ pattern, colors }`: the pattern's id and `"foreground"` or `"foregroundToBackground"`.
  - `dab` is called with `input.pressure` from 0 to 1 (a mouse or finger is always 1). It returns `{ density, size }`, each 0 to 1. `size` is a fraction of the brush's size.

`console.log` writes to the system log. There is no file, network or document access.

`options` holds the brush's options by id. Sliders are numbers, toggles are booleans, and choices and patterns are strings.

## How a script runs

Scripts never run while you paint. When the options change, Compositor asks `ink` once and `dab` at 256 pressures, and strokes look up the results. So `dab` must depend only on its arguments.

Each call has a deadline: 1 second to load, a quarter of a second to answer.
- A script that throws is shown in Plugins… with the line it stopped at.
- A script that runs past the deadline is given up on until Compositor is next opened. JavaScriptCore can't stop a script that keeps running, so nothing is sent to that plugin again.

Nothing about plugins is saved in projects. Strokes are ordinary pixels, so a project painted with a plugin brush opens without the plugin.
