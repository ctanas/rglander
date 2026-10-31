#!/bin/bash
# RG Lander - PortMaster launcher.
# Follows the standard PortMaster LÖVE template (love_11.5 runtime).

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR=/$directory/ports/rglander
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR"
cd "$GAMEDIR"

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

# Saves/settings go to rglander/conf; SDL gets the device's pad mapping.
export XDG_DATA_HOME="$CONFDIR"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
# Tell the game it is on the handheld: fullscreen, gamepad-first input.
export RGLANDER_DEVICE=1

RUNTIME_TXT="$controlfolder/runtimes/love_11.5/love.txt"
if [ ! -f "$RUNTIME_TXT" ]; then
  pm_message "RG Lander needs the love_11.5 runtime - install it from PortMaster first."
  sleep 5
  pm_finish
  exit 1
fi
source "$RUNTIME_TXT"

$GPTOKEYB "$LOVE_GPTK" &
pm_platform_helper "$LOVE_BINARY"
$LOVE_RUN gamedata

pm_finish
