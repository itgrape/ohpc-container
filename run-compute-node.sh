#!/bin/bash

# Which node
read -p "Please enter compute node order: " order


echo "=== Start compute-node-$order"
docker run -d --rm \
    --add-host=ipa.example.com:10.10.110.201 \
    --add-host=head.example.com:10.10.110.201 \
    --add-host=compute-0.example.com:10.10.110.202 \
    --add-host=compute-1.example.com:10.10.110.203 \
    --add-host=compute-2.example.com:10.10.110.41 \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    --net=host \
    --name=compute-$order --hostname=compute-$order.example.com \
    --gpus all \
    ohpc-container/compute

# test
docker exec -it compute-$order /bin/bash
