# RNDX for Atomic
This repository is a port of [RNDX](https://github.com/srlion/rndx) to the Atomic Framework.

## Installation
Download the [latest version](https://github.com/TeamMeadows/rndx-atomic/releases/latest) and extract it to the `addons` folder

## Example of usage
```lua
---@class YoursPackage: Atomic.Package
local package = current()
local config = self:getConfiguration()
local rounding = config:get("rounding")

local RNDX = package:getDependency("dev.srlion.rndx")
---@cast RNDX RNDX

local someColor = Color(170, 55, 127)
package:listen(function(self)
  local w, h = ScrW(), ScrH()
  local boxW, boxH = w/2, h/2

  RNDX:draw(rounding, w/2-boxW/2, h/2-boxH/2, boxW, boxH, someColor)
end, "HUDPaint")
```