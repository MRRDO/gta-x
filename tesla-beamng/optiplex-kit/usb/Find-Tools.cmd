@echo off
rem For the Windows Setup screen itself: press Shift+F10 for a command prompt, then type  Find-Tools.cmd  after
rem changing to the USB drive, or run:  for %d in (D E F G H I J K) do @if exist %d:\Find-Tools.cmd %d:\Find-Tools.cmd
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist %%d:\OptiPlexTools\README_FIRST.txt (
    echo Found the tools on %%d:
    dir %%d:\OptiPlexTools
    notepad %%d:\OptiPlexTools\README_FIRST.txt
    goto :eof
  )
)
echo OptiPlexTools not found on any drive.
