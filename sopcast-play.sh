#!/bin/sh

######################################################
# simple script which runs sopcast client in bg
# waits a few seconds and runs player (vlc, mplayer)
######################################################

killall -9 sp-sc-auth
sp-sc-auth $* 55558 55559 >/dev/null 2>/dev/null &
sleep 3
mplayer http://localhost:55559/tv.asf
killall -9 sp-sc-auth
