say CC_CODEX_FIXTURE_LOAD
gamerule spawnRadius 0
gamerule doDaylightCycle false
gamerule doWeatherCycle false
time set day
setworldspawn 0 64 0
forceload add 0 0
fill -3 63 -3 3 63 3 minecraft:stone
setblock 0 64 0 computercraft:computer_command replace
data merge block 0 64 0 {On:1b}
setblock 0 65 0 computercraft:monitor_normal replace
setblock 0 64 -1 computercraft:wireless_modem_normal[facing=south] replace
setblock -1 64 0 minecraft:chest replace
setblock 1 64 0 minecraft:redstone_block replace
setblock 2 64 0 minecraft:gold_block replace
schedule function cc_codex_test:boot 1s replace
