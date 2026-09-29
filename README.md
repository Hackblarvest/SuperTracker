# SuperTracker

A small quality-of-life addon for **WoW: Forever** that restores the retail **in-world quest navigation
marker**: the golden diamond that floats over your destination and shows the distance in yards.

## Why

The Forever client ships the complete retail navigation system, but the option that turns it on
(`showInGameNavigation`) is off by default and missing from the menus. SuperTracker switches it on and adds
a few conveniences around it.

## Features

- **In-world marker** for the tracked quest or map pin, with distance. Click a quest in the objective
  tracker to track it.
- **Auto-track:** when nothing is tracked (a quest was turned in or abandoned, a map pin was cleared or
  reached), the nearest quest in your quest log is tracked automatically.
- **`/way` map pins:** set a map pin from chat and navigate to it straight away.
- Settings under **Options → AddOns → SuperTracker**.

## Commands

| Command | Effect |
|---|---|
| `/supertracker` | open the settings |
| `/supertracker on` / `off` / `toggle` | turn the in-world marker on or off |
| `/way 42.5 66.6` | map pin at 42.5, 66.6 on your current map, and track it |
| `/way 1429 42.5 66.6 Gryan` | map pin on a given map ID, with an optional note |
| `/way clear` | remove the map pin |

If TomTom is installed, `/way` is left to TomTom; `/stway` always works.

## Installation

Copy the `SuperTracker` folder into `World of Warcraft\_classic_beta_\Interface\AddOns` and log in from
character select.

## License

MIT. See [LICENSE](LICENSE).
