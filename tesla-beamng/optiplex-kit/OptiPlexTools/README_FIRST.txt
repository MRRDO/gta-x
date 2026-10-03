OPTIPLEX TOOLS (Quentin's BeamNG + FSD machine)
================================================
Open START-HERE.cmd. It is a menu; everything asks before it changes anything.

 1  Collect facts + benchmark   read-only: GPU, VRAM, RAM channels, disk, case, connectors, speed tests
 2  Windows setup               the Windows tuning list you chose (see below)
 3  Install apps                Chrome, AnyDesk, Claude, Git, Node, Python, HWiNFO, Cloudflared, ...
 4  Install Car Mode            the Tesla bridge + app (needs the car-mode folder or your GitHub login)
 5  BeamNG settings             copy the laptop's settings (fps capped at 60), with a backup
 6  Training on / off           learns from your driving ONLY when the PC is idle and you switched it on
 8  Benchmark plan              what is done / left in the test ladder (also read BENCHMARK-PLAN.txt)

Order for the first evening: 1 -> 3 -> 4 -> 2 -> 5, then follow BENCHMARK-PLAN.txt with the game open
(menu 8 shows what is done and what is left).

What 2 does and does not do (your choices from the email)
  does:      High performance power plan, sleep/hibernate stay AVAILABLE but never trigger by themselves,
             Game Mode on, Game Bar / background recording off, list startup apps, Windows Update
             active hours and no automatic driver updates, firewall ports 8765 + 8770 (Private networks only),
             Defender exclusions for BeamNG, optional fixed 16 GB page file, BeamNG on the high-performance GPU,
             a "Car Mode" task that starts the bridge when you log in
  does NOT:  turn sleep/hibernate off, touch transparency/animations (#37), notifications/Focus assist (#38),
             make restore points (#40), set auto-login (that needs your password; do it yourself in netplwiz)
Every changed value is written to reports\tune-undo.json so it can be put back.

Windows 10 note: Windows 10 stopped getting free security updates on Oct 14, 2025. Fine for a game PC that
does not browse much; keep Chrome updated and do not read email on it.

These scripts were written without a Windows machine to test them on. They only read or ask first, but if
anything errors, copy the red text and send it to Claude.

New: menu 9 in START-HERE.cmd shows the newest specs + test results on screen and opens a ready-written email to quentincpullum@gmail.com (you press Send; no password is stored). Menu 1 does this automatically after the benchmark.
