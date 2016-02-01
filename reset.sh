#!/bin/sh

rm /tmp/*
sudo ovs-vsctl del-br br0x1
sudo ovs-vsctl del-br br0x2
sudo ip netns delete host1
sudo ip netns delete host2
sudo ip netns delete host3
sudo ip netns delete host4
