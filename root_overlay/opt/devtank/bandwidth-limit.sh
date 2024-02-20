#!/bin/bash

for interface in $(ifconfig | awk '/veth/ { print $1 }' | tr -d :); do
	wondershaper "$interface" 102400 102400
done
