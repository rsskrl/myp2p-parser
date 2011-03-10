#!/bin/sh

######################################################
# simple script which runs sopcast client in bg
# waits a few seconds and runs player (vlc, mplayer)
######################################################

PLAYER="mplayer"
OUT_PORT="55559"
IN_PORT="55558"

killall -9 sp-sc-auth sp-sc 2>/dev/null

sp-sc-auth $* ${IN_PORT} ${OUT_PORT} >/dev/null 2>/dev/null &
sleep 10 
${PLAYER} http://localhost:${OUT_PORT}/tv.asf

killall -9 sp-sc-auth sp-sc 2>/dev/null

